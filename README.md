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
tests/renderer_hddagi_sparse/
  hddagi_brick_layout.h       grid, coordinate conversion, atlas addressing
  hddagi_brick_allocator.*    page table, states, generations, scroll replay
  test_*.cpp                  43 cases, dependency-free
  run_tests.sh                build + run
  fixtures/                   deterministic GPU-facing vectors
tools/
  make_manifest.py        M0.01
  hddagi_allocations.py   M0.04
  check_shader_sites.py   M0.06 coverage enforcement
  memory_model.py         M0.08
```

## Status

**M0 partially complete, M1 complete.**

- M0.01, M0.04, M0.06, M0.08 ran here. M0.02, M0.03, M0.05, M0.07 require a
  Windows 11 + MSVC + Vulkan build and were not executed.
- M1 (CPU oracle) is complete: 43 test cases pass, clean under ASan/UBSan, and the
  suite is proven to fail under deliberate mutation.

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
