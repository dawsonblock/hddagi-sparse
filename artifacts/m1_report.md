# M1 report — CPU reference addressing, allocator and tests

Executed 2026-11-08 on macOS arm64. Pure C++17, no engine, no GPU, no third-party
dependencies. 43 test cases pass, clean under ASan and UBSan.

## What exists

```
tests/renderer_hddagi_sparse/
  test_harness.h              minimal registry + assertions (no GoogleTest)
  hddagi_brick_layout.h       M1.01 / M1.02  grid, coordinates, atlas addressing
  hddagi_brick_allocator.h    M1.03 / M1.04  page table, states, generations
  hddagi_brick_allocator.cpp
  test_main.cpp
  test_brick_addressing.cpp   12 cases
  test_brick_allocator.cpp    13 cases
  test_scroll_replay.cpp       8 cases
  test_randomized.cpp          2 cases (100,000 + 20,000 seeded operations)
  test_negative.cpp            6 cases (RFC section 12 negative tests)
  test_format_roundtrip.cpp    2 cases + fixture export
  run_tests.sh
  fixtures/                   generated, deterministic
```

## Semantics, taken from source rather than invented

| rule | source |
|---|---|
| `position` moves in ±8 voxel steps (`drag_margin * 2`) | `gi.cpp:1110-1144` |
| `region_world_offset = position / REGION_CELLS` | `gi.cpp:1597-1599` |
| wrapped = `(local + offset*8) & (grid-1)` | `hddagi_screen_probe.glsl:1803`, `hddagi_integrate.glsl:566-572` |
| physical Y = wrapped Y + cascade × grid_size.y | `hddagi_integrate.glsl:571` |
| cascade world origin = `position - cascade_size/2` | `gi.cpp:1550` |
| dirty slab widened by 2 voxels on the retained side | `gi.cpp:1540-1560` |

One consequence worth stating explicitly, because the whole page table depends on it:
**the wrapped slot for a given world region is independent of the scroll.**
`wrapped = (region*8 + grid/2) & (grid-1)`, with no `position` term. That is why a page
table is possible at all, and also why the slot alone cannot prove identity: a slot
repeats every `grid/8` regions, so two world regions one full torus apart share it.
The exact `(cascade, world region, generation)` tag is what disambiguates them.

## The bug this milestone was built to catch

The first implementation inverted the wrap incorrectly:

```
local = brick * 8                      // WRONG: brick index is in wrapped space
local = (brick * 8 - position) & mask  // correct
```

It is invisible at `position = 0` and at any position where the camera has not moved
by a non-multiple of the brick edge, which is most manual testing. It was caught by
`all_committed_pages_are_in_window()` inside the scroll replay tests, and the fix is
now `local_from_wrapped_brick()` in `hddagi_brick_layout.h`.

This is the concrete instance of the double-wrap class of error the RFC warned about
in section 5.

## Test inventory

| area | cases | what is asserted |
|---|---|---|
| layout | 4 | 2,048 bricks default / 4,096 full height; rejects non-power-of-two and non-brick-aligned shapes |
| coordinates | 8 | floor division with negatives, wrap round-trip, window edges for ±2048 positions, slot uniqueness across all cascades, atlas texel uniqueness |
| lifecycle | 6 | REQUESTED→ALLOCATED→INITIALIZING→COMMITTED; lookup before commit rejected; retire makes content unreachable |
| ownership | 4 | stale owner after a torus period; small scroll still valid; new owner replaces old page |
| capacity | 3 | explicit overflow with counters, no aliasing, recovery when capacity frees |
| generations | 2 | monotonic, never zero; 32-bit rollover forces full invalidation |
| scroll replay | 8 | single axis both directions, two axes, three-axis corner, 40x forward/back, full torus walk, teleport, 1-page pool |
| randomized | 2 | 100,000 mixed operations and 20,000 negative-biased operations, invariants checked every 250-500 ops |
| negative | 6 | corrupted generation, aliased page, delayed zeroing, early reuse, omitted writer request, overflow recovery |
| fixtures | 2 | struct sizes 16/32 bytes, little-endian byte layout |

## Mutation evidence

The suite was verified to fail when the model is broken, not merely to pass when it
is intact:

| mutation | result |
|---|---|
| drop `- position` in the wrap inversion | 6 cases fail, 51 assertion failures |
| allow release before the reader epoch advances | 2 cases fail, 5 assertion failures |

Both reverted; suite returns to 43/43.

## Fixtures for M2

`fixtures/addressing_vectors.json` — 1,180 cases covering five scroll positions, two
cascades, brick corners and edges. Each case carries wrapped coordinate, world region,
virtual slot, brick, local-in-brick, atlas texel and a packed-light canary.

`fixtures/pages.bin` — 768 bytes: 16 `PageEntry` records (16 B) and 16 `BrickMeta`
records (32 B), little-endian, for byte-exact comparison against the GPU port.

The canary is an identity encoding, **not** the engine's `E5B9G9R9` or `rgbe` packer.
Format parity is an M2/M3 concern.

## What M1 does not prove

- No shader has been compiled or executed. The GPU-side slot decoding is unverified.
- The allocator is a reference model, not the production implementation. It uses a
  host-side free list; the GPU path needs compaction and barriers instead.
- Residency is still unmeasured. Nothing here says how many pages a forest needs.
- The oracle assumes `position` is always a multiple of 8. That holds for the current
  source but is asserted, not enforced by the type system.

## Gate

M1's acceptance was: property tests pass for negative coordinates, wrap, teleport,
pool overflow and delayed reuse, including a deliberate stale-generation failure test.
All five are covered and passing, and each is demonstrated to fail under mutation.

M1.07 fixtures are produced. M2 remains blocked on the Windows/Vulkan host.
