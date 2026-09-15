"""
ZITLAS — Personal Coaching Programs API (backend/routes/coaching_programs.py)
Mounted at /api/coaching-programs.

    expert prices programs -> athlete requests one -> expert accepts / declines
        -> payment_required -> athlete pays from the ZITLAS Wallet -> active

MONEY MOVES IN EXACTLY ONE PLACE: POST /requests/{id}/pay, one Firestore
transaction that debits the wallet, writes the ledger row, marks the request
paid and starts the coaching relationship — all of it or none of it. Asking
for a program and an expert accepting it never touch the wallet.

The wallet mechanics are the ones buying Premium from the wallet already uses
(routes/payment.py purchase_membership_with_wallet): integer-paise decisions,
available = balance - reserved, the same wallet fields and ledger shape, the
same 402 insufficient_wallet_balance answer, the same freeze switch. There is
no second wallet and no Razorpay here — a short wallet is answered with Add
Funds on the client, never with a checkout.

The existing Personal Coaching escrow (routes/coaching.py +
personal_coach_requests) is NOT reused: it reserves at request time and
charges when the expert accepts. A program is paid only by the athlete, only
after acceptance.

WHO MAY DO WHAT (all enforced here, never by the client):
  * pricing: only an approved expert, only their OWN programPricing;
  * requests: the athlete is always the caller; price, duration, program
    type, status and paymentStatus are decided by the server;
  * accept/decline: only the approved expert the request names;
  * pay: only the athlete the request names, only once, only after the
    expert accepted — at the price and duration the request recorded.
coaching_program_requests is backend-only in firestore.rules.
"""

from __future__ import annotations

import re
import secrets
import time
import traceback
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException
from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter
from pydantic import BaseModel, Field

import launch_config
import wallet_config
from services import coaching_programs as cp
from services import firestore_service
from services.auth_service import require_expert, verify_firebase_token
from services.coaching_service import notify, now

router = APIRouter()

_ID_RE = re.compile(r"[A-Za-z0-9_\-]{1,128}")


def _db():
    db = firestore_service.get_client()
    if db is None:
        # Fail closed: without Firestore nothing here can be decided safely.
        raise HTTPException(status_code=503, detail="firestore_unavailable")
    return db


def _valid_id(value: str) -> bool:
    return bool(value) and _ID_RE.fullmatch(value) is not None


def _run(txn, db, label: str):
    """Run a transaction; intentional HTTPExceptions pass through untouched,
    anything else is logged in full and reported as a 500 with its cause."""
    try:
        return txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        print(f"[COACHING PROGRAMS] {label} failed: {type(e).__name__}: {e}")
        print(traceback.format_exc())
        raise HTTPException(status_code=500,
                            detail=f"{label}_failed: {type(e).__name__}") from None


def _by_newest(requests: list[dict]) -> list[dict]:
    return sorted(requests, key=lambda r: str(r.get("requestedAt") or ""), reverse=True)


def _still_active(rel: dict) -> bool:
    """Same test routes/coaching.py uses: status active AND endDateTs in the future."""
    end = rel.get("endDateTs")
    if rel.get("status") != "active" or end is None:
        return False
    try:
        return end > now()
    except TypeError:
        return False


def _legacy_open_query(db, athlete_uid: str):
    """An open request in the existing Personal Coaching escrow."""
    return db.collection("personal_coach_requests") \
        .where(filter=FieldFilter("athleteId", "==", athlete_uid)) \
        .where(filter=FieldFilter("status", "==", "pending"))


# ── Expert: program pricing ──────────────────────────────────────────────────

def _pricing_response(expert_data: dict | None) -> dict:
    return {
        "currency": cp.CURRENCY,
        "limits": {"minPaise": cp.MIN_PRICE_PAISE, "maxPaise": cp.MAX_PRICE_PAISE},
        "programs": cp.pricing_view(expert_data),
    }


