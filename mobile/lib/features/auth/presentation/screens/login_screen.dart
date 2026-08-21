import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../auth_state.dart';
import '../../data/auth_exception.dart';
import '../../data/auth_repository.dart';
import '../auth_visuals.dart';
import '../widgets/auth_icons.dart';
import '../widgets/gradient_border_card.dart';

/// Native rebuild of `frontend/pages/login/login.js` + `login.html` +
/// `login.css` — this is a visual migration of the real website auth page,
/// not a redesign. All layout/color/spacing values below are ported from
/// `login.css`'s literal declarations (see the class-level doc comments on
/// each private widget for the exact CSS rule each one mirrors). The one
/// deliberate omission is the page's decorative motion (drifting glow
/// orbs/particles, the animated gradient-border sweep, the mobile
/// "scroll cue" chevron) — a native scrollable screen has no use for a
/// web scroll-hint affordance, and ambient CSS keyframe animations don't
/// change any of the static visual properties this task asks to match.
///
/// All state/validation/submission logic below is unchanged from the prior
/// implementation — only presentation was rewritten.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _confirmController = TextEditingController();

  /* ONE ZITLAS LOGIN. There is no role selector: the sign-in form is
     identical for everybody, and where the account lands is decided AFTER
     authentication by GET /api/auth/role (see RoleRepository), from the
     verified `expert` custom claim plus `experts/{uid}.approved`. Nothing on
     this screen can influence that. */
  bool _isSignup = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _rememberMe = false;
  bool _loading = false;
  bool _googleLoading = false;
  bool _showOverlay = false;
  final Set<String> _fieldErrors = {};

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _clearFieldError(String key) {
    if (_fieldErrors.remove(key)) setState(() {});
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _title {
    if (_isSignup) return 'Create Account';
    return 'Welcome Back';
  }

  String get _subtitle {
    if (_isSignup) return "Join ZITLAS — start your AI-powered fitness journey";
    return 'Sign in to continue your AI-powered fitness journey';
  }

  String get _submitLabel {
    if (_isSignup) return 'Create Account';
    return 'Sign In';
  }

  bool get _validEmail =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_emailController.text.trim());

  Future<void> _handleSubmit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();
    final confirm = _confirmController.text;

    setState(() => _fieldErrors.clear());

    if (email.isEmpty) return setState(() => _fieldErrors.add('email'));
    if (password.isEmpty) return setState(() => _fieldErrors.add('password'));
    if (!_validEmail) {
      setState(() => _fieldErrors.add('email'));
      _showMessage('Please enter a valid email address.');
      return;
    }

    if (_isSignup) {
      if (name.isEmpty) {
        setState(() => _fieldErrors.add('name'));
        _showMessage('Please enter your full name.');
        return;
      }
      if (password.length < 6) {
        setState(() => _fieldErrors.add('password'));
        _showMessage('Password must be at least 6 characters.');
        return;
      }
      if (password != confirm) {
        setState(() => _fieldErrors.add('confirm'));
        _showMessage('Passwords do not match.');
        return;
      }
    }

    setState(() => _loading = true);
    final authState = context.read<AuthState>();
    try {
      if (_isSignup) {
        // Every new account is a user. Expert onboarding is closed, and an
        // expert only exists once an admin grants the claim.
        await authState.signUp(
            email: email, password: password, name: name, role: 'user');
      } else {
        await authState.signIn(email, password);
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
      setState(() {
        if (e.code == null ||
            {'user-not-found', 'wrong-password', 'invalid-credential'}.contains(e.code)) {
          _fieldErrors.addAll({'email', 'password'});
        } else if (e.code == 'email-already-in-use') {
          _fieldErrors.add('email');
        } else if (e.code == 'weak-password') {
          _fieldErrors.add('password');
        }
      });
    } finally {
      if (mounted && !_showOverlay) setState(() => _loading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _googleLoading = true);
    final authState = context.read<AuthState>();
    try {
      final outcome = await authState.signInWithGoogle();
      if (outcome is GoogleSignInResolved && mounted) {
        // Matches login.js's showLoginOverlay() for an existing Google user.
        setState(() => _showOverlay = true);
      } else if (outcome is GoogleSignInNeedsRole && mounted) {
        // A brand-new Google account. This used to open a role picker
        // offering User or Expert; there is no choice to make any more.
        await authState.completeGoogleRoleSelection(outcome.firebaseUser, 'user');
        if (mounted) setState(() => _showOverlay = true);
      }
    } on AuthCancelledException {
      // Silent, matches login.js's popup-closed-by-user no-op.
    } on AuthException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted && !_showOverlay) setState(() => _googleLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !_validEmail) {
      _showMessage('Enter your email address above, then tap Forgot Password.');
      setState(() => _fieldErrors.add('email'));
      return;
    }
    try {
      await context.read<AuthState>().sendPasswordReset(email);
      _showMessage('Password reset email sent! Check your inbox.');
    } on AuthException catch (e) {
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authStatus = context.watch<AuthState>().status;
    final firebaseUnavailable = authStatus == AuthStatus.firebaseUnavailable;
    final mediaHeight = MediaQuery.sizeOf(context).height;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // dark icons over the cream bg
        statusBarBrightness: Brightness.light, // iOS: light background
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: AuthColors.bg,
        body: Stack(
          children: [
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Deliberately NOT inside a SafeArea — this is the
                  // decorative background layer, which should bleed under
                  // the status bar for a true edge-to-edge look. Its own
                  // text content sits well below the status bar's height
                  // regardless (see _HeroSection), so nothing readable is
                  // ever obscured.
                  _HeroSection(heroHeight: mediaHeight * 0.5),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 430),
                          child: GradientBorderCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (firebaseUnavailable) ...[
                                const _FirebaseUnavailableBanner(),
                                const SizedBox(height: 16),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                _title,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AuthColors.ink,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.4,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _subtitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AuthColors.muted,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 24),
                              if (_isSignup) ...[
                                _AuthTextField(
                                  controller: _nameController,
                                  hint: 'Full Name',
                                  iconPath: AuthIconPaths.user,
                                  hasError: _fieldErrors.contains('name'),
                                  textInputAction: TextInputAction.next,
                                  onChanged: () => _clearFieldError('name'),
                                ),
                                const SizedBox(height: 12),
                              ],
                              _AuthTextField(
                                controller: _emailController,
                                hint: 'Email or Mobile Number',
                                iconPath: AuthIconPaths.mail,
                                hasError: _fieldErrors.contains('email'),
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                onChanged: () => _clearFieldError('email'),
                              ),
                              const SizedBox(height: 12),
                              _AuthTextField(
                                controller: _passwordController,
                                hint: 'Password',
                                iconPath: AuthIconPaths.lock,
                                hasError: _fieldErrors.contains('password'),
                                obscureText: _obscurePassword,
                                textInputAction:
                                    _isSignup ? TextInputAction.next : TextInputAction.done,
                                onSubmitted: _isSignup ? null : _handleSubmit,
                                onChanged: () => _clearFieldError('password'),
                                trailing: GestureDetector(
                                  onTap: () =>
                                      setState(() => _obscurePassword = !_obscurePassword),
                                  child: AuthIcon(
                                    _obscurePassword ? AuthIconPaths.eyeOpen : AuthIconPaths.eyeClosed,
                                    size: 16,
                                    color: AuthColors.muted,
                                  ),
                                ),
                              ),
                              if (_isSignup) ...[
                                const SizedBox(height: 12),
                                _AuthTextField(
                                  controller: _confirmController,
                                  hint: 'Confirm Password',
                                  iconPath: AuthIconPaths.lock,
                                  hasError: _fieldErrors.contains('confirm'),
                                  obscureText: _obscureConfirm,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: _handleSubmit,
                                  onChanged: () => _clearFieldError('confirm'),
                                  trailing: GestureDetector(
                                    onTap: () =>
                                        setState(() => _obscureConfirm = !_obscureConfirm),
                                    child: AuthIcon(
                                      _obscureConfirm
                                          ? AuthIconPaths.eyeOpen
                                          : AuthIconPaths.eyeClosed,
                                      size: 16,
                                      color: AuthColors.muted,
                                    ),
                                  ),
                                ),
                              ],
                              if (!_isSignup) ...[
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: GestureDetector(
                                    onTap: _handleForgotPassword,
                                    child: const Text(
                                      'Forgot Password?',
                                      style: TextStyle(
                                        color: AuthColors.cyan,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                GestureDetector(
                                  onTap: () => setState(() => _rememberMe = !_rememberMe),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: Checkbox(
                                          value: _rememberMe,
                                          activeColor: AuthColors.orange,
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          onChanged: (v) =>
                                              setState(() => _rememberMe = v ?? false),
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      const Text(
                                        'Remember Me',
                                        style: TextStyle(
                                          color: AuthColors.muted,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              _AuthPrimaryButton(
                                label: _submitLabel,
                                loading: _loading,
                                onPressed: _loading ? null : _handleSubmit,
                              ),
                              const SizedBox(height: 20),
                              Row(
                                children: [
                                  const Expanded(child: Divider(color: AuthColors.border)),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    child: Text(
                                      'or continue with',
                                      style: TextStyle(
                                        color: AuthColors.muted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const Expanded(child: Divider(color: AuthColors.border)),
                                ],
                              ),
                              const SizedBox(height: 16),
                              _GoogleButton(
                                loading: _googleLoading,
                                onPressed: _googleLoading ? null : _handleGoogleSignIn,
                              ),
                              const SizedBox(height: 18),
                              Center(
                                child: GestureDetector(
                                  onTap: () => setState(() {
                                    _isSignup = !_isSignup;
                                    _fieldErrors.clear();
                                  }),
                                  child: Text(
                                    _isSignup ? 'Already have an account? Sign In' : 'Create Account',
                                    style: const TextStyle(
                                      color: AuthColors.orange,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_showOverlay) const _WelcomeOverlay(),
        ],
      ),
    ),
    );
  }
}

/// Mirrors `.hero-visual` + `.hero-copy` on mobile: a top image block that
/// dissolves into the page background, followed by the brand mark, eyebrow,
/// headline and subcopy — all in normal scroll flow above the login card.
class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.heroHeight});

  final double heroHeight;

  @override
  Widget build(BuildContext context) {
    final imageHeight = heroHeight.clamp(340, 640).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: imageHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/images/loginbg.png',
                fit: BoxFit.cover,
                alignment: const Alignment(0, 0.4),
              ),
              // .hero-visual::after — dissolves the photo into --z-bg at
              // every edge instead of a hard-edged crop.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AuthColors.bg,
                      AuthColors.bg.withValues(alpha: 0),
                      AuthColors.bg.withValues(alpha: 0),
                      AuthColors.bg,
                    ],
                    stops: const [0, 0.14, 0.76, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 4, 26, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Image.asset('assets/images/logo.png', height: 50),
              const SizedBox(height: 14),
              const Text(
                'YOUR AI-POWERED FITNESS JOURNEY STARTS HERE',
                style: TextStyle(
                  color: AuthColors.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              const Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Build Your\n', style: TextStyle(color: AuthColors.ink)),
                    TextSpan(
                      text: 'Healthier Future.',
                      style: TextStyle(color: AuthColors.orange),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Personalized AI-powered fitness plans designed for weight loss, '
                'muscle gain, nutrition, and expert coaching.',
                style: TextStyle(
                  color: AuthColors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `.lf-input-group` — icon + input, 46px tall, 14px radius, translucent
/// white fill, orange focus glow, red shake-border on validation error.
class _AuthTextField extends StatefulWidget {
  const _AuthTextField({
    required this.controller,
    required this.hint,
    required this.iconPath,
    required this.hasError,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.trailing,
  });

  final TextEditingController controller;
  final String hint;
  final String iconPath;
  final bool hasError;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final VoidCallback? onSubmitted;
  final VoidCallback? onChanged;
  final Widget? trailing;

  @override
  State<_AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<_AuthTextField> {
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() => setState(() => _focused = _focusNode.hasFocus));
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.hasError
        ? AuthColors.errorBorder
        : (_focused ? AuthColors.orange : AuthColors.muted);

    return Container(
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.hasError
              ? AuthColors.errorBorder
              : (_focused ? AuthColors.orange.withValues(alpha: 0.5) : AuthColors.border),
        ),
        color: _focused ? AuthColors.inputFillFocus : AuthColors.inputFill,
        boxShadow: _focused
            ? [const BoxShadow(color: Color(0x21FF8C00), blurRadius: 22)]
            : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 46,
            child: Center(child: AuthIcon(widget.iconPath, size: 17, color: iconColor)),
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              obscureText: widget.obscureText,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              onSubmitted: widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
              onChanged: (_) => widget.onChanged?.call(),
              style: const TextStyle(color: AuthColors.ink, fontSize: 14.5),
              cursorColor: AuthColors.orange,
              decoration: InputDecoration(
                // The app's global dark theme (ZitlasTheme.dark, see
                // lib/app/theme.dart) sets inputDecorationTheme.filled=true
                // with a near-black fillColor for the rest of the app's
                // (dark) screens. Without an explicit override here, Flutter
                // merges that theme default into this field, painting a
                // black rectangle behind just the TextField's own text area
                // — that was the "black inner rectangle" bug. This screen
                // already draws the field's real background/border on the
                // outer Container above, so the TextField itself must not
                // paint any fill of its own.
                filled: false,
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: const TextStyle(color: Color(0xB3667085), fontSize: 14.5),
              ),
            ),
          ),
          if (widget.trailing != null)
            Padding(padding: const EdgeInsets.only(right: 14), child: widget.trailing!),
        ],
      ),
    );
  }
}

/// `.btn-login` — full-width 50px gradient button with an ambient glow.
class _AuthPrimaryButton extends StatelessWidget {
  const _AuthPrimaryButton({required this.label, required this.loading, required this.onPressed});

  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [AuthColors.orange, AuthColors.orange2, AuthColors.orange],
          ),
          boxShadow: kAuthButtonGlow,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Center(
              child: loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AuthColors.btnLoginText,
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: AuthColors.btnLoginText,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.btn-google` — white pill button with the real 4-color Google mark.
class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCCFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AuthColors.border),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AuthColors.muted),
                    )
                  else
                    const GoogleLogo(size: 18),
                  const SizedBox(width: 10),
                  Text(
                    loading ? 'Signing in…' : 'Continue with Google',
                    style: const TextStyle(
                      color: AuthColors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.role-selector` — sliding-pill Athlete/Expert toggle.

/// `.login-overlay` — full-screen post-auth transition shown while the
/// router hands off to the resolved dashboard.
class _WelcomeOverlay extends StatelessWidget {
  /* One message for everybody. This used to read "Expert Portal Loading"
     when the login screen's role toggle said expert — but that toggle is
     gone, and the destination is only known once the server answers. */
  const _WelcomeOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: AuthColors.overlayBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const SizedBox(
                      width: 72,
                      height: 72,
                      child: CircularProgressIndicator(strokeWidth: 3, color: AuthColors.orange),
                    ),
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AuthColors.cyan,
                        valueColor: const AlwaysStoppedAnimation(AuthColors.cyan),
                      ),
                    ),
                    Image.asset('assets/images/logo.png', height: 26),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Welcome back',
                style: const TextStyle(
                  color: AuthColors.muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FirebaseUnavailableBanner extends StatelessWidget {
  const _FirebaseUnavailableBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AuthColors.cardSolid,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AuthColors.errorBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Firebase is not configured for this build yet — sign-in is disabled. '
              'See docs/MIGRATION_INVENTORY.md §4.',
              style: const TextStyle(color: AuthColors.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
