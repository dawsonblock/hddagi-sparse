# Light-process buffer sizing — measured

The largest single allocation in HDDAGI that nobody revisits. Seven storage buffers,
each pre-sized at `solid_cell_ratio = 0.5` of the full voxel count, on a hardcoded
default that no project setting can reach.

Measured on the macOS build, six cascades, 16x8x16 (1,048,576 voxels per cascade).

## The numbers

| `solid_cell_ratio` | cells per cascade | one buffer | all seven | peak observed usage | image vs 0.5 |
|---:|---:|---:|---:|---:|---|
| **0.50** (shipped) | 524,288 | 8.00 MiB | **56.00 MiB** | 2.56% of voxels | baseline |
| 0.10 | 104,857 | 1.60 MiB | 11.20 MiB | 12.8% of cap | 25 px differ, max delta 1 |
| **0.05** | 52,428 | 0.80 MiB | **5.60 MiB** | 25.6% of cap | 30 px differ, max delta 1 |
| 0.01 | 10,485 | 0.16 MiB | 1.12 MiB | **128% of cap — overflow** | 22.0% px differ, max delta 3 |

Peak observed usage was 13,409 cells in cascade 0, 3,940 in cascade 1, then 850, 225,
68, 18. Total 18,510 cells across all six cascades, against 3,670,016 cells of
allocated capacity: **0.5% utilisation**.

Image comparison is per-pixel RGB over 746,496 pixels against the shipped 0.5 build.

## What this shows

At `0.05` the frame is visually identical to the shipped configuration — 30 pixels
out of 746,496 change, each by one least-significant bit — while the seven buffers drop
from **56.0 MiB to 5.6 MiB, a 50.4 MiB saving (90%)**.

For comparison, the sparse-brick proposal nets 26.6 MiB at 50% residency for 13-24
engineer-weeks. This change is one afternoon.

## The overflow path already worked

The first thing checked was whether shrinking is safe. It is, but not for the reason
I expected:

- `hddagi_preprocess.glsl:742` guards the LIGHT_STORE append with
  `if (index < params.maximum_light_cells)`, and the `else` branch zeroes the light for
  the dropped cell.
- `maximum_light_cells` is already a push-constant field (`gi.h:342`), set from
  `solid_cell_count` at `gi.cpp:875`.
- The LIGHT_SCROLL append is unguarded, but it only copies entries that were already
  capped by LIGHT_STORE, so it cannot exceed the same bound.

So the design anticipated a cap and handled it. The bug was that the cap was fixed at
0.5 of the voxel count with no way to change it.

The `0.01` run confirms the failure mode: capacity below demand, no errors, no crash,
no memory corruption, and a smooth quality degradation (22% of pixels, max delta 3).
That is the correct behaviour for a cap.

## The change

`rendering/global_illumination/hddagi/solid_cell_ratio`, a float in `[0.01, 1.0]`,
default 0.5, registered in `rendering_server.cpp` and read at HDDAGI creation. The
budget is logged once per instance:

```
HDDAGI_PROCESS_BUDGET ratio=0.050 cells_per_cascade=52428 bytes_per_buffer=0.80 MiB total_buffers=5.60 MiB (7 buffers)
```

## What this does not establish

- **The scene is small**: five wall slabs and six boxes. A dense forest will use far
  more cells. The knob is now measurable per scene, but the forest number is unmeasured.
- **No VRAM measurement.** The figures are declared allocation sizes. They are exact
  and deterministic, but they are not what the driver commits.
- **No frame-time measurement.** Shrinking a buffer can change cache behaviour in
  either direction; nothing here says it is faster.
- **The 0.05 value is not a recommendation for forests.** It is safe here with 3.9x
  headroom. For a dense scene, measure first — the instrumentation is in the build.
- Only one cascade format and one screen-probe mode were exercised.

## Dense forest

The room scene is not the interesting case. A stress scene was built with a camera
*inside* a forest at eye height, roughly one tree per 3 m^2, 4,000 trunks and canopies
in a MultiMesh.

Peak process-cell demand per cascade: **70,355** (cascade 0), 59,555 (1), 37,385 (2).
Cascade 0 saturates at about 70k whether the forest has 1,500 or 4,000 trees, because
the finest cascade covers a fixed 25.6 m and is already dense at 1,500.

Demand is 6.7% of the voxel count, so the required ratio is about **0.067**.

| ratio | seven buffers | capacity | headroom | image vs 0.5 |
|---:|---:|---:|---:|---|
| 0.50 | 56.00 MiB | 524,288 | 7.5x | baseline |
| **0.25** | **28.00 MiB** | 262,144 | 3.7x | 528 px (0.07%), max delta 1 |
| **0.10** | **11.20 MiB** | 104,857 | 1.49x | 980 px (0.13%), max delta 1 |
| 0.05 | 5.60 MiB | 52,428 | **0.75x — overflow** | 175,946 px (23.6%), max delta 10 |

The threshold falls exactly where the arithmetic predicts, between 0.10 and 0.05.

At **0.10** the forest frame is visually identical (980 of 746,496 pixels, one LSB
each) and the seven buffers drop from 56.0 to 11.2 MiB: **44.8 MiB saved**.

## Two bad measurements before the good one

Worth recording because both looked plausible:

1. 4,000 trees packed into a 22 m radius is 2.6 trees/m^2. It produced a demand of
   101,634 cells and a completely black frame — the camera was inside the canopy.
   The number was real, the scene was nonsense.
2. Spreading the same 4,000 trees over 178 m put almost all of them outside the fine
   cascades. Demand fell to 4,304, *below* the room scene. Also real, also useless.

Only the third arrangement — camera in the forest, realistic spacing — measures what
the question is actually about.

## Recommendation

Ship the setting. Default **0.10**: 44.8 MiB saved on a dense forest with 1.49x
headroom and no measurable image change. Keep 0.25 available for scenes that are
denser than this one, and do not go below 0.10 without measuring the specific scene,
because the drop is no longer free once capacity falls under demand.

This is the cheapest large win found so far. It does not replace the sparse work if the
goal is scaling the world volume, but it does remove the strongest argument for
pursuing sparse purely to save memory.
