import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/recipe_repository.dart';
import '../../models/creator_recipe.dart';

/// A YouTube creator's profile, rendered natively inside ZITLAS.
///
/// The athlete does NOT leave the app to look at a creator — only the
/// explicit "View on YouTube" action does that.
///
/// Every field shown comes from the YouTube API. Subscriber counts, ratings,
/// verified badges and review counts are deliberately absent: ZITLAS has no
/// source of truth for those about someone else's channel, and inventing
/// them would be a fabricated endorsement.
class CreatorProfileScreen extends StatefulWidget {
  const CreatorProfileScreen({super.key, required this.channelId});

  final String channelId;

  @override
  State<CreatorProfileScreen> createState() => _CreatorProfileScreenState();
}

class _CreatorProfileScreenState extends State<CreatorProfileScreen> {
  final _repo = RecipeRepository();

  bool _loading = true;
  CreatorChannel? _channel;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final channel = await _repo.getCreatorChannel(widget.channelId);
      if (!mounted) return;
      setState(() {
        _channel = channel;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
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
        ),
        title: const Text(
          'Creator',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: ZitlasTokens.primary));
    }
    final channel = _channel;
    if (_error != null || channel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_off_outlined, size: 40, color: ZitlasTokens.textMuted),
              const SizedBox(height: 12),
              const Text(
                "We couldn't load this creator's profile right now.",
                textAlign: TextAlign.center,
                style: TextStyle(color: ZitlasTokens.textMuted, fontSize: 13.5),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('Try Again')),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 42,
            backgroundColor: ZitlasTokens.bgCardLight,
            backgroundImage: channel.channelThumbnail != null
                ? NetworkImage(channel.channelThumbnail!)
                : null,
            child: channel.channelThumbnail == null
                ? const Icon(Icons.person_rounded, size: 34, color: ZitlasTokens.textMuted)
                : null,
          ),
          const SizedBox(height: 12),
          Text(
            channel.channelName,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
          ),
          if (channel.channelHandle != null) ...[
            const SizedBox(height: 3),
            Text(
              channel.channelHandle!,
              style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x1FFF0000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'YouTube Creator',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFCC0000)),
            ),
          ),
          if ((channel.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZitlasTokens.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: ZitlasTokens.borderSub),
              ),
              child: Text(
                channel.description!,
                style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.45),
              ),
            ),
          ],
          const SizedBox(height: 18),
          // The ONLY action that leaves ZITLAS, and it is explicit.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openOnYouTube(channel.channelUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              label: const Text('View on YouTube', style: TextStyle(fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                foregroundColor: ZitlasTokens.primaryDark,
                side: const BorderSide(color: ZitlasTokens.primary),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Recipe content belongs to the creator. ZITLAS surfaces it with '
            'attribution and never re-hosts it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: ZitlasTokens.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
