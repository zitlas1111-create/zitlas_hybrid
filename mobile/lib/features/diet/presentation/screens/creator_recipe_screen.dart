import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../data/recipe_repository.dart';
import '../../models/creator_recipe.dart';

enum _Phase { loading, error, empty, ready }

/// 🎥 Creator Recipe — a YouTube creator's video for the food the athlete is
/// about to eat.
///
/// PLAYBACK: YouTube's own IFrame embed inside `webview_flutter` (already a
/// dependency for the coaching WebView). That is the officially permitted
/// mechanism — ZITLAS never downloads, re-hosts or proxies media. When
/// YouTube marks a video non-embeddable, the screen shows the thumbnail plus
/// an explicit "Watch on YouTube" action instead of attempting a workaround.
///
/// ATTRIBUTION is not decoration: the creator's name, handle and the YouTube
/// source are always on screen, and this screen never calls the content "a
/// ZITLAS recipe".
class CreatorRecipeScreen extends StatefulWidget {
  const CreatorRecipeScreen({super.key, required this.food, required this.mealType});

  /// The food from the meal card — what relevance is actually judged on.
  final String food;
  final String mealType;

  @override
  State<CreatorRecipeScreen> createState() => _CreatorRecipeScreenState();
}

class _CreatorRecipeScreenState extends State<CreatorRecipeScreen> {
  final _repo = RecipeRepository();

  _Phase _phase = _Phase.loading;
  AthleteRecipeContext _context = const AthleteRecipeContext();

  /// The whole ranked page, fetched ONCE. "See Another Recipe" walks this
  /// list rather than re-querying — every extra search costs YouTube quota
  /// that is shared across the entire deployment.
  List<CreatorRecipe> _videos = const [];
  int _index = 0;
  final Set<String> _shown = {};

  /// Videos whose player reported an error. Never offered again this
  /// session, and used to decide when the pool is genuinely exhausted.
  final Set<String> _failed = {};

  /// True once the player signals it is ready. Until then the video's own
  /// thumbnail is shown as a LOADING state only — never as the final
  /// player, which is what left the screen looking like a frozen image.
  bool _playerReady = false;

  /// The real, interactive YouTube player. `youtube_player_iframe` drives
  /// the official IFrame Player API and renders YouTube's own controls
  /// (play/pause, scrubber, fullscreen), which a hand-hosted iframe inside
  /// a bare WebView never managed to do on Android.
  YoutubePlayerController? _player;

