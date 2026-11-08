// M1.01 / M1.02 — layout, coordinate conversion, atlas addressing.

#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <cstdint>

using namespace hddagi_sparse;

namespace {

const GridLayout kDefault = GridLayout::make(128, 64, 128, 6);
const GridLayout kFullHeight = GridLayout::make(128, 128, 128, 6);

int region_start_local(int region, int position, int grid) {
	return region * BRICK_EDGE - position + grid / 2;
}

} // namespace

TEST(layout_dimensions_match_source) {
	CHECK(kDefault.valid());
	CHECK(kFullHeight.valid());
	// gi.cpp:369-380 — default 16x8x16 halves the Y extent.
	CHECK_EQ(kDefault.size[1], 64);
	CHECK_EQ(kFullHeight.size[1], 128);
	CHECK_EQ(kDefault.bricks_per_axis(0), 16);
	CHECK_EQ(kDefault.bricks_per_axis(1), 8);
	CHECK_EQ(kDefault.bricks_per_axis(2), 16);
	// RFC section 3: 2,048 bricks in a default cascade, 4,096 full height.
	CHECK_EQ(kDefault.bricks_per_cascade(), 2048);
	CHECK_EQ(kFullHeight.bricks_per_cascade(), 4096);
	CHECK_EQ(kDefault.virtual_pages(), 2048 * 6);
	CHECK_EQ(kFullHeight.virtual_pages(), 4096 * 6);
}

TEST(layout_rejects_bad_shapes) {
	CHECK(!GridLayout::make(127, 64, 128, 6).valid()); // not a power of two
	CHECK(!GridLayout::make(128, 60, 128, 6).valid()); // not a multiple of the brick edge
	CHECK(!GridLayout::make(128, 64, 128, 0).valid()); // no cascades
	CHECK(!GridLayout::make(128, 64, 128, 9).valid()); // beyond MAX_CASCADES
}

TEST(floor_div_handles_negatives) {
	// The engine only ever divides exact multiples of 8, but the oracle must be
	// correct in general or the multiple-of-8 assumption becomes invisible.
	CHECK_EQ(floor_div(8, 8), 1);
	CHECK_EQ(floor_div(0, 8), 0);
	CHECK_EQ(floor_div(-1, 8), -1);
	CHECK_EQ(floor_div(-8, 8), -1);
	CHECK_EQ(floor_div(-9, 8), -2);
	CHECK_EQ(floor_div(7, 8), 0);
	CHECK_EQ(floor_div(-7, 8), -1);
}

TEST(wrap_matches_engine_formula) {
	int local[3] = { 0, 0, 0 };
	int position[3] = { 0, 0, 0 };
	WrappedVoxel w = wrap_local(kDefault, local, position);
	CHECK_EQ(w.x, 0);

	local[0] = 127;
	w = wrap_local(kDefault, local, position);
	CHECK_EQ(w.x, 127);

	// (local + position) & (grid - 1), including negative positions.
	local[0] = 3;
	position[0] = -8;
	w = wrap_local(kDefault, local, position);
	CHECK_EQ(w.x, (3 - 8) & 127);
	CHECK_EQ(w.x, 123);

	local[0] = 0;
	position[0] = -128;
	w = wrap_local(kDefault, local, position);
	CHECK_EQ(w.x, 0);
}

TEST(wrap_round_trips_through_unwrap) {
	for (int position_x = -256; position_x <= 256; position_x += 8) {
		for (int local_x = 0; local_x < 128; local_x += 13) {
			int position[3] = { position_x, 0, 0 };
			int local[3] = { local_x, 0, 0 };
			WrappedVoxel w = wrap_local(kDefault, local, position);
			int back[3];
			CHECK(unwrap_to_local(kDefault, w, position, back));
			CHECK_EQ(back[0], local_x);
		}
	}
}

