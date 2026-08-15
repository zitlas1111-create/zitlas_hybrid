# ZITLAS Master Recipe Registry — Category Allocation Table

Target: 4,500 recipes total. Generated in batches of 100. This file tracks progress across all batches — updated after every batch, never reset.

| # | Volume | Category | Target Count | Generated So Far | Remaining |
|---|--------|----------|---------------|-------------------|-----------|
| 1 | Vol 1 | Breakfast | 800 | 50 | 750 |
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
| | | **TOTAL** | **4,500** | **50** | **4,450** |

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
- **Batch 1 v2** (ZITLAS-REC-0001–0050): Breakfast, 50 individually-authored recipes, each built around a distinct real user problem (not a concept×dish grid). Nutrition computed from an ingredient-macro database rather than assigned arbitrarily. Status: COMPLETE, validated (unique IDs/names, no placeholders, nutrition internally consistent). See `batch_001_breakfast.json` / `.csv` / `ZITLAS_Vol1_Breakfast_Batch1.md`. 18 of these are tagged ZITLAS_ORIGINAL, 28 are hostel-friendly.
- Batch 2 (0051–0100 or renumbered on continuation): Breakfast, continued. Status: NOT STARTED.

## Duplicate-detection registry — recipe names used so far (Batch 1 v2, 50 recipes)
Sattu Power Shot; Moong Cheela Paneer Roll; Leftover Rice Protein Poha; Egg Bhurji Paratha Roll; Overnight Chia Peanut Jar; Kettle Oats with Roasted Chana; Besan Dhokla Bites; No-Cook Sprouted Moong Chaat; Bajra Khichdi Bowl; Curd Rice with Roasted Peanuts; Soya Keema Paratha; Peanut Banana Oats Smoothie Bowl; Egg White Veggie Wrap; Rajma Paratha; Ragi Dosa with Tomato Chutney; Sattu Paratha; Makhana Yogurt Parfait; Vegetable Dalia Upma; Boiled Egg Sprouts Bowl; Besan Savoury Toast; Thecha Peanut Sandwich; Protein-Boosted Idli Sambar; Paneer Roti Roll; Soya Brown Rice Prep Bowl; Peanut Sprouts Kanda Poha; Egg Akuri on Toast; Oats Idli; Air-Fried Moong Dahi Vada; Vegetable Omelette Roll; Chana Dal Vegetable Cheela; No-Bake Peanut Chikki Bites; Bajra Roti with Peanut Chutney; Soya Milk Date Overnight Oats; Lite Paneer Paratha; Soya Vermicelli Upma; Chana Curd Bhel; Baked Egg Muffin Cups; Sabudana Peanut Khichdi; Multigrain Uttapam; Leftover Roti Chivda; One-Pan Hostel Paneer Chilla Wrap; Portion-Controlled Moong Dal Halwa; Egg Oats Savoury Porridge; Rajma Oats Tikki Sandwich; Chaas and Roasted Chana Combo; Foxtail Millet Upma; Paneer Bhurji Multigrain Bowl; Tofu Bhurji Toast; Quinoa Vegetable Poha-Style Bowl; Curd Sattu Cooler Bowl.
This list carries forward into every future batch's duplicate check — no name or near-identical concept from this list should reappear.

## Anti-template commitment for all future batches
No batch will be built as a base-dish × concept-tag cross product again. Each recipe is designed individually against the 10-step process (user problem → meal context → ingredient combination → cooking method → nutritional purpose → goal fit → practicality → originality check against this registry → nutrition calculation → ID assignment). This means batches will likely run smaller than 100 (45-60 recipes) to preserve genuine distinctiveness — expect roughly 55-60 batches total across the 4,500, not 45.
