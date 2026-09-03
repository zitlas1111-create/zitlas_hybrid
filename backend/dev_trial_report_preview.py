"""
ZITLAS — DEVELOPMENT-ONLY trial report preview
(backend/dev_trial_report_preview.py)

THROWAWAY. Not imported by main.py, not registered as a route, not part of
the test suite, and safe to delete. Its only job is to let a developer look
at what compute_trial_report() actually returns for one real engagement
before any of it is wired into the product.

READ-ONLY, TWICE OVER: services/trial_report_service.py contains no write
call of any kind, and this script only prints what that function returns.
Nothing here creates a trial_reports document.

NO IDENTIFIERS ARE HARDCODED. The athlete uid and request id must be
supplied on the command line, so this file never carries a real user's id
into version control.

Usage (from backend/, with FIREBASE_SERVICE_ACCOUNT_JSON or _FILE set):

    python dev_trial_report_preview.py <athlete_uid> <request_id>
    python dev_trial_report_preview.py <athlete_uid> <request_id> --summary

    # Find candidate engagements to preview, without needing an id to hand:
    python dev_trial_report_preview.py --list
"""

from __future__ import annotations

import argparse
import json
import sys


def _summarise(report: dict) -> str:
    """The human-readable digest — the shape a UI would actually render."""
    period = report["period"]
    metrics = report["metrics"]
    lines = [
        "",
        "=" * 68,
        f"  TRIAL REPORT v{report['reportVersion']} — {report['engagementId']}",
        "=" * 68,
        f"  Coach          {report['coach']['name']} ({report['coach']['id']})",
        f"  Type           {period['coachingType']}   status={period['status']}",
        f"  Plan           {report['plan']['label']}   fee={report['plan']['fee']}",
        f"  Period         {period['startDate']}",
        f"                 -> {period['effectiveEndDate']}",
        f"  Duration       {period['durationDays']}d scheduled / "
        f"{period['elapsedDays']}d elapsed",
        "-" * 68,
    ]

    def row(label: str, block: dict, *keys: str) -> str:
        available = block.get("available")
        mark = {True: "OK ", "partial": "PART", False: "N/A"}.get(available, "?  ")
        detail = "  ".join(
            f"{k}={block.get(k)}" for k in keys if block.get(k) is not None)
        if available is False:
            detail = f"reason={block.get('reason')}"
        return f"  [{mark}] {label:<22} {detail}"

    lines += [
        row("Meal follow-through", metrics["mealFollowThrough"],
            "percent", "submitted", "expected", "daysActive"),
        row("Meal quality", metrics["mealQuality"],
            "percent", "averageRating", "reviewedMeals", "lowConfidence"),
        row("Expert engagement", metrics["expertEngagement"],
            "activityCount", "mealReviews", "mealResponses",
            "planModifications", "expertMessages"),
        row("Workout adherence", metrics["workoutAdherence"],
            "completedWorkoutDays", "workoutCheckins",
            "completionRateOfElapsedDays"),
        # planAdherence carries no percent by design, so its components are
        # printed instead of an empty line.
        f"  [PART] {'Plan adherence':<22} "
        + "  ".join(f"{k}={v}" for k, v
                    in metrics["planAdherence"]["components"].items())
        + f"  missing={metrics['planAdherence']['missing']}",
        row("Follow-up", metrics["followUp"], "percent"),
        row("Overall score", metrics["overall"], "percent"),
        "-" * 68,
    ]

    evolution = metrics["planEvolution"]
    lines += [
        "  PLAN EVOLUTION  (AI generates -> coach customizes -> athlete follows)",
        f"    started from   {evolution['startedFrom']}",
        f"    wording        {evolution['wording']}",
        f"    saves / mods   {evolution['planSaves']} saves, "
        f"{evolution['modifications']} real modifications "
        f"({evolution['redundantSaves']} redundant)",
    ]
    for segment in evolution["segments"]:
        monday = segment["mealsByWeekday"].get("monday")
        lines.append(
            f"    {segment['effectiveFrom'][:16]} -> "
            f"{segment['effectiveTo'][:16]}  {segment['source']:<28} "
            f"v={segment['version']}  meals/Mon={monday}")
    lines.append("-" * 68)

    progress = metrics["progress"]
    lines += [
        f"  Weight         {progress['startingWeightKg']} -> "
        f"{progress['endingWeightKg']} kg "
        f"(change={progress['weightChangeKg']}, "
        f"{progress['weightInterpretation']})",
        f"  Steps          total={progress['steps']['total']}  "
        f"avg={progress['steps']['dailyAverage']}  "
        f"days={progress['steps']['daysRecorded']}",
        f"  Sleep          avg={progress['sleep']['dailyAverageHours']}h  "
        f"days={progress['sleep']['daysRecorded']}",
        f"  Streak         current={progress['streak']['current']}  "
        f"longest={progress['streak']['longest']}",
        "-" * 68,
        "  DATA QUALITY",
    ]
    for warning in report["dataQuality"]["warnings"]:
        lines.append(f"    - {warning}")
    lines += ["=" * 68, ""]
    return "\n".join(lines)


def _list_engagements(limit: int) -> int:
    """Print rateable/finished engagements so a developer can pick one.

    Reads `personal_coaching` and prints the athlete uid + requestId pairs
    this script accepts. Read-only, like everything else here.
    """
    from services import firestore_service

    db = firestore_service.get_client()
    if db is None:
        print(f"Firestore is not configured: {firestore_service.config_error()}")
        return 2

    print(f"\n{'athleteId':<32} {'requestId':<28} {'status':<10} type")
    print("-" * 88)
    shown = 0
    for doc in db.collection("personal_coaching").limit(limit).stream():
        rel = doc.to_dict() or {}
        if not rel.get("requestId"):
            continue
        print(f"{doc.id:<32} {str(rel.get('requestId')):<28} "
              f"{str(rel.get('status')):<10} {rel.get('coachingType')}")
        shown += 1
    if not shown:
        print("(no engagements with a requestId found)")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Preview a computed trial report. Reads only; writes nothing.")
    parser.add_argument("athlete_uid", nargs="?",
                        help="the athlete's Firebase uid")
    parser.add_argument("request_id", nargs="?",
                        help="the engagement's requestId (the stable identity)")
    parser.add_argument("--summary", action="store_true",
                        help="human-readable digest instead of raw JSON")
    parser.add_argument("--list", action="store_true",
                        help="list engagements available to preview, then exit")
    parser.add_argument("--limit", type=int, default=25,
                        help="how many engagements --list should show")
    args = parser.parse_args()

    if args.list:
        return _list_engagements(args.limit)

    if not args.athlete_uid or not args.request_id:
        parser.error("athlete_uid and request_id are required "
                     "(or use --list to find one)")

    from services.trial_report_service import (
        EngagementUnavailable,
        compute_trial_report,
    )

    try:
        report = compute_trial_report(args.athlete_uid, args.request_id)
    except EngagementUnavailable as exc:
        # Expected and informative, not a crash: this is exactly what the
        # service raises when the engagement's dates have been overwritten
        # by a newer one.
        print(f"\nENGAGEMENT UNAVAILABLE\n  {exc}\n")
        return 1

    if args.summary:
        print(_summarise(report))
    else:
        print(json.dumps(report, indent=2, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
