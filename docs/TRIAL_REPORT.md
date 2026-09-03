# Trial Completion Report — implementation note

A summary an athlete sees when a Personal Coaching engagement (free trial or
paid) ends: what their plan was, what they submitted, what their coach did,
and what changed — with anything the data cannot support left explicitly
unavailable rather than guessed.

## 1. What it is

One immutable Firestore document per coaching engagement, computed once when
the engagement ends and never recomputed.

| Piece | File |
|---|---|
| Computation (pure, read-only) | `backend/services/trial_report_service.py` |
| Persistence + idempotency | `backend/services/trial_report_store.py` |
| Read API | `backend/routes/trial_report.py` |
| Mobile screen | `mobile/lib/features/trial_report/` |
| Dev preview CLI | `backend/dev_trial_report_preview.py` |

`trial_report_service.py` contains no write call of any kind — that is a
property you can verify by grepping the one file. Every write lives in
`trial_report_store.py`.

## 2. Why `requestId` is the identity

`trial_reports/{requestId}` — **not** `{athleteId}`.

`personal_coaching/{athleteId}` is keyed by athlete and **overwritten** when a
new coach is accepted (`routes/coaching.py`'s accept transaction; the same
fact `routes/expert_ratings.py::_resolve_engagement` documents). An athlete
has many engagements over time, so keying reports by athlete would let a
second trial silently destroy the first one's report.

`requestId` is the stable engagement identity — the same id `expert_ratings`
uses as its document id, for the same reason.

Because the document id *is* the engagement id, one engagement can only ever
have one report. Duplication is structurally impossible, not merely checked.

## 3. When it is generated

Attached to the **existing** coaching lifecycle. No new scheduler was added.

```
ACTIVE ENGAGEMENT
      ↓
sweep_expired_relationships()  (existing 15-min APScheduler job)
  or  POST /api/coaching/end   (athlete ends it early)
      ↓
status transition COMMITS          ← the lifecycle is now correct
      ↓
trial_report_store.generate_and_store()   ← strictly after, strictly additive
      ↓
trial_reports/{requestId} created
```

**Report generation can never block the lifecycle.** It runs only after the
transaction has committed, `generate_and_store()` does not raise, and both
call sites wrap it in a second try/except anyway. If it fails, the engagement
is still correctly `expired`/`ended` — there is just no report yet.

## 4. Why it is immutable

Three independent facts make recompute-on-read wrong, not merely slower:

1. `personal_coaching/{athleteId}` is overwritten on the next accept — the
   previous engagement's dates are then gone.
2. The AI-plan segment is only resolvable while `users/{uid}.planId` still
   matches what the coach's plan versions were seeded from. A regeneration
   invalidates it, so a report computable at completion stops being
   computable later.
3. `firestore.rules` gates the coach's read of `meal_checkins` on
   `isActiveCoachOf()`, which is false by definition once coaching ends.

So the report is frozen at completion. `GET` never recomputes and never
writes.

## 5. Retries

A failure writes **no document at all**. There is no half-written or `failed`
report to clean up, so a retry is simply the next call — the next sweep pass
picks it up automatically.

The one exception: if a document exists but is missing required fields
(`trial_report_store._REQUIRED_FIELDS`), it is treated as **malformed** and is
never silently overwritten. That state needs a human, not a retry loop, so it
is logged distinctly and the read API answers `500 report_malformed`.

## 6. How plan evolution is represented

**ZITLAS's real flow is AI-first**, and the report's wording must respect it:

```
ZITLAS AI generates the athlete's diet plan
      ↓
the Personal Coach reviews it
      ↓
the coach CUSTOMIZES that plan
      ↓
the athlete follows the resulting plan
```

The coach's editor is literally preloaded with the athlete's AI plan —
`ensureDietDraft()` in `coaching-workspace.js` calls `dietFromAiPlan()` and
banners *"Preloaded from the user's AI-generated diet plan."* A blank template
is reachable only when no AI plan exists at all.

`metrics.planEvolution` therefore carries an ordered list of **segments**,
each with `source` (`ai_generated` | `coach_customized` |
`coach_authored_from_template`), `effectiveFrom`/`effectiveTo`, the resolved
`mealsByWeekday`, and the version metadata. Plus a `wording` field
(`ai_plan_only` | `coach_customized_ai_plan` | `coach_authored_from_template`)
so no client has to invent a phrasing.