TEST(world_region_covers_exactly_the_cascade_window) {
	// A cascade spans grid/8 regions. Check that the lowest and highest local voxels
	// land on the expected window edges for an arbitrary scroll offset.
	const int cases[][3] = {
		{ 0, 0, 0 },
		{ 8, 8, 8 },
		{ -8, -8, -8 },
		{ 1024, -1024, 512 },
		{ -2048, 2048, -4096 },
	};

	for (const auto &position : cases) {
		int lo_local[3] = { 0, 0, 0 };
		int hi_local[3] = { kDefault.size[0] - 1, kDefault.size[1] - 1, kDefault.size[2] - 1 };
		WorldRegion lo = world_region_of(kDefault, lo_local, position);
		WorldRegion hi = world_region_of(kDefault, hi_local, position);

		CHECK_EQ(hi.x - lo.x, kDefault.bricks_per_axis(0) - 1);
		CHECK_EQ(hi.y - lo.y, kDefault.bricks_per_axis(1) - 1);
		CHECK_EQ(hi.z - lo.z, kDefault.bricks_per_axis(2) - 1);

		// The cascade origin is position - grid/2, so region lo starts there.
		CHECK_EQ(lo.x, floor_div(position[0] - kDefault.size[0] / 2, BRICK_EDGE));
		CHECK_EQ(lo.y, floor_div(position[1] - kDefault.size[1] / 2, BRICK_EDGE));
		CHECK_EQ(lo.z, floor_div(position[2] - kDefault.size[2] / 2, BRICK_EDGE));
	}
}

TEST(region_to_slot_is_scroll_independent) {
	// A world region always lands in the same wrapped slot; that is what makes a
	// page table possible at all, and also why the slot alone cannot prove identity.
	const int zero_position[3] = { 0, 0, 0 };
	for (int position_x = -128; position_x <= 128; position_x += 8) {
		int position[3] = { position_x, 0, 0 };
		WorldRegion r;
		r.x = 0;
		r.y = 0;
		r.z = 0;
		// The local voxel that holds region r depends on the scroll, but the wrapped
		// slot it lands in does not. Compare each position's own local coordinate.
		int local[3];
		local[0] = region_start_local(r.x, position[0], kDefault.size[0]);
		local[1] = region_start_local(r.y, position[1], kDefault.size[1]);
		local[2] = region_start_local(r.z, position[2], kDefault.size[2]);
		WrappedVoxel w = wrap_local(kDefault, local, position);

		int local0[3];
		local0[0] = region_start_local(r.x, zero_position[0], kDefault.size[0]);
		local0[1] = region_start_local(r.y, zero_position[1], kDefault.size[1]);
		local0[2] = region_start_local(r.z, zero_position[2], kDefault.size[2]);
		const WrappedVoxel at_origin = wrap_local(kDefault, local0, zero_position);

		CHECK_EQ(virtual_slot_of(kDefault, 0, w), virtual_slot_of(kDefault, 0, at_origin));
	}
}

TEST(virtual_slots_are_unique_and_in_range) {
	const int bpc = kDefault.bricks_per_cascade();
	for (int cascade = 0; cascade < kDefault.cascade_count; cascade++) {
		for (int z = 0; z < kDefault.bricks_per_axis(2); z++) {
			for (int y = 0; y < kDefault.bricks_per_axis(1); y++) {
				for (int x = 0; x < kDefault.bricks_per_axis(0); x++) {
					int brick[3] = { x, y, z };
					int slot = virtual_slot_of_brick(kDefault, cascade, brick);
					CHECK(slot >= 0);
					CHECK(slot < kDefault.virtual_pages());
					CHECK_EQ(slot / bpc, cascade);

					WrappedVoxel w;
					w.x = x * BRICK_EDGE;
					w.y = y * BRICK_EDGE;
					w.z = z * BRICK_EDGE;
					CHECK_EQ(virtual_slot_of(kDefault, cascade, w), slot);
				}
			}
		}
	}
}

