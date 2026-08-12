import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/config/env.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/widgets/zitlas_loading_ring.dart';
import '../auth/auth_state.dart';

/// Personal Coaching, served by the Website inside a secure, chromeless
/// WebView until native Flutter reaches feature parity. This is the ONLY
/// WebView in the app — every other module is native.
///
/// Once open, the ENTIRE coach journey stays inside this one WebView as a
/// single continuous Website session — profile, Request Review, Personal
/// Coach, payment, active coaching, diet/training, meal snap/review, chat,
/// calls, progress, End Coaching. Nothing about that journey is bounced back
/// to a native screen; Flutter's only remaining involvement here is what a
/// website genuinely cannot do for itself:
///  * the auth bridge (native Firebase session → a real web session, so the
///    athlete is never asked to log in again — see [_provideToken]);
///  * logout (the native app owns the real session, so the website hands
///    logout back to Flutter to finish — see [_onLogout]);
///  * OS-level capabilities: the camera/gallery file chooser for chat photos,
///    and camera/mic permission grants for coach voice/video calls.
/// The Android back button already walks the Website's OWN page history first
/// (see the `PopScope` in [build]) and only leaves this screen — back to the
/// native Experts list — once that history is exhausted.
///
/// The whole authentication pipeline is instrumented: every stage prints a
/// `[COACHING WEBVIEW]` line, the embedded page's console is mirrored to the
/// native log as `[WV-CONSOLE]`, and the bridge reports the signInWithCustomToken
/// result back over the `ZitlasWebview` channel (`auth-ok`/`auth-fail:<code>`),
/// so a failure names the EXACT stage instead of a silent reload loop.
class CoachingWebViewScreen extends StatefulWidget {
  const CoachingWebViewScreen({
    super.key,
    required this.relativePath,
    required this.title,
  });

  /// Path + query on the backend host (which also serves the website), e.g.
  /// `/pages/coaches/cprofile.html?id=<coachId>&webview=1`.
  final String relativePath;

  /// Shown only if the page fails to load (there is no visible app bar in the
  /// success case — the embedded page provides its own header).
  final String title;

  /// The COMPLETE coach journey — profile browsing, Request Review, Personal
  /// Coach, Razorpay payment, and (once coaching is active) the full coaching
  /// workspace (diet, training, meal snap/review, chat, calls, progress, End
  /// Coaching) — all rendered by the Website's own `cprofile.html` and kept
  /// entirely inside this ONE WebView, exactly like a normal browser visit.
  /// The website's OWN JS decides what to show (browsing UI vs. the active-
  /// coaching overlay) based on the relationship it reads from Firestore;
  /// Flutter never intervenes in that decision or hands any of it back to a
  /// native screen — see the class doc for what IS still Flutter's job.
  ///
  /// [action] optionally deep-links straight into one of the website's own
  /// flows on load — 'verify' (Request Review) | 'coach' (Personal Coach) |
  /// 'ask' (Chat Now) — reusing `cprofile.js`'s OWN existing `?action=`
  /// handling (it already auto-clicks the matching button after load), so
  /// this never duplicates that logic in Dart.
  ///
  /// `expertId=` (not `id=`) matches the query key `cprofile.js`'s real page
  /// `init()` checks FIRST (`params.get('expertId') || params.get('id')`) —
  /// verified against the live site, not the older `getCoachId()` helper
  /// (dead code, never called) that only reads `id=`.
  factory CoachingWebViewScreen.coachProfile({required String expertId, String? action}) {
    var path = '/pages/coaches/cprofile.html'
        '?expertId=${Uri.encodeComponent(expertId)}&webview=1';
    if (action != null && action.isNotEmpty) path += '&action=$action';
    return CoachingWebViewScreen(relativePath: path, title: 'Coach Profile');
  }

  /// The coach/expert portal (roster, reviews, plan editing).
  factory CoachingWebViewScreen.expertDashboard() {
    return const CoachingWebViewScreen(
      relativePath: '/pages/experts/expert-dashboard.html?webview=1',
      title: 'Coach Dashboard',
    );
  }

  @override
  State<CoachingWebViewScreen> createState() => _CoachingWebViewScreenState();
}

