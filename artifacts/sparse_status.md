# Sparse bricks — gate, measurements, and what is still missing

Executed 2026-11-08 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900.
Engine binary `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b`
(built with the gate below).

**This is not a sparse-lighting integration.** The sparse path has no radiance store
and no sampling stage, so the dense light texture is still the only source of
lighting. Nothing below is a renderer memory saving, and the sparse plan's 4.73 MiB
must not be quoted as one.

## What exists

| piece | file | status |
|---|---|---|
| capability probe + dispatch plan | `hddagi_sparse_plan.{h,cpp}` | runs at HDDAGI creation when gated on |
| translation parity kernel | `hddagi_sparse_shaders.inc` | self-test only |
| atlas canary write/check kernels | `hddagi_sparse_shaders.inc` | self-test only |
| brick allocator kernel | `hddagi_sparse_shaders.inc` | self-test only |
| **radiance store into the atlas** | — | **does not exist** |
| **sampling the atlas in lighting** | — | **does not exist** |
| **page-table binding in the GI light pass** | — | **does not exist** |

The four kernels are infrastructure tests. They prove addressing, page allocation and
atlas read/write, not lighting.

## The gate

New project setting, default **false**:

```
rendering/global_illumination/hddagi/sparse_enabled
```

| gate | behaviour |
|---|---|
| `false` (default) | dense renderer only; no probe, no self-test, no sparse allocation. Logs `HDDAGI_SPARSE_MODE dense (sparse disabled)`. |
| `true` | runs the capability probe and, if `sparse_selftest` is also true, the self-test. Logs `HDDAGI_SPARSE_MODE probe (lighting remains dense; no sparse savings claimed)`. |

`sparse_selftest` and `sparse_selftest_fixtures` keep their old meaning but now only
run inside the gate. The dense path is unchanged and remains the fallback.

## Measurements

**Image parity.** Same scene, 100 trees, gate off vs on, 1600x900:

| capture | mean abs delta | pixels >8 | max | byte-identical |
|---|---:|---:|---:|---|
| normal | 0.0090 | 0.022% | 73 | no |
| HDDAGI debug draw | 0.0193 | 0.045% | 36 | no |

The images are effectively identical; the residual is GI temporal nondeterminism
between processes, not a sparse lighting change. That is expected: lighting is still
dense.

**Frame time.** 600 trees, 60 measured frames:

| gate | p50 | p95 | scene built |
|---|---:|---:|---:|
| off | 24.201 | 24.951 | 1,371 ms |
| on (probe only) | 24.174 | 24.578 | 1,407 ms |

No per-frame cost: the probe runs once at creation (+36 ms startup). The self-test is
not run in the benchmark (`bench_run.sh` sets `sparse_selftest=false`).

**Startup, gate on with the self-test.** 1,500 trees, `--quit-after 5`, three runs each:

| gate | wall time | peak RSS |
|---|---:|---:|
| off | 2.18, 2.19, 2.35 s (median 2.19) | 470.5, 496.1, 511.3 MB (median 496.1) |
| on (probe + self-test) | 2.56, 2.79, 2.86 s (median 2.79) | 521.2, 526.8, 528.7 MB (median 526.8) |

The self-test costs **~0.6 s at startup** (four shader compiles plus kernel
dispatches). Peak RSS is ~31 MB higher, but run-to-run noise is ~40 MB and this is a
peak during the transient self-test, not steady-state residency. It is not a saving and
not a reliable cost; it is recorded only to show the self-test is not free.

## The exact blocker

To make sparse bricks light anything, three pieces are missing:

1. **A radiance-store kernel.** The atlas is `R32_UINT` viewed as
   `E5B9G9R9_UFLOAT_PACK32`; the dense light-process shader writes radiance to a dense
   slot. Nothing writes radiance into `atlas_texel(page_id, local)`, so the atlas
   contains only canary patterns after the self-test.
2. **A sampling path.** The scene lighting shader samples the dense 3D light texture
   directly. It has no page-table lookup and no atlas indirection, so a sparse atlas
   cannot be read even if it were populated.
3. **Per-frame allocator integration.** The allocator kernel is dispatched against
   fixtures once. In the renderer it would need a per-frame probe-request buffer, a
   compaction/allocate dispatch, and a fallback path for pages that overflow.

Until those exist, enabling the gate cannot change the image, cannot reduce the dense
light texture, and cannot reduce memory. The honest next step is (1) and (2) together
for one cascade, compared against the dense cascade image, before any whole-renderer
claim is made.

## Reproducing

```bash
cd hddagi-sparse

# gate off (default): dense only
../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64 \
  --path platform/test_project --quit-after 5

# gate on with the self-test
printf '[rendering]\nglobal_illumination/hddagi/sparse_enabled=true\n' \
  > platform/test_project/override.cfg
../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64 \
  --path platform/test_project --quit-after 5
rm platform/test_project/override.cfg
```

The self-test log should read:

```
HDDAGI sparse probe: SUPPORTED (check 0) - all capability checks passed
HDDAGI sparse self-test: PASS
HDDAGI_SPARSE_MODE probe (lighting remains dense; no sparse savings claimed)
```

## Known limitations

- The gate is an infrastructure gate, not a renderer mode switch.
- Peak RSS is measured with `/usr/bin/time -l` over a five-frame run; it includes
  startup transients and is not steady-state residency.
- The self-test allocation is freed at the end of the test. Driver-side memory may not
  return to the OS, which is one reason the peak RSS delta is not a residency figure.
- The plan's `total=4.73 MiB` is arithmetic over the requested page capacity. It is not
  an allocation measurement and is not a saving.
