import '../../../core/util/json_coerce.dart';

/// A YouTube creator's recipe video.
///
/// EXPLICITLY NOT a [Recipe]. ZITLAS recipes are ZITLAS's own curated
/// content with ingredients, nutrition and instructions; this is someone
/// else's video, surfaced with attribution. Keeping them as separate types
/// is what stops the UI ever labelling a creator's work "a ZITLAS recipe".
class CreatorRecipe {
  const CreatorRecipe({
    required this.videoId,
    required this.title,
    required this.videoUrl,
    this.description,
    this.thumbnailUrl,
    this.channelId,
    this.channelName,
    this.embeddable = true,
    this.platform = 'youtube',
    this.durationSeconds,
    this.isShort = false,
  });

  final String videoId;
  final String title;
  final String videoUrl;
  final String? description;
  final String? thumbnailUrl;
  final String? channelId;
  final String? channelName;

  /// False when YouTube forbids embedding. The screen must then show the
  /// thumbnail + a "Watch on YouTube" action rather than attempting any
  /// workaround — no downloading, no proxying.
  final bool embeddable;
  final String platform;

  /// Real length from YouTube's `contentDetails.duration`. The backend only
  /// ever returns short-form videos (<= 180s), so this is display/telemetry
  /// detail rather than something the client has to police.
  final int? durationSeconds;

  /// Backend's best-effort "this is genuinely a Short" signal.
  final bool isShort;

  /// e.g. "0:45" — shown next to the title so the athlete can see at a
  /// glance that this is a quick watch.
  String? get durationLabel {
    final d = durationSeconds;
    if (d == null || d <= 0) return null;
    return '${d ~/ 60}:${(d % 60).toString().padLeft(2, '0')}';
  }

  /// The public watch URL — used ONLY for the "Watch on YouTube" fallback
  /// and for a non-embeddable video. Playback itself goes through
  /// `youtube_player_iframe`, which is handed [videoId] directly.
  ///
  /// History worth keeping: this screen previously hand-hosted YouTube's
  /// IFrame API inside a bare WebView. Navigating straight to `/embed/`
  /// gave Error 153 (no embedding origin); hosting it via
  /// `loadDataWithBaseURL` fixed that but the API's `onReady` never fired
  /// on Android, so no controls ever appeared. The package handles both.

  static CreatorRecipe? fromMap(Map<String, dynamic> m) {
    final id = asText(m['video_id']);
    if (id == null) return null;
    return CreatorRecipe(
      videoId: id,
      title: asText(m['title']) ?? 'Creator recipe',
      videoUrl: asText(m['video_url']) ?? 'https://www.youtube.com/watch?v=$id',
      description: asText(m['description']),
      thumbnailUrl: asText(m['thumbnail_url']),
      channelId: asText(m['channel_id']),
      channelName: asText(m['channel_name']),
      embeddable: m['embeddable'] != false,
      platform: asText(m['platform']) ?? 'youtube',
      durationSeconds: asInt(m['duration_seconds']),
      isShort: m['is_short'] == true,
    );
  }
}

/// A creator's public YouTube channel. Every field comes from the YouTube
/// API — subscriber counts, ratings and verified badges are deliberately
/// absent rather than invented.
class CreatorChannel {
  const CreatorChannel({
    required this.channelId,
    required this.channelName,
    this.channelHandle,
    this.channelThumbnail,
    required this.channelUrl,
    this.description,
  });

  final String channelId;
  final String channelName;

  /// e.g. "@RahulFitness" — YouTube's `customUrl`, absent for many channels.
  final String? channelHandle;
  final String? channelThumbnail;
  final String channelUrl;
  final String? description;

  static CreatorChannel? fromMap(Map<String, dynamic> m) {
    final id = asText(m['channel_id']);
    if (id == null) return null;
    return CreatorChannel(
      channelId: id,
      channelName: asText(m['channel_name']) ?? 'YouTube Creator',
      channelHandle: asText(m['channel_handle']),
      channelThumbnail: asText(m['channel_thumbnail']),
      channelUrl: asText(m['channel_url']) ?? 'https://www.youtube.com/channel/$id',
      description: asText(m['description']),
    );
  }
}
