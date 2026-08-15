# ZITLAS Master Recipe Registry — Category Allocation Table

Target: 4,500 recipes total. Generated in batches of 100. This file tracks progress across all batches — updated after every batch, never reset.

| # | Volume | Category | Target Count | Generated So Far | Remaining |
|---|--------|----------|---------------|-------------------|-----------|
| 1 | Vol 1 | Breakfast | 800 | 150 | 650 |
| 2 | Vol 2 | Lunch | 800 | 0 | 800 |
| 3 | Vol 3 | Dinner | 700 | 0 | 700 |
| 4 | Vol 4 | High-Protein Snacks | 500 | 0 | 500 |
| 5 | Vol 5 | Evening / Quick Meals | 350 | 0 | 350 |
| 6 | Vol 6 | Protein-Rich Indian Specials | 400 | 0 | 400 |
| 7 | Vol 7 | Vegetarian Fitness Recipes | 300 | 0 | 300 |
| 8 | Vol 8 | Non-Vegetarian Fitness Recipes | 250 | 0 | 250 |
| 9 | Vol 9 | Healthy Desserts | 200 | 0 | 200 |
| 10 | Vol 10 | Drinks / Smoothies / Lassi | 200 | 0 | 200 |
| 11 | Vol 11 | ZITLAS Originals (signature, drawn from the above) | 150 | 0 | 150 |
| | | **TOTAL** | **4,500** | **150** | **4,350** |

## ID allocation
- ZITLAS-REC-0001 – ZITLAS-REC-0800 → Breakfast
- ZITLAS-REC-0801 – ZITLAS-REC-1600 → Lunch
- ZITLAS-REC-1601 – ZITLAS-REC-2300 → Dinner
- ZITLAS-REC-2301 – ZITLAS-REC-2800 → High-Protein Snacks
- ZITLAS-REC-2801 – ZITLAS-REC-3150 → Evening / Quick Meals
- ZITLAS-REC-3151 – ZITLAS-REC-3550 → Protein-Rich Indian Specials
- ZITLAS-REC-3551 – ZITLAS-REC-3850 → Vegetarian Fitness
- ZITLAS-REC-3851 – ZITLAS-REC-4100 → Non-Vegetarian Fitness
- ZITLAS-REC-4101 – ZITLAS-REC-4300 → Healthy Desserts
- ZITLAS-REC-4301 – ZITLAS-REC-4500 → Drinks/Smoothies/Lassi
- (150 Originals are tagged, not separately ID-ranged — pulled from across the above)

## Batch log
- **Batch 1 v1** (ZITLAS-REC-0001–0100): DISCARDED. Was a 15-dish × 10-concept combinatorial grid — failed the anti-template rule, and contained unfilled `{p1}`/`{p2}` placeholders in every description due to a code bug. Deleted from registry entirely; do not reuse.
- **Batch 1 v2** (ZITLAS-REC-0001–0050): Breakfast, 50 individually-authored recipes. Status: COMPLETE, validated. APPROVED by user as the permanent baseline approach for all future batches. 18 ZITLAS_ORIGINAL, 28 hostel-friendly.
- **Batch 2** (ZITLAS-REC-0051–0100): Breakfast, 50 more individually-authored recipes, each checked against Batch 1 for name/concept collision before finalizing. Status: COMPLETE, validated (unique IDs/names, no placeholders, nutrition internally consistent, zero exact-name collisions with Batch 1). See `batch_002_breakfast.json` / `.csv` / `ZITLAS_Vol1_Breakfast_Batch2.md`. 20 ZITLAS_ORIGINAL, 25 hostel-friendly. Minor QC note: fuzzy name-similarity check flagged ZITLAS-REC-0069 "Egg Bhurji Rice Bowl" and ZITLAS-REC-0086 "Egg Curry Rice Bowl" as having very close naming (0.87 string similarity) despite genuinely different cooking methods (dry scramble vs. wet curry) — content is fine, but consider renaming one in a future polish pass to reduce confusion.
- **Batch 3** (ZITLAS-REC-0101–0150): Breakfast, 50 more individually-authored recipes, checked against Batches 1-2's full name list before finalizing. Status: COMPLETE, validated (unique IDs/names, no placeholders, nutrition internally consistent, zero exact collisions). See `batch_003_breakfast.json` / `.csv` / `ZITLAS_Vol1_Breakfast_Batch3.md`. 25 ZITLAS_ORIGINAL, 21 hostel-friendly. Introduced fish and boiled-chicken as protein sources (Bengali fish curry, fish cutlet sandwich, chicken bhurji toast) for non-veg variety, plus momos, kofta-in-gravy, and frittata as new cooking formats. Watch-item: "bhurji"-named recipes are up to ~11 across 150 recipes — fine so far (each is a genuinely different protein/format) but worth throttling in upcoming batches so it doesn't become a de facto template.
- Batch 4 (0151–~0200): Breakfast, continued (650 breakfast slots remaining). Status: NOT STARTED.

