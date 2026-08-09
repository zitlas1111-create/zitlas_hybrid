# Railway Environment — Preparation Inventory

**Status: PHASE 1 (preparation only).** Nothing has been deployed to Railway.
Render is untouched and remains the live production service. This document
contains **no secret values** — only variable names, purpose, and where each
one currently lives.

Re-derived directly from source on 2026-08-09 (`grep -rhoE
"os\.(getenv|environ\.get)\(" backend/**/*.py`, plus one variable —
`GROQ_API_KEY_DIET` — found only by tracing a dynamic `os.getenv(key_env)`
call whose argument is a variable, not a string literal, so it doesn't show up
in a naive grep for `os.getenv("...")`). Cross-checked against
`docs/CONSOLIDATION.md`'s existing list, which independently confirms the same
set.

## Backend environment variables

| Variable | Used by | Purpose | Required? | Currently on Render? | Railway action | Secret? |
|---|---|---|---|---|---|---|
| `FIREBASE_SERVICE_ACCOUNT_JSON` or `FIREBASE_SERVICE_ACCOUNT_FILE` | `identity_service`, `firestore_service`, `push_service`, `auth_service` | Admin SDK: Firestore, FCM, custom tokens | **Yes** — `/api/coaching/*` returns 503 without it | SECRET EXISTS LOCALLY (not in `backend/.env`; Render dashboard only) | Copy the same value into Railway's variable UI | **Secret** |
| `GROQ_API_KEY` | `groq_service` | Primary LLM, fallback target for `GROQ_API_KEY_DIET` | **Yes** | SECRET EXISTS LOCALLY | Copy | **Secret** |
| `GROQ_API_KEY_DIET` | `assessment.py`, `groq_service` (diet/nutrition prompts) | Separate Groq key so diet-plan generation doesn't share rate limit with general AI | Recommended — falls back to `GROQ_API_KEY` if unset (`groq_service.py` `_get_client`) | SECRET EXISTS LOCALLY | Copy | **Secret** |
| `GEMINI_API_KEY` | `gemini_service` | Vision (Meal Snap, certificate OCR) + LLM fallback | **Yes** | SECRET EXISTS LOCALLY | Copy | **Secret** |
| `OPENROUTER_API_KEY` | `groq_service` | Second LLM fallback | Recommended | SECRET EXISTS LOCALLY | Copy | **Secret** |
| `RAZORPAY_KEY_ID` | `razorpay_service` | Payments — public key half | **Yes** for live payments | SECRET EXISTS LOCALLY | Copy | Sensitive (not a bearer secret, but should not be hardcoded) |
| `RAZORPAY_KEY_SECRET` | `razorpay_service` | Payments — signing secret | **Yes** for live payments | SECRET EXISTS LOCALLY | Copy | **Secret** |
| `ELEVENLABS_API_KEY` | `voice` (Zino TTS) | Text-to-speech | Optional (voice feature only) | SECRET EXISTS LOCALLY | Copy if voice is used | **Secret** |
| `ELEVENLABS_VOICE_ID` | `voice` | Selects Zino's voice | Optional | SECRET EXISTS LOCALLY (not a bearer credential, but treat as configuration, not code) | Copy if voice is used | No |
| `ELEVENLABS_MODEL_ID` | `voice` | TTS model override | Optional | NOT in local `.env` — check Render dashboard | Copy if set on Render | No |
| `SUPPORT_EMAIL` | `support` | Outgoing support mail — From address | Optional | SECRET EXISTS LOCALLY | Copy if support email is used | No |
| `SUPPORT_EMAIL_PASSWORD` | `support` | SMTP auth | Optional | SECRET EXISTS LOCALLY | Copy if support email is used | **Secret** |
| `ZITLAS_ADMIN_UIDS` | `auth_service` | Admin-role allowlist (comma-separated Firebase UIDs) | Recommended | NOT in local `.env` — check Render dashboard | Copy if set on Render | Sensitive |
| `GROQ_PRIMARY_MODEL` / `GROQ_FALLBACK_MODEL` / `GROQ_STT_MODEL` | `groq_service` | Model-ID overrides | Optional (has code defaults) | Check Render dashboard | Copy only if Render has non-default values | No |
| `DISABLE_KB_PREWARM` | `main.py` lifespan | Skips FAISS pre-warm at boot (memory) | Recommended `=true` on a memory-constrained plan | Likely `true` on Render free tier | **Set `true` for the initial Railway test deploy** — see RAG section below | No |
| `ALLOW_MULTI_KB_SEARCH` | `rag_service` | Enables cross-KB search | Optional | Check Render dashboard | Copy Render's current value | No |
| `CLIENT_TRIAL_MODE` | trial-mode config | **Monetisation flag** — whether coaching runs in trial mode | **Yes — must match Render exactly** | Check Render dashboard | Copy Render's exact current value | No |
| `PLATFORM_CHARGES_FREE` | trial-mode config | **Monetisation flag** — whether the platform fee is waived | **Yes — must match Render exactly** | Check Render dashboard | Copy Render's exact current value | No |

