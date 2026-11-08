# hddagi-sparse — M0 work tree

Working area for the HDDAGI sparse-brick cascade proposal. Nothing here modifies the
supplied source trees; every tool reads them read-only.

## Layout

```
artifacts/
  manifest.json           source provenance: archive hash, per-tree hashes, version, VCS state
  engine_version.txt      one-line identity of the engine tree
  allocations.json        every HDDAGI texture/buffer, declared dims, format, estimated bytes
  allocations.csv         same, flat
  shader_sites.json       every payload declaration/read/write across the HDDAGI shaders
  memory_model.json       residency sweep, atlas packing, overhead, break-even
  memory_model.md         readable version of the same
  decision.md             M0.09 record: what passed, what is blocked, recommendation
  m1_report.md            M1 record: semantics, test inventory, mutation evidence
  m2_scaffold.md          M2 scaffold: capability table, shader map, integration recipe
  macos_bringup.md        engine builds and HDDAGI renders on Metal
  light_process_buffers.md measured 56 -> 5.6 MiB with an identical frame
tests/renderer_hddagi_sparse/
  hddagi_brick_layout.h       grid, coordinate conversion, atlas addressing
  hddagi_brick_allocator.*    page table, states, generations, scroll replay
  test_*.cpp                  43 cases, dependency-free
  run_tests.sh                build + run
  fixtures/                   deterministic GPU-facing vectors
engine/
  hddagi_sparse_plan.h/.cpp   capability checks + dispatch planning, no RD dependency
  test_sparse_plan.cpp        15 cases
  RD_ADAPTER.md               uncompiled RenderingDevice integration recipe
gpu/
  shaders/                    four compute shaders, compiled and SPIR-V validated
  hddagi_sparse_gpu_model.h   CPU twin of those shaders, same byte layouts
  test_gpu_model.cpp          7 cases: fixture parity, allocator invariants, canary
  make_fixture_bin.py         JSON fixtures -> 80-byte binary records
  build.sh                    compile shaders + validate + run twin tests
  run_gpu_tests.sh            execute the kernels on this GPU (Metal)
  metal/                      Swift harnesses for probe, canary and allocator
platform/
  engine_changes.patch        every engine change as a diff against the supplied tree
  build_and_run.sh            build in a copy, run the smoke project
  test_project/               HDDAGI smoke scene with frame capture
tools/
  make_manifest.py        M0.01
  hddagi_allocations.py   M0.04
  check_shader_sites.py   M0.06 coverage enforcement
  memory_model.py         M0.08
```

## Status

**Engine builds and runs on macOS. M0 partially complete, M1 complete, M2 kernels
execute on GPU but are not wired into the engine.**

- **The fork builds and runs on this Mac** (Metal 4, Forward+): 4,421 translation
  units, HDDAGI smoke scene renders, `DEBUG_DRAW_HDDAGI` shows the voxelised volume.
  See `artifacts/macos_bringup.md`. The Windows/Vulkan path is still unbuilt, so
  M0.05 and M0.07 (GPU counters and timings) remain blocked.
- M1 (CPU oracle) is complete: 43 test cases pass, clean under ASan/UBSan, and the
  suite is proven to fail under deliberate mutation.
- M2 kernels **execute on this machine's GPU** (Apple M2 Pro, Metal): translation
  parity 1,180/1,180, atlas canary 524,288/524,288 texels, allocator invariants hold.
  The capability/dispatch decision core is tested (15 cases). The M2 gate still names
  Vulkan on the RTX 3080 Ti, so it is not met. See `artifacts/m2_scaffold.md`.

Read `artifacts/decision.md` for the M0 gate and `artifacts/m1_report.md` for M1.

No number in `artifacts/` is a VRAM measurement. They are source-derived arithmetic.

## Quick start

```bash
python3 tools/make_manifest.py
python3 tools/hddagi_allocations.py --json artifacts/allocations.json --csv artifacts/allocations.csv
python3 tools/check_shader_sites.py
python3 tools/memory_model.py --subsystem-mib 291.628 \
        --json artifacts/memory_model.json --markdown artifacts/memory_model.md
```

`check_shader_sites.py` exits non-zero when a shader payload access exists that is not
registered in `shader_sites.json`. It is intended to be run after every shader change
in later milestones.

```bash
cd tests/renderer_hddagi_sparse
./run_tests.sh                 # build and run the CPU oracle
./run_tests.sh --fixtures      # also regenerate fixtures/
CXXFLAGS="-fsanitize=address,undefined" BUILD=build-san ./run_tests.sh
```

```bash
cd gpu
./build.sh                     # compile + validate shaders, run the twin tests
./run_gpu_tests.sh             # execute the kernels on this machine's GPU (Metal)

cd ../engine
./build.sh                     # capability and dispatch decisions
```