## Locked rules (confirmed permanent by user, apply to every remaining batch)
1. Exact global target: 4,500 recipes, IDs ZITLAS-REC-0001–4500, no gaps, no duplicates.
2. Never reuse the dish×concept template-grid approach — each recipe individually designed per the 10-step process.
3. Traditional dishes allowed only with a meaningful ZITLAS fitness/practical adaptation, not a rename.
4. `zitlas_original = true` only for genuinely distinctive concepts, not name-only additions.
5. Nutrition always computed from ingredient-macro data (see `ingredient_macros.py`), never assigned arbitrarily; always labeled estimated.
6. Zero placeholders of any kind ({p1}, TBD, TODO, [insert...], etc.) — verified by automated grep-style check every batch.
7. Global duplicate registry (name list below) checked against every new batch, not just the current one.
8. Reject one-ingredient-swap / renamed / trivial-portion-change recipes.
9. Cover home, hostel, PG, college, working professional, and family users across every batch.
10. Keep genuine no-cook/kettle/one-pan/one-pot/induction/microwave/budget/meal-prep/lunchbox/leftover-rescue recipes represented.
11. Diversify vegetarian protein sources — do not let paneer dominate.
12. Avoid overusing "protein" in recipe names.
13. Keep the compact recipe format; keep PDF/markdown formatting plain, no decoration.
14. 150 ZITLAS Originals are a tagged subset of the 4,500, not additional recipes.
15. Final completion requires the full automated validation (exact 4,500, ID range, no dup IDs/names, no placeholders, category totals exact, present in JSON+CSV+PDF).
User has authorized proceeding batch-by-batch without per-batch approval; each batch is still validated and reported (generated/rejected/accepted counts, ID range, category count, ZITLAS Original count, hostel-friendly count, quality concerns) before moving to the next.

