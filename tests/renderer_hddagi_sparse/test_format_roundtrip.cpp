// M1.07 — byte-level fixtures for the GPU test to consume later.
//
// Two outputs, both deterministic:
//   addressing_vectors.json  human-readable expectations
//   pages.bin                raw PageEntry / BrickMeta bytes, little-endian
//
// The packed-light value here is an identity canary, NOT the engine's E5B9G9R9 or
// rgbe packing. It exists to make a swapped page or wrong voxel obvious; format
// parity against the real packer is an M2/M3 concern.

#include "hddagi_brick_allocator.h"
#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace hddagi_sparse;

namespace {

void put_u32(std::vector<uint8_t> &out, uint32_t v) {
	out.push_back(uint8_t(v & 0xFF));
	out.push_back(uint8_t((v >> 8) & 0xFF));
	out.push_back(uint8_t((v >> 16) & 0xFF));
	out.push_back(uint8_t((v >> 24) & 0xFF));
}

// Deterministic identity canary: cascade, region and local voxel folded into 32 bits
// with distinct bit ranges so a transposition is visible rather than merely different.
uint32_t canary_light(int cascade, const WorldRegion &r, const int local[3]) {
	const uint32_t c = uint32_t(cascade) & 0x7u;
	const uint32_t rx = uint32_t(r.x) & 0x1FFu;
	const uint32_t ry = uint32_t(r.y) & 0xFFu;
	const uint32_t rz = uint32_t(r.z) & 0x1FFu;
	const uint32_t lx = uint32_t(local[0]) & 0x7u;
	const uint32_t ly = uint32_t(local[1]) & 0x7u;
	const uint32_t lz = uint32_t(local[2]) & 0x7u;
	return (c << 29) | ((rx & 0x7u) << 26) | ((ry & 0x7u) << 23) | ((rz & 0x7u) << 20) |
			(lx << 17) | (ly << 14) | (lz << 11) | (rz << 2) | (ry >> 6);
}

std::vector<int> sample_positions() {
	return { 0, 8, -8, 1024, -1024 };
}

std::vector<std::array<int, 3>> sample_locals(const GridLayout &l) {
	std::vector<std::array<int, 3>> out;
	// brick corners, the centre, and the far edge on every axis
	const int xs[] = { 0, 1, 7, 8, 63, 64, 127 };
	const int ys[] = { 0, 1, 7, 8, 31, 32, 63 };
	const int zs[] = { 0, 1, 7, 8, 63, 64, 127 };
	for (int y : ys) {
		for (int x : xs) {
			for (int z : zs) {
				if ((x + y + z) % 3 == 0) { // deterministic subset, keeps the file small
					out.push_back({ x, y, z });
				}
			}
		}
	}
	(void)l;
	return out;
}

} // namespace

TEST(struct_sizes_match_the_shader_layout) {
	CHECK_EQ(sizeof(PageEntry), size_t(16));
	CHECK_EQ(sizeof(BrickMeta), size_t(32));
}

TEST(serialized_bytes_are_stable) {
	BrickAllocator a(GridLayout::make(128, 64, 128, 1), 4);
	a.request(0, WorldRegion{ -3, 2, -1 }, 7);
	a.allocate_pending(7);
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		const PageEntry &e = a.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			a.begin_initialize(e.page_id);
			a.commit(e.page_id, 7);
		}
	}
	PageLookupResult r = a.lookup_key(0, WorldRegion{ -3, 2, -1 });
	REQUIRE(r.valid);

	const BrickMeta &m = a.meta(r.page_id);
	std::vector<uint8_t> bytes;
	put_u32(bytes, uint32_t(m.world_region[0]));
	put_u32(bytes, uint32_t(m.world_region[1]));
	put_u32(bytes, uint32_t(m.world_region[2]));
	put_u32(bytes, uint32_t(m.owner_cascade));
	put_u32(bytes, m.generation);
	put_u32(bytes, uint32_t(m.state));
	put_u32(bytes, m.last_write_epoch);
	put_u32(bytes, m.retired_epoch);
	CHECK_EQ(bytes.size(), size_t(32));

	// little-endian, first field is -3
	CHECK_EQ(int(bytes[0]), 0xFD);
	CHECK_EQ(int(bytes[1]), 0xFF);
	CHECK_EQ(int(bytes[2]), 0xFF);
	CHECK_EQ(int(bytes[3]), 0xFF);
}

