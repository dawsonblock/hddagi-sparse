// M2 scaffold tests: the CPU twin of the shaders, checked against the M1 oracle
// and the binary fixtures the probe shader will consume.

#include "../tests/renderer_hddagi_sparse/hddagi_brick_layout.h"
#include "../tests/renderer_hddagi_sparse/test_harness.h"
#include "hddagi_sparse_gpu_model.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <vector>

using namespace sb_gpu;

namespace {

constexpr uint32_t kGridX = 128;
constexpr uint32_t kGridY = 64;
constexpr uint32_t kGridZ = 128;
constexpr uint32_t kCascades = 2;
constexpr uint32_t kPageSlotsX = 8;
constexpr uint32_t kPageSlotsY = 8;
constexpr size_t kSlots = 2048 * 2;
constexpr size_t kRecordBytes = 80;

struct FixtureRecord {
	uint32_t cascade;
	int32_t position[3];
	int32_t local[3];
	uint32_t expected_slot;
	uint32_t expected_wrapped[3];
	int32_t expected_region[3];
	uint32_t expected_texel[3];
	uint32_t pad[3]; // keeps the record at the 80-byte stride the shader expects
};

std::vector<FixtureRecord> load_fixtures(const char *path) {
	std::vector<FixtureRecord> out;
	std::ifstream in(path, std::ios::binary);
	if (!in.good()) {
		return out;
	}
	std::vector<char> raw((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	const size_t count = raw.size() / kRecordBytes;
	for (size_t i = 0; i < count; i++) {
		const char *p = raw.data() + i * kRecordBytes;
		FixtureRecord r;
		std::memcpy(&r, p, kRecordBytes);
		out.push_back(r);
	}
	return out;
}

hddagi_sparse::GridLayout oracle_layout() {
	return hddagi_sparse::GridLayout::make(int(kGridX), int(kGridY), int(kGridZ), int(kCascades));
}

} // namespace

TEST(gpu_struct_sizes_match_the_shader_layout) {
	CHECK_EQ(sizeof(PageEntry), size_t(16));
	CHECK_EQ(sizeof(BrickMeta), size_t(32));
	CHECK_EQ(sizeof(Counters), size_t(32));
	CHECK_EQ(sizeof(FixtureRecord), kRecordBytes);
}

TEST(floor_div8_matches_the_oracle) {
	for (int v = -4096; v <= 4096; v++) {
		if (floor_div8(v) != hddagi_sparse::floor_div(v, 8)) {
			test::report_failure(__FILE__, __LINE__, "floor_div8 disagreed at " + std::to_string(v));
			return;
		}
	}
}

TEST(shader_translation_matches_oracle_fixtures) {
	const std::vector<FixtureRecord> fixtures = load_fixtures("fixtures/probe_fixtures.bin");
	REQUIRE(!fixtures.empty());

	const hddagi_sparse::GridLayout layout = oracle_layout();
	const IVec3 grid = { int(kGridX), int(kGridY), int(kGridZ) };
	const IVec3 brick_dims = { 16, 8, 16 };

	int mismatches = 0;
	for (const FixtureRecord &f : fixtures) {
		const IVec3 position = { f.position[0], f.position[1], f.position[2] };
		const IVec3 local = { f.local[0], f.local[1], f.local[2] };

		const IVec3 wrapped = wrap(local, position, grid);
		const IVec3 region = world_region(local, position, grid);
		const uint32_t slot = slot_of(wrapped, f.cascade, brick_dims);
		const IVec3 local_in_brick = { wrapped.x & 7, wrapped.y & 7, wrapped.z & 7 };
		const IVec3 texel = atlas_texel(slot, local_in_brick, int(kPageSlotsX), int(kPageSlotsY));

		bool ok = slot == f.expected_slot &&
				wrapped.x == int(f.expected_wrapped[0]) &&
				wrapped.y == int(f.expected_wrapped[1]) &&
				wrapped.z == int(f.expected_wrapped[2]) &&
				region.x == f.expected_region[0] &&
				region.y == f.expected_region[1] &&
				region.z == f.expected_region[2] &&
				texel.x == int(f.expected_texel[0]) &&
				texel.y == int(f.expected_texel[1]) &&
				texel.z == int(f.expected_texel[2]);

		// Cross-check against the independent M1 oracle as well, so a fixture that
		// was generated wrongly cannot make both sides agree by accident.
		int local_arr[3] = { local.x, local.y, local.z };
		int position_arr[3] = { position.x, position.y, position.z };
		const hddagi_sparse::WrappedVoxel ow = hddagi_sparse::wrap_local(layout, local_arr, position_arr);
		const hddagi_sparse::WorldRegion orr = hddagi_sparse::world_region_of(layout, local_arr, position_arr);
		const int oslot = hddagi_sparse::virtual_slot_of(layout, int(f.cascade), ow);
		ok = ok && ow.x == wrapped.x && ow.y == wrapped.y && ow.z == wrapped.z;
		ok = ok && orr.x == region.x && orr.y == region.y && orr.z == region.z;
		ok = ok && oslot == int(slot);

		if (!ok) {
			mismatches++;
		}
	}
	CHECK_EQ(mismatches, 0);
}

TEST(canary_atlas_is_unique_and_detectable) {
	const uint32_t pages = 64;
	const size_t texels = size_t(kPageSlotsX) * 8 * size_t(kPageSlotsY) * 8 * size_t(pages / (kPageSlotsX * kPageSlotsY));
	std::vector<uint32_t> atlas(texels, 0);

	canary_write(atlas, pages, int(kPageSlotsX), int(kPageSlotsY));
	CheckResult clean = canary_check(atlas, pages, int(kPageSlotsX), int(kPageSlotsY));
	CHECK_EQ(clean.mismatches, 0u);

	// Distinct (page, local) pairs must have produced distinct values.
	std::set<uint32_t> distinct;
	for (uint32_t page = 0; page < pages; page++) {
		for (uint32_t l = 0; l < 512; l++) {
			distinct.insert((page << 9) | l);
		}
	}
	CHECK_EQ(distinct.size(), size_t(pages) * 512);

	// One corrupted texel must be caught and located.
	atlas[1234] ^= 0xFFFFu;
	CheckResult bad = canary_check(atlas, pages, int(kPageSlotsX), int(kPageSlotsY));
	CHECK_EQ(bad.mismatches, 1u);
}

TEST(gpu_shaped_allocator_respects_capacity_and_uniqueness) {
	GpuModel model;
	model.reset(kSlots, 256);

	for (uint32_t i = 0; i < 300; i++) {
		model.set_request(1000 + i);
	}
	model.run_compact();
	CHECK_EQ(model.counters.compacted_count, 300u);

	model.run_allocate(1, 1);
	CHECK_EQ(model.counters.allocated, 256u);
	CHECK_EQ(model.counters.overflow, 44u);

	std::set<uint32_t> pages;
	for (const PageEntry &e : model.table) {
		if (e.state == STATE_ALLOCATED) {
			pages.insert(e.page_id);
		}
	}
	CHECK_EQ(pages.size(), size_t(256));

	model.run_initialize(1);
	CHECK_EQ(model.counters.committed, 256u);
}

TEST(gpu_shaped_allocator_generations_are_distinct) {
	GpuModel model;
	model.reset(kSlots, 64);
	for (uint32_t i = 0; i < 64; i++) {
		model.set_request(i * 7);
	}
	model.run_compact();
	model.run_allocate(1000, 1);
	model.run_initialize(1);

	std::set<uint32_t> gens;
	for (const PageEntry &e : model.table) {
		if (e.state == STATE_COMMITTED) {
			gens.insert(e.generation);
		}
	}
	CHECK_EQ(gens.size(), size_t(64));
}

TEST(compaction_order_is_stable_within_a_word) {
	GpuModel model;
	model.reset(kSlots, 64);
	model.set_request(3);
	model.set_request(1);
	model.set_request(31);
	model.run_compact();
	// LSB-first within the single word.
	REQUIRE(model.counters.compacted_count == 3u);
	CHECK_EQ(model.compacted[0], 1u);
	CHECK_EQ(model.compacted[1], 3u);
	CHECK_EQ(model.compacted[2], 31u);
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (std::strcmp(argv[i], "--fixtures") == 0 && i + 1 < argc) {
			test::options().fixtures_dir = argv[++i];
		}
	}
	return test::run_all();
}