@router.get("/pricing/me")
async def get_my_pricing(caller: dict = Depends(require_expert)):
    db = _db()
    snap = db.collection("experts").document(caller["uid"]).get()
    return _pricing_response(snap.to_dict() if snap.exists else {})


@router.put("/pricing")
async def save_my_pricing(payload: Any = Body(...), caller: dict = Depends(require_expert)):
    """`{"prices": {"10_day": 49900, "1_month": 129900, "3_month": null}}`.

    Integer paise only; null = not offered; a program left out is unchanged.
    One bad value rejects the whole update and writes nothing.
    """
    uid = caller["uid"]
    try:
        changes = cp.parse_pricing_update(payload)
    except cp.PriceError as e:
        print(f"[COACHING PROGRAMS] pricing rejected — uid={uid} error={e.code} "
              f"programId={e.program_id}")
        raise HTTPException(status_code=400,
                            detail={"error": e.code, "programId": e.program_id}) from None

    db = _db()
    ref = db.collection("experts").document(uid)

    @firestore.transactional
    def _txn(tx):
        snap = ref.get(transaction=tx)
        if not snap.exists:
            raise HTTPException(status_code=404, detail="expert_not_found")
        data = snap.to_dict() or {}
        merged = cp.merge_pricing(data.get(cp.PRICING_FIELD), changes, now().isoformat())
        # Replaces the whole map (update, not a merge) so a program the
        # expert stopped offering really disappears.
        tx.update(ref, {cp.PRICING_FIELD: merged})
        data[cp.PRICING_FIELD] = merged
        return data

    data = _run(_txn, db, "program_pricing")
    print(f"[COACHING PROGRAMS] pricing saved — uid={uid} "
          f"prices={ {k: v.get('pricePaise') for k, v in data[cp.PRICING_FIELD].items()} }")
    return {"success": True, **_pricing_response(data)}


# ── Athlete: what this expert offers, and my request with them ──────────────

@router.get("/experts/{expert_id}")
async def get_expert_programs(expert_id: str, caller: dict = Depends(verify_firebase_token)):
    if not _valid_id(expert_id):
        raise HTTPException(status_code=404, detail="expert_not_found")
    db = _db()
    snap = db.collection("experts").document(expert_id).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="expert_not_found")
    expert = snap.to_dict() or {}
    approved = expert.get("approved") is True

    # An unavailable program says WHY, so the clients show the real state
    # rather than one catch-all: this expert hasn't priced it yet, or isn't
    # taking program requests at all. The price is still only ever the
    # validated stored one — nothing here invents a number.
    programs = []
    for p in cp.pricing_view(expert if approved else {}):
        view = {k: v for k, v in p.items() if k != "updatedAt"}
        view["unavailableReason"] = (
            None if p["available"] else ("not_priced" if approved else "expert_unavailable"))
        programs.append(view)

    mine = [
        d.to_dict() or {}
        for d in db.collection(cp.REQUESTS_COLLECTION)
        .where(filter=FieldFilter("athleteId", "==", caller["uid"])).stream()
    ]
    mine = _by_newest([r for r in mine if r.get("expertId") == expert_id])
    current = next((r for r in mine if cp.is_open(r)), mine[0] if mine else None)

    return {
        "expertId": expert_id,
        "expertName": expert.get("name") or "Expert",
        "expertAvailable": approved,
        "currency": cp.CURRENCY,
        "programs": programs,
        "request": cp.public_request(current) if current else None,
    }


def _text(value: Any) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _photo_url(expert: dict) -> str | None:
    """The expert's profile photo — the same fields the apps' expert cards
    read — and only an http(s) URL, never a data: blob or a storage path."""
    for key in ("profilePhoto", "photo", "image", "photoURL", "photoUrl"):
        value = _text(expert.get(key))
        if value and value.lower().startswith(("https://", "http://")):
            return value
    return None


