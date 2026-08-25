"""ZITLAS — LIVE end-to-end proof of the meal-photo flow (MANUAL, guarded).

    athlete -> Firebase Storage -> download URL -> meal_checkins.imageUrl
            -> read back by the ASSIGNED nutritionist -> image bytes fetched

Every read/write goes through the rules-enforced REST APIs with REAL Firebase
ID tokens, so this proves the DEPLOYED rules, not the text of storage.rules.
Covers all four meal types plus account isolation at both the Firestore and
Storage layers.

*** THIS WRITES TO THE LIVE PROJECT. *** It creates four throwaway auth users,
one coaching relationship, four check-in documents and four Storage objects,
then DELETES all of them (see cleanup()). It is deliberately NOT collected by
pytest and refuses to run without an explicit opt-in:

    cd backend
    ZITLAS_LIVE_VERIFY=yes python ../tests/live/verify_meal_photo_flow.py

Run it after deploying Storage rules, or whenever the rules change.
"""
import os
import sys
import urllib.parse
import uuid

import requests
from dotenv import load_dotenv


if os.environ.get("ZITLAS_LIVE_VERIFY") != "yes":
    raise SystemExit(
        "refusing to run: this script writes to the LIVE zitlas-b8677 project. "
        "Set ZITLAS_LIVE_VERIFY=yes if that is what you want.")

load_dotenv(".env")
sys.path.insert(0, ".")

from services.google_credentials import load_credentials  # noqa: E402
from services import firestore_service  # noqa: E402
from google.cloud import storage as gcs  # noqa: E402
import firebase_admin  # noqa: E402
from firebase_admin import auth as fb_auth, credentials as fb_creds  # noqa: E402

BUCKET = "zitlas-b8677.firebasestorage.app"
WEB_API_KEY = "AIzaSyAR4Q0Ldur2Y2N8iHwsAmPS4V2cWCvf_pg"
PROJECT = "zitlas-b8677"

ATHLETE = "zz_e2e_athlete_delete_me"
OTHER_ATHLETE = "zz_e2e_other_athlete_delete_me"
COACH = "zz_e2e_coach_delete_me"
OTHER_COACH = "zz_e2e_other_coach_delete_me"

MEALS = ["breakfast", "lunch", "dinner", "snack"]

JPEG_HEAD = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
                   0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
JPEG_TAIL = bytes([0xFF, 0xD9])

results = []
created_docs = []
created_objects = []


def check(name, actual, expected, detail=""):
    ok = actual == expected
    results.append((ok, name))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}  (got {actual}, expected {expected}) {detail}")


def id_token_for(uid):
    ct = fb_auth.create_custom_token(uid).decode()
    r = requests.post(
        f"https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key={WEB_API_KEY}",
        json={"token": ct, "returnSecureToken": True}, timeout=30)
    r.raise_for_status()
    return r.json()["idToken"]


def fs_get(path, token):
    """Rules-enforced Firestore REST read."""
    r = requests.get(
        f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/documents/{path}",
        headers={"Authorization": f"Bearer {token}"}, timeout=30)
    return r


def make_jpeg(tag):
    """A distinct, real JPEG per meal so we can prove the RIGHT bytes came back."""
    body = tag.encode() * 8
    return JPEG_HEAD + body + JPEG_TAIL


