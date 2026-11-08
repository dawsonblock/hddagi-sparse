# Sparse-brick memory model: 6 cascades, 16x8x16

Source-derived arithmetic. Capacity is what costs memory, not occupancy.

| mode | pools | residency | dense MiB | atlas MiB | overhead MiB | net saved MiB | saving % of dense |
|---|---|---|---|---|---|---|---|
| light_only | unified | 10% | 24.00 | 2.40 | 0.23 | 21.37 | 89.0% |
| light_only | unified | 25% | 24.00 | 6.00 | 0.29 | 17.70 | 73.8% |
| light_only | unified | 33% | 24.00 | 7.92 | 0.33 | 15.75 | 65.6% |
| light_only | unified | 50% | 24.00 | 12.00 | 0.40 | 11.60 | 48.3% |
| light_only | unified | 67% | 24.00 | 16.08 | 0.47 | 7.45 | 31.0% |
| light_only | unified | 75% | 24.00 | 18.00 | 0.51 | 5.49 | 22.9% |
| light_only | unified | 90% | 24.00 | 21.60 | 0.57 | 1.83 | 7.6% |
| light_only | unified | 100% | 24.00 | 24.00 | 0.61 | -0.61 | -2.5% |
| three_field | unified | 10% | 54.00 | 5.40 | 0.23 | 48.37 | 89.6% |
| three_field | unified | 25% | 54.00 | 13.50 | 0.29 | 40.20 | 74.5% |
| three_field | unified | 33% | 54.00 | 17.82 | 0.33 | 35.85 | 66.4% |
| three_field | unified | 50% | 54.00 | 27.00 | 0.40 | 26.60 | 49.3% |
| three_field | unified | 67% | 54.00 | 36.19 | 0.47 | 17.34 | 32.1% |
| three_field | unified | 75% | 54.00 | 40.50 | 0.51 | 12.99 | 24.1% |
| three_field | unified | 90% | 54.00 | 48.60 | 0.57 | 4.83 | 8.9% |
| three_field | unified | 100% | 54.00 | 54.00 | 0.61 | -0.61 | -1.1% |
| three_field | split | 10% | 54.00 | 5.40 | 0.72 | 47.88 | 88.7% |
| three_field | split | 25% | 54.00 | 13.50 | 0.95 | 39.55 | 73.2% |
| three_field | split | 33% | 54.00 | 17.82 | 1.08 | 35.10 | 65.0% |
| three_field | split | 50% | 54.00 | 27.00 | 1.34 | 25.66 | 47.5% |
| three_field | split | 67% | 54.00 | 36.19 | 1.60 | 16.21 | 30.0% |
| three_field | split | 75% | 54.00 | 40.50 | 1.73 | 11.77 | 21.8% |
| three_field | split | 90% | 54.00 | 48.60 | 1.96 | 3.44 | 6.4% |
| three_field | split | 100% | 54.00 | 54.00 | 2.11 | -2.11 | -3.9% |

## Break-even residency

- `light_only`: net saving stays positive only below **97.5%** residency.
- `three_field`: net saving stays positive only below **98.9%** residency.

## Context against the whole HDDAGI footprint

- HDDAGI subsystem at this scenario (M0.04): **291.6 MiB**
- Net saving at 50% three-field residency: **26.6 MiB** = **9.1%** of the subsystem