**Never say "your coach created your diet plan."** Say "your AI-generated plan
was customized by your coach", or "your coach made N modifications".

### Saves vs modifications

A plan save is **not** a modification. The workspace autosaves, and re-saving
unchanged content writes a fresh version document. Consecutive versions whose
`data` is deep-equal are collapsed, with the version immediately *before* the
engagement as the baseline. `planSaves` and `modifications` are both reported;
only `modifications` is used to claim customization happened.

## 7. Why meal expectations use elapsed 24-hour slots

A trial running `2026-03-02 09:00 → 2026-03-12 09:00` is **10 days** but
touches **11 calendar dates**. Charging both partial boundary dates a full
day of expected meals inflated the denominator ~10%, costing the athlete
about nine percentage points of follow-through for nothing they did.

So meal expectations run on `engagement_slots()`: slot 1 is `start → start+24h`,
slot 2 `+24h → +48h`, and so on. A 10-day trial is exactly 10 slots, every
check-in falls in exactly one, and numerator and denominator share one
partition so neither can inflate the other.

**Two day models exist on purpose.** `users/{uid}/activity/{date}` and
`weight_log/{date}` are documents *addressed by calendar date*, so those keep
calendar lookups. `dataQuality.dayModels` states which model each figure uses.

An engagement ended mid-day leaves a final **partial** slot. It is charged in
full — the athlete entered that day and could submit meals in it, so excluding
it from the denominator while counting its check-ins would inflate the
percentage. Prorating would require knowing which of the day's meals fell
inside the window, which is not recorded. The partial is disclosed instead.

## 8. The historical AI-plan limitation

`users/{uid}.dietPlan` holds only the **current** AI plan and is overwritten
on every regeneration. There is no archive.

But every coach plan version is stamped with the `planId` it was seeded from
(`draft.planId = athleteCtx().planId`). When the athlete's live `planId` still
equals that stamp, no regeneration has happened and the live AI plan provably
*is* the one that applied. When it differs, **the AI segment is emitted with
an empty expectation** — those days carry no meal expectation rather than a
guessed one, and `dataQuality` says so.

The current AI plan is never substituted as a historical guess.

> Worth fixing later: archive the AI plan into `versions` with `type: 'ai'` at
> engagement start, which removes this limitation entirely.

## 9. Why follow-up is unavailable

`followUp.available = false`, `reason: follow_up_completion_not_tracked`.

There is no record anywhere in ZITLAS connecting *expert recommendation →
athlete completed that recommendation*. `coaching_meal_requests.status`
records that the **expert replied**, never that the athlete acted on it.
Inventing a percentage from that would be a fabricated number an athlete
would act on. Follow-up tracking is a separate future feature.

## 10. Why the overall score is unavailable

`overall.available = false`, `reason: scoring_model_not_finalized`.

Two of its intended inputs (follow-up completion, prescribed workout
adherence) do not exist, and there is no agreed weighting for the ones that
do. Publishing a number now would freeze an arbitrary model into the first
reports ever shown, which later tuning could not retroactively correct.

## 11. Metric honesty contract

Every metric block carries `available`: `true`, `"partial"`, or `false` — with
a `reason` when false. **If the data cannot support a number, the metric is
unavailable rather than guessed.** In particular:

- no denominator → `expected_meals_unavailable`, never a default 4 meals/day;
- no expert reviews → no meal-quality percentage, and emphatically not `0`;
- workout figures are named `completionRateOfElapsedDays` with
  `prescribedComparisonAvailable: false` — they are activity, not
  prescribed-vs-completed adherence;
- weight change is signed and `weightInterpretation` is
  `not_evaluated_goal_unknown` — whether -2 kg is progress depends on a goal
  this report does not read.

UI must render unavailable metrics as an explanation, never as `0%`.

## 12. Security

`trial_reports/{requestId}` in `firestore.rules`:

- `allow write: if false` — backend-only (Admin SDK), so a client can never
  manufacture a "completed trial". Same posture as `wallet_transactions`.
- `allow read` for the `athleteId` or `coachId` named **on the report**.
  Deliberately not `isActiveCoachOf()`: the report exists because the
  engagement ended, at which point that helper is false by definition and the
  coach could never read their own completed engagement's record.

`GET /api/trial-report/{requestId}` re-checks the same pair against the stored
document, and answers **404 rather than 403** for a non-party, so engagement
ids cannot be probed.
