# M0 decision record — HDDAGI sparse bricks

Generated 2026-11-08 from the supplied tree `godot-dynamic_gi_2` (Godot 4.8.0-dev,
no VCS metadata). Host: macOS arm64. **No engine build was executed. No GPU was
touched. No VRAM was measured.**

This record separates three evidence classes on purpose:

| class | meaning |
|---|---|
| **verified** | Read directly from source and re-checked by a script in `tools/`. |
| **derived** | Arithmetic over verified source facts. Not a measurement. |
| **blocked** | Requires a Windows/Vulkan build that cannot run on this host. |

---

## 1. Ticket status

| ticket | status | why |
|---|---|---|
| M0.01 provenance | **done** | `manifest.json`, `engine_version.txt` |
| M0.02 build baseline | **blocked** | needs Windows 11 + MSVC + Vulkan SDK |
| M0.03 scene fixtures | **blocked** | needs a running engine |
| M0.04 allocation inventory | **done (source-derived)** | `allocations.json` |
| M0.05 GPU writer-support counters | **blocked** | needs a GPU and a build |
| M0.06 shader consumer map | **done** | `shader_sites.json`, coverage-checked |
| M0.07 timestamps + camera runner | **blocked** | needs a build |
| M0.08 memory model | **done (derived)** | `memory_model.json` |
| M0.09 GO/NO-GO | **partial** | this document |

Two of the four GO/NO-GO criteria in the RFC are measurement criteria. They cannot
be satisfied here, so this is not a complete M0 gate.

---

## 2. Verified source facts

Re-checked against the tree, not taken from the RFC on trust:

- `version.py` reports 4.8.0-dev. There is **no `.git` directory**; commit identity is
  genuinely unknown. Archive SHA-256 is `5cfbab8c…ae1948`.
- `gi.h:748-750` — `MAX_CASCADES=8`, `CASCADE_SIZE=128`, `REGION_CELLS=8`.
- `gi.cpp:361-380` — default format is 16x8x16 → cascade height 64; full-height
  variants use 128.
- `gi.cpp:458-479` — light is `R32_UINT` with an `E5B9G9R9_UFLOAT_PACK32` shared
  view; neighbour is `R32_UINT`; disocclusion is `R8_UINT`.
- `gi.h:943` — `hddagi_solid_cell_ratio = 0.5`, a hardcoded default, not a project
  setting. This drives the light-process buffer size.
- `gi.cpp:1097-1183` — camera movement quantised in 8-voxel steps with dirty-slab
  borders, as the RFC describes.

The RFC's factual basis holds. Nothing in section 2 of the RFC was contradicted.

---

## 3. Allocation inventory (derived)

Six cascades, 16x8x16, 1080p, stochastic screen probes, specular on, SVGF off.

| group | MiB | share |
|---|---:|---:|
| screen-probe specular | 63.28 | 21.7% |
| light-process buffers | 56.66 | 19.4% |
| **migratable payload (light + neighbour + disocclusion)** | **54.00** | **18.5%** |
| surface render targets | 39.00 | 13.4% |
| light probes | 35.81 | 12.3% |
| occlusion | 25.53 | 8.8% |
| screen-probe core | 16.56 | 5.7% |
| occupancy | 0.79 | 0.3% |
| **total** | **291.63** | |

The payload figure reproduces the RFC's 54 MiB exactly, which validates the model.
Everything else in the table is additional context the RFC did not quantify.

Sensitivity of the payload share:

| scenario | payload MiB | subsystem MiB | payload share |
|---|---:|---:|---:|
| 6 cascades, 16x8x16, 1080p | 54.0 | 291.6 | 18.5% |
| 6 cascades, 16x8x16, 1440p | 54.0 | 353.7 | 15.3% |
| 6 cascades, 16x16x16, 1080p | 108.0 | 498.0 | 21.7% |
| 4 cascades, 16x16x16, 1080p | 72.0 | 363.9 | 19.8% |

Resolution growth does not touch the world volume; it grows the screen-probe groups.
So the payload share *falls* as resolution rises.

---

## 4. Shader consumer map (verified)

42 declarations and accesses across 10 shader files, all registered in
`shader_sites.json` and enforced by `tools/check_shader_sites.py`.

- **13 exact-texel reads, 0 filtered reads.** Every light read is `texelFetch`; every
  metadata read is `imageLoad`. The `linear_sampler` binding is never used for
  filtering on these payloads.
- Therefore **v1 needs no halo**, confirming RFC section 3. The padded 10³ brick
  (1.95x volume) is correctly rejected as premature.
- Binding reuse hazard is real and now concrete: `hddagi_preprocess.glsl` declares
  `light_tex` at binding 12 (line 40, `MODE_LIGHT_STORE`) and again at binding 1
  (line 96, `MODE_REGION_STORE`). A binding free in one variant is not free in all.

---

## 5. Memory model (derived)

`memory_model.json`. Assumptions: 16 B page entry, 32 B brick metadata, near-cubic
atlas packing, capacity — not occupancy — is what costs memory.

| residency | net saved (three-field) | % of dense payload |
|---:|---:|---:|
| 10% | 48.4 MiB | 89.6% |
| 25% | 40.2 MiB | 74.5% |
| 50% | 26.6 MiB | 49.3% |
| 75% | 13.0 MiB | 24.1% |
| 90% | 4.8 MiB | 8.9% |
| 100% | −0.6 MiB | negative |