def _expertise(expert: dict) -> list[str]:
    """Up to four areas the expert works in, from their own profile."""
    raw = expert.get("specialties") or expert.get("expertise")
    if isinstance(raw, str):
        raw = re.split(r"[,/]", raw)
    if not isinstance(raw, list):
        return []
    return [s.strip() for s in raw if isinstance(s, str) and s.strip()][:4]


@router.get("/programs/{program_id}/experts")
async def list_program_experts(program_id: str, caller: dict = Depends(verify_firebase_token)):
    """GET STARTED's "choose your expert" step: the approved experts who offer
    `program_id`, each at their OWN server-side price — the same validated
    price GET /experts/{id} quotes. Read-only: POST /requests re-reads the
    chosen expert's price and snapshots it, so nothing here can set a price."""
    program = cp.PROGRAMS.get(program_id)
    if program is None:
        raise HTTPException(status_code=400, detail="invalid_program")
    db = _db()
    caller_uid = caller.get("uid") or ""
    experts = []
    for snap in db.collection("experts").where(filter=FieldFilter("approved", "==", True)).stream():
        data = snap.to_dict() or {}
        # Re-checked rather than trusting the query alone; and an expert is
        # never offered their own program (POST /requests refuses it).
        if data.get("approved") is not True or snap.id == caller_uid:
            continue
        price = cp.stored_price(data, program_id)
        if price is None:
            continue
        experts.append({
            "expertId": snap.id,
            "expertName": data.get("name") or "Expert",
            "specialization": _text(data.get("specialization") or data.get("speciality")
                                    or data.get("role")),
            "photoUrl": _photo_url(data),
            "expertise": _expertise(data),
            "pricePaise": price,
        })
    experts.sort(key=lambda e: (str(e["expertName"]).lower(), e["expertId"]))
    return {
        "programId": program_id,
        "title": program["title"],
        "durationDays": program["durationDays"],
        "currency": cp.CURRENCY,
        "experts": experts,
    }


class ProgramRequestBody(BaseModel):
    # ONLY these two. Anything else a client sends (a price, a status, a
    # duration, an athleteId…) is ignored — the server decides all of it.
    expertId: str = Field(..., min_length=1, max_length=128)
    programId: str = Field(..., min_length=1, max_length=32)