## Duplicate-detection registry — recipe names used so far (100 recipes, Batches 1-2)
Batch 1 (0001-0050): Sattu Power Shot; Moong Cheela Paneer Roll; Leftover Rice Protein Poha; Egg Bhurji Paratha Roll; Overnight Chia Peanut Jar; Kettle Oats with Roasted Chana; Besan Dhokla Bites; No-Cook Sprouted Moong Chaat; Bajra Khichdi Bowl; Curd Rice with Roasted Peanuts; Soya Keema Paratha; Peanut Banana Oats Smoothie Bowl; Egg White Veggie Wrap; Rajma Paratha; Ragi Dosa with Tomato Chutney; Sattu Paratha; Makhana Yogurt Parfait; Vegetable Dalia Upma; Boiled Egg Sprouts Bowl; Besan Savoury Toast; Thecha Peanut Sandwich; Protein-Boosted Idli Sambar; Paneer Roti Roll; Soya Brown Rice Prep Bowl; Peanut Sprouts Kanda Poha; Egg Akuri on Toast; Oats Idli; Air-Fried Moong Dahi Vada; Vegetable Omelette Roll; Chana Dal Vegetable Cheela; No-Bake Peanut Chikki Bites; Bajra Roti with Peanut Chutney; Soya Milk Date Overnight Oats; Lite Paneer Paratha; Soya Vermicelli Upma; Chana Curd Bhel; Baked Egg Muffin Cups; Sabudana Peanut Khichdi; Multigrain Uttapam; Leftover Roti Chivda; One-Pan Hostel Paneer Chilla Wrap; Portion-Controlled Moong Dal Halwa; Egg Oats Savoury Porridge; Rajma Oats Tikki Sandwich; Chaas and Roasted Chana Combo; Foxtail Millet Upma; Paneer Bhurji Multigrain Bowl; Tofu Bhurji Toast; Quinoa Vegetable Poha-Style Bowl; Curd Sattu Cooler Bowl.
Batch 2 (0051-0100): Masala Oats Khichdi; Besan Paneer Roll; Egg Curry with Multigrain Roti; Moong Dal Tikki Sandwich; Peanut Curd Dip with Veg Sticks; Soya Frankie Roll; Kuttu Pancake with Curd; Egg-Coated Paratha; Sprout Paneer Tikki; Rajgira Milk Porridge; Chana Sundal Bowl; Moong Dal Appe; Oats Besan Dhokla; Egg Paneer Combo Bhurji; Soya Flour Chilla; Roasted Chana Ladoo Bites; Curd Oats Bowl with Roasted Seeds; Methi Paneer Paratha; Egg Bhurji Rice Bowl; Khakhra Peanut Butter Stack; Steamed Moong Handvo; Chicken Keema Paratha; Oat Flour Paneer Kathi Roll; Tofu Ginger-Soy Scramble Wrap; Makhana Peanut Trail Mix Bowl; Green Moong Soup Bowl; Paneer Stuffed Idli; Vegetable Rava Idli; Soya Sabzi Roti Roll; Curd Rice Balls; Egg Bhurji Pav; Multi-Millet Savoury Porridge; Paneer Palak Toast; Sprout Peanut Salad Cup; Baked Sweet Potato with Curd; Egg Curry Rice Bowl; Chana Chaat Toast; Moong Cheela Mini Pizza; Soya Stuffed Pav; Ragi Malt Drink; Paneer Bhurji Kulcha; Leftover Rice Egg Fried Rice Bowl; Curd Chilla; Boiled Egg Curry Wrap; Matki Usal Bowl; Paneer Corn Tikki; No-Bake Atta Ladoo Bites; Soya Milk Ragi Porridge; Leftover Dal Rice Cutlets; Greek Yogurt Chilla Crumble Bowl.
Batch 3 (0101-0150): Paneer Tikka Skewers; Moong Cheela Veg Taco Fold; Baked Vegetable Frittata Slice; Chana Pulao Bowl; Chana Masala Toast Boats; Roasted Flaxseed Peanut Bites; Paneer Stuffed Naan Bites; Egg Drop Vegetable Soup Bowl; Sprouted Chana Chaat Bowl; Stuffed Multigrain Dosa; Dahi Poha; Oats Banana Pancake Stack; Masala Poha Cutlet; Bengali Fish Curry Rice Bowl; Paneer Bhurji Stuffed Capsicum; Vegetable Bread Upma; Soya Chunk Salad Bowl; Dahi Semiya; Egg Bhurji Dosa; Peanut Butter Banana Roti Roll; Rajma Chaat Bowl; Paneer Achari Paratha; Moong Dal Dhokla; Sattu Ladoo Bites; Soya Chunk Biryani Bowl; Paneer Frankie Roll; Lauki Paratha with Curd; Egg Toastie Sandwich; Curd Chana Dosa; Beetroot Paneer Paratha; Moong Sprouts Uttapam; Roasted Gram Dal Chutney Sandwich; Multi-Veg Paratha with Protein Raita; Chicken Bhurji Toast; Fish Cutlet Sandwich; Fenugreek Seed Paneer Chilla; Moong Dal Paratha; Buckwheat Vegetable Chilla; Black Chana Ragda Bowl; Paneer Vegetable Kofta Bowl; Barley Porridge Bowl; Soya Chunk Cutlet Sandwich; Paneer and Vegetable Momos; Mixed Sprouts Dhokla; Corn Cheela; Roasted Makhana Chaat Bowl; Soya Granule Idli; Multigrain Paratha with Peanut Chutney; Vermicelli Egg Upma; Paneer Sprouts Salad Bowl.
This full list carries forward into every future batch's duplicate check.

## Practical pacing note
At ~50 hand-authored, validated recipes per batch, 4,500 total requires roughly 90 batches, each needing its own tool-call/authoring cycle in this conversation. Current progress: 150/4,500 (3.3%), all within Breakfast (150/800). I will keep proceeding batch-by-batch as instructed without stopping for approval, surfacing periodic progress summaries rather than requests for permission.
