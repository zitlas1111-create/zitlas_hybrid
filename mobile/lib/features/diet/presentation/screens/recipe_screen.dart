import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../data/recipe_repository.dart';
import '../../models/meal_slot.dart';
import '../../../../core/network/api_exception.dart';
import '../../models/meal_recipe.dart';
import '../../models/recipe.dart';

enum _Phase { loading, error, none, preview, detail }

/// "Get Easy ZITLAS Recipe" — native Flutter screen (never a WebView, never
/// the website's recipe page), reached from a Diet meal card's recipe
/// button. Fetches from the EXISTING backend recipe API
/// (`GET /api/recipes/recommended`) via [RecipeRepository] — no local copy
/// of the 637-recipe dataset, no second recommendation engine.
class RecipeScreen extends StatefulWidget {
  const RecipeScreen({
    super.key,
    required this.mealType,
    this.mealName,
    this.foods = const [],
    this.repository,
  });

  /// One of breakfast/lunch/dinner/snack — always set from the meal card
  /// that opened this screen (item 2: never a different meal's recipe).
  final String mealType;

  /// THE DISH the athlete tapped, e.g. "Poha, Peanuts". When present it is
  /// the primary key: the screen asks `/api/recipes/for-meal`, whose answer
  /// is about this dish or explicitly empty. When absent (a manual deep link
  /// carrying no meal_name) the screen falls back to the slot recommender —
  /// which is where the original bug lived, so that fallback is never used
  /// to paper over a dish lookup that failed.
  final String? mealName;

  /// The plan components rendered under the meal name. They sharpen
  /// generation; they never replace [mealName] as the identifier.
  final List<String> foods;

  /// Injected only by tests, which drive this screen with the real API
  /// payloads (see test/recipe_video_ui_test.dart) rather than reaching the
  /// network. Null in the app — the screen builds its own, exactly as before.
  final RecipeRepository? repository;

  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  late final RecipeRepository _repo = widget.repository ?? RecipeRepository();
  _Phase _phase = _Phase.loading;
  AthleteRecipeContext _context = const AthleteRecipeContext();
  Recipe? _current;
  List<String> _reasons = const [];
  final Set<String> _shownIds = {};
  bool _viewingDetail = false;

  /// The video for THIS dish, when the backend found one it could verify.
  MealRecipeVideo? _video;
  String? _videoNote;

  /// A spent weekly recipe allowance (free 7, premium 27) is a real answer,
  /// not an outage — it gets its own copy instead of "try again", which
  /// would tell the athlete to repeat something that cannot succeed.
  String? _limitMessage;

  /// True while the dish-specific path is in use, i.e. [widget.mealName] was
  /// supplied. Drives the loading copy and hides "Get Another Recipe", which
  /// is meaningless once the dish itself is the question.
  bool get _dishSpecific => (widget.mealName ?? '').trim().isNotEmpty;

  // Filter overrides — null means "use the user's own profile value".
  // Normalized to the filter sheet's lowercase, singular option values
  // (e.g. "Breakfast" from meal.mealName -> "breakfast", "Snacks" -> "snack")
  // — the backend's own _resolve_meal_type() already accepts any of these
  // forms, but the filter sheet's ChoiceChip needs an exact match to show
  // the right chip as pre-selected when first opened.
  late String _mealType = _normalizeMealType(widget.mealType);

  static String _normalizeMealType(String raw) {
    final lower = raw.toLowerCase();
    return lower == 'snacks' ? 'snack' : lower;
  }
  String? _cookingOverride;
  String? _dietOverride;
  String? _goalOverride;

  /// How long until training, in minutes — pre-workout only, and ONLY ever
  /// set by the athlete tapping a chip on this screen. ZITLAS stores no
  /// workout start time anywhere (`WorkoutDay` carries `duration_minutes`
  /// but no clock time, and a diet meal's `time` is free text with no link
  /// to a training session), so asking is the only honest way to get it.
  /// Null = not stated; the backend then applies its own documented default
  /// rather than either side inventing a time.
  int? _minutesUntilWorkout;

