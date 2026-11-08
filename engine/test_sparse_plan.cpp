// M2.01 / M2.04 decision-core tests. No RenderingDevice, no GPU.

#include "../tests/renderer_hddagi_sparse/test_harness.h"
#include "hddagi_sparse_plan.h"

#include <cstring>
#include <fstream>
#include <string>

using namespace hddagi_sparse;

namespace {

DeviceCaps good_caps() {
	DeviceCaps c;
	c.max_texture_size_3d = 16384;
	c.max_storage_buffers_per_set = 16;
	c.max_storage_images_per_set = 8;
	c.max_push_constant_size = 128;
	c.max_compute_workgroups_x = 65535;
	c.r32_uint_3d_storage = true;
	c.r8_uint_3d_storage = true;
	c.e5b9g9r9_shareable_view = true;
	c.storage_buffer = true;
	return c;
}

SparseRequest default_request(uint32_t pages = 1024) {
	SparseRequest r;
	r.cascade_count = 6;
	r.grid[0] = 128;
	r.grid[1] = 64;
	r.grid[2] = 128;
	r.requested_pages = pages;
	return r;
}

} // namespace

TEST(happy_path_is_supported) {
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request());
	CHECK_EQ(p.decision, Decision::SUPPORTED);
	CHECK_EQ(p.failed_check, Check::NONE);
	CHECK_EQ(p.virtual_pages, 12288u);
	CHECK_EQ(p.capacity, 1024u);
}

TEST(atlas_factorisation_matches_the_rfc_example) {
	// RFC section 7 works 1,024 pages as 8x8x16 slots -> 64x64x128 texels.
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(1024));
	CHECK_EQ(p.page_slots[0], 8);
	CHECK_EQ(p.page_slots[1], 8);
	CHECK_EQ(p.page_slots[2], 16);
	CHECK_EQ(p.atlas_texels[0], 64);
	CHECK_EQ(p.atlas_texels[1], 64);
	CHECK_EQ(p.atlas_texels[2], 128);
	// 1,024 pages x 512 voxels x 4 bytes = 2 MiB per 32-bit field.
	CHECK_EQ(p.light_atlas_bytes, uint64_t(2) * 1024 * 1024);
	CHECK_EQ(p.neighbour_atlas_bytes, uint64_t(2) * 1024 * 1024);
	CHECK_EQ(p.disocclusion_atlas_bytes, uint64_t(512) * 1024);
}

TEST(page_table_and_metadata_bytes) {
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(1024));
	CHECK_EQ(p.page_table_bytes, uint64_t(12288) * 16);
	CHECK_EQ(p.meta_bytes, uint64_t(1024) * 32);
	CHECK_EQ(p.request_bitset_bytes, uint64_t(12288 / 8));
	CHECK_EQ(p.compacted_bytes, uint64_t(1024) * 4);
	CHECK_EQ(p.free_list_bytes, uint64_t(1024) * 4);
}

TEST(each_missing_format_refuses_with_its_own_check_id) {
	{
		DeviceCaps c = good_caps();
		c.r32_uint_3d_storage = false;
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::LIGHT_FORMAT);
	}
	{
		DeviceCaps c = good_caps();
		c.r8_uint_3d_storage = false;
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::DISOCLUSION_FORMAT);
	}
	{
		DeviceCaps c = good_caps();
		c.e5b9g9r9_shareable_view = false;
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::SHARED_LIGHT_VIEW);
	}
	{
		DeviceCaps c = good_caps();
		c.storage_buffer = false;
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::STORAGE_BUFFER);
	}
}

TEST(push_constant_and_descriptor_limits_refuse) {
	{
		DeviceCaps c = good_caps();
		c.max_push_constant_size = 32; // manage needs 40
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::PUSH_CONSTANTS);
	}
	{
		DeviceCaps c = good_caps();
		c.max_storage_buffers_per_set = 7; // manage binds 8
		const SparsePlan p = plan_sparse_resources(c, default_request());
		CHECK_EQ(p.decision, Decision::REFUSED);
		CHECK_EQ(p.failed_check, Check::DESCRIPTOR_BUDGET);
	}
}

TEST(tiny_3d_extent_refuses) {
	DeviceCaps c = good_caps();
	c.max_texture_size_3d = 4; // smaller than one 8-texel brick
	const SparsePlan p = plan_sparse_resources(c, default_request());
	CHECK_EQ(p.decision, Decision::REFUSED);
	CHECK_EQ(p.failed_check, Check::ATLAS_EXTENT);
}

TEST(extent_limit_reduces_capacity_and_says_so) {
	DeviceCaps c = good_caps();
	c.max_texture_size_3d = 64; // 8 page slots per axis -> 512 pages max
	const SparsePlan p = plan_sparse_resources(c, default_request(12288));
	CHECK_EQ(p.decision, Decision::REDUCED_CAPACITY);
	CHECK_EQ(p.capacity, 512u);
	CHECK_EQ(p.page_slots[0], 8);
	CHECK_EQ(p.page_slots[1], 8);
	CHECK_EQ(p.page_slots[2], 8);
	// The reduction must be visible in the accounting, not silent.
	CHECK(p.light_atlas_bytes == uint64_t(512) * 512 * 4);
}

TEST(zero_requested_pages_still_produces_a_valid_plan) {
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(0));
	CHECK_EQ(p.decision, Decision::SUPPORTED);
	CHECK_EQ(p.capacity, 1u);
}