@router.post("/requests")
async def create_program_request(body: ProgramRequestBody,
                                 caller: dict = Depends(verify_firebase_token)):
    athlete_uid = caller.get("uid") or ""
    expert_id = body.expertId.strip()
    program_id = body.programId.strip()
    program = cp.PROGRAMS.get(program_id)
    if program is None:
        raise HTTPException(status_code=400, detail="invalid_program")
    if not _valid_id(expert_id):
        raise HTTPException(status_code=404, detail="expert_not_found")
    if expert_id == athlete_uid:
        raise HTTPException(status_code=400, detail="cannot_request_self")

    db = _db()
    expert_ref = db.collection("experts").document(expert_id)
    user_ref = db.collection("users").document(athlete_uid)
    rel_ref = db.collection("personal_coaching").document(athlete_uid)
    requests_col = db.collection(cp.REQUESTS_COLLECTION)
    mine_query = requests_col.where(filter=FieldFilter("athleteId", "==", athlete_uid))
    legacy_open_query = _legacy_open_query(db, athlete_uid)

    @firestore.transactional
    def _txn(tx):
        expert_snap = expert_ref.get(transaction=tx)
        expert = expert_snap.to_dict() if expert_snap.exists else None
        if not expert or expert.get("approved") is not True:
            raise HTTPException(status_code=404, detail="expert_not_found")

        # One open request per athlete+expert. The same program again returns
        # the request already waiting (a double tap, a retry); a different
        # program has to wait until this one is resolved.
        mine = _by_newest([d.to_dict() or {} for d in tx.get(mine_query)])
        for existing in mine:
            if existing.get("expertId") != expert_id or not cp.is_open(existing):
                continue
            if existing.get("programId") == program_id:
                return {"already": True, "request": existing}
            raise HTTPException(status_code=409, detail={
                "error": "program_request_exists",
                "programId": existing.get("programId"),
                "requestId": existing.get("requestId"),
            })

        # The existing Personal Coaching rules still hold: one open coaching
        # request at a time, and one coach at a time.
        if list(tx.get(legacy_open_query)):
            raise HTTPException(status_code=409, detail="open_request_exists")
        rel_snap = rel_ref.get(transaction=tx)
        if rel_snap.exists:
            rel = rel_snap.to_dict() or {}
            if _still_active(rel) and rel.get("coachId") != expert_id:
                raise HTTPException(status_code=409, detail="active_coaching_exists")

        # The price is the expert's CURRENT stored price, re-validated here —
        # never a number from the request.
        price = cp.stored_price(expert, program_id)
        if price is None:
            raise HTTPException(status_code=409, detail="program_unavailable")

        user_snap = user_ref.get(transaction=tx)
        user = (user_snap.to_dict() if user_snap.exists else None) or {}
        stamp = now().isoformat()
        request_id = f"CPR_{int(time.time() * 1000)}_{secrets.token_hex(3)}"
        pricing_entry = (expert.get(cp.PRICING_FIELD) or {}).get(program_id) or {}
        doc = {
            "requestId": request_id,
            "athleteId": athlete_uid,
            "athleteName": user.get("name") or caller.get("name") or "Athlete",
            "expertId": expert_id,
            "expertName": expert.get("name") or "Expert",
            "programId": program_id,
            "programTitle": program["title"],
            "programType": program["programType"],
            "durationDays": program["durationDays"],
            # Snapshot: later price changes never alter this request.
            "pricePaise": price,
            "currency": cp.CURRENCY,
            "priceUpdatedAt": pricing_entry.get("updatedAt"),
            "status": cp.STATUS_PENDING,
            "paymentStatus": cp.PAYMENT_UNPAID,
            "requestedAt": stamp,
            "updatedAt": stamp,
        }
        tx.set(requests_col.document(request_id), doc)
        return {"already": False, "request": doc}

    result = _run(_txn, db, "program_request")
    req = result["request"]
    print(f"[COACHING PROGRAMS] request {'already open' if result['already'] else 'created'} — "
          f"requestId={req.get('requestId')} athlete={athlete_uid} expert={expert_id} "
          f"program={program_id} pricePaise={req.get('pricePaise')}")

    if not result["already"]:
        try:
            notify(db, expert_id, "New Program Request",
                   f"{req['athleteName']} requested your {req['programTitle']}.",
                   category="expert", type="coaching_program_request",
                   action="expert_dashboard", priority="high")
        except Exception:  # noqa: BLE001 — never fails a committed request
            print(f"[COACHING PROGRAMS] expert notification failed (non-fatal) — "
                  f"requestId={req.get('requestId')}")
            print(traceback.format_exc())

    return {"success": True, "alreadyRequested": result["already"],
            "request": cp.public_request(req)}


def _running(req: dict, moment: datetime) -> bool:
    """A paid program that has not reached its end date."""
    if req.get("status") != cp.STATUS_ACTIVE:
        return False
    ends = req.get("endsAt")
    if not ends:
        return True
    try:
        end = datetime.fromisoformat(str(ends))
    except ValueError:
        return True
    if end.tzinfo is None:
        end = end.replace(tzinfo=timezone.utc)
    return end > moment