  /// Drives the AppBar title, preview kicker and detail-view "why this was
  /// recommended" framing (item 16/21) — recomputed from `_mealType` (not
  /// cached from `initState`) since a filter-sheet override can change it.
  MealSlot? get _slot => mealSlotFromApiValue(_mealType);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = context.read<AuthState>().profile?.uid;
    if (uid != null) {
      try {
        _context = await _repo.resolveContext(uid);
      } catch (_) {
        // Context is a nice-to-have, not a hard dependency — a failed
        // profile read must not block the recipe fetch itself.
      }
    }
    await _fetch(excludeShown: false);
  }

  Future<bool> _fetch({required bool excludeShown}) async {
    setState(() {
      _phase = _Phase.loading;
      _limitMessage = null;
    });
    if (_dishSpecific) return _fetchForMeal();
    try {
      final result = await _repo.getRecommended(
        mealType: _mealType,
        fitnessGoal: _goalOverride ?? _context.fitnessGoal,
        dietType: _dietOverride ?? _context.dietType,
        livingSituation: _cookingOverride ?? _context.livingSituation,
        state: _context.state,
        excludeIds: excludeShown ? _shownIds : null,
        // Only ever sent for pre-workout, and only when the athlete stated
        // it — never inferred.
        minutesUntilWorkout:
            _slot == MealSlot.preWorkout ? _minutesUntilWorkout : null,
        limit: 1,
      );
      if (!mounted) return false;
      final recipe = result.first;
      if (recipe == null) {
        setState(() => _phase = _Phase.none);
        return false;
      }
      final alreadySeen = excludeShown && _shownIds.contains(recipe.id);
      if (alreadySeen && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You've seen all matching recipes — starting over.")),
        );
      }
      _shownIds.add(recipe.id);
      setState(() {
        _current = recipe;
        _reasons = result.reasonsFor(recipe.id);
        _phase = _Phase.preview;
        _viewingDetail = false;
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _limitMessage = _limitMessageFor(e);
        _phase = _Phase.error;
      });
      return false;
    }
  }

  /// `GET /api/recipes/for-meal` — the recipe for the dish that was tapped.
  ///
  /// No `excludeShown` and no draw-a-different-one retry: for a specific
  /// dish there is exactly one right answer, and the backend caches it under
  /// the dish name so opening the same meal twice returns the same recipe.
  Future<bool> _fetchForMeal() async {
    try {
      final result = await _repo.getForMeal(
        mealName: widget.mealName!.trim(),
        mealType: _slot?.apiValue ?? _mealType,
        foods: widget.foods,
        dietType: _dietOverride ?? _context.dietType,
        fitnessGoal: _goalOverride ?? _context.fitnessGoal,
      );
      if (!mounted) return false;
      final recipe = result.recipe;
      if (recipe == null) {
        setState(() => _phase = _Phase.none);
        return false;
      }
      _shownIds.add(recipe.id);
      setState(() {
        _current = recipe;
        _reasons = recipe.whyItWorks;
        _video = result.video;
        _videoNote = result.videoNote;
        _phase = _Phase.preview;
        _viewingDetail = false;
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _limitMessage = _limitMessageFor(e);
        _phase = _Phase.error;
      });
      return false;
    }
  }

  /// Copy for a spent allowance (429). Null for anything else, which stays
  /// a plain "temporarily unavailable".
  static String? _limitMessageFor(Object e) {
    if (e is! ApiException || e.statusCode != 429) return null;
    final detail = e.body is Map ? (e.body as Map)['detail'] : null;
    final tier = detail is Map ? detail['tier'] : null;
    final limit = detail is Map ? detail['limit'] : null;
    if (tier == 'free') {
      return 'You have used all ${limit ?? 7} recipes for this week. '
          'Upgrade to Premium for 27 a week.';
    }
    return 'Recipe limit reached for this week.';
  }

  void _applyFilters({String? mealType, String? cooking, String? diet, String? goal}) {
    setState(() {
      if (mealType != null) _mealType = mealType;
      _cookingOverride = cooking;
      _dietOverride = diet;
      _goalOverride = goal;
      _shownIds.clear(); // a filter change is a new query, not "another" of the old one
    });
    _fetch(excludeShown: false);
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<_FilterSelection>(
      context: context,
      backgroundColor: ZitlasTokens.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => _RecipeFilterSheet(
        mealType: _mealType,
        cooking: _cookingOverride,
        diet: _dietOverride,
        goal: _goalOverride,
      ),
    );
    if (result != null) {
      _applyFilters(mealType: result.mealType, cooking: result.cooking, diet: result.diet, goal: result.goal);
    }
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
        title: Text(
          _slot?.isWorkoutSlot == true ? _slot!.recipeKicker : '🍳 Easy ZITLAS Recipes',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune, color: ZitlasTokens.textPrimary),
            onPressed: _openFilters,
            tooltip: 'Filters',
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.loading:
        return _CenteredMessage(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: ZitlasTokens.primary),
              const SizedBox(height: 16),
              Text(
                'Finding ${_slot?.findingLabel ?? 'the best ZITLAS recipe'} for you…',
                style: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 13.5),
              ),
            ],
          ),
        );
      case _Phase.error:
        final limited = _limitMessage != null;
        return _CenteredMessage(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(limited ? Icons.lock_clock_rounded : Icons.cloud_off_rounded,
                  size: 40, color: ZitlasTokens.textMuted),
              const SizedBox(height: 12),
              Text(
                  _limitMessage ??
                      'Recipes are temporarily unavailable. Please try again.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: ZitlasTokens.textMuted, fontSize: 13.5)),
              const SizedBox(height: 16),
              // Retrying a spent allowance only reproduces the same answer.
              if (limited)
                OutlinedButton(
                    onPressed: () => context.pop(),
                    child: const Text('Back to Diet'))
              else
                ElevatedButton(
                    onPressed: () => _fetch(excludeShown: false),
                    child: const Text('Try Again')),
            ],
          ),
        );
      case _Phase.none:
        return _CenteredMessage(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.restaurant_menu, size: 40, color: ZitlasTokens.textMuted),
              const SizedBox(height: 12),
              const Text('No ZITLAS recipe matches this yet — check back as our recipe library grows.',
                  textAlign: TextAlign.center, style: TextStyle(color: ZitlasTokens.textMuted, fontSize: 13.5)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => context.pop(), child: const Text('Back to Diet')),
            ],
          ),
        );
      case _Phase.preview:
      case _Phase.detail:
        final recipe = _current;
        if (recipe == null) return const SizedBox.shrink();
        return _viewingDetail
            ? _RecipeDetailView(
                recipe: recipe,
                reasons: _reasons,
                slot: _slot,
                video: _video,
                videoNote: _videoNote,
                // "Get Another Recipe" only makes sense while the question is
                // "a recipe for this slot". Once the athlete tapped a specific
                // dish there IS no other recipe for it — offering one would
                // hand back a different meal, which is the bug this path
                // exists to fix.
                onGetAnother: _dishSpecific
                    ? null
                    : () async {
                        final found = await _fetch(excludeShown: true);
                        if (found) setState(() => _viewingDetail = true);
                      },
              )
            : _RecipePreviewCard(
                recipe: recipe,
                reasons: _reasons,
                slot: _slot,
                onViewRecipe: () => setState(() => _viewingDetail = true),
                minutesUntilWorkout: _minutesUntilWorkout,
                onTimingChanged: _slot == MealSlot.preWorkout
                    ? (minutes) {
                        setState(() {
                          _minutesUntilWorkout = minutes;
                          // A different window is a different question, not
                          // "another of the same" — start the exclusion set
                          // over so the best fuel for the new window can be
                          // offered even if it was already shown.
                          _shownIds.clear();
                        });
                        _fetch(excludeShown: false);
                      }
                    : null,
              );
    }
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 32), child: child));
  }
}

