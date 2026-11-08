# M2 scaffold — GPU page table and physical pool

Status: **scaffolding only. The M2 gate is NOT met.** No Vulkan device was created,
no dispatch was executed, no VRAM was allocated. What exists is a shader set that
provably compiles, and a CPU twin of those shaders that provably agrees with the M1
oracle on 1,180 fixtures.

## 1. What is actually verified here

| claim | evidence |
|---|---|
| Four compute shaders compile to SPIR-V | `glslangValidator -V --target-env vulkan1.0`, 4/4 |
| The SPIR-V is structurally valid | `spirv-val`, 4/4 clean |
| Entry points, workgroup size and bindings are what the design says | `spirv-dis`: `LocalSize 64 1 1`, bindings 0-7 as declared |
| The translation algorithm matches the M1 oracle | 1,180 fixture records, 0 mismatches |
| Struct layouts are 16 / 32 / 32 bytes | `static_assert`, verified at runtime |
| The GPU-shaped allocator respects capacity and never aliases | 300 requests into 256 pages: 256 allocated, 44 overflowed, 256 distinct page ids |
| Canary encoding is a bijection over (page, local) | 32,768 distinct values, one corrupted texel detected and located |
| Capability decisions are correct and fail closed | 14 cases in `engine/`, including one per refusal reason |
| Dispatch sizing and push-constant layout are right | 14 cases, incl. workgroup-limit splitting for a 12,288-page pool |

Reproduce with `gpu/build.sh` (shaders + twin, 7 cases) and `engine/build.sh`
(decision core, 14 cases).

**The twin is a transcription of the GLSL, not an independent implementation.**
Agreement with the M1 oracle validates the algorithm and the layout contract; it
cannot validate that the GLSL executes as written. That distinction is the whole
reason M2 exists as a separate milestone.

## 2. What is not verified

- Shader execution. Nothing has run on a GPU.
- Format and usage support on the target driver (M2.01 is a table, not a result).
- `E5B9G9R9_UFLOAT_PACK32` shared-view decode parity. The canary shaders read raw
  `R32_UINT`; decode parity needs a real device and a real sampler.
- Barriers, dispatch ordering and async completion. The shaders assume the host
  inserts the right barriers; that assumption is untested.
- Atlas cache behaviour, bandwidth, and any performance claim.

## 3. M2.01 capability checks

Every one of these must pass at startup or sparse mode must refuse to initialise and
fall back to dense. Refusing is the correct behaviour; a half-initialised sparse path
is worse than no sparse path.

| # | requirement | check | fail action |
|---|---|---|---|
| 1 | 3D `R32_UINT` with storage | `texture_create` with `TEXTURE_TYPE_3D` + `TEXTURE_USAGE_STORAGE_BIT`, then `texture_is_valid` | refuse |
| 2 | 3D `R8_UINT` with storage | same, `DATA_FORMAT_R8_UINT` | refuse |
| 3 | `E5B9G9R9_UFLOAT_PACK32` as a shareable format on the `R32_UINT` light atlas | `TextureFormat::shareable_formats`, then `texture_create_shared` with `TextureView::format_override` | refuse |
| 4 | Atlas fits the 3D extent limit | `limit_get(LIMIT_MAX_TEXTURE_SIZE_3D)` vs chosen slot factorisation | shrink capacity, then refuse |
| 5 | Storage buffers | `storage_buffer_create` for table, metadata, free list, counters | refuse |
| 6 | Compute pipelines for all four shaders | `shader_create_from_spirv` + `compute_pipeline_create`, both RIDs valid | refuse |
| 7 | Uniform set creation | `uniform_set_create` returns a valid RID for each binding set | refuse |

Sources for the exact names: `rendering_device_commons.h:402-408` (usage bits),
`:433-446` (`TextureFormat`), `:988-989` (`LIMIT_MAX_TEXTURE_SIZE_2D/3D`),
`rendering_device.h:469` (`texture_create`), `:1063` (`storage_buffer_create`),
`:1199` (`uniform_set_create`), `:1286` (`compute_pipeline_create`).

## 3a. Decision core (`engine/`)

The engine side splits into two pieces that need no RenderingDevice at all, so both
are implemented and tested here rather than deferred to the Windows box:

| file | responsibility |
|---|---|
| `hddagi_sparse_plan.h/.cpp` | `plan_sparse_resources()`: run the seven capability checks, factorise page slots, reduce or refuse capacity, compute every byte of the resource budget |
| | `plan_dispatch()`: workgroup counts, push-constant blocks, canary pass splitting |
| `test_sparse_plan.cpp` | 14 cases, including one per refusal reason and a byte-layout check |
| `RD_ADAPTER.md` | the uncompiled recipe: how to fill `DeviceCaps` from probes, create the resources, and order the dispatches |

The split matters because it moves the risky arithmetic off the critical path. When
the Windows build happens, only the RD calls in `RD_ADAPTER.md` remain untested; the
decisions they feed are already proven.

## 4. Resource budget

From the M0 accountant, six default cascades, 16 B page entry, 32 B brick metadata:

| resource | size | note |
|---|---:|---|
| virtual page table | 196,608 B | 12,288 slots x 16 B, one per cascade, dense |
| brick metadata | 32 B x capacity | only for physical pages |
| request bitset | 1,536 B | 12,288 bits |
| compacted request list | 4 B x capacity | |
| free list | 4 B x capacity | |
| counters | 32 B | |
| light atlas | 2,048 B x capacity | 8^3 x 4 B |
| neighbour atlas | 2,048 B x capacity | |
| disocclusion atlas | 512 B x capacity | |
| **overhead, excluding atlases** | **~200 KiB + 40 B/capacity** | |

At 1,024 pages this is about 4.7 MiB total against 54 MiB dense. The M0 model already
established that the win comes entirely from capacity being below residency.

## 5. Shader and binding map

| shader | set 0 bindings | push constants |
|---|---|---|
| `hddagi_sparse_brick_probe.comp` | 0 fixtures, 1 results | count, grid, cascade count, brick dims, page slots |
| `hddagi_sparse_brick_manage.comp` | 0 table, 1 meta, 2 free list, 3 cursor, 4 requests, 5 compacted, 6 counters, 7 allocated slots | mode, word count, slot count, capacity, epoch, generation base, brick dims |
| `hddagi_sparse_brick_canary_write.comp` | 0 atlas | page count, page slots |
| `hddagi_sparse_brick_canary_check.comp` | 0 atlas, 1 result | page count, page slots |

These numbers are scaffold-local. When the shaders are folded into the real HDDAGI
variants, bindings must be re-derived per variant: M0 confirmed that
`hddagi_preprocess.glsl` already reuses `light_tex` at binding 12 and binding 1 in
different modes, so a binding free in one variant is not free in all of them.

## 6. Determinism

Translation is deterministic and is what the fixtures pin, field for field.

Allocation is **not** deterministic. `allocate_one` takes its destination index from
`atomicAdd(free_cursor)`, so page ids differ between runs. The RFC's M2.04 wording
("exact page-ID parity") can therefore only apply to translation, not to allocation.
Allocation is validated by invariants instead: distinct pages, capacity respected,
overflow counted, generations unique. If exact page ids are needed for debugging, the
production path should compact in slot order with a two-pass prefix sum and use the
atomic path only as the fast variant.

## 7. Integration sketch

Written against the real signatures in the supplied tree, but **not compiled**: the
engine build is unavailable on this host. Treat this as a recipe, not as code.

```
// startup, once per HDDAGI instance
RD::TextureFormat tf;
tf.format = RD::DATA_FORMAT_R32_UINT;
tf.texture_type = RD::TEXTURE_TYPE_3D;
tf.width  = px * 8;  tf.height = py * 8;  tf.depth = pz * 8;
tf.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
tf.shareable_formats.push_back(RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32);
light_atlas = RD::get_singleton()->texture_create(tf, RD::TextureView());
// sampled view, exactly as gi.cpp:468-470 does for the dense texture
RD::TextureView tv; tv.format_override = RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32;
light_atlas_sampled = RD::get_singleton()->texture_create_shared(tv, light_atlas);

page_table = RD::get_singleton()->storage_buffer_create(slots * sizeof(PageEntry));
// ... meta, free list, cursor, requests, compacted, counters, allocated slots

// per epoch
RD::ComputeListID cl = RD::get_singleton()->compute_list_begin();
RD::get_singleton()->compute_list_bind_compute_pipeline(cl, pipeline_manage);
RD::get_singleton()->compute_list_bind_uniform_set(cl, set_manage, 0);
RD::get_singleton()->compute_list_set_push_constant(cl, &pc, sizeof(pc));
RD::get_singleton()->compute_list_dispatch(cl, groups, 1, 1);
RD::get_singleton()->compute_list_add_barrier(cl);   // required between modes
RD::get_singleton()->compute_list_end();
```

The barrier between `MODE_COMPACT` and `MODE_ALLOCATE` is load-bearing: allocate reads
`counters.compacted_count`, which compact writes. Splitting them into separate compute
lists without a barrier would race.

## 8. Remaining M2 work, in order

1. Build the engine on the Windows host (M0.02, still the blocking prerequisite).
2. Implement the capability table as a startup check that fails closed (M2.01).
3. Create the atlas and buffers, name them, and assert the byte budget matches
   section 4 (M2.02).
4. Port the three manage modes into `HDDAGI` and prove the compact/allocate barrier
   ordering with a GPU validation layer (M2.03).
5. Run `hddagi_sparse_brick_probe` against `fixtures/probe_fixtures.bin` and require
   0 mismatches over 1,180 records (M2.04).
6. Run the canary write/check pair on the real atlas, then repeat with the sampled
   `E5B9G9R9` view and a decode tolerance policy (M2.05).
7. Drive mixed-sign scroll and reuse through the real renderer, with the validation
   layer enabled, and confirm no stale reads (M2.06).
8. Exercise destruction: scene unload, GI toggle, cascade-count change, forced
   capability refusal (M2.07).

## 9. Gate

Not met. M2's gate is "GPU micro-test passes in Vulkan on RTX 3080 Ti". Nothing in
this scaffold substitutes for that, and no performance or correctness claim about the
GPU path should be made from it.
