# RenderingDevice adapter recipe (M2.01, M2.02, M2.04)

This is the part that cannot be compiled on the current host. It is written against
the real signatures in the supplied tree and is intended to be transcribed, not
trusted. Everything below is unverified until it builds on the Windows machine.

Signatures referenced (all from `servers/rendering/rendering_device.h` unless noted):

| call | line |
|---|---|
| `RID texture_create(const TextureFormat &, const TextureView &, const Vector<Vector<uint8_t>> &)` | 469 |
| `bool texture_is_valid(RID)` | 479 |
| `Error texture_clear(RID, const Color &, uint32_t, uint32_t, uint32_t, uint32_t)` | 487 |
| `RID storage_buffer_create(uint32_t, Span<uint8_t>, BitField<StorageBufferUsage>, BitField<BufferCreationBits>)` | 1063 |
| `RID uniform_set_create(const VectorView<Uniform> &, RID, uint32_t, bool)` | 1199 |
| `RID compute_pipeline_create(RID, const Vector<PipelineSpecializationConstant> &)` | 1286 |
| `uint64_t limit_get(Limit) const` | 1931 |
| `void free_rid(RID)` | 1908 |
| `RID shader_create_from_spirv(const Vector<ShaderStageSPIRVData> &, const String &)` | 1042 |

`TextureFormat` fields: `rendering_device_commons.h:433-446`.
Usage bits: `rendering_device_commons.h:402-408`.
Limits: `rendering_device_commons.h:988-989`, `:996-1006`.

---

## 1. Filling `DeviceCaps`

There is no format-support query in this API. The only reliable probe is to create
the exact resource and see whether the RID is valid. Do this once, at renderer
initialisation, and cache the result.

```cpp
// Uncompiled sketch. Assumes RD::get_singleton() is available.
static bool probe_3d_storage(RD::DataFormat p_format, const Vector<RD::DataFormat> &p_shareable,
        bool p_need_shared_view) {
    RD::TextureFormat tf;
    tf.format = p_format;
    tf.texture_type = RD::TEXTURE_TYPE_3D;
    tf.width = 1;
    tf.height = 1;
    tf.depth = 1;
    tf.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT;
    if (p_need_shared_view) {
        tf.usage_bits |= RD::TEXTURE_USAGE_SAMPLING_BIT;
        for (const RD::DataFormat &f : p_shareable) {
            tf.shareable_formats.push_back(f);
        }
    }

    RID base = RD::get_singleton()->texture_create(tf, RD::TextureView());
    if (!RD::get_singleton()->texture_is_valid(base)) {
        return false;
    }
    bool ok = true;
    if (p_need_shared_view) {
        RD::TextureView tv;
        tv.format_override = RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32;
        RID shared = RD::get_singleton()->texture_create_shared(tv, base);
        ok = RD::get_singleton()->texture_is_valid(shared);
        if (ok) {
            RD::get_singleton()->free_rid(shared);
        }
    }
    RD::get_singleton()->free_rid(base);
    return ok;
}

hddagi_sparse::DeviceCaps caps;
caps.max_texture_size_3d          = RD::get_singleton()->limit_get(RD::LIMIT_MAX_TEXTURE_SIZE_3D);
caps.max_storage_buffers_per_set  = RD::get_singleton()->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_UNIFORM_SET);
caps.max_storage_images_per_set   = RD::get_singleton()->limit_get(RD::LIMIT_MAX_STORAGE_IMAGES_PER_UNIFORM_SET);
caps.max_push_constant_size       = RD::get_singleton()->limit_get(RD::LIMIT_MAX_PUSH_CONSTANT_SIZE);
caps.max_compute_workgroups_x     = RD::get_singleton()->limit_get(RD::LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X);

Vector<RD::DataFormat> shareable = { RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32 };
caps.r32_uint_3d_storage    = probe_3d_storage(RD::DATA_FORMAT_R32_UINT, shareable, true);
caps.r8_uint_3d_storage     = probe_3d_storage(RD::DATA_FORMAT_R8_UINT, {}, false);
caps.e5b9g9r9_shareable_view = caps.r32_uint_3d_storage; // the shared view is the probe above
caps.storage_buffer          = RD::get_singleton()->storage_buffer_create(16).is_valid();
```

Note the ordering: `e5b9g9r9_shareable_view` is only meaningful if the base
`R32_UINT` texture was created, because the shared view is a child of it. Probing the
view on its own would report a false negative on drivers that support it fine.

`hddagi_sparse::plan_sparse_resources(caps, request)` then returns one of three
outcomes. **All three must be handled.** A `REFUSED` plan means the dense path stays
in use, not that the feature is half-initialised.

---

## 2. Creating resources from a `SparsePlan`

```cpp
RD::TextureFormat tf;
tf.format = RD::DATA_FORMAT_R32_UINT;
tf.texture_type = RD::TEXTURE_TYPE_3D;
tf.width  = plan.atlas_texels[0];
tf.height = plan.atlas_texels[1];
tf.depth  = plan.atlas_texels[2];
tf.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
tf.shareable_formats.push_back(RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32);
RID light_atlas = RD::get_singleton()->texture_create(tf, RD::TextureView());
ERR_FAIL_COND(light_atlas.is_null());

RD::TextureView tv;
tv.format_override = RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32;
RID light_atlas_sampled = RD::get_singleton()->texture_create_shared(tv, light_atlas);
```