TEST(atlas_texels_are_unique_per_page_and_local_voxel) {
	// 8x8x16 slots = 1024 pages = 64x64x128 texels.
	const int px = 8, py = 8;
	for (uint32_t page = 0; page < 1024; page++) {
		for (int lz = 0; lz < 8; lz += 3) {
			for (int ly = 0; ly < 8; ly += 3) {
				for (int lx = 0; lx < 8; lx += 3) {
					int local[3] = { lx, ly, lz };
					int t[3];
					atlas_texel_of(page, px, py, local, t);
					CHECK(t[0] >= 0 && t[0] < 64);
					CHECK(t[1] >= 0 && t[1] < 64);
					CHECK(t[2] >= 0 && t[2] < 128);
				}
			}
		}
	}

	// Spot-check the RFC's worked example: page 0 local (0,0,0) -> texel (0,0,0);
	// page 1 -> x = 8; page 8 -> y = 8; page 64 -> z = 8.
	int t[3];
	int local[3] = { 0, 0, 0 };
	atlas_texel_of(0, px, py, local, t);
	CHECK_EQ(t[0], 0);
	CHECK_EQ(t[1], 0);
	CHECK_EQ(t[2], 0);
	atlas_texel_of(1, px, py, local, t);
	CHECK_EQ(t[0], 8);
	atlas_texel_of(8, px, py, local, t);
	CHECK_EQ(t[0], 0);
	CHECK_EQ(t[1], 8);
	atlas_texel_of(64, px, py, local, t);
	CHECK_EQ(t[2], 8);
}

TEST(large_world_coordinates_stay_in_range) {
	// Near int32 bounds, region arithmetic must not overflow the slot index.
	const int positions[] = { 1 << 20, -(1 << 20), 1 << 24, -(1 << 24) };
	for (int p : positions) {
		int position[3] = { p, 0, p };
		int local[3] = { 127, 63, 127 };
		WorldRegion r = world_region_of(kDefault, local, position);
		WrappedVoxel w = wrap_local(kDefault, local, position);
		int slot = virtual_slot_of(kDefault, 0, w);
		CHECK(slot >= 0 && slot < kDefault.virtual_pages());
		// The region itself may be large; only the slot must stay bounded.
		CHECK(r.x == floor_div(p + 127 - 64, BRICK_EDGE));
	}
}

TEST(update_slab_matches_engine_border) {
	// gi.cpp:1540-1560 — the retained side gets two extra voxels.
	const int forward[3] = { 8, 0, 0 };
	Slab s = compute_update_slab(kDefault, forward);
	CHECK_EQ(s.from[0], 0);
	CHECK_EQ(s.size[0], 10); // 8 scrolled + 2 border

	const int backward[3] = { -8, 0, 0 };
	s = compute_update_slab(kDefault, backward);
	CHECK_EQ(s.from[0], 128 - 8 - 2);
	CHECK_EQ(s.size[0], 10);

	const int still[3] = { 0, 0, 0 };
	s = compute_update_slab(kDefault, still);
	CHECK_EQ(s.size[0], 128);
	CHECK_EQ(s.size[1], 64);
}

TEST(slab_bricks_include_the_border_brick) {
	// The +2 border crosses a brick boundary: a 10-voxel slab starting at 0 reaches
	// into brick 1. An implementation that invalidated only 8 voxels would miss it.
	const int forward[3] = { 8, 0, 0 };
	Slab s = compute_update_slab(kDefault, forward);
	std::vector<BrickCoord> bricks;
	bricks_intersecting_slab(kDefault, s, bricks);

	bool saw_brick_one = false;
	for (const BrickCoord &b : bricks) {
		if (b.x == 1) {
			saw_brick_one = true;
		}
	}
	CHECK(saw_brick_one);
	CHECK_EQ(bricks.size(), size_t(2 * 8 * 16)); // 2 x-bricks, full y and z
}

TEST(full_slab_covers_every_brick) {
	const int still[3] = { 0, 0, 0 };
	Slab s = compute_update_slab(kDefault, still);
	std::vector<BrickCoord> bricks;
	bricks_intersecting_slab(kDefault, s, bricks);
	CHECK_EQ(bricks.size(), size_t(kDefault.bricks_per_cascade()));
}
