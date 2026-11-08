# Wind — foliage sway

Executed 2026-11-07 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900.
Build `4.8.dev.custom_build`, forest scene, 600 trees.
Binary sha256: `29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e`.

## 1. The problem

Every run of this project printed, on every frame, for every foliage material:

```
WARNING: Shader uses global parameter 'wind_power', but it was removed at some point. Material will not display correctly.
WARNING: Shader uses global parameter 'wind_sway_amplitudes', but it was removed at some point. ...
WARNING: Shader uses global parameter 'wind_sway_frequencies', but it was removed at some point. ...
WARNING: Shader uses global parameter 'wind_turbulence', but it was removed at some point. ...
WARNING: Shader uses global parameter 'wind_velocity', but it was removed at some point. ...
```

The foliage shaders declare those five as `global uniform`, and every material already
sets `wind_enabled = true`, but nothing in this fork registers the globals. So the
warnings were correct: no foliage moved, and the materials were evaluated against
whatever default an unregistered global resolves to.

## 2. The fix

`platform/test_project/hddagi_wind.gd`, autoloaded as `Wind`, registers the five
globals at startup and drives a gust envelope on `wind_power`.

```gdscript
RenderingServer.global_shader_parameter_add("wind_power", GLOBAL_VAR_TYPE_FLOAT, 5.0)
RenderingServer.global_shader_parameter_add("wind_sway_amplitudes", GLOBAL_VAR_TYPE_VEC4, Vector4(0.4, 0.1, 0.1, 0.1))
RenderingServer.global_shader_parameter_add("wind_sway_frequencies", GLOBAL_VAR_TYPE_VEC4, Vector4(2.9, 5.4, 7.8, 10.2))
RenderingServer.global_shader_parameter_add("wind_turbulence", GLOBAL_VAR_TYPE_FLOAT, 0.5)
RenderingServer.global_shader_parameter_add("wind_velocity", GLOBAL_VAR_TYPE_VEC2, Vector2(1, 1))
```

`HDDAGI_WIND=0` pins `wind_power` to zero while leaving the globals registered, so the
shaders take the same path and log the same warnings as with wind on; the foliage simply
stays still. `tools/bench_run.sh` sets that by default so timings stay comparable with
the pre-wind baseline. (Not registering the globals would restore the per-frame
"global parameter was removed" warning.)

## 3. Only `wind_power` can be animated

The vertex shader computes its phase as

```glsl
float wind_time = TIME - dot(world_pos.xz, wind_effective_velocity);
```

so `wind_velocity` and `wind_turbulence` are **phase** terms, not just amplitudes.
Changing either shifts every instance's phase by `dot(pos, delta)` — for a tree 50 m
away, a 0.1 change in speed is roughly a 5 rad jump, which pops the whole forest at
once. `wind_sway_frequencies` is worse: the phase is `wind_time * frequency` and `TIME`
grows without bound, so any frequency change is a discontinuity that grows over time.

`wind_power` is a pure multiplier on displacement, so it is the only parameter that can
vary continuously. All gusting therefore rides on it. Per-instance variety still comes
from the shader's world-position noise (`wind_turbulence`) and per-vertex variety from
the baked vertex colours, so one global gust does not look uniform.

## 4. Calibration

Foliage3D ships tuned defaults in its own demo `project.godot` `[shader_globals]`, and
those are used for the four shape parameters rather than inventing a curve. But its
`wind_power` of **0.2** is calibrated for the addon's own scene and produces no
measurable motion here — measured 0 px of leaf travel over 3 s.

Model-space sizes were read from the meshes rather than guessed:

| mesh | height |
|---|---:|
| `grass_lod0` | 0.77 m |
| `elm_lod0` | 8.47 m |
| `pine_lod0` | 11.93 m |
| `oak_lod0` | 16.85 m |

A leaf tip displaces about **0.064 m per unit of `wind_power`** with these amplitudes
(derived from the shader and confirmed against the pixel measurements below), so:

- `wind_power = 5.0` gives ~**0.32 m** on a 17 m oak, about 1.9% of its height, which
  is a moderate breeze. Gusts reach ~6.5 (see below).
- Trunks use `wind_power_scale = 0.01` and leaves `0.1`, both already set by the demo
  materials, so trunks barely move while canopies do — which is correct.