/// Item 4 of the spec — the short recommendation preview shown before the
/// athlete commits to viewing the full recipe.
class _RecipePreviewCard extends StatelessWidget {
  const _RecipePreviewCard({
    required this.recipe,
    required this.reasons,
    required this.onViewRecipe,
    this.slot,
    this.minutesUntilWorkout,
    this.onTimingChanged,
  });
  final Recipe recipe;
  final List<String> reasons;
  final VoidCallback onViewRecipe;
  final MealSlot? slot;

  /// Non-null only for the pre-workout slot — see `_minutesUntilWorkout`.
  final int? minutesUntilWorkout;
  final ValueChanged<int?>? onTimingChanged;

  @override
  Widget build(BuildContext context) {
    final suitability = [
      if (recipe.homeFriendly) 'Home Friendly',
      if (recipe.hostelFriendly) 'Hostel Friendly',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: ZitlasCard(
        color: ZitlasTokens.bgCard,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Kicker(text: slot?.isWorkoutSlot == true ? slot!.recipeKicker : '🍳 Easy ZITLAS Recipe'),
            if (slot?.isWorkoutSlot == true) ...[
              const SizedBox(height: 6),
              Text(slot!.recipeSubtitle, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
            ],
            if (onTimingChanged != null) ...[
              const SizedBox(height: 12),
              _WorkoutTimingPicker(
                selected: minutesUntilWorkout,
                onChanged: onTimingChanged!,
              ),
            ],
            const SizedBox(height: 10),
            Text(
              recipe.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              children: [
                _Stat(value: '${recipe.caloriesKcal ?? '—'}', label: 'kcal'),
                _Stat(value: '${recipe.proteinG ?? '—'}g', label: 'Protein'),
                _Stat(value: '${recipe.totalTimeComputed}', label: 'min'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                _Tag(recipe.difficulty),
                _Tag(recipe.dietType),
                for (final s in suitability) _Tag(s),
              ],
            ),
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                reasons.join(' · '),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted, height: 1.4),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onViewRecipe,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('View Recipe', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Item 12/13 — the full recipe detail.
class _RecipeDetailView extends StatelessWidget {
  const _RecipeDetailView({
    required this.recipe,
    required this.reasons,
    required this.onGetAnother,
    this.slot,
    this.video,
    this.videoNote,
  });
  final Recipe recipe;
  final List<String> reasons;
  /// Null when this recipe is for one specific dish — see the call site.
  final VoidCallback? onGetAnother;

  /// A cooking video the backend verified is about THIS dish, or null.
  final MealRecipeVideo? video;

  /// Why there is no video, when the backend said so.
  final String? videoNote;
  final MealSlot? slot;

  /// Family Combo / Multi-Goal has no implementation anywhere in this app
  /// yet (checked: no family_combo/family_members field on the user doc or
  /// in local state). This is a real, currently-always-false hook rather
  /// than a fabricated signal — the moment that feature exists, this is the
  /// one line that needs to change, not a new section built from scratch.
  bool get _isFamilyContext => false;

  @override
  Widget build(BuildContext context) {
    final suitability = [
      if (recipe.hostelFriendly) 'Hostel Friendly',
      if (recipe.homeFriendly) 'Home Friendly',
    ].join(' & ');
    final badges = <String>[
      recipe.difficulty,
      '${recipe.totalTimeComputed} min total',
      '${recipe.servings} serving${recipe.servings == 1 ? '' : 's'}',
      recipe.costLevel,
      recipe.dietType,
      if (recipe.regionalTag != null) recipe.regionalTag!,
      if (suitability.isNotEmpty) suitability,
      ...recipe.fitnessGoals,
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (slot?.isWorkoutSlot == true) ...[
            _Kicker(text: slot!.recipeKicker),
            const SizedBox(height: 6),
            Text(slot!.recipeSubtitle, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
            const SizedBox(height: 10),
          ],
          Text(recipe.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
          const SizedBox(height: 6),
          if (recipe.description.isNotEmpty)
            Text(recipe.description, style: const TextStyle(fontSize: 13.5, color: ZitlasTokens.textSecondary, height: 1.5)),
          const SizedBox(height: 14),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final b in badges) _Tag(b)]),
          const SizedBox(height: 14),
          if (_isFamilyContext) ...[
            const _Tag('👨‍👩‍👧‍👦 Family Friendly'),
            const SizedBox(height: 4),
            const Text("Portions can be adjusted per family member's goal.",
                style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
            const SizedBox(height: 14),
          ],
          const _SectionTitle('Nutrition'),
          _NutritionGrid(recipe: recipe),
          const _SectionTitle('Ingredients'),
          _BulletList(items: recipe.ingredients),
          const _SectionTitle('How to Make It'),
          _NumberedList(items: recipe.instructions),
          if (recipe.primaryProteinSources.isNotEmpty) ...[
            const _SectionTitle('Primary Protein Sources'),
            _BulletList(items: recipe.primaryProteinSources),
          ],
          if (recipe.whyItWorks.isNotEmpty) ...[
            const _SectionTitle('Why It Works'),
            _BulletList(items: recipe.whyItWorks),
          ],
          const _SectionTitle('Why ZITLAS Recommends It'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ZitlasTokens.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              reasons.isNotEmpty ? '${reasons.join('. ')}.' : 'A well-rounded ZITLAS recipe for this meal.',
              style: const TextStyle(fontSize: 13, color: ZitlasTokens.textPrimary, height: 1.5),
            ),
          ),
          if (recipe.equipment.isNotEmpty) ...[
            const _SectionTitle('Equipment'),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final e in recipe.equipment) _Tag(e)]),
          ],
          if (recipe.tags.isNotEmpty) ...[
            const SizedBox(height: 18),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in recipe.tags) _Tag(t)]),
          ],
          // Only a VERIFIED preparation video is ever rendered. The backend
          // already refuses to send anything else, so this is a second gate
          // rather than the decision — a clip that merely shows the finished
          // dish misleads about what the athlete is meant to do, and no video
          // is strictly better than that.
          if (video != null && video!.verified) ...[
            const _SectionTitle('Watch how to make it'),
            _MealVideoCard(video: video!),
          ] else ...[
            // Always say something. An unverified video reaching here with no
            // note would otherwise render as a silently missing section.
            const _SectionTitle('Watch how to make it'),
            Text(videoNote ?? 'Recipe video coming soon.',
                style: const TextStyle(
                    fontSize: 12.5, color: ZitlasTokens.textMuted, height: 1.5)),
          ],
          const SizedBox(height: 22),
          if (onGetAnother != null)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onGetAnother,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Get Another Recipe', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The verified cooking video for this dish. Opens in YouTube rather than
/// embedding a player: this screen is a recipe, not a video screen, and the
/// browse feature (`CreatorRecipeScreen`) already owns the embedded-player
/// experience.
class _MealVideoCard extends StatelessWidget {
  const _MealVideoCard({required this.video});
  final MealRecipeVideo video;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final url = video.videoUrl;
        if (url == null) return;
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        decoration: BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZitlasTokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            if (video.thumbnailUrl != null)
              SizedBox(
                width: 116,
                height: 74,
                child: Image.network(
                  video.thumbnailUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: ZitlasTokens.bgCardLight,
                    child: Icon(Icons.play_circle_outline,
                        color: ZitlasTokens.textMuted),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: ZitlasTokens.textPrimary),
                    ),
                    if (video.channelName != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        video.channelName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: ZitlasTokens.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(Icons.open_in_new_rounded,
                  size: 18, color: ZitlasTokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
    );
  }
}

class _NutritionGrid extends StatelessWidget {
  const _NutritionGrid({required this.recipe});
  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final cells = [
      ('Calories', '${recipe.caloriesKcal ?? '—'} kcal'),
      ('Protein', '${recipe.proteinG ?? '—'}g'),
      ('Carbohydrates', '${recipe.carbsG ?? '—'}g'),
      ('Fat', '${recipe.fatG ?? '—'}g'),
      ('Fiber', '${recipe.fiberG ?? '—'}g'),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6,
      children: [
        for (final c in cells)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ZitlasTokens.bgCardLight,
              border: Border.all(color: ZitlasTokens.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(c.$1, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted)),
                const SizedBox(height: 2),
                Text(c.$2, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
              ],
            ),
          ),
      ],
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(color: ZitlasTokens.primary, fontWeight: FontWeight.w800)),
                Expanded(child: Text(item, style: const TextStyle(fontSize: 13.5, color: ZitlasTokens.textPrimary, height: 1.4))),
              ],
            ),
          ),
      ],
    );
  }
}

