#include "hddagi_sparse_plan.h"

#include <algorithm>
#include <cmath>

namespace hddagi_sparse {

uint32_t max_pages_for_slots(uint32_t max_slots) {
	// Three axes of page slots, each axis limited by the 3D extent.
	const uint64_t v = uint64_t(max_slots) * uint64_t(max_slots) * uint64_t(max_slots);
	return v > 0xFFFFFFFFull ? 0xFFFFFFFFu : uint32_t(v);
}

bool factorise_slots(uint32_t capacity, uint32_t max_slots, int out[3]) {
	if (capacity == 0 || max_slots == 0) {
		return false;
	}
	if (uint64_t(capacity) > uint64_t(max_slots) * max_slots * max_slots) {
		return false;
	}

	// Prefer a near-cubic split: it minimises the longest axis, which is what
	// texture extent limits constrain first. The search is bounded around the cube
	// root because a very lopsided split wastes slots for no benefit, and an
	// unbounded scan would be O(max_slots^2) at startup.
	uint32_t best_slots = 0;
	int best[3] = { 0, 0, 0 };

	const double cube_root = std::cbrt(double(capacity));
	uint32_t limit = uint32_t(cube_root * 2.0) + 2;
	if (limit < 4) {
		limit = 4;
	}
	if (limit > max_slots) {
		limit = max_slots;
	}

	for (uint32_t px = 1; px <= limit; px++) {
		const uint32_t remaining = (capacity + px - 1) / px;
		if (remaining == 0) {
			break;
		}
		for (uint32_t py = 1; py <= limit; py++) {
			const uint32_t pz = (remaining + py - 1) / py;
			if (pz > max_slots) {
				continue;
			}
			const uint32_t slots = px * py * pz;
			if (slots < capacity) {
				continue;
			}
			// Fewer slots wins. On a tie, prefer the shorter longest axis (the 3D
			// extent limit constrains that first), then the larger shortest axis,
			// which rejects lopsided splits such as 4x16x16 in favour of 8x8x16.
			const int longest = int(std::max(px, std::max(py, pz)));
			const int shortest = int(std::min(px, std::min(py, pz)));
			const int best_longest = std::max(best[0], std::max(best[1], best[2]));
			const int best_shortest = std::min(best[0], std::min(best[1], best[2]));
			const bool better = best_slots == 0 || slots < best_slots ||
					(slots == best_slots && (longest < best_longest ||
							(longest == best_longest && shortest > best_shortest)));
			if (better) {
				best_slots = slots;
				best[0] = int(px);
				best[1] = int(py);
				best[2] = int(pz);
			}
		}
	}

	if (best_slots == 0) {
		return false;
	}
	out[0] = best[0];
	out[1] = best[1];
	out[2] = best[2];
	return true;
}

SparsePlan plan_sparse_resources(const DeviceCaps &caps, const SparseRequest &request) {
	SparsePlan plan;
	plan.virtual_pages = uint32_t(request.cascade_count) *
			uint32_t((request.grid[0] / BRICK_EDGE) * (request.grid[1] / BRICK_EDGE) * (request.grid[2] / BRICK_EDGE));

	// Checks 1-3: the three formats and the shared view. A device that cannot do
	// all three cannot host the payload group at all, so there is no partial mode.
	if (!caps.r32_uint_3d_storage) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::LIGHT_FORMAT;
		plan.reason = "3D R32_UINT storage image unsupported";
		return plan;
	}
	if (!caps.r8_uint_3d_storage) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::DISOCLUSION_FORMAT;
		plan.reason = "3D R8_UINT storage image unsupported";
		return plan;
	}
	if (!caps.e5b9g9r9_shareable_view) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::SHARED_LIGHT_VIEW;
		plan.reason = "E5B9G9R9 shared sampled view unsupported; decode parity would be unprovable";
		return plan;
	}
	if (!caps.storage_buffer) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::STORAGE_BUFFER;
		plan.reason = "storage buffers unsupported";
		return plan;
	}

	// Check 4: atlas extent. Reduce capacity rather than refuse, because a smaller
	// pool is still correct; the RFC requires the reduction to be recorded.
	if (caps.max_texture_size_3d < BRICK_EDGE) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::ATLAS_EXTENT;
		plan.reason = "3D texture extent smaller than one brick";
		return plan;
	}
	const uint32_t max_slots = uint32_t(caps.max_texture_size_3d / BRICK_EDGE);
	const uint32_t max_pages = max_pages_for_slots(max_slots);

	uint32_t capacity = request.requested_pages;
	bool reduced = false;
	if (capacity == 0) {
		capacity = 1;
	}
	if (capacity > max_pages) {
		capacity = max_pages;
		reduced = true;
	}

	int slots[3] = { 0, 0, 0 };
	if (!factorise_slots(capacity, max_slots, slots)) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::ATLAS_EXTENT;
		plan.reason = "no page-slot factorisation fits the 3D extent limit";
		return plan;
	}

	// Check 6: the manage shader's push constant block.
	if (caps.max_push_constant_size < sizeof(ManagePushConstants)) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::PUSH_CONSTANTS;
		plan.reason = "push constant limit below the manage block size";
		return plan;
	}

	// Check 7: the manage shader binds eight storage buffers in set 0.
	if (caps.max_storage_buffers_per_set < 8) {
		plan.decision = Decision::REFUSED;
		plan.failed_check = Check::DESCRIPTOR_BUDGET;
		plan.reason = "fewer than eight storage buffers per set";
		return plan;
	}

	const uint32_t slots_total = uint32_t(slots[0]) * uint32_t(slots[1]) * uint32_t(slots[2]);

	plan.capacity = capacity;
	plan.page_slots[0] = slots[0];
	plan.page_slots[1] = slots[1];
	plan.page_slots[2] = slots[2];
	plan.atlas_texels[0] = slots[0] * BRICK_EDGE;
	plan.atlas_texels[1] = slots[1] * BRICK_EDGE;
	plan.atlas_texels[2] = slots[2] * BRICK_EDGE;

	// Atlas cost is driven by allocated slots, not by requested pages: the slack
	// from rounding up to whole page slots is real memory.
	plan.light_atlas_bytes = uint64_t(slots_total) * VOXELS_PER_BRICK * 4ull;
	plan.neighbour_atlas_bytes = uint64_t(slots_total) * VOXELS_PER_BRICK * 4ull;
	plan.disocclusion_atlas_bytes = uint64_t(slots_total) * VOXELS_PER_BRICK * 1ull;

	plan.page_table_bytes = uint64_t(plan.virtual_pages) * PAGE_ENTRY_BYTES;
	plan.meta_bytes = uint64_t(capacity) * BRICK_META_BYTES;
	plan.request_bitset_bytes = (uint64_t(plan.virtual_pages) + 7) / 8;
	plan.compacted_bytes = uint64_t(capacity) * 4;
	plan.free_list_bytes = uint64_t(capacity) * 4;

	plan.total_bytes = plan.light_atlas_bytes + plan.neighbour_atlas_bytes +
			plan.disocclusion_atlas_bytes + plan.page_table_bytes + plan.meta_bytes +
			plan.request_bitset_bytes + plan.compacted_bytes + plan.free_list_bytes +
			COUNTERS_BYTES;

	if (reduced) {
		plan.decision = Decision::REDUCED_CAPACITY;
		plan.reason = "requested page count exceeds what the 3D extent limit can address";
	} else {
		plan.decision = Decision::SUPPORTED;
		plan.reason = "all capability checks passed";
	}
	return plan;
}

