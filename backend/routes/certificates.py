"""
ZITLAS — Expert Certificate Verification Route

POST /api/certificates/verify — AI-validates + OCRs an uploaded coaching
certificate. Rejected uploads (is_certificate=false) are discarded
immediately, matching the product requirement to never persist a
non-certificate file.

STORAGE: this route does NOT persist the accepted file anywhere — it only
returns the AI analysis. This backend runs on Render, whose filesystem is
ephemeral: a previous version of this route wrote accepted files to
backend/uploads/certificates/ and returned a "/uploads/certificates/..."
URL, which worked until the next deploy recreated the container from a
fresh image and silently wiped every file that had been written at
runtime — every certificate uploaded before a deploy 404s forever after
it (this is the bug this rewrite fixes). The frontend, which already has
the original File object and an authenticated Firebase session, now
uploads it directly to Firebase Storage (permanent, survives deploys) and
only THEN calls saveCertificate() with the resulting download URL — see
assets/js/certificate-manager.js's uploadAndVerify(). This route stays
storage-agnostic on purpose.

This route does NOT touch Firestore — same architecture as every other
route in this backend. It returns the computed result; the frontend (in the
expert's authenticated session) persists the expert_certificates/{id} doc
and recomputes experts/{uid}.verified. See CLAUDE.md for why: this project
has no Firebase Admin SDK anywhere in the backend, Firestore is
frontend-only throughout.
"""

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from services import certificate_verification

from services import auth_service
from services.auth_service import require_expert

router = APIRouter()

_ALLOWED_TYPES = {
    "image/jpeg": "jpg",
    "image/png":  "png",
    "application/pdf": "pdf",
}
_MAX_BYTES = 10 * 1024 * 1024  # 10 MB


@router.post("/verify")
async def verify_certificate(
    expertId: str = Form(...),
    file: UploadFile = File(...),
    caller: dict = Depends(require_expert),
) -> JSONResponse:
    """Upload a credential for AI verification. EXPERT ONLY.

    Previously unauthenticated with a client-supplied `expertId`, so anyone
    could attach a certificate to any expert's profile — or burn the AI
    verification budget anonymously. Expert onboarding is frozen, so the only
    legitimate callers are the existing approved experts re-submitting their
    OWN credential.
    """
    expertId = auth_service.assert_owns_expert_id(caller, expertId)
    print(f"[CERT VERIFY] expertId={expertId}  filename={file.filename!r}  type={file.content_type!r}")

    if file.content_type not in _ALLOWED_TYPES:
        raise HTTPException(status_code=400, detail="Only JPG, PNG, and PDF files are accepted.")

    content = await file.read()
    print(f"[CERT VERIFY] size={len(content):,} bytes")
    if len(content) > _MAX_BYTES:
        raise HTTPException(status_code=413, detail="File too large (max 10 MB).")

    # PDF -> rasterize page 1 to PNG for the vision model only. The
    # ORIGINAL PDF (not the raster) is what the frontend uploads to
    # Firebase Storage if this comes back accepted.
    analysis_bytes, analysis_mime = content, file.content_type
    if file.content_type == "application/pdf":
        try:
            import fitz  # PyMuPDF
            pdf = fitz.open(stream=content, filetype="pdf")
            if pdf.page_count < 1:
                raise ValueError("empty PDF")
            pix = pdf[0].get_pixmap(dpi=200)
            analysis_bytes = pix.tobytes("png")
            analysis_mime = "image/png"
            pdf.close()
        except Exception as e:
            print(f"[CERT VERIFY] PDF rasterize failed: {e}")
            raise HTTPException(status_code=400, detail="Could not read this PDF — please upload a clearer file.")

    try:
        analysis = await certificate_verification.verify_certificate_image(analysis_bytes, analysis_mime)
    except Exception as e:
        print(f"[CERT VERIFY] AI verification failed: {e}")
        raise HTTPException(status_code=502, detail=f"Verification AI is unavailable right now: {e}")

    print(f"[CERT VERIFY] is_certificate={analysis.get('is_certificate')} "
          f"confidence={analysis.get('verification_confidence')}")

    if not analysis.get("is_certificate"):
        return JSONResponse({
            "accepted": False,
            "reason": analysis.get("rejection_reason")
                      or "This doesn't appear to be a professional coaching certificate.",
        })

    # Accepted — storage is the FRONTEND's job now (Firebase Storage,
    # permanent). This route intentionally returns no certificateUrl.
    status, score = certificate_verification.compute_status(analysis)
    print(f"[CERT VERIFY] accepted, status={status} score={score} — "
          f"frontend will upload to Firebase Storage and persist certificateUrl")

    return JSONResponse({
        "accepted": True,
        "fileType": file.content_type,
        "coachName": analysis.get("coach_name"),
        "certificateName": analysis.get("certificate_name"),
        "issuingOrganization": analysis.get("issuing_organization"),
        "certificateNumber": analysis.get("certificate_number"),
        "issuedDate": analysis.get("issued_date"),
        "expiryDate": analysis.get("expiry_date"),
        "verificationScore": score,
        "verificationStatus": status,
        "flags": {
            "hasOfficialLogo":  bool(analysis.get("has_official_logo")),
            "hasSignature":     bool(analysis.get("has_signature")),
            "hasQrCode":        bool(analysis.get("has_qr_code")),
            "hasStampOrSeal":   bool(analysis.get("has_stamp_or_seal")),
            "signsOfTampering": bool(analysis.get("signs_of_tampering")),
            "isBlurry":         bool(analysis.get("is_blurry")),
            "hasCroppedText":   bool(analysis.get("has_cropped_text")),
            "missingIssuer":    bool(analysis.get("missing_issuer")),
        },
        "analysisNotes": analysis.get("analysis_notes"),
    })