  CreatorRecipe? get _current => _index < _videos.length ? _videos[_index] : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final uid = context.read<AuthState>().profile?.uid;
    if (uid != null) {
      try {
        _context = await _repo.resolveContext(uid);
      } catch (_) {
        // Context only sharpens the search; a failed profile read must not
        // block the feature.
      }
    }
    try {
      final videos = await _repo.getCreatorRecipes(
        food: widget.food,
        mealType: widget.mealType,
        fitnessGoal: _context.fitnessGoal,
        dietType: _context.dietType,
        livingSituation: _context.livingSituation,
        region: _context.state,
        favoriteFoods: _context.favoriteFoods,
        limit: 10,
      );
      if (!mounted) return;
      if (videos.isEmpty) {
        setState(() => _phase = _Phase.empty);
        return;
      }
      setState(() {
        _videos = videos;
        _index = 0;
        _phase = _Phase.ready;
      });
      _mountPlayer();
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _Phase.error);
    }
  }

  void _mountPlayer() {
    final video = _current;
    if (video == null || !video.embeddable) {
      setState(() => _player = null);
      return;
    }
    _shown.add(video.videoId);

    // Hand-hosting the IFrame API in a bare WebView got as far as painting
    // the video, but never produced a working player: the API's `onReady`
    // never fired under Android's `loadDataWithBaseURL`, so YouTube's own
    // controls never appeared and the screen sat on the loading thumbnail.
    // `youtube_player_iframe` drives the same official IFrame Player API but
    // handles the Android specifics (platform view, origin, JS bridge) that
    // the hand-rolled version could not.
    _player?.close();
    final controller = YoutubePlayerController.fromVideoId(
      videoId: video.videoId,
      // Deterministic by design. Android blocks unattended autoplay, so
      // relying on it produces "sometimes plays" — the athlete taps YouTube's
      // own play button instead, which always works.
      autoPlay: false,
      params: const YoutubePlayerParams(
        // YouTube's native chrome: play/pause, scrubber, fullscreen.
        showControls: true,
        showFullscreenButton: true,
        // Keeps playback INSIDE ZITLAS rather than handing off to the
        // system/YouTube fullscreen player.
        playsInline: true,
        strictRelatedVideos: true,
        enableCaption: false,
      ),
    );

    // Ready/error come from the player itself now, not a hand-written JS
    // bridge — so the thumbnail overlay lifts when the player is genuinely
    // interactive, and a dead video is still auto-skipped.
    controller.listen((state) {
      if (!mounted) return;
      if (!_playerReady && state.playerState != PlayerState.unknown) {
        setState(() => _playerReady = true);
      }
      if (state.error != YoutubeError.none) {
        if (kDebugMode) debugPrint('[CREATOR PLAYER] ${video.videoId} -> ${state.error}');
        _onPlayerMessage(video.videoId, 'error:${state.error}');
      }
    });

    setState(() {
      _player = controller;
      _playerReady = false;
    });
  }

  @override
  void dispose() {
    _player?.close();
    super.dispose();
  }

  /// A video that reports a playback error is SKIPPED automatically rather
  /// than left as a broken player — the athlete asked for a recipe, not an
  /// error code. Guarded so a run of bad videos can't loop forever.
  void _onPlayerMessage(String videoId, String message) {
    if (message == 'ready') {
      if (mounted) setState(() => _playerReady = true);
      return;
    }
    if (!message.startsWith('error')) return;
    if (kDebugMode) debugPrint('[CREATOR] playback failed for $videoId: $message');

    _failed.add(videoId);
    final hasAlternative = _videos.any((v) => !_failed.contains(v.videoId));
    if (!hasAlternative) {
      // Everything in the pool failed — show the controlled empty state
      // instead of an endless skip loop.
      if (mounted) setState(() => _phase = _Phase.empty);
      return;
    }
    if (mounted) _seeAnother();
  }

  /// Advances within the already-fetched list — the athlete stays inside
  /// ZITLAS and no new YouTube search is issued.
  void _seeAnother() {
    if (_videos.length <= 1) return;
    // Prefer something not yet seen; fall back to cycling rather than
    // dead-ending once every result has been shown.
    var next = (_index + 1) % _videos.length;
    for (var i = 0; i < _videos.length; i++) {
      final candidate = (_index + 1 + i) % _videos.length;
      final id = _videos[candidate].videoId;
      if (_failed.contains(id)) continue;   // never re-offer a broken video
      if (!_shown.contains(id)) {
        next = candidate;
        break;
      }
    }
    setState(() => _index = next);
    _mountPlayer();
  }

  Future<void> _openOnYouTube(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary),
          onPressed: () => context.pop(),
          tooltip: 'Back to Diet',
        ),
        title: const Text(
          '🎥 Creator Recipe',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.loading:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: ZitlasTokens.primary),
              SizedBox(height: 16),
              Text('Finding a creator recipe for you…',
                  style: TextStyle(color: ZitlasTokens.textMuted, fontSize: 13.5)),
            ],
          ),
        );
      case _Phase.error:
        return _Message(
          icon: Icons.cloud_off_rounded,
          text: 'Creator recipes are temporarily unavailable. Please try again.',
          actionLabel: 'Try Again',
          onAction: _load,
        );
      case _Phase.empty:
        // Deliberately NOT filled with a loosely-related video.
        return _Message(
          icon: Icons.videocam_off_rounded,
          text: 'No suitable creator recipe found right now.',
          actionLabel: 'Try Again',
          onAction: _load,
          secondaryLabel: 'Browse on YouTube',
          onSecondary: () => _openOnYouTube(
            'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent('${widget.food} recipe')}',
          ),
        );
      case _Phase.ready:
        return _buildVideo(_current!);
    }
  }

  Widget _buildVideo(CreatorRecipe video) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              // Shorts are vertical. Forcing 16:9 letterboxed them into a
              // thin strip surrounded by black, which is most of what the
              // "black player" looked like. 9:16 is capped to something
              // that still leaves the title and buttons on screen.
              aspectRatio: video.isShort ? 3 / 4 : 16 / 9,
              child: video.embeddable && _player != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        // THE REAL, INTERACTIVE PLAYER — YouTube's own
                        // chrome (play button, scrubber, fullscreen). Always
                        // mounted, never replaced by an image.
                        YoutubePlayer(
                          key: ValueKey(video.videoId),
                          controller: _player!,
                          aspectRatio: video.isShort ? 3 / 4 : 16 / 9,
                        ),
                        // LOADING STATE ONLY. Covers the brief gap before
                        // the player is interactive, and is torn down the
                        // moment it is — it must never be the final state,
                        // which is exactly what made the screen look frozen.
                        if (!_playerReady)
                          Positioned.fill(
                            child: IgnorePointer(
                              // Ignores pointers so a tap always reaches the
                              // real player underneath, even mid-load.
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (video.thumbnailUrl != null)
                                    Image.network(
                                      video.thumbnailUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, e, s) => Container(color: Colors.black12),
                                    )
                                  else
                                    Container(color: Colors.black12),
                                  Container(color: Colors.black.withValues(alpha: 0.25)),
                                  const Center(
                                    child: SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.4, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    )
                  : _NonEmbeddable(
                      video: video,
                      onWatch: () => _openOnYouTube(video.videoUrl),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            video.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary, height: 1.3),
          ),
          if (video.durationLabel != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 14, color: ZitlasTokens.primary),
                const SizedBox(width: 3),
                Text(
                  'Short · ${video.durationLabel}',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZitlasTokens.primary),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _Attribution(
            video: video,
            onOpenProfile: video.channelId == null
                ? null
                : () => context.push('/creator/${video.channelId}'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _videos.length > 1 ? _seeAnother : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('See Another Recipe',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(
                backgroundColor: ZitlasTokens.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: ZitlasTokens.border,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton.icon(
              onPressed: () => _openOnYouTube(video.videoUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 15),
              label: const Text('Watch on YouTube', style: TextStyle(fontSize: 12.5)),
              style: TextButton.styleFrom(foregroundColor: ZitlasTokens.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// YouTube forbids embedding for this video. Show what we legitimately can
/// (its own thumbnail) and hand the athlete off to YouTube — never a
/// download, a proxy, or a scraped player.
class _NonEmbeddable extends StatelessWidget {
  const _NonEmbeddable({required this.video, required this.onWatch});
  final CreatorRecipe video;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (video.thumbnailUrl != null)
          Image.network(video.thumbnailUrl!, fit: BoxFit.cover,
              errorBuilder: (_, e, s) => Container(color: Colors.black12))
        else
          Container(color: Colors.black12),
        Container(color: Colors.black.withValues(alpha: 0.45)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This creator has disabled in-app playback',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: onWatch,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Watch on YouTube'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Attribution extends StatelessWidget {
  const _Attribution({required this.video, this.onOpenProfile});
  final CreatorRecipe video;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Recipe by',
              style: TextStyle(fontSize: 11, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            video.channelName ?? 'YouTube Creator',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0x1FFF0000),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('YouTube',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFFCC0000))),
              ),
              const Spacer(),
              if (onOpenProfile != null)
                TextButton.icon(
                  onPressed: onOpenProfile,
                  icon: const Icon(Icons.person_outline_rounded, size: 15),
                  label: const Text('View Creator Profile', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: ZitlasTokens.primaryDark,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: ZitlasTokens.textMuted),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 13.5)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
            if (secondaryLabel != null && onSecondary != null) ...[
              const SizedBox(height: 6),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