@router.get("/requests/me")
async def my_program_requests(caller: dict = Depends(verify_firebase_token)):
    """The caller's own program requests, newest first, and `current` — the
    one still waiting (on the expert or on payment) or still running. Both
    clients restore the Programs screen from this after an app restart or a
    page refresh, so what the athlete sees is always the server's state.
    Read-only."""
    db = _db()
    uid = caller.get("uid") or ""
    mine = _by_newest([
        d.to_dict() or {}
        for d in db.collection(cp.REQUESTS_COLLECTION)
        .where(filter=FieldFilter("athleteId", "==", uid)).stream()
    ])
    moment = now()
    current = next((r for r in mine if cp.is_open(r) or _running(r, moment)), None)
    return {
        "requests": [cp.public_request(r) for r in mine[:50]],
        "current": cp.public_request(current) if current else None,
    }


# ── Expert: my program requests, accept / decline ────────────────────────────

@router.get("/requests/expert")
async def list_expert_program_requests(caller: dict = Depends(require_expert)):
    db = _db()
    docs = db.collection(cp.REQUESTS_COLLECTION) \
        .where(filter=FieldFilter("expertId", "==", caller["uid"])).stream()
    items = _by_newest([cp.public_request(d.to_dict()) for d in docs])
    # Pending first (stable sort keeps newest-first inside each group).
    items.sort(key=lambda r: r.get("status") != cp.STATUS_PENDING)
    pending = sum(1 for r in items if r.get("status") == cp.STATUS_PENDING)
    return {"requests": items[:100], "pendingCount": pending}


#: decision -> (new status, timestamp field, extra fields, expert-facing message)
_DECISIONS = {
    # Accepting charges NOTHING: it records the acceptance and that payment
    # is now due. The athlete pays later, from their own wallet.
    "accept": (cp.STATUS_ACCEPTED, "acceptedAt",
               {"expertAccepted": True, "paymentStatus": cp.PAYMENT_REQUIRED},
               "Program request accepted. Payment is pending."),
    "decline": (cp.STATUS_DECLINED, "declinedAt", {}, "Program request declined."),
}


def _decide(request_id: str, caller: dict, decision: str) -> dict:
    target, stamp_field, extra, message = _DECISIONS[decision]
    if not _valid_id(request_id):
        raise HTTPException(status_code=404, detail="request_not_found")
    db = _db()
    ref = db.collection(cp.REQUESTS_COLLECTION).document(request_id)
    expert_uid = caller["uid"]

    @firestore.transactional
    def _txn(tx):
        snap = ref.get(transaction=tx)
        if not snap.exists:
            raise HTTPException(status_code=404, detail="request_not_found")
        data = snap.to_dict() or {}
        if data.get("expertId") != expert_uid:
            raise HTTPException(status_code=403, detail="not_your_request")
        status = data.get("status")
        if status == target:
            return {"already": True, "request": data}  # idempotent repeat
        if status != cp.STATUS_PENDING:
            raise HTTPException(status_code=409,
                                detail={"error": "not_pending", "status": status})
        stamp = now().isoformat()
        # ONLY the decision. Price, program and duration are left exactly as
        # the request recorded them.
        change = {"status": target, stamp_field: stamp, "updatedAt": stamp, **extra}
        tx.update(ref, change)
        data.update(change)
        return {"already": False, "request": data}

    result = _run(_txn, db, f"program_request_{decision}")
    req = result["request"]
    print(f"[COACHING PROGRAMS] {decision} — requestId={request_id} expert={expert_uid} "
          f"already={result['already']} paymentStatus={req.get('paymentStatus')}")

    if not result["already"]:
        title = req.get("programTitle") or "program"
        expert_name = req.get("expertName") or "Your expert"
        try:
            if decision == "accept":
                notify(db, req.get("athleteId"), "Program Request Accepted",
                       f"{expert_name} accepted your {title}. "
                       "Pay from your ZITLAS Wallet to start.",
                       category="expert", type="coaching_program_accepted", action="coaches")
            else:
                notify(db, req.get("athleteId"), "Program Request Declined",
                       f"{expert_name} declined your {title} request.",
                       category="expert", type="coaching_program_declined", action="coaches")
        except Exception:  # noqa: BLE001
            print(f"[COACHING PROGRAMS] athlete notification failed (non-fatal) — "
                  f"requestId={request_id}")
            print(traceback.format_exc())

    return {"success": True, "already": result["already"], "message": message,
            "request": cp.public_request(req)}


