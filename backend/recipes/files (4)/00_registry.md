# ZITLAS Master Recipe Registry — Category Allocation Table

Target: 4,500 recipes total. Generated in batches of 100. This file tracks progress across all batches — updated after every batch, never reset.

| # | Volume | Category | Target Count | Generated So Far | Remaining |
|---|--------|----------|---------------|-------------------|-----------|
| 1 | Vol 1 | Breakfast | 800 | 100 | 700 |
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
| | | **TOTAL** | **4,500** | **100** | **4,400** |

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
- **Batch 1** (ZITLAS-REC-0001 – 0100): Breakfast, base dishes × fitness concepts grid. Status: COMPLETE. See `batch_001_breakfast.json` / `.csv` / `.md`.
- Batch 2 (0101–0200): Breakfast, continued. Status: NOT STARTED.

## Duplicate-detection registry (concept fingerprints used so far — Batch 1)
Each fingerprint = (base dish family, primary protein combo, concept). No two recipes in Batch 1 share a fingerprint. This list carries forward to Batch 2+.
Base dish families used: upma, poha, idli/dosa batter, paratha/thepla, oats/dalia, besan chilla, moong dosa, sprouts bowl, egg-based, sandwich/toast, smoothie bowl, dhokla, muesli/overnight oats, khichdi(breakfast-style), sattu drink-meal.
