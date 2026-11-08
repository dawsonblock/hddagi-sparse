// CPU twin of the M2 micro-test shaders.
//
// This is a transcription of the GLSL in gpu/shaders/, operating on the same byte
// layouts. It exists because the shaders cannot be executed on this host: if the
// transcription and the M1 oracle agree, the algorithm and the layout contract are
// validated, and only the GPU binding/execution remains unverified.
//
// It is NOT a second independent design. It is a mirror, and the report says so.

#pragma once

#include <cstdint>
#include <vector>

#if defined(_MSC_VER)
#include <intrin.h>
#endif

namespace sb_gpu {

constexpr uint32_t INVALID_PAGE = 0xFFFFFFFFu;

enum : uint32_t {
	STATE_UNMAPPED = 0,
	STATE_REQUESTED = 1,
	STATE_ALLOCATED = 2,
	STATE_INITIALIZING = 3,
	STATE_COMMITTED = 4,
	STATE_RETIRED = 6,
	STATE_FREE = 7,
	STATE_OVERFLOWED = 8,
};

struct PageEntry {
	uint32_t page_id;
	uint32_t generation;
	uint32_t state;
	uint32_t reserved;
};

struct BrickMeta {
	int32_t region_x;
	int32_t region_y;
	int32_t region_z;
	int32_t owner_cascade;
	uint32_t generation;
	uint32_t state;
	uint32_t last_write_epoch;
	uint32_t retired_epoch;
};

struct Counters {
	uint32_t requested;
	uint32_t compacted_count;
	uint32_t allocated;
	uint32_t overflow;
	uint32_t committed;
	uint32_t pad0;
	uint32_t pad1;
	uint32_t pad2;
};

struct CheckResult {
	uint32_t mismatches;
	uint32_t first_bad_page;
	uint32_t first_bad_local;
	uint32_t pad;
};

static_assert(sizeof(PageEntry) == 16, "PageEntry must stay 16 bytes");
static_assert(sizeof(BrickMeta) == 32, "BrickMeta must stay 32 bytes");
static_assert(sizeof(Counters) == 32, "Counters must stay 32 bytes");
static_assert(sizeof(CheckResult) == 16, "CheckResult must stay 16 bytes");

struct IVec3 {
	int x = 0;
	int y = 0;
	int z = 0;
};

inline int ctz32(uint32_t v) {
#if defined(_MSC_VER)
	unsigned long index = 0;
	_BitScanForward(&index, v);
	return int(index);
#else
	return __builtin_ctz(v);
#endif
}

// Mirrors sb_floor_div8 in the shader, which deliberately differs from C++
// truncating division for negative inputs.
inline int floor_div8(int v) {
	return (v >= 0) ? (v >> 3) : -(((-v) + 7) >> 3);
}

inline IVec3 wrap(IVec3 local, IVec3 position, IVec3 grid) {
	return { (local.x + position.x) & (grid.x - 1),
		(local.y + position.y) & (grid.y - 1),
		(local.z + position.z) & (grid.z - 1) };
}

inline IVec3 world_region(IVec3 local, IVec3 position, IVec3 grid) {
	IVec3 world = { position.x + local.x - grid.x / 2,
		position.y + local.y - grid.y / 2,
		position.z + local.z - grid.z / 2 };
	return { floor_div8(world.x), floor_div8(world.y), floor_div8(world.z) };
}

inline uint32_t slot_of(IVec3 wrapped, uint32_t cascade, IVec3 brick_dims) {
	IVec3 b = { wrapped.x >> 3, wrapped.y >> 3, wrapped.z >> 3 };
	return cascade * uint32_t(brick_dims.x * brick_dims.y * brick_dims.z) +
			uint32_t(b.x) + uint32_t(b.y) * uint32_t(brick_dims.x) +
			uint32_t(b.z) * uint32_t(brick_dims.x) * uint32_t(brick_dims.y);
}

inline IVec3 atlas_texel(uint32_t page_id, IVec3 local_in_brick, int page_slots_x, int page_slots_y) {
	const uint32_t px = uint32_t(page_slots_x);
	const uint32_t py = uint32_t(page_slots_y);
	const uint32_t bx = page_id % px;
	const uint32_t by = (page_id / px) % py;
	const uint32_t bz = page_id / (px * py);
	return { int(bx) * 8 + local_in_brick.x, int(by) * 8 + local_in_brick.y, int(bz) * 8 + local_in_brick.z };
}

inline uint32_t canary(uint32_t cascade, IVec3 region, IVec3 local_in_brick, uint32_t generation) {
	return ((cascade & 7u) << 29) | ((uint32_t(region.x) & 7u) << 26) | ((uint32_t(region.y) & 7u) << 23) |
			((uint32_t(region.z) & 7u) << 20) | ((uint32_t(local_in_brick.x) & 7u) << 17) |
			((uint32_t(local_in_brick.y) & 7u) << 14) | ((uint32_t(local_in_brick.z) & 7u) << 11) |
			(generation & 0x7FFu);
}

// One simulated dispatch's worth of state.
struct GpuModel {
	std::vector<PageEntry> table;
	std::vector<BrickMeta> meta;
	std::vector<uint32_t> free_list;
	uint32_t free_cursor = 0;
	std::vector<uint32_t> request_words;
	std::vector<uint32_t> compacted;
	std::vector<uint32_t> allocated_slots;
	Counters counters{};