class _CoachingWebViewScreenState extends State<CoachingWebViewScreen> {
  late final WebViewController _controller;
  final ApiClient _api = ApiClient()
    ..authTokenProvider = () async => FirebaseAuth.instance.currentUser?.getIdToken();
  final GlobalKey<RefreshIndicatorState> _refreshKey = GlobalKey<RefreshIndicatorState>();

  bool _loading = true;
  bool _failed = false;
  bool _tokenInFlight = false;

  /// Whether the branded loading cover is still in the widget tree.
  ///
  /// Separate from [_loading] so the cover can FADE out (rather than vanish)
  /// and then be removed once the fade ends — leaving it mounted at opacity 0
  /// would keep the ring's AnimationController ticking behind a fully loaded
  /// page for no reason.
  bool _loadingCoverMounted = true;

  /// Message shown on the error view.
  String? _errorMessage;

  /// Set once the bridge reports a successful signInWithCustomToken. Used to
  /// tell a normal first-load login-redirect (session not established yet, wait)
  /// apart from a post-auth bounce (signed in, but the page's own guard still
  /// rejected — an account/data problem, not an auth one).
  bool _sawAuthOk = false;

  /// True once a logout is underway, so the 'logout' message and the login
  /// redirect it triggers don't each try to sign out / navigate.
  bool _loggingOut = false;

  /// Fires if the sign-in produces neither auth-ok nor auth-fail in time, so a
  /// silent stall becomes a visible, retryable error instead of a spinner.
  Timer? _authTimer;
  static const _authTimeout = Duration(seconds: 15);

  /// Live vertical scroll offset of the embedded page (pull-to-refresh arms
  /// only while scrolled to the very top).
  double _scrollY = 0;
  double _pullStartDy = 0;
  bool _arming = false;

  /// The page to load, with the CURRENT native uid appended.
  ///
  /// `uid` is what lets webview-bridge.js verify that the web session it
  /// restored belongs to the user who is signed in natively. The Firebase JS
  /// SDK persists its own session in WebView storage, which a native sign-out
  /// does NOT clear — so without this check an account switch would keep
  /// running the coaching pages as the PREVIOUS user (which is exactly how an
  /// expert ended up in the athlete area). Not a credential: a uid is not
  /// secret and grants nothing on its own; the actual sign-in still requires a
  /// backend-minted custom token.
  String get _url {
    final base = '${Env.apiBaseUrl}${widget.relativePath}';
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return base;
    final sep = base.contains('?') ? '&' : '?';
    return '$base${sep}uid=${Uri.encodeComponent(uid)}';
  }

  /// Host of the backend/website, so the navigation delegate can tell an
  /// in-app link (keep in the WebView) from an external one (system browser).
  late final String _appHost = Uri.parse(Env.apiBaseUrl).host;

  /// The page this screen was opened ON — its ROOT. Back must never escape
  /// past it into an unrelated part of the website; at the root the only way
  /// out is the exit confirmation, which returns to the NATIVE screen below.
  late final String _rootPath = Uri.parse(_url).path;

  /// Path of the page currently showing, tracked from the navigation callbacks
  /// (this webview_flutter version has no onUrlChange). Compared against
  /// [_rootPath] to decide "walk website history" vs "offer to exit".
  String? _currentPath;

  /// Website pages that legitimately belong to the coaching surface. Anything
  /// else on our own host — the athlete profile, the site dashboard, the
  /// website's own Experts list — is NOT part of this flow: Flutter owns those
  /// screens natively, so navigating there inside the coaching WebView is
  /// always wrong, and letting one into the history is what made "Back" land
  /// on the website user profile.
  static const _coachingPaths = <String>[
    '/pages/coaches/cprofile.html',
    '/pages/coaches/expert-review.html',
    '/pages/experts/expert-dashboard.html',
    '/pages/experts/modify-diet.html',
    '/pages/experts/modify-workout.html',
    '/pages/experts/pricing.html',
  ];

  static bool _isCoachingPath(String path) {
    final p = path.toLowerCase();
    for (final allowed in _coachingPaths) {
      if (p == allowed || p.endsWith(allowed)) return true;
    }
    return false;
  }

  bool get _isAtRoot {
    final current = _currentPath;
    // Before the first page commits, treat it as the root: there is no
    // website history to walk yet, so Back must offer to exit.
    if (current == null) return true;
    return current.toLowerCase() == _rootPath.toLowerCase();
  }