def main():
    creds = load_credentials(["https://www.googleapis.com/auth/devstorage.full_control"])
    gcs_client = gcs.Client(project=PROJECT, credentials=creds)
    bucket = gcs_client.bucket(BUCKET)
    db = firestore_service.get_client()

    if not firebase_admin._apps:
        import os
        firebase_admin.initialize_app(
            fb_creds.Certificate(os.environ["FIREBASE_SERVICE_ACCOUNT_FILE"]))

    t_athlete = id_token_for(ATHLETE)
    t_other_athlete = id_token_for(OTHER_ATHLETE)
    t_coach = id_token_for(COACH)
    t_other_coach = id_token_for(OTHER_COACH)

    # The coaching relationship (backend/Admin-SDK-owned, as in production).
    db.collection("personal_coaching").document(ATHLETE).set({
        "athleteId": ATHLETE, "coachId": COACH, "coachName": "Test Nutritionist",
        "status": "active", "planType": None,
    })
    created_docs.append(("personal_coaching", ATHLETE))
    print(f"seeded active coaching: {ATHLETE} -> {COACH}\n")

    urls = {}
    print("STEP 1-5 — athlete uploads a NEW photo per meal, via the rules-enforced API:")
    for meal in MEALS:
        payload = make_jpeg(meal)
        path = f"meal_checkins/{ATHLETE}/{uuid.uuid4().hex[:10]}_{meal}.jpg"
        r = requests.post(
            f"https://firebasestorage.googleapis.com/v0/b/{BUCKET}/o?name={urllib.parse.quote(path, safe='')}",
            headers={"Authorization": f"Firebase {t_athlete}", "Content-Type": "image/jpeg"},
            data=payload, timeout=45)
        ok = r.status_code == 200
        meta = r.json() if ok else {}
        created_objects.append(path)
        dl = meta.get("downloadTokens", "")
        url = (f"https://firebasestorage.googleapis.com/v0/b/{BUCKET}/o/"
               f"{urllib.parse.quote(path, safe='')}?alt=media&token={dl}")
        urls[meal] = (url, payload)
        check(f"{meal}: uploaded to Firebase Storage", r.status_code, 200,
              f"size={meta.get('size')} type={meta.get('contentType')}")

    print("\nSTEP 6 — athlete writes meal_checkins.imageUrl (rules-enforced):")
    checkin_ids = {}
    for meal in MEALS:
        cid = f"MCI_ZZTEST_{uuid.uuid4().hex[:8]}"
        checkin_ids[meal] = cid
        url, _ = urls[meal]
        r = requests.post(
            f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/"
            f"documents/meal_checkins?documentId={cid}",
            headers={"Authorization": f"Bearer {t_athlete}"},
            json={"fields": {
                "checkinId": {"stringValue": cid},
                "athleteId": {"stringValue": ATHLETE},
                "athleteName": {"stringValue": "E2E Athlete"},
                "coachId": {"stringValue": COACH},
                "day": {"stringValue": "Monday"},
                "mealType": {"stringValue": meal},
                "mealName": {"stringValue": meal.title()},
                "status": {"stringValue": "pending"},
                "imageUrl": {"stringValue": url},
                "timestamp": {"stringValue": "2026-08-25T10:00:00.000Z"},
            }}, timeout=30)
        created_docs.append(("meal_checkins", cid))
        check(f"{meal}: meal_checkins doc created by the athlete", r.status_code, 200)

    print("\nSTEP 7-9 — the ASSIGNED nutritionist reads it and loads the photo:")
    for meal in MEALS:
        cid = checkin_ids[meal]
        r = fs_get(f"meal_checkins/{cid}", t_coach)
        check(f"{meal}: assigned nutritionist CAN read the check-in", r.status_code, 200)
        if r.status_code != 200:
            continue
        stored = r.json()["fields"]["imageUrl"]["stringValue"]
        expected_url, expected_bytes = urls[meal]
        check(f"{meal}: imageUrl points at Firebase Storage",
              "firebasestorage.googleapis.com" in stored, True)
        img = requests.get(stored, timeout=45)
        check(f"{meal}: the nutritionist's URL returns the image",
              img.status_code, 200,
              f"bytes={len(img.content)} type={img.headers.get('Content-Type')}")
        check(f"{meal}: the bytes are the athlete's ORIGINAL photo",
              img.content == expected_bytes, True)

    print("\nSTEP 12/14 — persistence: re-fetch after the writer is gone:")
    # Nothing in the chain depends on the backend process; re-fetch proves the
    # object lives in Storage, not in any process memory or container disk.
    url, payload = urls["breakfast"]
    again = requests.get(url, timeout=45)
    check("breakfast photo still served on a fresh request", again.status_code, 200)
    check("  ...still byte-identical", again.content == payload, True)

    print("\nACCOUNT ISOLATION — Firestore layer:")
    cid = checkin_ids["breakfast"]
    r = fs_get(f"meal_checkins/{cid}", t_other_athlete)
    check("another athlete CANNOT read the check-in", r.status_code, 403)
    r = fs_get(f"meal_checkins/{cid}", t_other_coach)
    check("an UNASSIGNED nutritionist CANNOT read the check-in", r.status_code, 403)
    r = requests.get(
        f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/documents/meal_checkins/{cid}",
        timeout=30)
    check("an UNAUTHENTICATED caller CANNOT read the check-in", r.status_code, 403)

    print("\nACCOUNT ISOLATION — Storage layer:")
    p = created_objects[0]
    r = requests.get(f"https://firebasestorage.googleapis.com/v0/b/{BUCKET}/o/{urllib.parse.quote(p, safe='')}",
                     headers={"Authorization": f"Firebase {t_other_athlete}"}, timeout=30)
    check("another athlete CANNOT read the object by path", r.status_code, 403)
    r = requests.get(f"https://firebasestorage.googleapis.com/v0/b/{BUCKET}/o/{urllib.parse.quote(p, safe='')}",
                     headers={"Authorization": f"Firebase {t_other_coach}"}, timeout=30)
    check("an UNASSIGNED nutritionist CANNOT read the object by path", r.status_code, 403)

    cleanup(bucket, db)

    failed = [r for r in results if not r[0]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


def cleanup(bucket, db):
    print("\nCLEANUP:")
    for path in created_objects:
        try:
            bucket.blob(path).delete()
        except Exception as e:
            print("   object:", e)
    print(f"  deleted {len(created_objects)} storage objects")
    for coll, doc in created_docs:
        try:
            db.collection(coll).document(doc).delete()
        except Exception as e:
            print("   doc:", e)
    print(f"  deleted {len(created_docs)} firestore docs")
    for uid in (ATHLETE, OTHER_ATHLETE, COACH, OTHER_COACH):
        try:
            fb_auth.delete_user(uid)
        except Exception as e:
            print(f"   user {uid}: {e}")
    print("  deleted 4 test users")


if __name__ == "__main__":
    sys.exit(main())
