// M2.01 / M2.04 decision core, free of RenderingDevice dependencies.
//
// The engine side of sparse bricks splits cleanly in two:
//
//   1. decide whether this device can support the mode, and at what capacity;
//   2. decide how many workgroups to dispatch and what push constants to send.
//
// Both are pure arithmetic over numbers the adapter reads from RenderingDevice.
// Keeping them here means they can be compiled and tested on a host with no GPU,
// and the Windows integration only has to supply the numbers and bind the RIDs.
//
// This file does not include rendering_device.h on purpose. The adapter that
// fills DeviceCaps lives in RD_ADAPTER.md.

#pragma once

#include <cstdint>

namespace hddagi_sparse {

constexpr int BRICK_EDGE = 8;
constexpr uint32_t VOXELS_PER_BRICK = 512;
constexpr uint32_t WORKGROUP_SIZE = 64;

// Byte sizes of the records the shaders consume. Kept in sync with
// gpu/hddagi_sparse_gpu_model.h by static_assert there and by test here.
constexpr uint32_t PAGE_ENTRY_BYTES = 16;
constexpr uint32_t BRICK_META_BYTES = 32;
constexpr uint32_t COUNTERS_BYTES = 32;
constexpr uint32_t CHECK_RESULT_BYTES = 16;

// What the adapter must discover before sparse mode can be considered.
//
// Format/usage support cannot be queried directly in this RenderingDevice API.
// The adapter probes each one by creating a 1x1x1 texture with the exact format
// and usage, checking texture_is_valid(), and freeing it. These fields are the
// results of those probes, not assumptions.
struct DeviceCaps {
	uint64_t max_texture_size_3d = 0;
	uint64_t max_storage_buffers_per_set = 0;
	uint64_t max_storage_images_per_set = 0;
	uint64_t max_push_constant_size = 0;
	uint64_t max_compute_workgroups_x = 0;

	bool r32_uint_3d_storage = false;
	bool r8_uint_3d_storage = false;
	bool e5b9g9r9_shareable_view = false;
	bool storage_buffer = false;
};

struct SparseRequest {
	int cascade_count = 6;
	int grid[3] = { 128, 64, 128 };
	uint32_t requested_pages = 1024;
};

enum class Decision : uint32_t {
	SUPPORTED = 0,
	REDUCED_CAPACITY = 1,
	REFUSED = 2,
};

// Check ids match the capability table in artifacts/m2_scaffold.md.
enum class Check : uint32_t {
	NONE = 0,
	LIGHT_FORMAT = 1,
	DISOCLUSION_FORMAT = 2,
	SHARED_LIGHT_VIEW = 3,
	ATLAS_EXTENT = 4,
	STORAGE_BUFFER = 5,
	PUSH_CONSTANTS = 6,
	DESCRIPTOR_BUDGET = 7,
};

struct SparsePlan {
	Decision decision = Decision::REFUSED;
	Check failed_check = Check::NONE;
	const char *reason = "";

	uint32_t virtual_pages = 0;
	uint32_t capacity = 0; // pages actually allocated after any reduction
	int page_slots[3] = { 0, 0, 0 };
	int atlas_texels[3] = { 0, 0, 0 };

	uint64_t light_atlas_bytes = 0;
	uint64_t neighbour_atlas_bytes = 0;
	uint64_t disocclusion_atlas_bytes = 0;
	uint64_t page_table_bytes = 0;
	uint64_t meta_bytes = 0;
	uint64_t request_bitset_bytes = 0;
	uint64_t compacted_bytes = 0;
	uint64_t free_list_bytes = 0;
	uint64_t total_bytes = 0;
};

// Largest page-slot factorisation whose product is >= capacity and whose axes
// stay within max_slots. Returns false when not even one page fits.
bool factorise_slots(uint32_t capacity, uint32_t max_slots, int out[3]);

// Maximum number of pages that can be addressed given an axis limit.
uint32_t max_pages_for_slots(uint32_t max_slots);

SparsePlan plan_sparse_resources(const DeviceCaps &caps, const SparseRequest &request);

// ---------------------------------------------------------------------------
// Dispatch planning (M2.04)
// ---------------------------------------------------------------------------

// Push constant blocks, laid out exactly as the shaders declare them.
struct ProbePushConstants {
	uint32_t count;
	uint32_t grid_x;
	uint32_t grid_y;
	uint32_t grid_z;
	uint32_t cascade_count;
	uint32_t brick_dim_x;
	uint32_t brick_dim_y;
	uint32_t brick_dim_z;
	uint32_t page_slots_x;
	uint32_t page_slots_y;
};

struct ManagePushConstants {
	uint32_t mode;
	uint32_t word_count;
	uint32_t slot_count;
	uint32_t capacity;
	uint32_t epoch;
	uint32_t generation_base;
	uint32_t bricks_per_cascade;
	uint32_t brick_dim_x;
	uint32_t brick_dim_y;
	uint32_t brick_dim_z;
};

struct CanaryPushConstants {
	uint32_t page_count;
	uint32_t page_slots_x;
	uint32_t page_slots_y;
	uint32_t offset; // first linear index for this pass; lets a large pool be split
};

static_assert(sizeof(ProbePushConstants) == 40, "probe push constants must be 40 bytes");
static_assert(sizeof(ManagePushConstants) == 40, "manage push constants must be 40 bytes");
static_assert(sizeof(CanaryPushConstants) == 16, "canary push constants must be 16 bytes");

enum : uint32_t {
	MODE_COMPACT = 0,
	MODE_ALLOCATE = 1,
	MODE_INITIALIZE = 2,
};

struct DispatchPlan {
	uint32_t probe_groups = 0;
	uint32_t compact_groups = 0;
	uint32_t allocate_groups = 0;
	uint32_t initialize_groups = 0;

	// The canary pass scales with capacity * 512, so it can exceed the device's
	// workgroup-count limit. The host issues `canary_passes` dispatches of at most
	// `canary_groups` groups each, advancing `canary.offset` by groups * 64.
	uint32_t canary_total_groups = 0;
	uint32_t canary_groups = 0;
	uint32_t canary_passes = 0;

	ProbePushConstants probe{};
	ManagePushConstants compact{};
	ManagePushConstants allocate{};
	ManagePushConstants initialize{};
	CanaryPushConstants canary{};
};

inline uint32_t groups_for(uint32_t items) {
	return (items + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
}

DispatchPlan plan_dispatch(const SparsePlan &plan, uint32_t fixture_count,
		uint32_t epoch, uint32_t generation_base, int cascade_count, const int grid[3],
		uint32_t max_workgroups_x = 65535);

} // namespace hddagi_sparse