  @override
  void initState() {
    super.initState();
    _log('STEP init — url=$_url');
    // Temporary diagnostic — remove once the www.zitlas.com domain-migration
    // investigation is closed. expertId is read back out of the constructed
    // URL rather than threaded through separately, since this screen is
    // shared by every coaching page (coachProfile/expertDashboard/etc) and
    // not all of them carry one; athleteId has no separate identifier in
    // this flow — the signed-in Firebase uid IS the athlete when opened from
    // the athlete side, so that's what's logged under that name.
    final dbgUri = Uri.tryParse(_url);
    _log('[COACHING DEBUG] '
        'origin=${dbgUri?.origin} '
        'apiUrl=${Env.apiBaseUrl} '
        'endpoint=${dbgUri?.path} '
        'athleteId=${FirebaseAuth.instance.currentUser?.uid} '
        'expertId=${dbgUri?.queryParameters['expertId']}');
    _controller = WebViewController.fromPlatformCreationParams(
      const PlatformWebViewControllerCreationParams(),
      onPermissionRequest: _onWebPermissionRequest,
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('ZitlasWebview', onMessageReceived: _onJsMessage)
      // Mirror the embedded page's console to the native log — this is how the
      // page's OWN guard logs ([AUTH UID], [USER DOC], [EXPERT DOC], Firebase
      // errors) become visible while diagnosing the auth pipeline.
      ..setOnConsoleMessage(_onConsole)
      ..setOnScrollPositionChange((ScrollPositionChange c) => _scrollY = c.y)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _log('STEP page-started — $url');
            _currentPath = Uri.tryParse(url)?.path ?? _currentPath;
            // Re-mount the cover as well as re-showing it: a later navigation
            // (or a pull-to-refresh) may have already faded and removed it.
            if (mounted) {
              setState(() {
                _loading = true;
                _loadingCoverMounted = true;
              });
            }
          },
          onPageFinished: (url) {
            _log('STEP page-finished — $url (atRoot=$_isAtRoot)');
            _currentPath = Uri.tryParse(url)?.path ?? _currentPath;
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (WebResourceError err) {
            // Only a MAIN-document failure is fatal; sub-resource errors (an
            // image, a beacon) must not blank the whole screen.
            if (err.isForMainFrame ?? true) {
              _log('STEP FAILURE web-resource — ${err.errorCode} ${err.description}');
              // Temporary diagnostic — remove once the www.zitlas.com
              // domain-migration investigation is closed. A main-frame
              // resource error has no HTTP response at all (this fires for
              // DNS/connection failures too, before any request reaches a
              // server) — err.errorCode/description are the closest
              // equivalents to "status"/"response" available here.
              _log('[COACHING DEBUG] '
                  'origin=${Uri.tryParse(_url)?.origin} '
                  'apiUrl=${Env.apiBaseUrl} '
                  'endpoint=${Uri.tryParse(_url)?.path} '
                  'status=${err.errorCode} '
                  'response=${err.description}');
              _showError('Could not load coaching. Check your connection and retry.');
            }
          },
          onNavigationRequest: _onNavigation,
        ),
      );

    // Android-only wiring: chat image upload (file chooser) + let the page play
    // media (WebRTC call) without a user gesture. iOS gets the equivalents from
    // Info.plist + WKWebView defaults.
    if (_controller.platform is AndroidWebViewController) {
      final android = _controller.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
      android.setOnShowFileSelector(_androidPickFiles);
    }