⚠️ **`CLIENT_TRIAL_MODE` and `PLATFORM_CHARGES_FREE` were not present in the local `backend/.env`** captured above — they only exist in the Render dashboard. Getting either wrong on Railway silently changes whether coaching is free or paid. **These must be read from the live Render dashboard, not guessed.**

## Platform-provided (not application secrets)

| Variable | Purpose | Render mechanism | Railway mechanism |
|---|---|---|---|
| `PORT` | Port the server binds | Injected automatically | Injected automatically — `startCommand` already uses `$PORT` (`railway.json`) |
| `NIXPACKS_PYTHON_VERSION` | Selects the Nix Python package | N/A (Render mechanism is unrelated — see below) | **Set to `3.13`** — see full writeup below |

### Python version — updated 2026-08-09 after live Render log inspection

**`render.yaml` still declares `PYTHON_VERSION=3.11`, but live Render production logs show the service is actually running under `/opt/render/project/python/Python-3.14.3/`.** This is a confirmed, unexplained drift between declared config and actual runtime — the repo's stated intent (3.11) does not match what Render is really doing (3.14.3). Source of the discrepancy is not knowable from this repo (it lives in Render's own account/dashboard history), so it is reported, not resolved, here.

**This matters for Railway because "reproduce production" turned out to be ambiguous — 3.11 is what's *declared*, 3.14.3 is what's *actually running*.** Rather than pick either by default, both were checked against Nixpacks' real source (`railwayapp/nixpacks`, `src/providers/python.rs`, `main` branch, fetched 2026-08-09):

- `get_nix_python_package()`'s version-match table **only has arms for `3.13, 3.12, 3.11, 3.10, 3.9, 3.8, 3.7` (and `2.7`)**. There is **no `("3", "14")` arm.** Requesting `NIXPACKS_PYTHON_VERSION=3.14` does not error — it silently falls through to the wildcard `_` arm, which returns Nixpacks' generic `python3` alias (whatever version that resolves to in the frozen nixpkgs archive `PYTHON_NIXPKGS_ARCHIVE` Nixpacks pins internally — not necessarily 3.14, and not directly controllable). **Practical conclusion: exact reproduction of Render's observed 3.14.3 is not achievable through Nixpacks' documented mechanism today.** Getting it would require a Dockerfile with an explicit Python 3.14 base image — a bigger structural change, not done here since the task asked to avoid unnecessary Docker configuration if Nixpacks can solve it cleanly.
- Given that constraint, **`3.13`** was chosen: it's the highest version Nixpacks' current match table actually supports (closest to the real 3.14.3, minimizing behavioral distance), and it is a *verified selection*, not the old default-by-habit "3.11". Confirmed via a live PyPI query (2026-08-09) that the two heaviest compiled dependencies both ship prebuilt wheels for it: `faiss-cpu` 1.15.0 and `torch` 2.13.0 both publish `cp313` wheels (both also publish `cp314` wheels, for what it's worth — the versions genuinely aren't the constraint here; Nixpacks' own supported-version list is). `sentence-transformers` is pure Python (no `cpXXX` tag) and is unaffected either way.
- **Action:** set `NIXPACKS_PYTHON_VERSION=3.13` as a Railway variable — confirmed exact key name from Nixpacks' `environment.rs`: `get_config_variable("PYTHON_VERSION")` reads `self.get_variable("NIXPACKS_PYTHON_VERSION")` literally (source read directly, not inferred).
- **This is an interim, evidence-based choice to unblock the build — not a final reproducibility claim.** If exact byte-for-byte version parity with Render (3.14.3) turns out to matter (rather than "a supported, verified-compatible recent 3.x"), that requires a Dockerfile-based approach instead, which is a separate, bigger decision to make deliberately, not as a side effect of a build fix.

## Not found in source

Searched for and confirmed absent — no action needed:
- Any `JWT_SECRET` / session-signing secret (auth is Firebase-native; NOT FOUND IN SOURCE)
- Any database connection string (Firestore only, via the service-account credential above; NOT FOUND IN SOURCE)
- Any `CORS_ORIGINS` env var (CORS is hardcoded in `main.py` — see the audit; not environment-driven)
- Any `WEBHOOK_URL` / `CALLBACK_URL` env var (NOT FOUND IN SOURCE — Razorpay integration is client-side checkout + server verification, no webhook configured)

## How this list was produced (reproducibility note)

Two independent passes, cross-checked:
1. `grep -rhoE "os\.(getenv|environ\.get)\(\s*[\"'][A-Za-z0-9_]+[\"']"` across every `.py` file under `backend/` (excluding `__pycache__`) — catches all *literal* string reads.
2. Manual trace of every call site that passes a **variable** as the env-var name (found one: `groq_service._get_client(key_env)`, called with `groq_key_env="GROQ_API_KEY_DIET"` from `assessment.py` and `groq_service.py`) — a literal-string grep alone misses this class of reference.

If a future audit only re-runs pass 1, it will silently drop `GROQ_API_KEY_DIET` again — worth remembering when this document is next updated.