class _NumberedList extends StatelessWidget {
  const _NumberedList({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}.', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: ZitlasTokens.primary)),
                ),
                Expanded(child: Text(items[i], style: const TextStyle(fontSize: 13.5, color: ZitlasTokens.textPrimary, height: 1.4))),
              ],
            ),
          ),
      ],
    );
  }
}

/// "When is your workout?" — the ONLY source of workout timing in ZITLAS.
///
/// The app stores no workout start time (checked: `WorkoutDay` has
/// `duration_minutes` and no clock field; a diet meal's `time` is free text
/// with no link to a training session), so rather than infer a gap from
/// data that doesn't exist, the athlete states it. "Not sure" is a real
/// option and the default: it sends nothing and lets the backend apply its
/// own documented short-window assumption.
class _WorkoutTimingPicker extends StatelessWidget {
  const _WorkoutTimingPicker({required this.selected, required this.onChanged});

  final int? selected;
  final ValueChanged<int?> onChanged;

  static const _options = <(int?, String)>[
    (null, 'Not sure'),
    (10, 'In ~10 min'),
    (25, 'In ~25 min'),
    (45, 'In ~45 min'),
    (90, 'In ~90 min'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'When is your workout?',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (minutes, label) in _options)
              ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 11.5)),
                selected: selected == minutes,
                onSelected: (_) => onChanged(minutes),
                selectedColor: ZitlasTokens.primary.withValues(alpha: 0.15),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ],
    );
  }
}