	void reset(size_t slot_count, size_t capacity) {
		table.assign(slot_count, PageEntry{ INVALID_PAGE, 0, STATE_UNMAPPED, 0 });
		meta.assign(capacity, BrickMeta{});
		free_list.resize(capacity);
		for (size_t i = 0; i < capacity; i++) {
			free_list[i] = uint32_t(i);
			meta[i].state = STATE_FREE;
		}
		free_cursor = 0;
		request_words.assign((slot_count + 31) / 32, 0);
		compacted.assign(slot_count, 0);
		allocated_slots.assign(capacity, 0);
		counters = Counters{};
	}

	void set_request(uint32_t slot) {
		request_words[slot / 32] |= (1u << (slot % 32));
		counters.requested++;
	}

	// Mirrors compact_requests: one pass over words, LSB first, atomic destination.
	void run_compact() {
		for (size_t w = 0; w < request_words.size(); w++) {
			uint32_t word = request_words[w];
			const uint32_t base = uint32_t(w) * 32u;
			while (word != 0u) {
				const int bit = ctz32(word);
				const uint32_t slot = base + uint32_t(bit);
				if (slot < table.size()) {
					compacted[counters.compacted_count++] = slot;
				}
				word &= word - 1u;
			}
		}
	}

	// Mirrors allocate_one.
	void run_allocate(uint32_t generation_base, uint32_t epoch, uint32_t cascade = 0) {
		for (uint32_t i = 0; i < counters.compacted_count; i++) {
			const uint32_t slot = compacted[i];
			const uint32_t cursor = free_cursor++;
			if (cursor >= free_list.size()) {
				counters.overflow++;
				table[slot].state = STATE_OVERFLOWED;
				continue;
			}
			const uint32_t page = free_list[cursor];
			const uint32_t generation = generation_base + i;

			table[slot].page_id = page;
			table[slot].generation = generation;
			table[slot].state = STATE_ALLOCATED;

			meta[page].generation = generation;
			meta[page].state = STATE_ALLOCATED;
			meta[page].last_write_epoch = epoch;
			meta[page].retired_epoch = 0;
			meta[page].owner_cascade = int32_t(cascade);

			allocated_slots[cursor] = slot;
			counters.allocated++;
		}
	}

	// Mirrors initialize_one, which runs after the host zeroes the page.
	void run_initialize(uint32_t epoch) {
		for (uint32_t cursor = 0; cursor < counters.allocated; cursor++) {
			const uint32_t slot = allocated_slots[cursor];
			const uint32_t page = table[slot].page_id;
			if (page == INVALID_PAGE || page >= meta.size()) {
				continue;
			}
			table[slot].state = STATE_COMMITTED;
			meta[page].state = STATE_COMMITTED;
			meta[page].last_write_epoch = epoch;
			counters.committed++;
		}
	}
};

// Mirrors canary_write.comp over a flat atlas buffer of uint texels.
inline void canary_write(std::vector<uint32_t> &atlas, uint32_t page_count, int page_slots_x, int page_slots_y) {
	for (uint32_t page = 0; page < page_count; page++) {
		for (uint32_t local_index = 0; local_index < 512u; local_index++) {
			IVec3 local = { int(local_index & 7u), int((local_index >> 3) & 7u), int((local_index >> 6) & 7u) };
			IVec3 t = atlas_texel(page, local, page_slots_x, page_slots_y);
			const size_t offset = size_t(t.x) + size_t(t.y) * size_t(page_slots_x * 8) +
					size_t(t.z) * size_t(page_slots_x * 8) * size_t(page_slots_y * 8);
			atlas[offset] = (page << 9) | local_index;
		}
	}
}

// Mirrors canary_check.comp.
inline CheckResult canary_check(const std::vector<uint32_t> &atlas, uint32_t page_count, int page_slots_x, int page_slots_y) {
	CheckResult r{};
	for (uint32_t page = 0; page < page_count; page++) {
		for (uint32_t local_index = 0; local_index < 512u; local_index++) {
			IVec3 local = { int(local_index & 7u), int((local_index >> 3) & 7u), int((local_index >> 6) & 7u) };
			IVec3 t = atlas_texel(page, local, page_slots_x, page_slots_y);
			const size_t offset = size_t(t.x) + size_t(t.y) * size_t(page_slots_x * 8) +
					size_t(t.z) * size_t(page_slots_x * 8) * size_t(page_slots_y * 8);
			const uint32_t expected = (page << 9) | local_index;
			if (atlas[offset] != expected) {
				if (r.mismatches == 0) {
					r.first_bad_page = page;
					r.first_bad_local = local_index;
				}
				r.mismatches++;
			}
		}
	}
	return r;
}

} // namespace sb_gpu