DispatchPlan plan_dispatch(const SparsePlan &plan, uint32_t fixture_count,
		uint32_t epoch, uint32_t generation_base, int cascade_count, const int grid[3],
		uint32_t max_workgroups_x) {
	DispatchPlan d;

	d.probe_groups = groups_for(fixture_count);
	d.probe.count = fixture_count;
	d.probe.grid_x = uint32_t(grid[0]);
	d.probe.grid_y = uint32_t(grid[1]);
	d.probe.grid_z = uint32_t(grid[2]);
	d.probe.cascade_count = uint32_t(cascade_count);
	d.probe.brick_dim_x = uint32_t(grid[0] / BRICK_EDGE);
	d.probe.brick_dim_y = uint32_t(grid[1] / BRICK_EDGE);
	d.probe.brick_dim_z = uint32_t(grid[2] / BRICK_EDGE);
	d.probe.page_slots_x = uint32_t(plan.page_slots[0]);
	d.probe.page_slots_y = uint32_t(plan.page_slots[1]);

	const uint32_t word_count = (plan.virtual_pages + 31) / 32;
	const uint32_t bricks_per_cascade = uint32_t((grid[0] / BRICK_EDGE) * (grid[1] / BRICK_EDGE) * (grid[2] / BRICK_EDGE));

	d.compact_groups = groups_for(word_count);
	d.allocate_groups = groups_for(plan.capacity);
	d.initialize_groups = groups_for(plan.capacity);
	d.canary_total_groups = groups_for(plan.capacity * VOXELS_PER_BRICK);
	const uint32_t limit = max_workgroups_x == 0 ? 1u : max_workgroups_x;
	d.canary_groups = d.canary_total_groups < limit ? d.canary_total_groups : limit;
	d.canary_passes = d.canary_total_groups == 0 ? 0u : (d.canary_total_groups + limit - 1) / limit;

	const uint32_t common[10] = { 0, word_count, plan.virtual_pages, plan.capacity, epoch,
		generation_base, bricks_per_cascade, uint32_t(grid[0] / BRICK_EDGE),
		uint32_t(grid[1] / BRICK_EDGE), uint32_t(grid[2] / BRICK_EDGE) };

	d.compact = ManagePushConstants{ MODE_COMPACT, common[1], common[2], common[3], common[4],
		common[5], common[6], common[7], common[8], common[9] };
	d.allocate = ManagePushConstants{ MODE_ALLOCATE, common[1], common[2], common[3], common[4],
		common[5], common[6], common[7], common[8], common[9] };
	d.initialize = ManagePushConstants{ MODE_INITIALIZE, common[1], common[2], common[3], common[4],
		common[5], common[6], common[7], common[8], common[9] };

	d.canary.page_count = plan.capacity;
	d.canary.page_slots_x = uint32_t(plan.page_slots[0]);
	d.canary.page_slots_y = uint32_t(plan.page_slots[1]);
	d.canary.offset = 0; // the host advances this per pass

	return d;
}

} // namespace hddagi_sparse