TEST(export_fixtures_for_gpu_tests) {
	if (!test::options().write_fixtures) {
		return; // normal test runs do not touch the filesystem
	}

	const GridLayout layout = GridLayout::make(128, 64, 128, 2);
	BrickAllocator a(layout, 4096);

	std::string json;
	json += "{\n";
	json += "  \"version\": 1,\n";
	json += "  \"generator\": \"test_format_roundtrip.cpp\",\n";
	json += "  \"layout\": { \"size\": [128, 64, 128], \"bricks\": [16, 8, 16], \"cascades\": 2, \"brick_edge\": 8 },\n";
	json += "  \"note\": \"packed_light is an identity canary, not the engine packer\",\n";
	json += "  \"cases\": [\n";

	std::vector<uint8_t> blob;
	bool first = true;
	uint32_t epoch = 1;

	for (int position_x : sample_positions()) {
		int position[3] = { position_x, 0, 0 };
		for (int cascade = 0; cascade < layout.cascade_count; cascade++) {
			for (const auto &local_arr : sample_locals(layout)) {
				int local[3] = { local_arr[0], local_arr[1], local_arr[2] };
				const WrappedVoxel w = wrap_local(layout, local, position);
				const WorldRegion region = world_region_of(layout, local, position);
				const int slot = virtual_slot_of(layout, cascade, w);
				const int brick[3] = { w.x / BRICK_EDGE, w.y / BRICK_EDGE, w.z / BRICK_EDGE };
				const int local_in_brick[3] = { w.x & 7, w.y & 7, w.z & 7 };
				int texel[3];
				atlas_texel_of(uint32_t(slot), 8, 8, local_in_brick, texel);

				a.request(cascade, region, epoch);
				a.allocate_pending(epoch);
				for (int s = 0; s < a.virtual_slot_count(); s++) {
					const PageEntry &e = a.table_entry(s);
					if (e.state == Residency::ALLOCATED) {
						a.begin_initialize(e.page_id);
						a.commit(e.page_id, epoch);
					}
				}

				const uint32_t canary = canary_light(cascade, region, local_in_brick);
				if (!first) {
					json += ",\n";
				}
				first = false;
				char buf[512];
				std::snprintf(buf, sizeof(buf),
						"    { \"cascade\": %d, \"position\": [%d,0,0], \"local\": [%d,%d,%d], "
						"\"wrapped\": [%d,%d,%d], \"region\": [%d,%d,%d], \"virtual_slot\": %d, "
						"\"brick\": [%d,%d,%d], \"local_in_brick\": [%d,%d,%d], "
						"\"atlas_texel\": [%d,%d,%d], \"packed_light\": %u }",
						cascade, position_x, local[0], local[1], local[2],
						w.x, w.y, w.z, region.x, region.y, region.z, slot,
						brick[0], brick[1], brick[2], local_in_brick[0], local_in_brick[1], local_in_brick[2],
						texel[0], texel[1], texel[2], canary);
				json += buf;
			}
		}
	}

	json += "\n  ]\n}\n";

	const std::filesystem::path dir(test::options().fixtures_dir);
	std::filesystem::create_directories(dir);
	{
		std::ofstream out(dir / "addressing_vectors.json", std::ios::binary);
		REQUIRE(out.good());
		out.write(json.data(), std::streamsize(json.size()));
	}

	// Raw page table bytes for a small deterministic pool.
	BrickAllocator small(layout, 16);
	for (int i = 0; i < 8; i++) {
		small.request(0, WorldRegion{ i - 4, 0, 0 }, 1);
	}
	small.allocate_pending(1);
	for (int slot = 0; slot < small.virtual_slot_count(); slot++) {
		const PageEntry &e = small.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			small.begin_initialize(e.page_id);
			small.commit(e.page_id, 1);
		}
	}

	std::vector<uint8_t> table_bytes;
	for (uint32_t pid = 0; pid < 16; pid++) {
		put_u32(table_bytes, pid);
		put_u32(table_bytes, small.page_generation(pid));
		put_u32(table_bytes, uint32_t(small.page_state(pid)));
		put_u32(table_bytes, 0);
		const BrickMeta &m = small.meta(pid);
		put_u32(table_bytes, uint32_t(m.world_region[0]));
		put_u32(table_bytes, uint32_t(m.world_region[1]));
		put_u32(table_bytes, uint32_t(m.world_region[2]));
		put_u32(table_bytes, uint32_t(m.owner_cascade));
		put_u32(table_bytes, m.generation);
		put_u32(table_bytes, uint32_t(m.state));
		put_u32(table_bytes, m.last_write_epoch);
		put_u32(table_bytes, m.retired_epoch);
	}
	{
		std::ofstream out(dir / "pages.bin", std::ios::binary);
		REQUIRE(out.good());
		out.write(reinterpret_cast<const char *>(table_bytes.data()), std::streamsize(table_bytes.size()));
	}

	CHECK_EQ(table_bytes.size(), size_t(16 * 48));
	CHECK(!json.empty());
}