TEST(factorisation_respects_the_axis_limit_and_never_undersizes) {
	const uint32_t limits[] = { 1, 2, 3, 8, 16, 64, 2048 };
	const uint32_t capacities[] = { 1, 7, 64, 512, 1024, 4096, 12288, 65536 };
	for (uint32_t max_slots : limits) {
		for (uint32_t capacity : capacities) {
			int slots[3] = { 0, 0, 0 };
			const bool ok = factorise_slots(capacity, max_slots, slots);
			const uint64_t max_pages = uint64_t(max_slots) * max_slots * max_slots;
			if (uint64_t(capacity) > max_pages) {
				CHECK(!ok);
				continue;
			}
			if (!ok) {
				test::report_failure(__FILE__, __LINE__,
						"factorisation failed for capacity " + std::to_string(capacity) +
								" max_slots " + std::to_string(max_slots));
				continue;
			}
			const uint64_t product = uint64_t(slots[0]) * uint64_t(slots[1]) * uint64_t(slots[2]);
			if (product < capacity) {
				test::report_failure(__FILE__, __LINE__, "factorisation undersized");
			}
			for (int i = 0; i < 3; i++) {
				if (slots[i] < 1 || uint32_t(slots[i]) > max_slots) {
					test::report_failure(__FILE__, __LINE__, "factorisation axis out of range");
				}
			}
		}
	}
}

TEST(dispatch_groups_round_up) {
	CHECK_EQ(groups_for(0), 0u);
	CHECK_EQ(groups_for(1), 1u);
	CHECK_EQ(groups_for(64), 1u);
	CHECK_EQ(groups_for(65), 2u);
	CHECK_EQ(groups_for(1180), 19u); // 1180 / 64 = 18.4
}

TEST(dispatch_plan_matches_the_fixture_file) {
	// Cross-check against the binary fixture metadata the probe shader consumes.
	std::ifstream in("../gpu/fixtures/probe_fixtures.json");
	REQUIRE(in.good());
	std::string json((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	REQUIRE(json.find("\"count\": 1180") != std::string::npos);

	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(1024));
	const int grid[3] = { 128, 64, 128 };
	const DispatchPlan d = plan_dispatch(p, 1180, 7, 1000, 6, grid);

	CHECK_EQ(d.probe.count, 1180u);
	CHECK_EQ(d.probe_groups, 19u);
	CHECK_EQ(d.probe.grid_x, 128u);
	CHECK_EQ(d.probe.grid_y, 64u);
	CHECK_EQ(d.probe.grid_z, 128u);
	CHECK_EQ(d.probe.cascade_count, 6u);
	CHECK_EQ(d.probe.brick_dim_x, 16u);
	CHECK_EQ(d.probe.brick_dim_y, 8u);
	CHECK_EQ(d.probe.brick_dim_z, 16u);
	CHECK_EQ(d.probe.page_slots_x, 8u);
	CHECK_EQ(d.probe.page_slots_y, 8u);
}

TEST(dispatch_plan_sizes_the_manage_modes) {
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(1024));
	const int grid[3] = { 128, 64, 128 };
	const DispatchPlan d = plan_dispatch(p, 1180, 7, 1000, 6, grid);

	CHECK_EQ(d.compact.mode, MODE_COMPACT);
	CHECK_EQ(d.allocate.mode, MODE_ALLOCATE);
	CHECK_EQ(d.initialize.mode, MODE_INITIALIZE);

	// 12,288 slots / 32 per word = 384 words -> 6 groups.
	CHECK_EQ(d.compact.word_count, 384u);
	CHECK_EQ(d.compact_groups, 6u);
	CHECK_EQ(d.allocate_groups, groups_for(1024));
	CHECK_EQ(d.initialize_groups, groups_for(1024));
	CHECK_EQ(d.canary.page_count, 1024u);
	CHECK_EQ(d.canary_total_groups, groups_for(1024 * 512));
	CHECK_EQ(d.canary_passes, 1u);
	CHECK_EQ(d.canary_groups, d.canary_total_groups);
}

TEST(push_constant_layout_is_byte_stable) {
	CHECK_EQ(sizeof(ProbePushConstants), size_t(40));
	CHECK_EQ(sizeof(ManagePushConstants), size_t(40));
	CHECK_EQ(sizeof(CanaryPushConstants), size_t(16));

	ProbePushConstants pc{};
	pc.count = 0xAABBCCDDu;
	unsigned char bytes[40];
	std::memcpy(bytes, &pc, sizeof(bytes));
	// Little-endian host: first field occupies bytes 0..3.
	CHECK_EQ(int(bytes[0]), 0xDD);
	CHECK_EQ(int(bytes[3]), 0xAA);
}

TEST(canary_dispatch_splits_when_it_exceeds_the_workgroup_limit) {
	// 12,288 pages x 512 voxels / 64 = 98,304 groups, above a 65,535 limit.
	const SparsePlan p = plan_sparse_resources(good_caps(), default_request(12288));
	const int grid[3] = { 128, 64, 128 };
	const DispatchPlan d = plan_dispatch(p, 1180, 7, 1000, 6, grid, 65535);

	CHECK_EQ(d.canary_total_groups, groups_for(12288u * 512u));
	CHECK_EQ(d.canary_total_groups, 98304u);
	CHECK_EQ(d.canary_groups, 65535u);
	CHECK_EQ(d.canary_passes, 2u);
	CHECK_EQ(d.canary.offset, 0u);

	// A generous limit means a single pass.
	const DispatchPlan one = plan_dispatch(p, 1180, 7, 1000, 6, grid, 200000);
	CHECK_EQ(one.canary_passes, 1u);
	CHECK_EQ(one.canary_groups, one.canary_total_groups);
}

int main(int argc, char **argv) {
	(void)argc;
	(void)argv;
	return test::run_all();
}
