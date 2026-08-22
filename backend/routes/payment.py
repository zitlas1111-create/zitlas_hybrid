"""
ZITLAS — Razorpay Standard Checkout routes (backend/routes/payment.py)

POST /api/payment/create-order — creates a Razorpay order for the caller's
own wallet recharge amount and records it server-side
(razorpay_orders/{orderId}) so /verify has an authoritative amount to
credit later. The amount itself is trusted at CREATE time (it's the user's
own choice of how much to add to their own wallet, not a price being
enforced against them — unlike routes/coaching.py's plan pricing, there is
no "correct" amount here to protect against a manipulated client value).
What must never be trusted from the client is whether a payment actually
happened — that's what /verify's signature check establishes.

POST /api/payment/verify — verifies the HMAC-SHA256 signature Razorpay's
checkout returns and, ONLY on a match, credits the wallet inside a
Firestore transaction — reusing the exact wallet-mutation shape
established in routes/coaching.py (same wallet doc fields, same
wallet_transactions audit-log shape) so this new money-in path looks
identical to the wallet's other credit paths to any code that reads it
back (cloud-sync.js, wallet.js, etc.).
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from google.cloud import firestore
from pydantic import BaseModel

import trial_config
import launch_config
import wallet_config
from services import firestore_service, razorpay_service
from services.auth_service import verify_firebase_token

router = APIRouter()

# Fee split kept identical to the old client-side attemptCharge (10% platform).
_PLATFORM_FEE_PERCENT = 0.10


def _membership_is_premium(membership: dict | None) -> bool:
    """Mirror of payment-service.js _membershipIsPremium — premium & unexpired."""
    if not membership or not isinstance(membership, dict):
        return False
    if membership.get("plan") != "premium" or not membership.get("active"):
        return False
    exp = membership.get("premium_expiry_date")
    if exp:
        try:
            if datetime.fromisoformat(str(exp).replace("Z", "+00:00")) <= _now():
                return False
        except Exception:
            pass
    return True

# ── Premium Membership pricing (SERVER-authoritative — the client sends
#    only 'monthly'|'yearly'; the price can never be manipulated) ──
MEMBERSHIP_PRICES_RUPEES = {"monthly": 149, "yearly": 999}
MEMBERSHIP_DURATION_DAYS = {"monthly": 30, "yearly": 365}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _db() -> firestore.Client:
    db = firestore_service.get_client()
    if db is None:
        reason = firestore_service.config_error() or "unknown — get_client() returned None with no recorded error"
        print(f"[PAYMENT] Firestore client unavailable — {reason}")
        raise HTTPException(status_code=503, detail=f"payment_service_unavailable: {reason}")
    return db


class CreateOrderBody(BaseModel):
    amount: float  # rupees — matches every other price/amount field in this codebase (₹, not paise)


class VerifyBody(BaseModel):
    razorpay_order_id: str
    razorpay_payment_id: str
    razorpay_signature: str


class MembershipOrderBody(BaseModel):
    billing: str  # 'monthly' | 'yearly' — price resolved server-side


class ChargeBody(BaseModel):
    # The athlete whose wallet is charged (may differ from the caller when the
    # assigned expert accepts a review on their own device — see /charge).
    athleteUid: str
    requestCollection: str   # e.g. 'review_requests'
    requestId: str
    amount: float = 0.0
    serviceType: str = "unknown"
    serviceLabel: str | None = None
    expertId: str | None = None
    expertName: str | None = None
    # Fields merged onto the request doc ONLY on a successful charge (e.g.
    # {status:'in_progress', chatUnlocked:true}). Never applied on the
    # insufficient-balance path.
    onSuccessUpdate: dict = {}
    # "Both" bundle: a linked review the same charge covers. Mirrored to the
    # SAME paid outcome SERVER-SIDE (was a client write of paymentStatus:'paid'
    # — a forgeable payment-state flag). Only mirrored when it belongs to the
    # same athlete.
    siblingRequestId: str | None = None


# Only these request collections may be advanced by a charge — a hard allowlist
# so onSuccessUpdate can never be aimed at an arbitrary collection/document.
_CHARGEABLE_COLLECTIONS = {"review_requests", "coaching_meal_requests"}
# Field on the request doc that identifies the assigned expert (used to
# authorize an expert-initiated charge).
_REQUEST_EXPERT_FIELDS = ("expertId", "coachId")


@router.post("/create-order")
async def create_order(body: CreateOrderBody, caller: dict = Depends(verify_firebase_token)):
    # WALLET FROZEN. This endpoint exists only to start a wallet recharge, so
    # it is refused outright rather than by amount — see wallet_config.py.
    # Premium has its own order endpoint (/membership/create-order) and is
    # deliberately untouched: Premium is bought from Razorpay, never from a
    # wallet balance.
    wallet_config.assert_wallet_unfrozen("wallet_recharge_create_order")
    uid = caller["uid"]
    print(f"[PAYMENT CREATE-ORDER] uid={uid} amount=₹{body.amount}")

    if body.amount <= 0:
        raise HTTPException(status_code=400, detail="invalid_amount")

    amount_paise = int(round(body.amount * 100))
    try:
        # Razorpay caps `receipt` at 40 chars. A Firebase uid alone is ~28,
        # so "wallet_<uid>_<ms-timestamp>" (~49) blew past that in
        # production (see Render logs — BAD_REQUEST_ERROR on every order).
        # The uid isn't needed here for correctness — razorpay_orders/{id}
        # already stores it — this is just a merchant-facing label, so a
        # short timestamp-only receipt is enough. "wallet_" + a 13-digit
        # ms timestamp is 20 chars, safely under the limit indefinitely.
        order = razorpay_service.create_order(
            amount_paise, receipt=f"wallet_{int(time.time() * 1000)}"
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except PermissionError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    db = _db()
    db.collection("razorpay_orders").document(order["order_id"]).set({
        "orderId": order["order_id"], "uid": uid, "amountPaise": order["amount"],
        "currency": order["currency"], "status": "created", "createdAt": _now().isoformat(),
    })

    print(f"[PAYMENT CREATE-ORDER] order recorded — orderId={order['order_id']} amountPaise={order['amount']}")
    return {
        "order_id": order["order_id"], "amount": order["amount"],
        "currency": order["currency"], "key_id": order["key_id"],
    }


@router.post("/verify")
async def verify_payment(body: VerifyBody, caller: dict = Depends(verify_firebase_token)):
    # WALLET FROZEN. This is the credit half of a wallet recharge. No new
    # recharge can be started (create-order above refuses first), so nothing
    # legitimate reaches here while the freeze is on.
    wallet_config.assert_wallet_unfrozen("wallet_recharge_verify")
    uid = caller["uid"]
    print(f"[PAYMENT VERIFY] uid={uid} orderId={body.razorpay_order_id} paymentId={body.razorpay_payment_id}")

    if not razorpay_service.verify_signature(
        body.razorpay_order_id, body.razorpay_payment_id, body.razorpay_signature
    ):
        print(f"[PAYMENT VERIFY] signature mismatch — orderId={body.razorpay_order_id} — wallet NOT credited")
        raise HTTPException(status_code=400, detail="signature_mismatch")

    db = _db()
    order_ref = db.collection("razorpay_orders").document(body.razorpay_order_id)
    user_ref = db.collection("users").document(uid)
    wallet_txn_id = "txn_" + body.razorpay_payment_id

    @firestore.transactional
    def _txn(tx):
        order_snap = order_ref.get(transaction=tx)
        if not order_snap.exists:
            raise HTTPException(status_code=404, detail="order_not_found")
        order = order_snap.to_dict()
        if order.get("uid") != uid:
            raise HTTPException(status_code=403, detail="not_your_order")
        if order.get("status") == "paid":
            # Idempotent retry (double-fire of the success handler, etc.) —
            # not an error, and must NOT credit a second time. Still returns
            # `balance` (the CURRENT one, unchanged) so the frontend's
            # response-shape assumption holds on every path, not just the
            # first-time-credited one.
            existing_wallet = (user_ref.get(transaction=tx).to_dict() or {}).get("wallet") or {}
            return {"already": True, "amount": order["amountPaise"] / 100.0,
                    "balance": float(existing_wallet.get("balance", 0) or 0)}

        amount_rupees = order["amountPaise"] / 100.0
        user_snap = user_ref.get(transaction=tx)
        user_data = user_snap.to_dict() if user_snap.exists else {}
        wallet = dict((user_data or {}).get("wallet") or {})
        balance_before = float(wallet.get("balance", 0) or 0)

        wallet["balance"] = balance_before + amount_rupees
        wallet["total_added"] = float(wallet.get("total_added", 0) or 0) + amount_rupees
        transactions = list(wallet.get("transactions", []))
        transactions.append({
            "id": wallet_txn_id, "type": "credit", "amount": amount_rupees,
            "description": "Added Funds via Razorpay", "date": _now().isoformat(),
        })
        wallet["transactions"] = transactions
        tx.set(user_ref, {"wallet": wallet}, merge=True)

        tx.set(db.collection("wallet_transactions").document(wallet_txn_id), {
            "transactionId": wallet_txn_id, "serviceType": "wallet_recharge", "userId": uid,
            "amount": amount_rupees, "walletBefore": balance_before, "walletAfter": wallet["balance"],
            "method": "razorpay", "razorpayOrderId": body.razorpay_order_id,
            "razorpayPaymentId": body.razorpay_payment_id, "status": "success",
            "createdAt": _now().isoformat(),
        })

        tx.update(order_ref, {
            "status": "paid", "razorpayPaymentId": body.razorpay_payment_id, "paidAt": _now().isoformat(),
        })
        return {"already": False, "amount": amount_rupees, "balance": wallet["balance"]}

    try:
        result = _txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:
        print(f"[PAYMENT VERIFY] unexpected failure — uid={uid} orderId={body.razorpay_order_id}: "
              f"{type(e).__name__}: {e}")
        raise HTTPException(status_code=500, detail=f"payment_credit_failed: {type(e).__name__}: {e}")

    print(f"[PAYMENT VERIFY] wallet credited — uid={uid} amount=₹{result['amount']} already={result.get('already')}")
    return {"success": True, **result}


# ══════════════════════════════════════════════════════════════════════
# PREMIUM MEMBERSHIP — the ONLY paid feature in ZITLAS
# (₹149/month or ₹999/year; every expert service is free platform-wide,
# see trial_config.PLATFORM_CHARGES_FREE). Same create→checkout→verify
# contract as the wallet flow above, with two hard rules:
#   1. The price is resolved SERVER-side from the billing period — the
#      client cannot choose an amount.
#   2. Premium activates ONLY inside /membership/verify, after the HMAC
#      signature check — never optimistically on the client.
# ══════════════════════════════════════════════════════════════════════

@router.post("/membership/create-order")
async def create_membership_order(body: MembershipOrderBody, caller: dict = Depends(verify_firebase_token)):
    uid = caller["uid"]
    billing = (body.billing or "").strip().lower()
    if billing not in MEMBERSHIP_PRICES_RUPEES:
        raise HTTPException(status_code=400, detail="invalid_billing_period")

    amount_rupees = MEMBERSHIP_PRICES_RUPEES[billing]
    amount_paise = amount_rupees * 100
    print(f"[MEMBERSHIP CREATE-ORDER] uid={uid} billing={billing} amount=₹{amount_rupees}")

    try:
        order = razorpay_service.create_order(
            amount_paise, receipt=f"premium_{int(time.time() * 1000)}"
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except PermissionError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    db = _db()
    db.collection("razorpay_orders").document(order["order_id"]).set({
        "orderId": order["order_id"], "uid": uid, "amountPaise": order["amount"],
        "currency": order["currency"], "status": "created",
        "purpose": "membership", "billing": billing,
        "createdAt": _now().isoformat(),
    })

    print(f"[MEMBERSHIP CREATE-ORDER] order recorded — orderId={order['order_id']}")
    return {
        "order_id": order["order_id"], "amount": order["amount"],
        "currency": order["currency"], "key_id": order["key_id"],
        "billing": billing, "price_rupees": amount_rupees,
    }


@router.post("/membership/verify")
async def verify_membership_payment(body: VerifyBody, caller: dict = Depends(verify_firebase_token)):
    uid = caller["uid"]
    print(f"[MEMBERSHIP VERIFY] uid={uid} orderId={body.razorpay_order_id}")

    if not razorpay_service.verify_signature(
        body.razorpay_order_id, body.razorpay_payment_id, body.razorpay_signature
    ):
        print(f"[MEMBERSHIP VERIFY] signature mismatch — orderId={body.razorpay_order_id} — premium NOT activated")
        raise HTTPException(status_code=400, detail="signature_mismatch")

    db = _db()
    order_ref = db.collection("razorpay_orders").document(body.razorpay_order_id)
    user_ref = db.collection("users").document(uid)
    txn_id = "txn_" + body.razorpay_payment_id

    @firestore.transactional
    def _txn(tx):
        order_snap = order_ref.get(transaction=tx)
        if not order_snap.exists:
            raise HTTPException(status_code=404, detail="order_not_found")
        order = order_snap.to_dict()
        if order.get("uid") != uid:
            raise HTTPException(status_code=403, detail="not_your_order")
        if order.get("purpose") != "membership":
            raise HTTPException(status_code=400, detail="not_a_membership_order")
        if order.get("status") == "paid":
            # Idempotent retry — return the membership already written.
            existing = (user_ref.get(transaction=tx).to_dict() or {}).get("membership") or {}
            return {"already": True, "membership": existing}

        billing = order.get("billing") or "monthly"
        start = _now()
        expiry = start + timedelta(days=MEMBERSHIP_DURATION_DAYS.get(billing, 30))
        membership = {
            "plan": "premium",
            "billing": billing,
            "premium_plan": billing,
            "active": True,
            "started_at": start.isoformat(),
            "premium_start_date": start.isoformat(),
            "premium_expiry_date": expiry.isoformat(),
            "payment_id": body.razorpay_payment_id,
            "order_id": body.razorpay_order_id,
            "payment_status": "paid",
        }
        tx.set(user_ref, {
            "membership": membership,
            "membershipUpdatedAt": start.isoformat(),
        }, merge=True)

        # Same audit-log collection every other payment writes to.
        tx.set(db.collection("wallet_transactions").document(txn_id), {
            "transactionId": txn_id, "serviceType": "premium_membership", "userId": uid,
            "amount": order["amountPaise"] / 100.0, "billing": billing,
            "method": "razorpay", "razorpayOrderId": body.razorpay_order_id,
            "razorpayPaymentId": body.razorpay_payment_id, "status": "success",
            "createdAt": start.isoformat(),
        })

        tx.update(order_ref, {
            "status": "paid", "razorpayPaymentId": body.razorpay_payment_id,
            "paidAt": start.isoformat(),
        })
        return {"already": False, "membership": membership}

    try:
        result = _txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:
        print(f"[MEMBERSHIP VERIFY] unexpected failure — uid={uid}: {type(e).__name__}: {e}")
        raise HTTPException(status_code=500, detail=f"membership_activation_failed: {type(e).__name__}: {e}")

    print(f"[MEMBERSHIP VERIFY] premium activated — uid={uid} already={result.get('already')}")
    return {"success": True, **result}


# ══════════════════════════════════════════════════════════════════════
# PLATFORM-SERVICE CHARGE — server-authoritative replacement for the old
# client-side ZitlasPayment.attemptCharge() Firestore transaction.
#
# WHY THIS MOVED SERVER-SIDE: the wallet lives in users/{uid}.wallet, and the
# old flow debited it from the BROWSER. Under production Security Rules the
# client can no longer write users/{uid}.wallet or wallet_transactions (see
# FIRESTORE_SECURITY_AUDIT.md V2), so the balance check + debit + audit record
# + request-advance must happen here, where the Admin SDK bypasses rules and
# the amount/policy can't be tampered with.
#
# AUTHORIZATION: the caller must be either the athlete themselves (paying for
# their own request) OR the expert assigned to the request (auto-charge on
# accept). Verified by reading the request doc's expert/coach field — never
# trusted from the body.
#
# PRICING/POLICY: the charge is forced to ₹0 whenever CLIENT_TRIAL_MODE or
# PLATFORM_CHARGES_FREE is on (both default True), or the athlete is a Premium
# member — same policy the client used to apply, now enforced where it can't be
# bypassed. At ₹0 no wallet field or wallet_transactions doc is written at all.
# ══════════════════════════════════════════════════════════════════════

@router.post("/charge")
async def charge_service(body: ChargeBody, caller: dict = Depends(verify_firebase_token)):
    caller_uid = caller["uid"]
    athlete_uid = body.athleteUid
    coll = body.requestCollection

    if coll not in _CHARGEABLE_COLLECTIONS:
        raise HTTPException(status_code=400, detail="invalid_request_collection")
    if not athlete_uid or not body.requestId:
        raise HTTPException(status_code=400, detail="missing_params")

    amount = max(0.0, float(body.amount or 0))
    db = _db()
    request_ref = db.collection(coll).document(body.requestId)
    user_ref = db.collection("users").document(athlete_uid)
    txn_id = "txn_" + str(int(time.time() * 1000)) + "_" + body.requestId[-6:]

    @firestore.transactional
    def _txn(tx):
        req_snap = request_ref.get(transaction=tx)
        if not req_snap.exists:
            raise HTTPException(status_code=404, detail="request_missing")
        req = req_snap.to_dict() or {}

        # ── Authorization (server-side, from the stored request) ──
        assigned_expert = next(
            (req.get(f) for f in _REQUEST_EXPERT_FIELDS if req.get(f)), None
        )
        if caller_uid != athlete_uid and caller_uid != assigned_expert:
            raise HTTPException(status_code=403, detail="not_authorized_for_request")
        # The request must actually belong to the athlete being charged.
        req_athlete = req.get("athleteId") or req.get("userId")
        if req_athlete and req_athlete != athlete_uid:
            raise HTTPException(status_code=403, detail="athlete_mismatch")

        if req.get("paymentStatus") == "paid":
            return {"success": True, "alreadyPaid": True,
                    "walletTransactionId": req.get("walletTransactionId")}

        # ── Server-authoritative pricing ──
        user_snap = user_ref.get(transaction=tx)
        user_data = user_snap.to_dict() if user_snap.exists else {}
        membership = (user_data or {}).get("membership")
        free = (trial_config.CLIENT_TRIAL_MODE
                or trial_config.PLATFORM_CHARGES_FREE
                or _membership_is_premium(membership))
        charge_amount = 0.0 if free else amount

        # Plan reviews and expert chat are free at launch. `free` above
        # already zeroes them; this refuses any non-zero amount that reaches
        # here another way rather than debiting an athlete for a free service.
        launch_config.assert_expert_service_charge_allowed(charge_amount)

        # WALLET FROZEN — but only for money that actually moves. At ₹0 (trial
        # mode, platform-free policy, or a Premium member) no wallet field and
        # no wallet_transactions doc is written, so those charges pass through
        # exactly as before and expert services keep working.
        wallet_config.assert_wallet_unfrozen("wallet_debit_service_charge",
                                             charge_amount)

        wallet = dict((user_data or {}).get("wallet") or {})
        balance = float(wallet.get("balance", 0) or 0)

        if charge_amount > 0 and balance < charge_amount:
            # Payment failed — record the expert's decision but do NOT advance
            # the request to a serving state (no onSuccessUpdate).
            tx.update(request_ref, {
                "status": "accepted",
                "paymentStatus": "awaiting_payment",
                "paymentAttemptedAt": _now().isoformat(),
            })
            return {"success": False, "error": "insufficient_balance",
                    "balance": balance, "required": charge_amount,
                    "shortfall": charge_amount - balance}

        wallet_before = balance
        wallet_after = balance - charge_amount

        if charge_amount > 0:
            platform_fee = round(charge_amount * _PLATFORM_FEE_PERCENT)
            wallet["balance"] = wallet_after
            wallet["total_spent"] = float(wallet.get("total_spent", 0) or 0) + charge_amount
            txns = list(wallet.get("transactions", []))
            txns.append({
                "id": txn_id, "type": "debit", "amount": charge_amount,
                "description": (body.serviceLabel or "ZITLAS service")
                               + (f" — {body.expertName}" if body.expertName else ""),
                "date": _now().isoformat(),
            })
            wallet["transactions"] = txns
            tx.set(user_ref, {"wallet": wallet, "walletUpdatedAt": _now().isoformat()}, merge=True)
            tx.set(db.collection("wallet_transactions").document(txn_id), {
                "transactionId": txn_id, "serviceType": body.serviceType,
                "expertId": body.expertId, "userId": athlete_uid,
                "amount": charge_amount, "walletBefore": wallet_before, "walletAfter": wallet_after,
                "grossAmount": charge_amount, "platformFee": platform_fee,
                "expertAmount": charge_amount - platform_fee, "status": "success",
                "createdAt": _now().isoformat(),
            })

        # Advance the request. onSuccessUpdate is client-supplied but written
        # only to THIS request doc, which the caller is authorized on.
        update = dict(body.onSuccessUpdate or {})
        update.update({
            "paymentStatus": "paid",
            "walletTransactionId": txn_id if charge_amount > 0 else None,
            "paidAt": _now().isoformat(),
            "chargeWaived": charge_amount == 0,
        })
        tx.update(request_ref, update)

        return {"success": True, "transactionId": txn_id if charge_amount > 0 else None,
                "walletBefore": wallet_before, "walletAfter": wallet_after,
                "charged": charge_amount}

    try:
        result = _txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:
        print(f"[PAYMENT CHARGE] failed — caller={caller_uid} athlete={athlete_uid} "
              f"req={coll}/{body.requestId}: {type(e).__name__}: {e}")
        raise HTTPException(status_code=500, detail=f"charge_failed: {type(e).__name__}: {e}")

    # ── "Both" bundle sibling mirror (server-side) ──
    # Only when the primary genuinely reached a paid state, and only onto a
    # sibling that belongs to the SAME athlete (verified from the stored doc).
    if body.siblingRequestId and result.get("success"):
        try:
            sib_ref = db.collection(coll).document(body.siblingRequestId)
            sib = sib_ref.get()
            if sib.exists:
                sd = sib.to_dict() or {}
                sib_athlete = sd.get("athleteId") or sd.get("userId")
                if sib_athlete == athlete_uid:
                    mirror = dict(body.onSuccessUpdate or {})
                    mirror.update({
                        "paymentStatus": "paid",
                        "walletTransactionId": result.get("transactionId"),
                        "paidAt": _now().isoformat(),
                    })
                    sib_ref.update(mirror)
                    print(f"[PAYMENT CHARGE] sibling mirrored req={coll}/{body.siblingRequestId}")
                else:
                    print(f"[PAYMENT CHARGE] sibling mirror SKIPPED (athlete mismatch) "
                          f"sibling={body.siblingRequestId}")
        except Exception as e:
            # Non-fatal — the primary charge already succeeded.
            print(f"[PAYMENT CHARGE] sibling mirror failed (non-fatal): {type(e).__name__}: {e}")

    print(f"[PAYMENT CHARGE] uid={athlete_uid} req={coll}/{body.requestId} "
          f"result={ {k: result[k] for k in result if k != 'transactions'} }")
    return result