    _controller.loadRequest(Uri.parse(_url));
  }

  @override
  void dispose() {
    _authTimer?.cancel();
    _api.close();
    super.dispose();
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[COACHING WEBVIEW] $msg');
  }

  // ── WebView console mirror ──────────────────────────────────────────────

  void _onConsole(JavaScriptConsoleMessage m) {
    if (kDebugMode) debugPrint('[WV-CONSOLE ${m.level.name}] ${m.message}');
  }

  // ── Auth bridge (message router) ────────────────────────────────────────

  void _onJsMessage(JavaScriptMessage message) {
    final m = message.message;
    _log('BRIDGE » $m');
    if (m == 'need-token') {
      _provideToken();
    } else if (m == 'logout') {
      _onLogout();
    } else if (m.startsWith('auth-ok')) {
      _onAuthOk(m);
    } else if (m.startsWith('auth-fail:')) {
      _onAuthFail(m.substring('auth-fail:'.length));
    }
    // Everything else (bridge-active, token-claims, auth-state, session-restored)
    // is diagnostic and already logged above.
  }

  /// Mints a custom token for the CURRENT native user and hands it to the page,
  /// which signs in with it. Logs the HTTP result and the (non-secret) JWT
  /// claims so a bad/mismatched token is obvious. On any failure it shows the
  /// error view and returns false — it never silently no-ops.
  Future<bool> _provideToken() async {
    if (_tokenInFlight) {
      _log('STEP token — already in flight, coalescing');
      return false;
    }
    _tokenInFlight = true;
    _log('STEP token-request START → POST /api/auth/webview-token');
    try {
      final res = await _api.post('/api/auth/webview-token');
      final token = (res is Map) ? res['customToken'] as String? : null;
      if (token == null || token.isEmpty) {
        _log('STEP token-request FAILURE — 200 but no customToken in body');
        _showError('Coaching sign-in is unavailable right now. Please try again.');
        return false;
      }
      _log('STEP token-request SUCCESS — got token (${token.length} chars)');
      _logJwtClaims(token);
      // A Firebase custom token is a JWT (no quotes/backslashes), but escape
      // defensively before embedding it in a JS string literal.
      final safe = token.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
      await _controller.runJavaScript("window.__zitlasWebviewSignIn('$safe');");
      _log('STEP token-inject SUCCESS — delivered to page, awaiting auth-ok/auth-fail');
      _startAuthTimeout();
      return true;
    } on ApiException catch (e) {
      _log('STEP token-request FAILURE — HTTP ${e.statusCode}: ${e.message}');
      _showError(_messageForStatus(e.statusCode));
      return false;
    } catch (e) {
      _log('STEP token-request FAILURE — $e');
      _showError('Could not connect to coaching. Check your connection and retry.');
      return false;
    } finally {
      _tokenInFlight = false;
    }
  }

  /// Decodes and logs the NON-SECRET JWT claims (aud/iss/sub/uid/exp) — never
  /// the signature — so a custom-token-mismatch (wrong project) is diagnosable
  /// from the native log alone.
  void _logJwtClaims(String jwt) {
    if (!kDebugMode) return;
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) {
        _log('JWT — not a JWT (${parts.length} segments)');
        return;
      }
      var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      b64 = b64.padRight(b64.length + (4 - b64.length % 4) % 4, '=');
      final claims = jsonDecode(utf8.decode(base64.decode(b64))) as Map<String, dynamic>;
      _log('JWT claims — aud=${claims['aud']} iss=${claims['iss']} '
          'uid=${claims['uid']} exp=${claims['exp']}');
    } catch (e) {
      _log('JWT — could not decode claims: $e');
    }
  }

  void _startAuthTimeout() {
    _authTimer?.cancel();
    _authTimer = Timer(_authTimeout, () {
      if (!mounted || _sawAuthOk || _failed) return;
      _log('STEP auth TIMEOUT — no auth-ok/auth-fail in ${_authTimeout.inSeconds}s');
      _showError('Coaching sign-in timed out. Please retry.');
    });
  }

  void _onAuthOk(String raw) {
    _authTimer?.cancel();
    _sawAuthOk = true;
    _log('STEP auth SUCCESS — $raw (page will render via its own auth listener)');
    // The page renders itself on its onAuthStateChanged(user); just make sure
    // no stale error/spinner is showing.
    if (mounted && (_failed || _loading)) {
      setState(() { _failed = false; _loading = false; _errorMessage = null; });
    }
  }

  void _onAuthFail(String code) {
    _authTimer?.cancel();
    _log('STEP auth FAILURE — signInWithCustomToken code=$code');
    _showError(_messageForAuthCode(code));
  }

  /// The embedded page logged out (it already tore down its Firestore listeners
  /// and cleared web storage first). The native app owns the real session, so
  /// finish the logout natively: sign out of Firebase, which the router's auth
  /// guard turns into a redirect to /login, and leave the WebView. This is why
  /// the website's logout hands off to us instead of navigating to its own
  /// login page (which the WebView blocks).
  Future<void> _onLogout() async {
    if (_loggingOut) return; // may arrive via both the 'logout' message and the login redirect
    _loggingOut = true;
    _log('STEP logout — native sign-out + leave WebView');
    _authTimer?.cancel();
    final router = GoRouter.of(context);
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      _log('native signOut failed: $e');
    }
    if (!mounted) return;
    router.go('/login');
  }

  /// Leaves this screen safely: pops if there is a route underneath (the
  /// normal case — this screen was pushed from the native Experts list),
  /// otherwise goes to the dashboard so GoRouter is never left with zero
  /// pages. Disposing the WebView (listeners, JS channel, controller) is
  /// handled by [dispose]; the Firebase session is deliberately untouched —
  /// leaving coaching is not signing out.
  void _leaveScreen(GoRouter router) {
    if (router.canPop()) {
      router.pop();
      return;
    }
    // Nothing underneath (this screen was reached with go(), e.g. the
    // post-login redirect or a notification tap). The fallback MUST be
    // role-aware: hardcoding '/dashboard' here sent an EXPERT into the athlete
    // home — a silent role downgrade, and one of the ways an expert ended up in
    // the athlete area. Read the role from the live AuthState, never a cached
    // or assumed value.
    final isExpert = context.read<AuthState>().profile?.resolvedRole == 'expert';
    final fallback = isExpert ? '/expert-dashboard' : '/dashboard';
    _log('STEP leave-screen — nothing to pop, role-aware fallback -> $fallback');
    router.go(fallback);
  }


  /// Maps a token-endpoint HTTP status to a human message. 404/405 means the
  /// route is missing from the deployed backend (ApiClient documents this).
  String _messageForStatus(int? status) {
    switch (status) {
      case 401:
      case 403:
        return 'Your session expired. Please sign out and back in, then reopen coaching.';
      case 404:
      case 405:
        return "Coaching isn't available on the server yet. Please try again later.";
      case 500:
      case 502:
      case 503:
        return 'Coaching is temporarily unavailable. Please try again in a moment.';
      default:
        return 'Could not start coaching just now. Please try again.';
    }
  }

  /// Maps a Firebase signInWithCustomToken error code to a human message.
  String _messageForAuthCode(String code) {
    if (code.contains('custom-token-mismatch') || code.contains('invalid-custom-token')) {
      // Server minted a token for a different Firebase project than the website
      // uses — a config problem, not something a retry fixes.
      return 'Coaching sign-in is misconfigured on the server. Please contact support.';
    }
    if (code.contains('network')) {
      return 'Network problem during coaching sign-in. Check your connection and retry.';
    }
    if (code == 'no-channel' || code == 'no-firebase') {
      return 'Coaching could not start. Please reopen it.';
    }
    return 'Coaching sign-in did not complete. Please retry.';
  }

  /// Single choke point for the error view.
  void _showError(String message) {
    _authTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _failed = true;
      _loading = false;
      _errorMessage = message;
    });
  }

  // ── Permissions (WebRTC coach calls) ───────────────────────────────────

  Future<void> _onWebPermissionRequest(WebViewPermissionRequest request) async {
    final wantsCamera = request.types.contains(WebViewPermissionResourceType.camera);
    final wantsMic = request.types.contains(WebViewPermissionResourceType.microphone);
    _log('STEP web-permission — camera=$wantsCamera mic=$wantsMic');

    var granted = true;
    if (wantsCamera) {
      granted = granted && (await Permission.camera.request()).isGranted;
    }
    if (wantsMic) {
      granted = granted && (await Permission.microphone.request()).isGranted;
    }
    if (granted) {
      await request.grant();
    } else {
      await request.deny();
    }
  }

  // ── File chooser (chat image attachments, Android) ──────────────────────

  Future<List<String>> _androidPickFiles(FileSelectorParams params) async {
    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (file == null) return const <String>[];
      return <String>[Uri.file(file.path).toString()];
    } catch (e) {
      _log('file pick failed: $e');
      return const <String>[];
    }
  }

  // ── Navigation policy ───────────────────────────────────────────────────

  NavigationDecision _onNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.navigate;

    // The native app is already authenticated, so the embedded module must
    // NEVER show the website's own login page.
    if (uri.path.toLowerCase().contains('/login')) {
      _log('STEP nav-login-intercept — sawAuthOk=$_sawAuthOk loggingOut=$_loggingOut');
      if (_loggingOut) {
        // Logout already in progress (via the 'logout' message) — just block the
        // website login; the native sign-out is taking us to the native login.
      } else if (_sawAuthOk) {
        // We WERE signed in and the page is now heading to login — a logout or a
        // session end (the website's own onAuthStateChanged(null) fires this
        // during signOut, possibly before its 'logout' message reaches us).
        // Finish it natively and leave, rather than re-authenticating (which
        // would defeat logout).
        _onLogout();
      } else {
        // First-load race: the page's guard ran before sign-in landed. Ensure a
        // token is on its way and WAIT for auth-ok — do NOT reload.
        _provideToken();
      }
      return NavigationDecision.prevent;
    }

    // Non-http(s) schemes and other hosts leave the WebView via the system
    // handler — the embedded module never becomes a general-purpose browser.
    final isHttp = uri.scheme == 'http' || uri.scheme == 'https';
    final sameHost = uri.host.isEmpty || uri.host == _appHost;

    if (isHttp && sameHost) {
      // ROOT CAUSE of "Back from Coach Profile lands on the website user
      // profile": pages on our own host that are NOT part of the coaching
      // surface could be navigated to (the site's shared bottom navbar links
      // to /pages/profile/profile.html, and cprofile.js falls back to
      // coaches.html when it cannot resolve an expert). Once such a page
      // entered the WebView history, walking back landed on it.
      //
      // Flutter owns those screens natively, so they are never a legitimate
      // destination here. Blocking them keeps the history purely coaching —
      // which is what makes back navigation predictable — and does not depend
      // on the website's own CSS chrome-hiding having loaded.
      if (!_isCoachingPath(uri.path)) {
        _log('STEP nav-blocked (not a coaching page) — ${uri.path}');
        // The website's own header back arrow navigates to coaches.html, and
        // its navbar to profile.html. Both mean "the user wants out of here",
        // so leave the WebView and land on the native screen underneath —
        // the same thing the hardware back button does. One behaviour, two
        // buttons, and no warning: this is ordinary navigation.
        _leaveScreen(GoRouter.of(context));
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }

    _launchExternal(uri);
    return NavigationDecision.prevent;
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _log('external launch failed: $e');
    }
  }

  // ── Pull-to-refresh ─────────────────────────────────────────────────────
  // A passive [Listener] observes pointer moves WITHOUT entering the gesture
  // arena, so the WebView keeps scrolling normally.

  void _onPointerDown(PointerDownEvent e) {
    _arming = _scrollY <= 0.5;
    _pullStartDy = e.position.dy;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_arming) return;
    if (_scrollY > 0.5) {
      _arming = false;
      return;
    }
    if (e.position.dy - _pullStartDy > 110) {
      _arming = false;
      _refreshKey.currentState?.show();
    }
  }

  Future<void> _onRefresh() async {
    await _controller.reload();
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        // Capture the router BEFORE the await — never touch BuildContext
        // across an async gap.
        final router = GoRouter.of(context);
        // 1) INTERNAL coaching navigation (profile -> request -> payment ->
        //    active coaching -> diet/training/chat…): walk the website's own
        //    history, which feels native and preserves the flow.
        //
        //    Anchored on the ROOT rather than on canGoBack() alone: history can
        //    contain entries from redirects during load, and following those
        //    blindly is exactly how Back used to escape the coaching surface
        //    into the website user profile.
        if (!_isAtRoot && await _controller.canGoBack()) {
          await _controller.goBack();
          return;
        }
        if (!mounted) return;
        // 2) At the ROOT the WebView is just another destination — back leaves
        //    it and lands on the native screen underneath (Experts). NO
        //    warning: closing a WebView is not exiting the app, and the app
        //    root is the only place that ever asks (see AppShell).
        _leaveScreen(router);
      },
      child: Scaffold(
        // TRANSPARENT, not black. The route is non-opaque (see _webViewPage in
        // app/router.dart), so the Flutter screen this was opened from is still
        // painted underneath — a black Scaffold here is exactly what turned the
        // hand-off into a black screen. The WebView itself already sets a
        // transparent background (setBackgroundColor below), so during load the
        // previous screen shows through the blur; once the page paints, the
        // website covers it normally.
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: _failed ? _errorView() : _webView(),
        ),
      ),
    );
  }

  Widget _webView() {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _arming = false,
      onPointerCancel: (_) => _arming = false,
      child: RefreshIndicator(
        key: _refreshKey,
        notificationPredicate: (_) => false,
        onRefresh: _onRefresh,
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            // Branded loading cover: lodo.png with the animated neon ring,
            // shown while the page loads and faded out once it is ready.
            //
            // Driven entirely by the EXISTING WebView loading lifecycle
            // (onPageStarted sets _loading, onPageFinished clears it) — there
            // is no artificial delay anywhere, so it disappears exactly when
            // the website is actually ready.
            //
            // `_loadingCoverMounted` keeps it in the tree only until the fade
            // finishes and then removes it, so the ring's ticker is not left
            // spinning invisibly behind a loaded page.
            if (_loadingCoverMounted)
              Positioned.fill(
                child: IgnorePointer(
                  // Blocks taps on a half-loaded page while visible, and gets
                  // out of the way (including of pull-to-refresh) once faded.
                  ignoring: !_loading,
                  child: AnimatedOpacity(
                    opacity: _loading ? 1 : 0,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut,
                    onEnd: () {
                      if (!_loading && mounted) {
                        setState(() => _loadingCoverMounted = false);
                      }
                    },
                    // The previous Flutter screen stays visible through this
                    // layer: blurred and dimmed, never replaced. The blur and
                    // the scrim are one BackdropFilter subtree so they fade in
                    // and out together with the logo — no frame shows a bare
                    // colour, which is what removes the black flash instead of
                    // just recolouring it.
                    child: _TransitionScrim(child: const ZitlasLoadingRing()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    // Reuses the SAME blur+dim layer as the loading cover. The Scaffold is
    // transparent now, so without this the white error text would sit directly
    // on the un-dimmed previous screen and be unreadable. A failed load
    // therefore lands on the recognisable (faint) screen the athlete came from
    // plus a legible message — never a black dead end.
    return _TransitionScrim(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 46, color: Colors.white54),
            const SizedBox(height: 14),
            Text(
              "Couldn't load ${widget.title}",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _errorMessage ?? 'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () {
                // Fresh attempt: clear error + the auth signals so a retry is
                // clean rather than already-exhausted.
                setState(() {
                  _failed = false;
                  _loading = true;
                  _errorMessage = null;
                });
                _sawAuthOk = false;
                _tokenInFlight = false;
                _authTimer?.cancel();
                _controller.loadRequest(Uri.parse(_url));
              },
              child: const Text('Retry'),
            ),
            TextButton(
              onPressed: () => _leaveScreen(GoRouter.of(context)),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Flutter → Website hand-off layer: the previous screen, blurred and
/// dimmed, with [child] (the ZITLAS badge + neon ring) bright and sharp on top.
///
/// WHY A BACKDROP FILTER RATHER THAN A SCREENSHOT. `BackdropFilter` blurs
/// whatever is already painted behind it in the same frame, so the "previous
/// screen" is the live one — nothing is captured, nothing is sized to a
/// particular device, and there is no image buffer to hold or leak. It works
/// identically on every Android screen size because it never has a resolution
/// of its own. This is only possible because the route is non-opaque
/// (`_webViewPage`); an opaque route would leave nothing behind to blur.
///
/// The scrim is layered INSIDE the filter subtree so the blur and the dim
/// animate as one unit with the logo, which is what prevents a bare-colour
/// frame (the old black flash) at either end of the fade.
class _TransitionScrim extends StatelessWidget {
  const _TransitionScrim({required this.child});

  final Widget child;

  /// Enough blur that the screen below reads as texture and depth rather than
  /// as content competing with the logo, while still being recognisably the
  /// screen the athlete just came from.
  static const double _blurSigma = 18;

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
      child: DecoratedBox(
        // ~54% -> ~72% dim, centre-weighted: a flat scrim at this strength
        // flattens the whole frame, whereas easing it darker toward the edges
        // keeps the middle clearer and lets the badge sit in its own pool of
        // light. Inside the 50-70% band, with the logo the brightest element.
        //
        // The tone is ZITLAS deep-green charcoal, NOT neutral black, and that is
        // deliberate for the one path where there is nothing to blur: most
        // entries `push` this route (so the previous screen is underneath), but
        // a notification tap can `go('/expert-dashboard')`, which REPLACES the
        // stack and leaves no underlay. With a near-black scrim that case would
        // fall back to exactly the black screen this change exists to remove;
        // tinted, it reads as an intentional brand surface either way.
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            radius: 0.95,
            colors: [Color(0x8A16281C), Color(0xB80D1611)],
          ),
        ),
        child: Center(child: child),
      ),
    );
  }
}
