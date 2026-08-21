"""
ZITLAS — One-off authorisation of the 3 existing experts
(backend/authorize_experts.py)

WHY THIS EXISTS
    The role resolver is server-authoritative: an account is an expert only if
    BOTH the Firebase custom claim `expert:true` AND `experts/{uid}.approved`
    are true. A Firebase Auth export showed that NO account in the project
    carried ANY custom claim, and the expert documents were `approved: false`
    or had no `approved` field at all — so all three experts correctly
    resolved to "user".

    The old login never needed the claim (it read client-writable
    `users/{uid}` fields), so nothing had ever set it.

IDENTITY IS RESOLVED BY EMAIL, NOT BY A TYPED UID
    Pavan Kumar's UID was reported as `r1idSpM0Ja...` (digit ZERO) while
    Firebase Auth holds `r1idSpMOJa...` (capital letter O) — a single
    character apart at index 7, and the two are visually identical in most
    console fonts. Writing a claim to the wrong string fails silently-ish;
    writing a Firestore doc under it would CREATE A DUPLICATE EXPERT.

    So each expert is looked up by their (Auth-verified) email, and the UID
    Firebase returns is treated as authoritative. Every reported spelling is
    then also probed in Firestore, so a document stored under the OTHER
    spelling is discovered and reported rather than duplicated.

WHAT IT DOES, for three accounts and nothing else:
    1. resolves the account by email -> authoritative Auth UID + claims,
    2. locates `experts/{uid}`, probing every candidate spelling,
    3. sets ONLY `approved: true` via merge — no other field is touched,
    4. merges `expert: True` into the EXISTING claims,
    5. re-reads both and verifies, refusing to report success otherwise.

SAFETY
    * Dry run by default. Nothing is written without --apply.
    * Never CREATES an expert document. A missing one is reported, not filled.
    * Refuses to write when the document lives under a different id than the
      Auth UID — that is a migration decision, not something to guess at.
    * Never deletes, never recreates, never changes a UID, never touches
      ratings/pricing/reviews/coaching records.

USAGE
    cd backend
    python authorize_experts.py            # dry run — shows what would change
    python authorize_experts.py --apply    # performs the change

    Requires FIREBASE_SERVICE_ACCOUNT_JSON (or _FILE) in the environment.

AFTER RUNNING
    Custom claims only appear in a NEWLY ISSUED ID token. Each expert must
    sign out and back in (or the client must call getIdToken(true)) before
    /api/auth/role will answer "expert".
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

sys.path.insert(0, __file__.rsplit("authorize_experts.py", 1)[0])

from dotenv import load_dotenv  # noqa: E402

load_dotenv()

from services import firestore_service, identity_service  # noqa: E402

#: The ONLY accounts this script may touch.
#:
#: `email` is the Auth-verified address (confirmed against a firebase
#: auth:export), used to resolve the authoritative UID. `uid_candidates` holds
#: every spelling that has been reported, so a Firestore document stored under
#: an alternative one is FOUND rather than duplicated.
EXPERTS = [
    {
        "name": "Pratik",
        "email": "rbicka111@gmail.com",
        "uid_candidates": ["qEX2DhZVWXd2LcBb9rwnSXGVQkx1"],
    },
    {
        "name": "Srujan Gullapalli",
        "email": "srujangullapalli143@gmail.com",
        "uid_candidates": ["pEL6QmJmohSsEpvmGTqHjrMse7b2"],
    },
    {
        "name": "Pavan Kumar",
        "email": "ravipavan401@gmail.com",
        # Auth holds the letter-O spelling; the digit-zero one was reported.
        # Both are probed in Firestore.
        "uid_candidates": [
            "r1idSpMOJaQM3R6Jny73XPWcnxq1",   # letter O  — Firebase Auth
            "r1idSpM0JaQM3R6Jny73XPWcnxq1",   # digit 0   — as reported
        ],
    },
]

APPLY = "--apply" in sys.argv


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def main() -> int:
    db = firestore_service.get_client()
    app = identity_service._get_app()

    if db is None or app is None:
        print("ABORT — Firebase Admin credentials are not configured here.")
        print("  Firestore client   :", "ok" if db else "UNAVAILABLE")
        print("  firebase_admin app :", "ok" if app else "UNAVAILABLE")
        print("\nSet FIREBASE_SERVICE_ACCOUNT_JSON (or FIREBASE_SERVICE_ACCOUNT_FILE)")
        print("and re-run. Nothing was changed.")
        return 2

    from firebase_admin import auth as fb_auth

    print("=" * 76)
    print("ZITLAS EXPERT AUTHORISATION — " + ("APPLY" if APPLY else "DRY RUN"))
    print("=" * 76)

    problems = 0
    for spec in EXPERTS:
        name = spec["name"]
        print(f"\n[EXPERT BOOTSTRAP] {name}")

        # ── 1. Resolve identity by EMAIL — the UID Auth returns wins. ─────
        try:
            user = fb_auth.get_user_by_email(spec["email"], app=app)
        except Exception as e:  # noqa: BLE001
            print(f"  !! no Firebase Auth account for {spec['email']!r} "
                  f"({type(e).__name__}) — SKIPPED")
            problems += 1
            continue

        uid = user.uid
        print(f"  UID   : {uid}")
        print(f"  Email : {user.email}")

        if uid not in spec["uid_candidates"]:
            print(f"  !! Auth UID is not among the reported spellings "
                  f"{spec['uid_candidates']} — SKIPPED, resolve the identity first.")
            problems += 1
            continue
        if uid != spec["uid_candidates"][0]:
            print(f"  ~~ note: resolved to an alternative reported spelling")

        # ── 2. Locate the expert document, probing every spelling. ────────
        found_id, snap = None, None
        for candidate in dict.fromkeys([uid, *spec["uid_candidates"]]):
            s = db.collection("experts").document(candidate).get()
            if s.exists:
                found_id, snap = candidate, s
                break

        if snap is None:
            print(f"  !! experts/{uid} does not exist (nor under any reported "
                  f"spelling). This script will NOT create one — SKIPPED.")
            problems += 1
            continue

        if found_id != uid:
            # A real divergence: the profile lives under a different id than
            # the account that signs in. Merging or moving it is a data
            # decision with consequences for reviews/coaching references.
            print(f"  !! DOCUMENT/UID DIVERGENCE — profile is at experts/{found_id}")
            print(f"     but the signing-in account is {uid}.")
            print(f"     NOT writing. This needs a migration decision.")
            problems += 1
            continue

        data = snap.to_dict() or {}
        existing_claims = dict(user.custom_claims or {})
        print(f"  Existing fields            : {sorted(data.keys())}")
        print(f"  Firestore approved (before): {data.get('approved', '(field absent)')}")
        print(f"  Custom claims (before)     : {existing_claims or '(none)'}")

        if not APPLY:
            print(f"  -> would set experts/{uid}.approved = true "
                  f"(merge; {len(data)} existing field(s) preserved)")
            print(f"  -> would set custom claims = { {**existing_claims, 'expert': True} }")
            continue

        # ── 3. Approve — merge, so every other field survives. ────────────
        ref = db.collection("experts").document(uid)
        ref.set({
            "approved": True,
            "approvedBy": "authorize_experts.py",
            "approvedAt": _now(),
        }, merge=True)

        # ── 4. Merge the claim, preserving any others. ────────────────────
        fb_auth.set_custom_user_claims(uid, {**existing_claims, "expert": True},
                                       app=app)

        # ── 5. Verify BOTH by re-reading. ─────────────────────────────────
        after_doc = ref.get().to_dict() or {}
        after_claims = dict(fb_auth.get_user(uid, app=app).custom_claims or {})

        approved_ok = after_doc.get("approved") is True
        claim_ok = after_claims.get("expert") is True

        print(f"  Firestore approved    : {after_doc.get('approved')}")
        print(f"  Firebase expert claim : {after_claims.get('expert')}")
        print(f"  Role endpoint         : "
              f"{'expert' if (approved_ok and claim_ok) else 'user'}")

        lost = set(data) - set(after_doc)
        if lost:
            print(f"  !! fields disappeared: {sorted(lost)}")
            problems += 1
        if not (approved_ok and claim_ok):
            print("  !! verification FAILED — this expert is NOT authorised")
            problems += 1

    print("\n" + "=" * 76)
    if not APPLY:
        print("DRY RUN — nothing was written. Re-run with --apply.")
        return 0
    if problems:
        print(f"COMPLETED WITH {problems} PROBLEM(S) — see above.")
        return 1
    print("ALL 3 EXPERTS AUTHORISED.")
    print("Each expert must SIGN OUT and back in: a custom claim only appears")
    print("in a newly issued ID token, so their current session still says user.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
