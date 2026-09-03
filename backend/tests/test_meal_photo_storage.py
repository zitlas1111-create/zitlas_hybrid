"""
ZITLAS — meal photos must be durable (backend/tests/test_meal_photo_storage.py)

THE BUG THIS PINS
-----------------
Firebase Storage was never provisioned on project zitlas-b8677. Both clients
uploaded meal photos "to Storage, with a fallback", so the fallback fired every
single time: `POST /api/chat/upload` wrote the file to the CONTAINER'S
EPHEMERAL DISK and returned `/uploads/chat/<hash>.jpg`, which was then saved
into `meal_checkins.imageUrl` permanently.

All ten production check-ins took that path. All ten now 404 in the
nutritionist's Meal Reviews tab — including MCI_1787549336726_sc6, the exact
record in the bug report. The athlete was told "Sent to your coach for review."

Two things had to change and both are pinned here:
  1. every call site that PERSISTS a photo URL must demand durable storage,
  2. the ephemeral endpoint must stay intact for chat, which does not persist.

Behavioural coverage of the fallback logic itself lives in
tests/js/meal-photo-durability.test.mjs (`node tests/js/…`), which runs the
real chat-attachments.js against a stub browser. This file guards the call
sites and the Storage rules, which that test cannot see.

Run: python -m pytest tests/test_meal_photo_storage.py -q
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

REPO = Path(__file__).resolve().parents[2]
CHAT_ATTACH = REPO / "frontend" / "website" / "assets" / "js" / "chat-attachments.js"
DIET_JS = REPO / "frontend" / "website" / "pages" / "diet" / "diet.js"
UPLOADER = REPO / "mobile" / "lib" / "features" / "coaching" / "data" / "meal_photo_uploader.dart"
CHECKIN_REPO = REPO / "mobile" / "lib" / "features" / "coaching" / "data" / "meal_checkin_repository.dart"
STORAGE_RULES = REPO / "storage.rules"
CHAT_ROUTE = REPO / "backend" / "routes" / "chat.py"
WORKSPACE_JS = REPO / "frontend" / "website" / "components" / "coaching-workspace.js"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


class TestTheWebsiteCallSites:
    """diet.js writes both persisted photo URLs."""

    @pytest.mark.parametrize("prefix", ["meal_checkins", "meal_snaps"])
    def test_meal_uploads_require_durable_storage(self, prefix):
        src = read(DIET_JS)
        call = re.search(
            r"ZitlasChatAttach\.upload\(\s*file\s*,\s*\{[^}]*pathPrefix:\s*'"
            + prefix + r"'[^}]*\}",
            src,
        )
        assert call, f"no upload call with pathPrefix '{prefix}' — did it move?"
        assert "requireDurable: true" in call.group(0), (
            f"the {prefix} upload may fall back to ephemeral disk; its URL is "
            "persisted and read back days later")

    def test_both_persisted_photo_uploads_are_covered(self):
        """A third persisted upload added without the flag fails here."""
        src = read(DIET_JS)
        calls = re.findall(r"ZitlasChatAttach\.upload\([^;]*?\)", src, re.S)
        persisted = [c for c in calls if "meal_" in c]
        assert len(persisted) == 2, (
            f"expected exactly the 2 known meal uploads, found {len(persisted)} — "
            "a new one must also pass requireDurable")
        for c in persisted:
            assert "requireDurable: true" in c


class TestChatAlsoRequiresDurableStorage:
    """Chat images ARE long-lived references — this class used to assert the
    opposite and has been inverted deliberately, not weakened.

    The original premise ("chat images are displayed immediately, not stored
    as long-lived references") was factually wrong, and the repository
    disproves it three ways:

      * the URL is written into `chat_rooms/{id}/messages/{id}.imageUrl`;
      * `firestore.rules` makes those messages IMMUTABLE
        (`allow update, delete: if false`), so a bad URL can never be fixed;
      * the full history is re-read by `onSnapshot(...).orderBy('timestamp')`
        every single time a chat is opened.

    On Railway the ephemeral fallback writes to the container's own disk —
    `backend/uploads/` is gitignored, is absent from the built image, is
    recreated empty at startup, and no Volume is attached — so every chat
    image 404s after the next deploy or crash-restart. That is the identical
    rot the meal check-ins above were fixed for.
    """

    def test_the_ephemeral_endpoint_still_exists(self):
        """The backend route is untouched — only the callers changed."""
        assert CHAT_ROUTE.exists()
        assert "/upload" in read(CHAT_ROUTE)

    def test_chat_call_sites_demand_durable_storage(self):
        for name in ("components/coaching-workspace.js",
                     "pages/coaches/cprofile.js",
                     "pages/experts/expert-dashboard.js"):
            src = read(REPO / "frontend" / "website" / name)
            calls = re.findall(r"ZitlasChatAttach\.upload\([^;]*?\)", src, re.S)
            assert calls, f"{name}: expected at least one chat upload call"
            for call in calls:
                assert "requireDurable: true" in call, (
                    f"{name}: a chat image URL is persisted into an immutable "
                    f"Firestore message, so it must never fall back to the "
                    f"container's ephemeral disk")

    def test_the_fallback_branch_is_still_reachable(self):
        """The fallback itself is NOT removed — other, non-persisted callers
        may still legitimately use it. Only the chat call sites opt out."""
        src = read(CHAT_ATTACH)
        assert "_uploadToBackend(blob)" in src, "chat lost its fallback entirely"


class TestTheDurableGuardItself:
    def test_it_throws_instead_of_falling_back(self):
        src = read(CHAT_ATTACH)
        guard = re.search(r"if \(opts\.requireDurable\) \{(.*?)\n        \}", src, re.S)
        assert guard, "the requireDurable guard is gone"
        assert "throw" in guard.group(1)
        assert "_uploadToBackend" not in guard.group(1)

    def test_the_message_says_the_photo_was_not_saved(self):
        """'Try again' alone let athletes believe the photo had been sent."""
        src = read(CHAT_ATTACH)
        msg = re.search(r"DURABLE_UPLOAD_FAILED\s*=\s*(.*?);", src, re.S).group(1)
        assert "NOT saved" in msg

    def test_it_is_exported_so_callers_can_match_on_it(self):
        assert "DURABLE_UPLOAD_FAILED: DURABLE_UPLOAD_FAILED" in read(CHAT_ATTACH)


class TestTheFlutterClient:
    def test_the_uploader_supports_a_no_fallback_mode(self):
        src = read(UPLOADER)
        assert "bool requireDurable = false" in src
        assert "durableUploadFailed" in src

    def test_the_guard_skips_the_backend(self):
        src = read(UPLOADER)
        guard = re.search(r"if \(requireDurable\) \{(.*?)\n      \}", src, re.S)
        assert guard, "the requireDurable guard is gone"
        assert "throw Exception(durableUploadFailed)" in guard.group(1)
        assert "_toBackend" not in guard.group(1)

    def test_the_checkin_repository_demands_it(self):
        src = read(CHECKIN_REPO)
        assert re.search(r"uploadPrepared\(\s*prepared\s*,\s*requireDurable:\s*true", src), (
            "meal_checkins.imageUrl is persisted and opened by the nutritionist")

    def test_both_clients_say_the_same_sentence(self):
        """An athlete on two devices must not get two different stories."""
        js = re.search(r"DURABLE_UPLOAD_FAILED\s*=\s*(.*?);", read(CHAT_ATTACH), re.S).group(1)
        dart = re.search(r"durableUploadFailed\s*=\s*(.*?);", read(UPLOADER), re.S).group(1)

        def words(s):
            return " ".join(re.findall(r"[A-Za-z]+", s))

        assert words(js) == words(dart)


class TestStorageRules:
    """The rules that will govern the bucket once it is provisioned."""

    def test_a_meal_photo_is_not_readable_by_path_guessing(self):
        """The requirement: an expert must NOT reach another athlete's photo by
        changing a uid in the path. Coaches are unaffected — they render the
        stored download URL, which carries its own token and never consults
        these rules."""
        rules = read(STORAGE_RULES)
        block = re.search(r"match /meal_checkins/\{uid\}/\{file\} \{(.*?)\}", rules, re.S)
        assert block, "the meal_checkins rule is missing"
        body = block.group(1)
        assert "allow read: if isUser(uid);" in body
        assert "allow read: if signedIn();" not in body, (
            "signedIn() lets ANY expert read ANY athlete's meal photo by path")

    def test_only_the_athlete_writes_their_own_photos(self):
        rules = read(STORAGE_RULES)
        for path in ("meal_checkins", "meal_snaps"):
            block = re.search(r"match /" + path + r"/\{uid\}/\{file\} \{(.*?)\}", rules, re.S)
            assert "allow write: if isUser(uid) && isImageUnder10MB();" in block.group(1)

    def test_unlisted_paths_are_closed(self):
        rules = read(STORAGE_RULES)
        catch_all = re.search(r"match /\{allPaths=\*\*\} \{(.*?)\}", rules, re.S)
        assert "allow read, write: if false;" in catch_all.group(1)

    def test_the_bucket_is_never_public(self):
        rules = read(STORAGE_RULES)
        assert not re.search(r"allow\s+(read|write|read,\s*write)\s*:\s*if\s+true", rules)

    def test_firebase_json_points_at_this_file(self):
        import json
        cfg = json.loads(read(REPO / "firebase.json"))
        assert cfg["storage"]["rules"] == "storage.rules"

    def test_every_upload_prefix_in_the_code_has_a_rule(self):
        """The catch-all denies anything undeclared, so a path used by the app
        but missing here breaks that feature the moment the rules deploy.
        `transformation_photos` was exactly that — found only because this
        cross-check was run before deploying."""
        rules = read(STORAGE_RULES)
        declared = set(re.findall(r"match /([a-z_]+)/\{uid\}/", rules))

        used = set()
        for base, exts in ((REPO / "frontend" / "website", (".js",)),
                           (REPO / "mobile" / "lib", (".dart",))):
            for root, _, files in os.walk(base):
                for f in files:
                    if f.endswith(exts):
                        src = read(Path(root) / f)
                        used |= set(re.findall(
                            r"(?:photoP|p)athPrefix\s*[:=]\s*'([a-z_]+)'", src))
        # The library default, applied whenever a caller passes no prefix.
        used.add("chat_uploads")

        missing = used - declared
        assert not missing, (
            f"used by upload code but not declared in storage.rules: {sorted(missing)}")


class TestTheNutritionistSeesWhichFailureItWas:
    """Three distinct states. The reported bug was a broken-image glyph; the
    deeper problem was that the coach could not tell "the athlete skipped the
    photo" from "the platform lost the photo". Flutter parity is covered by
    mobile/test/meal_review_photo_states_test.dart."""

    def test_a_missing_url_says_no_photo_submitted(self):
        src = read(WORKSPACE_JS)
        fn = re.search(r"function _cwPhotoMarkup\(.*?\n  \}", src, re.S)
        assert fn, "_cwPhotoMarkup is gone"
        assert "No photo submitted" in fn.group(0)

    def test_an_unreachable_url_says_photo_unavailable_instead(self):
        """3 of the 10 production records hold a relative /uploads/chat/ path.
        Calling those 'No photo submitted' blames the athlete for a photo the
        platform lost."""
        src = read(WORKSPACE_JS)
        handler = re.search(r"function _cwWireImageFallbacks\(.*?\n  \}", src, re.S)
        assert "Photo unavailable" in handler.group(0)
        assert "cw-review-thumb--missing" in handler.group(0)

    def test_every_meal_photo_goes_through_the_helper(self):
        """A raw <img> added later would skip both states silently."""
        src = read(WORKSPACE_JS)
        raw = src.count("data-cw-photo src=")
        assert raw == 1, (
            f"expected the only such tag to be inside _cwPhotoMarkup, found {raw}")

    def test_the_review_sheets_are_wired_too(self):
        """They marked their images data-cw-photo but never wired the handler,
        so an unreachable photo still showed a broken glyph once opened."""
        src = read(WORKSPACE_JS)
        open_sheet = re.search(r"function openSheet\(html\) \{(.*?)\n  \}", src, re.S)
        assert "_cwWireImageFallbacks" in open_sheet.group(1)

    def test_the_placeholder_keeps_the_images_own_size(self):
        """Hardcoding the thumb class shrank the enlarged view to 54px."""
        src = read(WORKSPACE_JS)
        handler = re.search(r"function _cwWireImageFallbacks\(.*?\n  \}", src, re.S)
        assert "img.className" in handler.group(0)

    def test_both_placeholder_styles_exist(self):
        css = read(REPO / "frontend" / "website" / "assets" / "css" / "coaching-workspace.css")
        assert ".cw-review-thumb--missing" in css
        assert ".cw-review-thumb--empty" in css
        assert ".cw-review-img-lg.cw-review-thumb--empty" in css, (
            "the enlarged placeholder is a <div> and would collapse without a "
            "min-height — .cw-review-img-lg only caps height")

    def test_the_two_clients_use_the_same_two_labels(self):
        js = read(WORKSPACE_JS)
        dart = read(REPO / "mobile" / "lib" / "features" / "coaching" /
                    "presentation" / "screens" / "meal_review_screen.dart")
        for label in ("No photo submitted", "Photo unavailable"):
            assert label in js, f"website lost the '{label}' state"
            assert label in dart, f"Flutter lost the '{label}' state"


class TestNoOneReDerivesSomeoneElsesStorageRef:
    """The read rule above is only safe while every reader uses the stored
    download URL. A `ref()` built from another user's uid would start failing
    the moment the rules deploy — catch that here instead."""

    def test_refs_are_only_built_on_upload_paths(self):
        offenders = []
        for root, _, files in os.walk(REPO / "frontend" / "website"):
            for f in files:
                if f.endswith(".js"):
                    p = Path(root) / f
                    if ".ref()" in read(p) and p.name != "chat-attachments.js":
                        offenders.append(str(p.relative_to(REPO)))
        for root, _, files in os.walk(REPO / "mobile" / "lib"):
            for f in files:
                if f.endswith(".dart"):
                    p = Path(root) / f
                    if "storage.ref()" in read(p) and p.name != "meal_photo_uploader.dart":
                        offenders.append(str(p.relative_to(REPO)))
        assert not offenders, (
            "these build a Storage ref outside the upload path and may break "
            f"under the uid-scoped read rule: {offenders}")
