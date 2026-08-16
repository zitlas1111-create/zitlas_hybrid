"""
ZITLAS — Minimal in-process fake of the google-cloud-firestore surface used
by routes/coaching.py, services/coaching_service.py, and
services/coaching_sweep.py (backend/tests/fake_firestore.py).

NOT a general-purpose Firestore emulator replacement: this single-threaded
fake does not reproduce real Firestore transaction semantics (optimistic
concurrency, server-side retry-on-conflict). It DOES roll back a
transaction's own buffered writes if the wrapped function raises, which is
the one guarantee these tests actually rely on (a validation failure must
not partially apply). Same accepted tradeoff as the existing JS mock
harness used for payment-service.js in this project.

A Firestore-emulator-backed suite (FIRESTORE_EMULATOR_HOST) remains the
recommended upgrade for real concurrency coverage once the Firebase CLI +
Java are available in the dev/CI environment — neither was installed where
this test suite was first written.
"""

from __future__ import annotations


class FakeSnapshot:
    def __init__(self, doc_id, data, reference=None):
        self.id = doc_id
        self._data = data
        self.exists = data is not None
        self.reference = reference

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


def _as_filter(field=None, op=None, value=None, filter=None):
    """Accepts BOTH `where(filter=FieldFilter(f, op, v))` and the older
    positional `where(f, op, v)`.

    The real SDK still supports the positional form (deprecated, not removed)
    and production code uses both — routes/admin.py's _recompute_verified is
    positional while newer callers pass FieldFilter. A double that only
    understood one form failed tests for code that works fine in production.
    """
    if filter is not None:
        return (filter.field_path, filter.op_string, filter.value)
    if field is None or op is None:
        raise TypeError("where() requires either filter= or (field, op, value)")
    return (field, op, value)


class FakeDocRef:
    def __init__(self, store, path):
        self._store = store
        self._path = path

    def get(self, transaction=None):
        data = self._store.get(self._path)
        return FakeSnapshot(self._path, data, reference=self)

    def set(self, data, merge=False):
        if merge and self._path in self._store and self._store[self._path] is not None:
            _deep_merge(self._store[self._path], data)
        else:
            self._store[self._path] = dict(data)

    def update(self, data):
        if self._path not in self._store or self._store[self._path] is None:
            raise KeyError(f"NOT_FOUND: {self._path}")
        cur = self._store[self._path]
        for k, v in data.items():
            _set_dotted(cur, k, v)

    def delete(self):
        # Firestore's delete is idempotent — removing an absent document is a
        # no-op, not an error. Modelled faithfully so a caller that deletes
        # defensively behaves the same here as in production.
        self._store.pop(self._path, None)


def _deep_merge(dst, patch):
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_merge(dst[k], v)
        else:
            dst[k] = v


def _set_dotted(obj, dotted_key, value):
    parts = dotted_key.split(".")
    for p in parts[:-1]:
        obj = obj.setdefault(p, {})
    obj[parts[-1]] = value


class FakeQuery:
    def __init__(self, store, collection, filters, limit=None):
        self._store = store
        self._collection = collection
        self._filters = filters  # list of (field_path, op_string, value)
        self._limit = limit

    def where(self, field=None, op=None, value=None, filter=None):
        f = _as_filter(field, op, value, filter)
        return FakeQuery(self._store, self._collection, self._filters + [f], self._limit)

    def limit(self, count):
        return FakeQuery(self._store, self._collection, self._filters, count)

    def _matches(self, data) -> bool:
        for field, op, value in self._filters:
            actual = data.get(field)
            if op == "==" and actual != value:
                return False
            if op == "<=" and not (actual is not None and actual <= value):
                return False
            if op == ">=" and not (actual is not None and actual >= value):
                return False
            if op == "in" and actual not in value:
                return False
        return True

    def stream(self):
        prefix = self._collection + "/"
        emitted = 0
        for path, data in list(self._store.items()):
            if self._limit is not None and emitted >= self._limit:
                return
            if path.startswith(prefix) and data is not None and self._matches(data):
                emitted += 1
                yield FakeSnapshot(path, data, reference=FakeDocRef(self._store, path))

    def get(self, transaction=None):
        return list(self.stream())


class FakeCollection:
    def __init__(self, store, name):
        self._store = store
        self._name = name

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._name}/{doc_id}")

    def where(self, field=None, op=None, value=None, filter=None):
        return FakeQuery(self._store, self._name, []).where(field, op, value, filter=filter)

    def limit(self, count):
        return FakeQuery(self._store, self._name, [], count)


class FakeTransaction:
    def __init__(self):
        self._pending = []  # list of (kind, ref, args, kwargs)

    def get(self, ref_or_query):
        return ref_or_query.get()

    def set(self, ref, data, merge=False):
        self._pending.append(("set", ref, (data,), {"merge": merge}))

    def update(self, ref, data):
        self._pending.append(("update", ref, (data,), {}))

    def _commit(self):
        for kind, ref, args, kwargs in self._pending:
            getattr(ref, kind)(*args, **kwargs)
        self._pending = []

    def _rollback(self):
        self._pending = []


class FakeClient:
    def __init__(self):
        self.store: dict[str, dict | None] = {}

    def collection(self, name):
        return FakeCollection(self.store, name)

    def transaction(self):
        return FakeTransaction()


def fake_transactional(func):
    """Drop-in replacement for google.cloud.firestore.transactional against
    a FakeTransaction: runs the function once (no retry-on-conflict, since
    this fake has no concurrent writers to conflict with), commits its
    buffered writes on success, discards them if it raises."""
    def wrapper(transaction, *args, **kwargs):
        try:
            result = func(transaction, *args, **kwargs)
        except Exception:
            transaction._rollback()
            raise
        transaction._commit()
        return result
    return wrapper