The neighbour atlas is the same block with `R32_UINT` and no shareable formats; the
disocclusion atlas is `R8_UINT`. Buffers:

```cpp
page_table = RD::get_singleton()->storage_buffer_create(plan.page_table_bytes);
metadata   = RD::get_singleton()->storage_buffer_create(plan.meta_bytes);
free_list  = RD::get_singleton()->storage_buffer_create(plan.free_list_bytes);
cursor     = RD::get_singleton()->storage_buffer_create(sizeof(uint32_t));
requests   = RD::get_singleton()->storage_buffer_create(plan.request_bitset_bytes);
compacted  = RD::get_singleton()->storage_buffer_create(plan.compacted_bytes);
counters   = RD::get_singleton()->storage_buffer_create(hddagi_sparse::COUNTERS_BYTES);
allocated  = RD::get_singleton()->storage_buffer_create(plan.compacted_bytes);
```

`plan.total_bytes` is the number to log and to compare against the M0 accountant. If
it disagrees with the sum of the created sizes, one of the two is wrong.

---

## 3. Dispatch sequence

The ordering below is the contract. The barrier after compaction is not optional:
`MODE_ALLOCATE` reads `counters.compacted_count`, which `MODE_COMPACT` writes.

```cpp
const hddagi_sparse::DispatchPlan d = hddagi_sparse::plan_dispatch(plan, fixture_count, epoch, generation_base, cascades, grid);

RD::ComputeListID cl = RD::get_singleton()->compute_list_begin();

// 1. probe (fixtures only; not part of the shipping path)
RD::get_singleton()->compute_list_bind_compute_pipeline(cl, probe_pipeline);
RD::get_singleton()->compute_list_bind_uniform_set(cl, probe_set, 0);
RD::get_singleton()->compute_list_set_push_constant(cl, &d.probe, sizeof(d.probe));
RD::get_singleton()->compute_list_dispatch(cl, d.probe_groups, 1, 1);

// 2. compact
RD::get_singleton()->compute_list_add_barrier(cl);      // zero the counters first
RD::get_singleton()->compute_list_bind_compute_pipeline(cl, manage_pipeline);
RD::get_singleton()->compute_list_bind_uniform_set(cl, manage_set, 0);
RD::get_singleton()->compute_list_set_push_constant(cl, &d.compact, sizeof(d.compact));
RD::get_singleton()->compute_list_dispatch(cl, d.compact_groups, 1, 1);

// 3. allocate — MUST follow a barrier
RD::get_singleton()->compute_list_add_barrier(cl);
RD::get_singleton()->compute_list_set_push_constant(cl, &d.allocate, sizeof(d.allocate));
RD::get_singleton()->compute_list_dispatch(cl, d.allocate_groups, 1, 1);

// 4. host: zero the newly allocated pages before they may be committed
//    texture_clear(light_atlas, Color(0,0,0,0), 0, 1, 0, layers) per retired page,
//    or a dedicated clear pass over allocated_slots. Zeroing must complete before
//    step 5, which is why it cannot be folded into the same compute list.

// 5. initialize — publishes COMMITTED
RD::get_singleton()->compute_list_add_barrier(cl);
RD::get_singleton()->compute_list_set_push_constant(cl, &d.initialize, sizeof(d.initialize));
RD::get_singleton()->compute_list_dispatch(cl, d.initialize_groups, 1, 1);

RD::get_singleton()->compute_list_end();
```

`compute_list_add_barrier` signature: `rendering_device.h:1692`. If the host splits
these into separate lists instead, an explicit dependency between the lists is
required; the barrier only orders within one list.

---

## 4. What to assert on the first Windows run

1. `plan.decision == SUPPORTED` at the requested capacity, or a logged
   `REDUCED_CAPACITY` with the achievable number. A silent reduction is a bug.
2. Every created RID is valid, and `plan.total_bytes` equals the sum of the sizes
   actually requested from RD.
3. The probe dispatch over `fixtures/probe_fixtures.bin` reports **0 mismatches** on
   1,180 records. This is the single most valuable check in M2: it validates the
   entire coordinate contract against the CPU oracle on real hardware.
4. The canary write/check pair reports 0 mismatches over `capacity * 512` texels.
5. With the validation layer enabled, the scroll/reuse loop produces no stale-read or
   uninitialised-read warnings.
6. `texture_clear` on the atlas actually zeroes the pages before commit; a page read
   before its clear must not be possible. Test by forcing the order wrong and
   confirming the check fires.

If item 3 fails, stop. Nothing downstream is meaningful until translation parity
holds, because every other result depends on the address being right.

---

## 5. Known unknowns for the Windows run

- Whether the driver reports `R32_UINT` 3D storage as supported but silently
  degrades it. The probe cannot detect that; only a performance measurement can.
- Whether `E5B9G9R9_UFLOAT_PACK32` shared views on a `R32_UINT` storage image are
  coherent after compute writes without an explicit image memory barrier. The dense
  code already relies on this (`gi.cpp:468-470`), so it is likely fine, but the
  sparse path writes from a different shader and should be checked.
- Whether `MAX_COMPUTE_WORKGROUP_COUNT_X` is the binding limit for the canary
  dispatch at large capacities. `plan_dispatch` computes groups from the capacity and
  does not currently clamp to that limit; if the limit is small, the canary pass must
  be split. This is a real gap, listed rather than hidden.
