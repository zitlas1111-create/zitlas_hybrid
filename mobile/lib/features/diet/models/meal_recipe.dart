import '../../../core/util/json_coerce.dart';
import 'recipe.dart';

/// A cooking video that is verified to be ABOUT one specific dish.
///
/// Distinct from `CreatorRecipe` (the /api/creator-recipes browse feature):
/// this one arrives attached to a recipe, was scored against that dish's
/// name by the backend (`meal_recipe_service.video_relevance`), and is
/// dropped entirely when nothing clears the bar — a loosely-related video
/// for a dish the athlete did not choose is the bug this whole path exists
/// to fix, so "no video" is a valid, honest answer.
class MealRecipeVideo {
  const MealRecipeVideo({
    required this.videoId,
    required this.videoUrl,
    required this.title,
    this.channelName,
    this.thumbnailUrl,
    this.durationSeconds,
    this.relevance,
    this.verified = false,
    this.matchType,
  });

  final String videoId;
  final String? videoUrl;
  final String title;
  final String? channelName;
  final String? thumbnailUrl;
  final int? durationSeconds;
  final num? relevance;

  /// True only when the backend confirmed the video NAMES this dish AND
  /// shows it being prepared. A clip that merely shows the finished dish is
  /// never verified — and is never sent at all, which is why the app can
  /// treat an absent video as "coming soon" rather than "lookup failed".
  final bool verified;

  /// `recipe_specific` — the only kind the backend will send.
  final String? matchType;

  static MealRecipeVideo? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final id = asText(m['video_id']);
    if (id == null) return null;
    return MealRecipeVideo(
      videoId: id,
      videoUrl: asText(m['video_url']) ?? 'https://www.youtube.com/watch?v=$id',
      title: asText(m['title']) ?? '',
      channelName: asText(m['channel_name']),
      thumbnailUrl: asText(m['thumbnail_url']),
      durationSeconds: asInt(m['duration_seconds']),
      relevance: asNum(m['relevance']),
      verified: m['verified'] == true,
      matchType: asText(m['match_type']),
    );
  }
}

/// `GET /api/recipes/for-meal` — the recipe for the dish the athlete
/// actually tapped, plus a video about that same dish.
///
/// The contrast with [RecipeRecommendation] is the entire point: that one
/// answers "give me *a* breakfast recipe" and picks at random from the
/// slot's pool, which is why tapping "Poha" could return "Masala Omelette".
/// Here `mealName` is the primary key on both sides — it drives generation,
/// the cache and the video query — so the response is always about the
/// tapped dish or explicitly empty.
class MealRecipeResult {
  const MealRecipeResult({
    required this.mealName,
    this.mealType,
    this.recipe,
    this.video,
    this.videoNote,
    this.cached = false,
    this.usage,
  });

  final String mealName;
  final String? mealType;
  final Recipe? recipe;
  final MealRecipeVideo? video;

  /// Set by the backend when it found a recipe but no video that was
  /// genuinely about this dish. Shown as-is; never a reason to fail.
  final String? videoNote;
  final bool cached;

  /// The weekly recipe allowance AFTER this call (free 7, premium 27), or
  /// null when the backend did not meter it.
  final Map<String, dynamic>? usage;

  static MealRecipeResult fromMap(Map<String, dynamic> m) => MealRecipeResult(
    mealName: asText(m['meal_name']) ?? '',
    mealType: asText(m['meal_type']),
    recipe: Recipe.fromMap(asMap(m['recipe']) ?? const {}),
    video: MealRecipeVideo.fromMap(asMap(m['video'])),
    videoNote: asText(m['video_note']),
    cached: m['cached'] == true,
    usage: asMap(m['usage']),
  );
}
