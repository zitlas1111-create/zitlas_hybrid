"""
ZITLAS — APScheduler job boundary (backend/tests/test_scheduler_jobs.py)

Regression for a live Railway production error that fired on EVERY tick:

    File "/app/backend/main.py", line 173, in <lambda>
      lambda: asyncio.create_task(asyncio.to_thread(support_service.ingest_replies))
    RuntimeError: no running event loop
    RuntimeWarning: coroutine 'to_thread' was never awaited

AsyncIOScheduler inspects each job callable: a COROUTINE function is awaited on
the event loop, a PLAIN function is dispatched to a worker thread. The jobs were
plain lambdas, so they ran in a thread with no running loop and
`asyncio.create_task()` raised immediately — meaning the job body never executed
at all. Support ingestion, the 48h request sweep and the 30d relationship sweep
were all silently dead in production.

These tests pin the property rather than the symptom: the registered callables
must be coroutine functions, and running one the way APScheduler would must
actually invoke the underlying work exactly once.

Run: python -m pytest tests/test_scheduler_jobs.py -q
"""
from __future__ import annotations

import asyncio
import inspect
import sys
import warnings
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main  # noqa: E402

ALL_JOBS = [
    main.job_sweep_expired_requests,
    main.job_sweep_expired_relationships,
    main.job_support_reply_ingest,
]


class TestJobsAreCoroutineFunctions:
    """The single property that makes AsyncIOScheduler take the await path."""

    @pytest.mark.parametrize("job", ALL_JOBS, ids=lambda j: j.__name__)
    def test_job_is_a_coroutine_function(self, job):
        assert inspect.iscoroutinefunction(job), (
            f"{job.__name__} is not a coroutine function, so AsyncIOScheduler "
            "would run it in a worker thread with no event loop"
        )
        # APScheduler's own check, not just inspect's.
        assert asyncio.iscoroutinefunction(job)

    @pytest.mark.parametrize("job", ALL_JOBS, ids=lambda j: j.__name__)
    def test_job_is_not_a_lambda_or_partial(self, job):
        """A lambda cannot be a coroutine function, and functools.partial
        historically confused iscoroutinefunction — so neither shape may
        reappear here."""
        assert job.__name__ != "<lambda>"
        assert not isinstance(job, __import__("functools").partial)

    def test_no_job_body_calls_create_task(self):
        """THE regression. `asyncio.create_task()` inside a scheduler job is
        what raised RuntimeError; the job must `await` instead."""
        for job in ALL_JOBS:
            src = inspect.getsource(job)
            assert "create_task" not in src, (
                f"{job.__name__} calls create_task \u2014 it will raise "
                "RuntimeError: no running event loop when run off the loop"
            )
            assert "await asyncio.to_thread" in src, (
                f"{job.__name__} must await asyncio.to_thread(...) so the "
                "blocking work runs off the event loop"
            )


class TestJobsActuallyRun:
    def test_support_ingest_invokes_the_service_exactly_once(self, monkeypatch):
        calls = []
        from services import support_service
        monkeypatch.setattr(support_service, "ingest_replies", lambda: calls.append(1))

        asyncio.run(main.job_support_reply_ingest())
        assert calls == [1], "the ingestion body did not run"

    def test_request_sweep_invokes_its_service(self, monkeypatch):
        calls = []
        from services import coaching_sweep
        monkeypatch.setattr(coaching_sweep, "sweep_expired_requests", lambda: calls.append(1))
        asyncio.run(main.job_sweep_expired_requests())
        assert calls == [1]

    def test_relationship_sweep_invokes_its_service(self, monkeypatch):
        calls = []
        from services import coaching_sweep
        monkeypatch.setattr(coaching_sweep, "sweep_expired_relationships", lambda: calls.append(1))
        asyncio.run(main.job_sweep_expired_relationships())
        assert calls == [1]

    def test_no_un_awaited_coroutine_warning(self, monkeypatch):
        """The second half of the production symptom: RuntimeWarning
        'coroutine to_thread was never awaited'."""
        from services import support_service
        monkeypatch.setattr(support_service, "ingest_replies", lambda: None)

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            asyncio.run(main.job_support_reply_ingest())

        never_awaited = [
            w for w in caught
            if issubclass(w.category, RuntimeWarning) and "never awaited" in str(w.message)
        ]
        assert not never_awaited, f"un-awaited coroutine: {[str(w.message) for w in never_awaited]}"

    def test_a_failure_propagates_rather_than_being_swallowed(self, monkeypatch):
        """The scheduler must still see real errors. Fixing the async boundary
        must not turn a genuine IMAP failure into silence."""
        from services import support_service

        def _boom():
            raise RuntimeError("IMAP unreachable")

        monkeypatch.setattr(support_service, "ingest_replies", _boom)
        with pytest.raises(RuntimeError, match="IMAP unreachable"):
            asyncio.run(main.job_support_reply_ingest())


class TestTheOldPatternReallyWasBroken:
    """Demonstrates the failure mode, so the fix above is not cargo-culted."""

    def test_create_task_off_the_loop_raises_no_running_event_loop(self):
        import threading

        captured = {}

        def worker():
            # Exactly what APScheduler did with the old plain-function job.
            coro = asyncio.sleep(0)
            try:
                asyncio.create_task(coro)
            except RuntimeError as e:
                captured["error"] = str(e)
            finally:
                # Close it explicitly: leaving it un-awaited is the SECOND half
                # of the production symptom, and reproducing it here on purpose
                # should not pollute the suite output.
                coro.close()

        t = threading.Thread(target=worker)
        t.start()
        t.join()

        assert "no running event loop" in captured.get("error", ""), (
            "expected RuntimeError: no running event loop \u2014 this is the "
            "production failure the fix removes"
        )


class TestSchedulerStartsAndFiresForReal:
    """Boots the real AsyncIOScheduler with the real job callables — the
    in-CI equivalent of watching Railway's deploy logs. Catches any future
    regression in the async/sync boundary without needing a deploy."""

    def test_asyncio_scheduler_runs_the_support_job_without_exception(self, monkeypatch):
        from apscheduler.schedulers.asyncio import AsyncIOScheduler

        calls = []
        from services import support_service
        monkeypatch.setattr(support_service, "ingest_replies", lambda: calls.append(1))

        job_errors = []

        async def drive():
            sched = AsyncIOScheduler()
            sched.add_job(
                main.job_support_reply_ingest,
                "interval", seconds=1, id="support_reply_ingest",
                max_instances=1, coalesce=True,
            )

            def _listener(event):
                if getattr(event, "exception", None):
                    job_errors.append(event.exception)

            from apscheduler.events import EVENT_JOB_ERROR
            sched.add_listener(_listener, EVENT_JOB_ERROR)
            sched.start()
            # Long enough for at least one tick on a slow CI box.
            await asyncio.sleep(2.5)
            sched.shutdown(wait=False)

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            asyncio.run(drive())

        assert not job_errors, f"scheduler job raised: {job_errors}"
        assert calls, "the support job never actually executed"

        never_awaited = [
            w for w in caught
            if issubclass(w.category, RuntimeWarning) and "never awaited" in str(w.message)
        ]
        assert not never_awaited, f"un-awaited coroutine: {[str(w.message) for w in never_awaited]}"
