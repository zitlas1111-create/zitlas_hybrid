"""
ZITLAS — Admin-only privileged operations (backend/routes/admin.py)

Certificate verification and expert approval used to be CLIENT writes gated
only by a client-writable users/{uid}.role field (FIRESTORE_SECURITY_AUDIT.md
V3/V4 — trivially spoofable). They now run here, behind require_admin (custom
claim or ZITLAS_ADMIN_UIDS allowlist), writing via the Admin SDK (which
bypasses Security Rules), so:

  - expert_certificates.verificationStatus,
  - experts/{uid}.verification / .verified / .approved,
  - and the Firebase Auth `expert` custom claim

can ONLY change through an authenticated admin. The admin UI
(assets/js/certificate-manager.js, pages/admin/admin-review.js) is preserved —
it just calls these endpoints instead of writing Firestore directly.

Faithful port of the old certificate-manager.js recomputeVerifiedFlag(): the
expert is "verified" iff they have >=1 certificate with
verificationStatus=='verified'; experts/{uid}.verification is the single object
every badge surface reads.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from google.cloud.firestore_v1.base_query import FieldFilter
from pydantic import BaseModel

from services import admin_service, firestore_service, identity_service
from services.auth_service import require_admin, verify_firebase_token

router = APIRouter()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _db():
    db = firestore_service.get_client()
    if db is None:
        reason = firestore_service.config_error() or "unknown"
        raise HTTPException(status_code=503, detail=f"admin_service_unavailable: {reason}")
    return db


class CertActionBody(BaseModel):
    certId: str
    reason: str | None = None  # required for reject


class ExpertApproveBody(BaseModel):
    expertId: str
    approved: bool = True


class ExpertDeactivateBody(BaseModel):
    expertId: str


class RecomputeBody(BaseModel):
    expertId: str


def _recompute_verified(db, expert_id: str) -> dict:
    """Mirror of certificate-manager.js recomputeVerifiedFlag — recompute the
    expert's badge state from their certificates and persist it. Returns the
    verification object written."""
    certs = db.collection("expert_certificates").where("expertId", "==", expert_id).stream()
    verified = []
    for c in certs:
        d = c.to_dict() or {}
        if d.get("verificationStatus") == "verified":
            verified.append(d)
    is_verified = len(verified) > 0
    verified_at = None
    if is_verified:
        stamps = sorted(
            [c.get("reviewedAt") or c.get("uploadedAt") for c in verified if (c.get("reviewedAt") or c.get("uploadedAt"))]
        )
        verified_at = stamps[0] if stamps else None
    verification = {
        "isVerified": is_verified,
        "verificationLevel": "professional" if is_verified else None,
        "verifiedAt": verified_at,
        "verifiedCertificates": len(verified),
    }
    db.collection("experts").document(expert_id).set(
        {"verification": verification, "verified": is_verified}, merge=True
    )
    return verification


@router.post("/certificates/approve")
async def approve_certificate(body: CertActionBody, request: Request,
                              admin: dict = Depends(require_admin)):
    db = _db()
    cert_ref = db.collection("expert_certificates").document(body.certId)
    snap = cert_ref.get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="certificate_not_found")
    _cert = snap.to_dict() or {}
    expert_id = _cert.get("expertId")
    prior_status = _cert.get("verificationStatus")
    if not expert_id:
        raise HTTPException(status_code=400, detail="certificate_missing_expertId")

    cert_ref.update({
        "verificationStatus": "verified",
        "reviewedBy": admin["uid"], "reviewedAt": _now_iso(), "rejectionReason": None,
    })
    verification = _recompute_verified(db, expert_id)
    # Grant the rules-level expert claim (best-effort; see identity_service).
    claim_set = identity_service.grant_expert(expert_id) if verification["isVerified"] else False

    admin_service.record_audit(
        admin_uid=admin["uid"], action=admin_service.CERT_APPROVED,
        target_uid=expert_id, target_type="expert_certificate",
        old_value={"verificationStatus": prior_status},
        new_value={"verificationStatus": "verified", "isVerified": verification["isVerified"]},
        request=request, extra={"certId": body.certId},
    )
    print(f"[ADMIN] cert approved certId={body.certId} expert={expert_id} claim_set={claim_set}")
    return {"success": True, "verification": verification,
            "claimSet": claim_set,
            "note": None if claim_set else "expert must re-login (or call getIdToken(true)) for the claim to take effect"}


@router.post("/certificates/reject")
async def reject_certificate(body: CertActionBody, request: Request,
                             admin: dict = Depends(require_admin)):
    if not body.reason:
        raise HTTPException(status_code=400, detail="reason_required")
    db = _db()
    cert_ref = db.collection("expert_certificates").document(body.certId)
    snap = cert_ref.get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="certificate_not_found")
    _cert = snap.to_dict() or {}
    expert_id = _cert.get("expertId")
    prior_status = _cert.get("verificationStatus")

    cert_ref.update({
        "verificationStatus": "rejected",
        "reviewedBy": admin["uid"], "reviewedAt": _now_iso(), "rejectionReason": body.reason,
    })
    verification = _recompute_verified(db, expert_id) if expert_id else {"isVerified": False}
    # If this leaves the expert with zero verified certs, drop the claim.
    if expert_id and not verification.get("isVerified"):
        identity_service.revoke_expert(expert_id)

    admin_service.record_audit(
        admin_uid=admin["uid"], action=admin_service.CERT_REJECTED,
        target_uid=expert_id, target_type="expert_certificate",
        old_value={"verificationStatus": prior_status},
        new_value={"verificationStatus": "rejected"},
        reason=body.reason, request=request, extra={"certId": body.certId},
    )
    print(f"[ADMIN] cert rejected certId={body.certId} expert={expert_id} reason={body.reason}")
    return {"success": True, "verification": verification}


@router.post("/experts/deactivate")
async def deactivate_expert(body: ExpertDeactivateBody, request: Request,
                            caller: dict = Depends(verify_firebase_token)):
    """Expert account/profile OFFBOARDING (was a set of privileged client
    Firestore writes — expert-dashboard.js delete flow — now denied by rules).

    AUTHORIZATION: the authenticated expert may deactivate their OWN profile;
    an admin may deactivate anyone's. Server-side (Admin SDK), it:
      * deletes experts/{uid} (the marketplace profile),
      * downgrades users/{uid}: strips 'expert'/'expert_pending' from roles[]
        and sets expert_status='none' (NEVER deletes the users doc — the same
        uid may hold athlete data),
      * revokes the `expert` custom claim.
    It deliberately does NOT delete the Firebase Auth account, nor referential/
    audit data (expert_reviews, expert_certificates, chat_rooms,
    personal_coaching) — those reference the uid and are preserved."""
    target = body.expertId
    if caller["uid"] != target and not caller.get("admin"):
        raise HTTPException(status_code=403, detail="not_authorized")

    db = _db()
    result = {"expertProfileDeleted": False, "userDowngraded": False, "claimRevoked": False}

    # 1. Remove the marketplace profile doc (if present).
    exp_ref = db.collection("experts").document(target)
    if exp_ref.get().exists:
        exp_ref.delete()
        result["expertProfileDeleted"] = True

    # 2. Downgrade the users doc without destroying athlete data.
    user_ref = db.collection("users").document(target)
    snap = user_ref.get()
    if snap.exists:
        d = snap.to_dict() or {}
        patch = {"expert_status": "none"}
        if isinstance(d.get("roles"), list):
            patch["roles"] = [r for r in d["roles"] if r not in ("expert", "expert_pending")]
        elif d.get("role") == "expert":
            patch["role"] = "athlete"   # downgrade, never delete
        user_ref.set(patch, merge=True)
        result["userDowngraded"] = True

    # 3. Revoke the rules-level expert claim.
    result["claimRevoked"] = identity_service.revoke_expert(target)

    admin_service.record_audit(
        admin_uid=caller["uid"], action=admin_service.EXPERT_DEACTIVATED,
        target_uid=target, target_type="expert",
        old_value={"marketplaceProfile": "present" if result["expertProfileDeleted"] else "absent"},
        new_value={"marketplaceProfile": "deleted", **result},
        reason=getattr(body, "reason", None), request=request,
        # A self-deactivation is a legitimate expert offboarding, not an admin
        # action; recording which it was matters when reading the trail back.
        extra={"selfService": caller["uid"] == target},
    )
    print(f"[ADMIN] expert deactivated target={target} by={caller['uid']} result={result}")
    return {"success": True, **result,
            "note": "Firebase Auth account and audit data (reviews, certs, chats) preserved"}


@router.post("/experts/recompute-verification")
async def recompute_verification(body: RecomputeBody, request: Request,
                                 admin: dict = Depends(require_admin)):
    """Admin maintenance: recompute experts/{uid}.verification/.verified from
    trusted certificate data server-side (replaces the client-side
    recomputeVerifiedFlag write that Security Rules now deny). Also syncs the
    expert claim to match the recomputed verified state."""
    db = _db()
    verification = _recompute_verified(db, body.expertId)
    if verification.get("isVerified"):
        identity_service.grant_expert(body.expertId)
    else:
        identity_service.revoke_expert(body.expertId)
    admin_service.record_audit(
        admin_uid=admin["uid"], action=admin_service.VERIFICATION_RECOMPUTED,
        target_uid=body.expertId, target_type="expert",
        new_value={"isVerified": verification.get("isVerified")}, request=request,
    )
    print(f"[ADMIN] recompute-verification expert={body.expertId} verified={verification.get('isVerified')}")
    return {"success": True, "verification": verification}


@router.post("/grant-admin")
async def grant_admin(body: ExpertApproveBody, request: Request,
                      admin: dict = Depends(require_admin)):
    """One-time bootstrap: set the `admin` custom claim on a uid so their ID
    token carries admin=true (needed for the admin cert-listing Security Rule).
    Callable by an existing admin — the FIRST admin is bootstrapped via the
    ZITLAS_ADMIN_UIDS env allowlist (auth_service), which makes require_admin
    pass without a claim; this endpoint then persists the claim so it survives
    independent of the env var. Reuses ExpertApproveBody.expertId as the target
    uid. The target must re-login (or call getIdToken(true)) for it to apply."""
    target = body.expertId
    ok = identity_service.grant_admin(target) if body.approved \
        else identity_service.revoke_admin(target)
    admin_service.record_audit(
        admin_uid=admin["uid"],
        action=admin_service.ADMIN_GRANTED if body.approved else admin_service.ADMIN_REVOKED,
        target_uid=target, target_type="admin_claim",
        old_value={"admin": not bool(body.approved)}, new_value={"admin": bool(body.approved)},
        request=request, extra={"claimSet": ok},
    )
    print(f"[ADMIN] grant-admin target={target} approved={body.approved} claim_set={ok}")
    return {"success": True, "claimSet": ok,
            "note": "target must re-login for the admin claim to take effect"}


@router.post("/experts/approve")
async def approve_expert(body: ExpertApproveBody, request: Request,
                         admin: dict = Depends(require_admin)):
    """Flip experts/{uid}.approved and (on approve) grant the expert claim.
    Certificate approval already grants the claim; this exists for direct
    expert-account approval independent of certificates."""
    db = _db()
    db.collection("experts").document(body.expertId).set(
        {"approved": bool(body.approved), "approvedBy": admin["uid"], "approvedAt": _now_iso()},
        merge=True,
    )
    claim_set = identity_service.grant_expert(body.expertId) if body.approved else identity_service.revoke_expert(body.expertId)
    admin_service.record_audit(
        admin_uid=admin["uid"],
        action=admin_service.EXPERT_APPROVED if body.approved else admin_service.EXPERT_REJECTED,
        target_uid=body.expertId, target_type="expert",
        old_value={"approved": not bool(body.approved)},
        new_value={"approved": bool(body.approved)},
        request=request, extra={"claimSet": claim_set},
    )
    print(f"[ADMIN] expert approve={body.approved} expert={body.expertId} claim_set={claim_set}")
    return {"success": True, "approved": bool(body.approved), "claimSet": claim_set}


# ═════════════════════════════════════════════════════════════════════════════
# ADMIN PORTAL — Phase 1: overview, audit trail, system health
#
# Everything below is READ-ONLY. The portal's first phase deliberately ships
# no new mutations: the existing five (certificate approve/reject, expert
# approve, expert deactivate, admin grant) now carry audit records, and adding
# read surfaces around them is safe to deploy against production on its own.
# ═════════════════════════════════════════════════════════════════════════════


def _count(db, collection: str, *, where: tuple | None = None, limit: int = 5000) -> int:
    """Best-effort count.

    Bounded by `limit` so a runaway collection can never turn the dashboard
    into a full-table scan, and returns -1 on failure so one broken collection
    degrades a single KPI card instead of failing the whole overview.
    """
    try:
        q = db.collection(collection)
        if where:
            field, op, value = where
            q = q.where(filter=FieldFilter(field, op, value))
        return sum(1 for _ in q.limit(limit).stream())
    except Exception as e:  # noqa: BLE001
        print(f"[ADMIN] count({collection}) failed: {type(e).__name__}: {e}")
        return -1


@router.get("/dashboard")
async def admin_dashboard(admin: dict = Depends(require_admin)) -> dict:
    """Overview KPIs.

    Counts are computed per-collection and independently guarded — a single
    unavailable collection yields -1 for its own card rather than a 500 for
    the whole dashboard, because an admin opening this during an incident
    needs whatever data IS available.
    """
    db = _db()

    users_total = _count(db, "users")
    experts_total = _count(db, "experts")

    return {
        "environment": admin_service.environment_label(),
        "generatedAt": admin_service.now_iso(),
        "users": {
            "total": users_total,
            "experts": experts_total,
            "suspended": _count(db, "users", where=("accountStatus", "==", "suspended")),
        },
        "experts": {
            "total": experts_total,
            "verified": _count(db, "experts", where=("verified", "==", True)),
            "approved": _count(db, "experts", where=("approved", "==", True)),
            "pendingVerification": _count(
                db, "expert_certificates", where=("verificationStatus", "==", "pending_review")
            ),
        },
        "coaching": {
            "active": _count(db, "personal_coaching", where=("status", "==", "active")),
            "pendingRequests": _count(
                db, "personal_coach_requests", where=("status", "==", "pending")
            ),
        },
        "reviews": {
            "pending": _count(db, "review_requests", where=("status", "==", "pending")),
            "completed": _count(db, "review_requests", where=("status", "==", "completed")),
        },
        "support": {
            "open": _count(db, "support_tickets", where=("status", "==", "OPEN")),
        },
        "audit": {"recent": _count(db, admin_service.AUDIT_COLLECTION, limit=1000)},
    }


@router.get("/audit-logs")
async def admin_audit_logs(
    page: int = 1,
    pageSize: int = 50,
    action: str | None = None,
    adminUid: str | None = None,
    targetUid: str | None = None,
    q: str | None = None,
    admin: dict = Depends(require_admin),
) -> dict:
    """The append-only admin trail, newest first.

    Read-only by design and with no delete/update counterpart anywhere in the
    API: an admin must not be able to erase their own history through the
    product. `firestore.rules` additionally denies the browser all direct
    access to this collection, so this endpoint is the only way in.
    """
    db = _db()
    size = admin_service.clamp_page_size(pageSize, default=50)

    try:
        docs = list(db.collection(admin_service.AUDIT_COLLECTION).limit(2000).stream())
    except Exception as e:  # noqa: BLE001
        print(f"[ADMIN] audit read failed: {type(e).__name__}: {e}")
        raise HTTPException(status_code=503, detail="audit_unavailable")

    rows = [admin_service.doc_to_dict(d) for d in docs]
    if action:
        rows = [r for r in rows if r.get("action") == action]
    if adminUid:
        rows = [r for r in rows if r.get("adminUid") == adminUid]
    if targetUid:
        rows = [r for r in rows if r.get("targetUid") == targetUid]
    if q:
        rows = [
            r for r in rows
            if admin_service.matches_search(
                (r.get("action"), r.get("adminUid"), r.get("targetUid"), r.get("reason")), q
            )
        ]

    rows.sort(key=lambda r: str(r.get("timestamp") or ""), reverse=True)
    return admin_service.paginate(rows, page=page, page_size=size)


@router.get("/system/health")
async def admin_system_health(admin: dict = Depends(require_admin)) -> dict:
    """Component health for the System Health page.

    Reports CONFIGURED / NOT CONFIGURED per AI provider by checking whether a
    key is present — never the key, its length, or any prefix of it. A boolean
    is the whole answer an admin needs, and anything more is a partial secret
    leak into an HTTP response.
    """
    import os

    def status(ok: bool) -> str:
        return "HEALTHY" if ok else "DOWN"

    firestore_ok = firestore_service.get_client() is not None
    providers = {
        "groq": bool(os.getenv("GROQ_API_KEY")),
        "gemini": bool(os.getenv("GEMINI_API_KEY")),
        "openrouter": bool(os.getenv("OPENROUTER_API_KEY")),
    }
    try:
        from services import kb_manager
        kb = kb_manager.get_cache_stats()
        rag = {
            "status": "HEALTHY",
            "loadedKbs": kb.get("loaded_kbs", []),
            "cacheSize": kb.get("cache_size", 0),
        }
    except Exception as e:  # noqa: BLE001
        rag = {"status": "DEGRADED", "error": type(e).__name__}

    return {
        "environment": admin_service.environment_label(),
        "checkedAt": admin_service.now_iso(),
        "components": {
            "backend": {"status": "HEALTHY"},
            "firestore": {
                "status": status(firestore_ok),
                # A short configuration reason, never a stack trace.
                "detail": None if firestore_ok else (firestore_service.config_error() or "unconfigured"),
            },
            "aiProviders": {
                "status": "HEALTHY" if any(providers.values()) else "DOWN",
                "configured": providers,
            },
            "rag": rag,
        },
    }