Break-even residency: **97.5%** for light-only, **98.9%** for three-field. Split pools
lose to a unified pool at every residency tested, because page tables and metadata
multiply while atlas bytes do not fall.

At 50% residency — the RFC's own GO threshold — the net saving is **26.6 MiB, which is
9.1% of the 291.6 MiB HDDAGI subsystem**.

---

## 6. Findings that change the plan

**F1. The atlas has no structural advantage over dense storage.**
A physical brick costs 4,608 B for the three-field group; the dense brick it replaces
also costs 4,608 B. The only saving is unallocated pages. This is why break-even sits
at ~98% residency. Sparse bricks are a bet on low residency and nothing else.

**F2. The migratable group is a minority of the subsystem.**
15-22% depending on shape. Even a perfect implementation that removed 100% of dense
payload would cut the HDDAGI footprint by under a quarter.

**F3. Two non-payload groups are larger than the payload group.**
Specular screen-probe textures (63.3 MiB at 1080p, 112.5 MiB at 1440p) and the
light-process buffers (56.7 MiB). The RFC anticipated this — its own stop condition
names screen-probe buffer count as the alternative target — but did not quantify it.
This model does.

**F4. `voxel_albedo_data` is a fourth per-voxel payload that the RFC omits.**
`gi.cpp:1271-1279` allocates `R16_UINT` at full cascade resolution (12 MiB at six
cascades) when irradiance-cache multi-bounce is active. It is read at
`hddagi_screen_probe.glsl:2035` and `:2153` and written at
`hddagi_direct_light.glsl:596`. The RFC's "three-field group" is therefore not the
complete set of per-voxel world payloads; a sparse implementation that ignores it
leaves a 12 MiB dense texture in place, and any "combined" residency claim must say
whether it includes this field.

**F5. The light-process buffers are sized by a hardcoded worst case.**
`solid_cell_ratio = 0.5` means each of the seven light-process buffers is allocated at
50% of the full voxel count regardless of actual geometry, and the render buffer is
double-buffered against the cascade buffer (`gi.cpp:949`). For an empty or sparse
world this is 56.7 MiB of largely unused storage. This is a separate optimisation
track, not part of this RFC, but it is a bigger and simpler target than sparse bricks
and should be evaluated first.

**F6. `render_aniso_normals` is 24 MiB of full-resolution atomic scratch.**
`gi.cpp:501-505`, cleared every region render (`gi.cpp:668`). Also per-voxel, also
dense, also a candidate — and it is write-only rasterizer scratch, which makes
residency classification easier than for radiance.

---

## 7. GO/NO-GO against the RFC's own criteria

| criterion | verdict | basis |
|---|---|---|
| Conservative required-brick residency materially below 50% for one costly payload | **UNKNOWN** | requires M0.05 GPU counters; blocked |
| Net savings justify page tables, metadata, lookup overhead | **MARGINAL PASS** | +26.6 MiB at 50% residency, 9.1% of subsystem |
| Exact light-read compatibility with stable shader variants | **PASS** | 13 exact reads, 0 filtered, verified |
| No severe random-memory or synchronisation penalty | **UNKNOWN** | requires GPU profiling; blocked |

The RFC states that M0 measurement is a hard prerequisite and that if the criteria
are not met, no M1. Two criteria are unmet only because they are unmeasurable on this
host — not because they failed.

---

## 8. Recommendation

**CONDITIONAL GO to M1. NO-GO to M2 on this host.**

Rationale:

1. M1 is the CPU oracle — coordinate conversion, page table, allocator, generation
   invariants, seeded property tests. It has zero GPU dependency, costs 1-2 weeks, and
   produces value regardless of whether sparse bricks ship: the addressing and
   lifetime tests are the part most likely to harbour a subtle bug, and they are
   cheapest to build now.
2. M2 requires a GPU primitive proof on the RTX 3080 Ti. Proceeding to it before M0.05
   exists would violate the RFC's own gate.
3. The economics are real but modest. A 9% subsystem reduction at 50% residency does
   not justify 13-24 engineer-weeks on its own. It justifies itself only if residency
   turns out to be low *and* the implementation is cheap, or if the same page-table
   machinery is later reused for the larger targets in F3/F5/F6.

If the goal is VRAM reduction in a forest scene, the evidence says to measure
residency first and to cost the light-process buffers and specular screen probes in
parallel. Sparse bricks should not be the only horse.

---

## 9. Required before the gate can close

On the Windows 11 / RTX 3080 Ti machine:

1. Build the fork (M0.02) and record the exact SCons invocation and toolchain versions.
2. Add the debug writer-support bitsets (M0.05) and capture the per-field residency
   distribution for the five fixtures, especially the dense forest.
3. Feed the measured residency into `tools/memory_model.py` and replace the assumed
   fractions with observed ones.
4. Re-run this decision record with measured numbers. Only then is M0.09 a real gate.

---

## 10. Reproducing these artifacts

```
python3 tools/make_manifest.py                    # provenance
python3 tools/hddagi_allocations.py --json artifacts/allocations.json --csv artifacts/allocations.csv
python3 tools/check_shader_sites.py               # shader map coverage
python3 tools/memory_model.py --subsystem-mib 291.628 \
        --json artifacts/memory_model.json --markdown artifacts/memory_model.md
```

All tools read the supplied tree read-only. No file in `godot-dynamic_gi_2`,
`Terrain3D-main` or `Foliage3D-master` was modified.