class _Kicker extends StatelessWidget {
  const _Kicker({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: ZitlasTokens.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZitlasTokens.primary)),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '$value ', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        TextSpan(text: label, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCardLight,
        border: Border.all(color: ZitlasTokens.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.textSecondary)),
    );
  }
}

class _FilterSelection {
  const _FilterSelection({this.mealType, this.cooking, this.diet, this.goal});
  final String? mealType;
  final String? cooking;
  final String? diet;
  final String? goal;
}

/// Item 15 — kept deliberately simple: meal type, cooking situation, diet,
/// goal. No region picker (the athlete's own confirmed region is already
/// applied automatically — see AthleteRecipeContext.state) and no dozens of
/// technical filters.
class _RecipeFilterSheet extends StatefulWidget {
  const _RecipeFilterSheet({this.mealType, this.cooking, this.diet, this.goal});
  final String? mealType;
  final String? cooking;
  final String? diet;
  final String? goal;

  @override
  State<_RecipeFilterSheet> createState() => _RecipeFilterSheetState();
}

class _RecipeFilterSheetState extends State<_RecipeFilterSheet> {
  late String? _mealType = widget.mealType;
  late String? _cooking = widget.cooking;
  late String? _diet = widget.diet;
  late String? _goal = widget.goal;

  static const _mealTypes = [
    ('breakfast', 'Breakfast'),
    ('lunch', 'Lunch'),
    ('dinner', 'Dinner'),
    ('snack', 'Snack'),
    ('pre_workout', 'Pre-Workout'),
    ('post_workout', 'Post-Workout'),
  ];
  static const _cookingOptions = [
    ('home', 'Home Cook'),
    ('hostel', 'Hostel Student'),
    ('pg', 'PG / Limited Kitchen'),
    ('travel', 'Quick / Minimal Equipment'),
  ];
  static const _dietOptions = [
    ('vegetarian', 'Vegetarian'),
    ('non-vegetarian', 'Non-Vegetarian'),
    ('eggetarian', 'Egg'),
  ];
  static const _goalOptions = [
    ('weight_loss', 'Weight Loss'),
    ('muscle_gain', 'Muscle Gain'),
    ('general_fitness', 'General Fitness'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: ZitlasTokens.border, borderRadius: BorderRadius.circular(99))),
            ),
            const Text('Filters', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 16),
            _FilterGroup(label: 'Meal Type', options: _mealTypes, value: _mealType,
                onChanged: (v) => setState(() => _mealType = v)),
            _FilterGroup(label: 'Cooking Situation', options: _cookingOptions, value: _cooking,
                onChanged: (v) => setState(() => _cooking = v), allowClear: true, clearLabel: 'Use my profile'),
            _FilterGroup(label: 'Diet', options: _dietOptions, value: _diet,
                onChanged: (v) => setState(() => _diet = v), allowClear: true, clearLabel: 'Use my profile'),
            _FilterGroup(label: 'Fitness Goal', options: _goalOptions, value: _goal,
                onChanged: (v) => setState(() => _goal = v), allowClear: true, clearLabel: 'Use my profile'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(
                  _FilterSelection(mealType: _mealType, cooking: _cooking, diet: _diet, goal: _goal),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterGroup extends StatelessWidget {
  const _FilterGroup({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.allowClear = false,
    this.clearLabel = 'Any',
  });

  final String label;
  final List<(String, String)> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowClear;
  final String clearLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (allowClear)
                ChoiceChip(
                  label: Text(clearLabel),
                  selected: value == null,
                  onSelected: (_) => onChanged(null),
                  selectedColor: ZitlasTokens.primary.withValues(alpha: 0.15),
                ),
              for (final o in options)
                ChoiceChip(
                  label: Text(o.$2),
                  selected: value == o.$1,
                  onSelected: (_) => onChanged(o.$1),
                  selectedColor: ZitlasTokens.primary.withValues(alpha: 0.15),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
