# Harvest pacing update (migration 021)

The web balance now gives a new player a 30-second first crop harvest, followed by longer crops that encourage return visits. Timings are configured on the server so browser defaults cannot override online growth. Existing crop and animal ready timestamps are preserved. Existing orchard cycles are proportionally remapped: growing trees keep the same percentage of progress, while ready trees stay ready.

## Crop times and unlock levels

| Crop | Unlock level | Grow time |
|---|---:|---:|
| Carrot | 1 | 30 sec |
| Tomato | 1 | 2 min |
| Potato | 3 | 5 min |
| Corn | 5 | 10 min |
| Pumpkin | 7 | 20 min |
| Berry | 8 | 30 min |
| Sunflower | 10 | 1 hr |
| Watermelon | 12 | 2 hr |
| Eggplant | 15 | 3 hr |
| Pineapple | 18 | 4 hr |
| Grape | 22 | 6 hr |

## Animal production

Chicken unlocks at level 5 and takes 10 minutes; pig at level 10 and 20 minutes; cow at level 15 and 30 minutes; fish at level 20 and 45 minutes.

## Orchard cycles

Starter orange remains a quick side activity at 90 seconds. Guava takes 10 minutes, mango 20 minutes, and lychee 30 minutes. The migration preserves the existing cycle progress when changing those durations.

## Apply

Run `20261028_021_retention_harvest_pacing.sql` once after migrations 001-020 and the admin game-config SQL are installed, then deploy the updated `outputs` website. The migration is transactional and has not been run against staging or production. Existing crop/animal timers are not restarted.

Unlock levels were reviewed and kept because they already form a clear progression: level 1 starts with two crops, level 3 adds potato, and levels 5/10/15/20 open chicken/pig/cow/fish alongside crop unlocks.