Grass is the exception. It is weighted by `VERTEX.y * VERTEX.y / wind_characteristic_height`
rather than by baked vertex colour, and its model is 0.77 m tall, so it responds about
**3.5x** more strongly per unit power than leaves. At `wind_power = 5.0` with the demo's
`wind_power_scale = 1.0` the grass would be driven flat. Its material scale is therefore
lowered to **0.15**, putting a blade tip at ~0.17 m.

Gusting is a sum of four incommensurate octaves with 1/f amplitude falloff:

```
0.50*sin(0.21 t) + 0.28*sin(0.53 t + 1.7) + 0.15*sin(1.19 t + 4.1) + 0.07*sin(2.71 t + 2.3)
```

giving `wind_power` in roughly 3.5–6.5 (±30% turbulence intensity, a normal value for
open terrain). It is evaluated at **10 Hz**, not per frame: the fastest component has a
~2.3 s period, so 10 Hz resolves it with room to spare and keeps the uniform update off
the critical path. There is no repeating period, so the wind never settles into a
visible loop.

## 5. Measurements

**Motion is real.** Two frames 3 s apart, static camera, 746,496 pixels:

| | pixels changed >8 | mean abs delta | mean luminance |
|---|---:|---:|---:|
| wind off | 0.07% | 0.13 | 81.455 |
| wind on | **46.0%** | **15.97** | 81.497 |

The luminance is unchanged, so this is motion rather than an exposure shift, and the
difference is concentrated in the canopy — the top third of the image changes 2.8x more
than the bottom third (24.8 vs 8.9). Rigid-shift correlation across canopy patches
returns low scores (0.34–0.76) and small offsets, which is the expected signature of
non-rigid deformation: individual leaves move differently rather than the canopy
translating as a block.

**Cost is at or below the noise floor.** Two independent pairs, static camera:

| run | wind off | wind on | delta |
|---|---:|---:|---:|
| 1 | 28.551 | 28.667 | +0.116 ms (0.4%) |
| 2 | 28.590 | 28.634 | +0.044 ms (0.2%) |

p95 is unchanged (29.70 vs 29.66). Moving camera is also unchanged: 25.819 ms with wind
against 25.759 ms measured before wind existed.

The reason the cost is this small is that the shader was **already** executing the wind
branch, because `wind_enabled` was already true and the globals resolved to zero. Turning
wind on changes the values, not the instruction count. There is no extra per-vertex work.

**HDDAGI is unaffected.** HDDAGI re-voxelises a cascade only when `dirty_regions` is set
by camera movement, so animated foliage does not trigger GI updates; the forest's
indirect lighting is computed from static geometry. That is the intended trade-off
(an animated forest must not force per-frame GI recomputation), and it is confirmed
empirically by the unchanged frame times above.

## 6. The bug that made wind look broken

The first working version declared `const BASE_POWER` twice during an edit. The script
failed to parse, the autoload failed to instantiate, and the result was:

```
SCRIPT ERROR: Parse Error: Constant "BASE_POWER" has the same name as a previously declared constant.
ERROR: Failed to instantiate an autoload, script 'res://hddagi_wind.gd' does not inherit from 'Node'.
```

The scene still rendered normally, the warnings were gone (the globals were never
registered, so nothing warned), and the measured motion was exactly 0 px. It looked
like "wind does nothing" rather than "wind did not load". Worth knowing: an autoload
that fails to parse is silent at the rendering level.

## 7. Reproducing

```bash
cd hddagi-sparse

# motion: two frames 3 s apart, static camera
WIND=1 SCENE=forest TREES=600 CAMERA=static GI=on RATIO=0.10 FRAMES=70 WARMUP=60 \
  TAG=wind BENCH_SNAP="10,60" BENCH_SNAP_DIR=/tmp/snap_wind ./tools/bench_run.sh

# cost
WIND=0 SCENE=forest TREES=600 CAMERA=static GI=on RATIO=0.10 TAG=w0 ./tools/bench_run.sh
WIND=1 SCENE=forest TREES=600 CAMERA=static GI=on RATIO=0.10 TAG=w1 ./tools/bench_run.sh
```

Files: `platform/test_project/hddagi_wind.gd`,
`platform/test_project/demo/foliage/materials/grass.tres` (`wind_power_scale` 1.0 → 0.15),
`platform/test_project/project.godot` (autoload).