@router.post("/requests/{request_id}/accept")
async def accept_program_request(request_id: str, caller: dict = Depends(require_expert)):
    return _decide(request_id, caller, "accept")


@router.post("/requests/{request_id}/decline")
async def decline_program_request(request_id: str, caller: dict = Depends(require_expert)):
    return _decide(request_id, caller, "decline")


# ── Athlete: pay for an accepted program and start it ────────────────────────

def _payment_response(request_id: str, req: dict, already: bool, balance: float | None) -> dict:
    paid = req.get("amountPaidPaise")
    return {
        "success": True,
        "already": already,
        "requestId": request_id,
        "programId": req.get("programId"),
        "paymentStatus": req.get("paymentStatus"),
        "programStatus": req.get("status"),
        "amountPaid": round(paid / 100.0, 2) if isinstance(paid, int) else None,
        "amountPaidPaise": paid,
        "startedAt": req.get("startedAt"),
        "endsAt": req.get("endsAt"),
        "balance": balance,
        "request": cp.public_request(req),
    }


@router.post("/requests/{request_id}/pay")
async def pay_for_program(request_id: str, caller: dict = Depends(verify_firebase_token)):
    """Pay for an ACCEPTED program in full from the caller's ZITLAS Wallet
    and start it. One Firestore transaction: the debit, the ledger row, the
    paid request and the active coaching relationship land together or not
    at all — there is no path that charges without starting, or starts
    without charging.

    NOTHING IS TAKEN FROM THE CLIENT. There is no body: the amount, the
    duration, the expert and the program are all read from the request the
    server wrote when it was made (the price snapshot), and the athlete is
    the verified caller.

    ONCE ONLY. The ledger row's id is derived from the request id
    (cp.ledger_id) and both are read inside the transaction, so a double tap,
    a retry after a timeout, a second device or a replayed call finds the
    request already paid and returns that same result without charging.
    Concurrent attempts touch the same documents, so Firestore lets exactly
    one of them commit; the other re-runs against the committed state.

    SHORT WALLET: 402 insufficient_wallet_balance with required/available in
    paise — the same answer as buying Premium from the wallet. Nothing is
    written; the request stays accepted with payment required. The client
    offers Add Funds; this endpoint never opens or implies a checkout.
    """
    athlete_uid = caller.get("uid") or ""
    if not _valid_id(request_id):
        raise HTTPException(status_code=404, detail="request_not_found")

    db = _db()
    req_ref = db.collection(cp.REQUESTS_COLLECTION).document(request_id)
    user_ref = db.collection("users").document(athlete_uid)
    rel_ref = db.collection("personal_coaching").document(athlete_uid)
    txn_id = cp.ledger_id(request_id)
    ledger_ref = db.collection("wallet_transactions").document(txn_id)
    legacy_open_query = _legacy_open_query(db, athlete_uid)

    @firestore.transactional
    def _txn(tx):
        # ── ALL READS FIRST ──────────────────────────────────────────────
        req_snap = req_ref.get(transaction=tx)
        if not req_snap.exists:
            raise HTTPException(status_code=404, detail="request_not_found")
        req = req_snap.to_dict() or {}
        if req.get("athleteId") != athlete_uid:
            raise HTTPException(status_code=403, detail="not_your_request")
        ledger_snap = ledger_ref.get(transaction=tx)
        user_snap = user_ref.get(transaction=tx)
        rel_snap = rel_ref.get(transaction=tx)
        legacy_open = list(tx.get(legacy_open_query))
        user = (user_snap.to_dict() if user_snap.exists else None) or {}
        wallet = dict(user.get("wallet") or {})

        # ── Already paid: the same result, nothing more ─────────────────
        if req.get("paymentStatus") == cp.PAYMENT_PAID:
            return {"already": True, "request": req,
                    "balance": float(wallet.get("balance", 0) or 0)}
        if ledger_snap.exists:
            # A ledger row for this request without a paid request cannot be
            # produced by this endpoint (both are written together). Refuse
            # rather than risk charging a second time.
            raise HTTPException(status_code=409, detail="payment_already_recorded")

        # ── Only an accepted, unpaid request can be paid ────────────────
        status = req.get("status")
        if status != cp.STATUS_ACCEPTED:
            error = "not_accepted" if status == cp.STATUS_PENDING else "not_payable"
            raise HTTPException(status_code=409, detail={"error": error, "status": status})
        if req.get("paymentStatus") not in cp.PAYABLE_PAYMENT_STATUSES:
            raise HTTPException(status_code=409, detail={
                "error": "not_payable", "paymentStatus": req.get("paymentStatus")})

        # ── The purchase is exactly what the request recorded ───────────
        program = cp.PROGRAMS.get(req.get("programId"))
        days = req.get("durationDays")
        expert_id = req.get("expertId")
        try:
            price_paise = cp.validate_price_paise(req.get("pricePaise"))
        except cp.PriceError:
            price_paise = None
        if (program is None or days != program["durationDays"] or price_paise is None
                or not expert_id or expert_id == athlete_uid):
            print(f"[PROGRAM PAY] refused malformed request {request_id}: program="
                  f"{req.get('programId')} days={days} price={req.get('pricePaise')}")
            raise HTTPException(status_code=409, detail="request_invalid")

        # ── Policy switches: nothing is written if either refuses ───────
        price_rupees = round(price_paise / 100.0, 2)
        launch_config.assert_program_payment_enabled()
        wallet_config.assert_wallet_unfrozen("wallet_debit_coaching_program", price_rupees)

        # ── The existing Personal Coaching rules: one coach at a time ───
        if legacy_open:
            raise HTTPException(status_code=409, detail="open_request_exists")
        if rel_snap.exists and _still_active(rel_snap.to_dict() or {}):
            # Paying would replace a relationship that is still running.
            # Renewing or extending one is not a defined rule yet, so refuse
            # (nothing charged) instead of silently overwriting it.
            raise HTTPException(status_code=409, detail="active_coaching_exists")

        # ── Wallet: integer paise, reserved money respected ─────────────
        balance_paise = cp.rupees_to_paise(wallet.get("balance", 0))
        reserved_paise = cp.rupees_to_paise(wallet.get("reserved", 0))
        available_paise = balance_paise - reserved_paise
        if available_paise < price_paise:
            print(f"[PROGRAM PAY] insufficient — uid={athlete_uid} request={request_id} "
                  f"available={available_paise} required={price_paise}")
            raise HTTPException(status_code=402, detail={
                "error": "insufficient_wallet_balance",
                "required": price_paise,
                "available": max(0, available_paise),
                "currency": cp.CURRENCY,
                "requiredRupees": price_rupees,
                "availableRupees": round(max(0, available_paise) / 100.0, 2),
            })

        start = now()
        end = cp.program_end(start, days)
        stamp = start.isoformat()
        title = req.get("programTitle") or program["title"]

        new_balance_paise = balance_paise - price_paise
        wallet["balance"] = round(new_balance_paise / 100.0, 2)
        wallet["total_spent"] = round(
            (cp.rupees_to_paise(wallet.get("total_spent", 0)) + price_paise) / 100.0, 2)
        transactions = list(wallet.get("transactions", []))
        transactions.append({
            "id": txn_id, "type": "debit", "amount": price_rupees,
            "description": f"{title} — {req.get('expertName') or 'Personal Coaching'}",
            "date": stamp,
        })
        wallet["transactions"] = transactions

        # ── WRITES — one commit ─────────────────────────────────────────
        tx.set(user_ref, {"wallet": wallet}, merge=True)
        tx.set(ledger_ref, {
            "transactionId": txn_id,
            "serviceType": cp.SERVICE_TYPE,
            "userId": athlete_uid,
            "athleteId": athlete_uid,
            "expertId": expert_id,
            "amount": price_rupees,
            "amountPaise": price_paise,
            "direction": "debit",
            "method": "wallet",
            "walletBefore": round(balance_paise / 100.0, 2),
            "walletAfter": wallet["balance"],
            "programRequestId": request_id,
            "programId": req.get("programId"),
            "programType": req.get("programType"),
            "durationDays": days,
            "status": "success",
            "createdAt": stamp,
        })
        change = {
            "status": cp.STATUS_ACTIVE,
            "paymentStatus": cp.PAYMENT_PAID,
            "paidAt": stamp,
            "activatedAt": stamp,
            "startedAt": stamp,
            "endsAt": end.isoformat(),
            "amountPaidPaise": price_paise,
            "walletTransactionId": txn_id,
            "updatedAt": stamp,
        }
        tx.update(req_ref, change)
        # The coaching relationship, in the exact shape routes/coaching.py's
        # /accept writes, so the app, the website's coaching gate, the
        # Security Rules (isActiveCoachOf) and the expiry sweep all treat it
        # as ordinary active coaching. The program request is the lifecycle
        # wrapper around it.
        tx.set(rel_ref, {
            "coachId": expert_id,
            "coachName": req.get("expertName"),
            "athleteId": athlete_uid,
            "athleteName": req.get("athleteName"),
            "planType": req.get("programType") or program["programType"],
            "planLabel": title,
            "coachingType": "PAID",
            "trialDurationDays": None,
            "startDate": stamp,
            "endDate": end.isoformat(),
            "endDateTs": end,  # native timestamp, for the rules and the sweep
            "status": "active",
            "subscriptionId": txn_id,
            "paymentId": txn_id,
            "fee": price_rupees,
            # `requestId` names a personal_coach_requests (escrow) doc, which
            # a program never has — the program's own id lives alongside.
            "requestId": None,
            "programRequestId": request_id,
            "programId": req.get("programId"),
            "durationDays": days,
            "source": "coaching_program",
        })
        req.update(change)
        return {"already": False, "request": req, "balance": wallet["balance"]}

    result = _run(_txn, db, "program_payment")
    req = result["request"]
    print(f"[PROGRAM PAY] {'already paid' if result['already'] else 'paid and started'} — "
          f"requestId={request_id} athlete={athlete_uid} expert={req.get('expertId')} "
          f"paise={req.get('amountPaidPaise')} endsAt={req.get('endsAt')} "
          f"balance={result['balance']}")

    if not result["already"]:
        title = req.get("programTitle") or "program"
        amount = round((req.get("amountPaidPaise") or 0) / 100.0, 2)
        shown = f"₹{amount:,.0f}" if amount == int(amount) else f"₹{amount:,.2f}"
        try:
            notify(db, athlete_uid, "Program Started",
                   f"Your {title} with {req.get('expertName') or 'your expert'} has started. "
                   f"{shown} was paid from your ZITLAS Wallet.",
                   category="expert", type="coaching_program_started",
                   action="coaching_workspace", action_id=req.get("expertId"),
                   priority="high")
            notify(db, req.get("expertId"), "Program Started",
                   f"{req.get('athleteName') or 'An athlete'} paid for your {title}. "
                   "Coaching starts now.",
                   category="expert", type="coaching_program_started",
                   action="expert_dashboard")
        except Exception:  # noqa: BLE001 — never fails a committed payment
            print(f"[PROGRAM PAY] notification failed (non-fatal) — requestId={request_id}")
            print(traceback.format_exc())

    return _payment_response(request_id, req, result["already"], result["balance"])
