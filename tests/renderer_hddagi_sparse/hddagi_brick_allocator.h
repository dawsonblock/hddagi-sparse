// CPU reference page table and allocator (RFC M1.03, M1.04, M1.05).
//
// Models the state machine from RFC section 6 and the ownership rule from section 5:
// a physical page is only valid for the exact (cascade, world region, generation)
// triple it was allocated for. Wrapped coordinates alone are never sufficient,
// because the same wrapped voxel names a different world region after a scroll.

#pragma once

#include "hddagi_brick_layout.h"

#include <cstdint>
#include <string>
#include <vector>

namespace hddagi_sparse {

constexpr uint32_t INVALID_PAGE = 0xFFFFFFFFu;

enum class Residency : uint32_t {
	UNMAPPED = 0,
	REQUESTED,
	ALLOCATED,
	INITIALIZING,
	COMMITTED,
	DIRTY,
	RETIRED,
	FREE,
	OVERFLOWED,
};

const char *residency_name(Residency r);

struct PageEntry {
	uint32_t page_id = INVALID_PAGE;
	uint32_t generation = 0;
	Residency state = Residency::UNMAPPED;
	uint32_t reserved = 0;
};

struct BrickMeta {
	int32_t world_region[3] = { 0, 0, 0 };
	int32_t owner_cascade = -1;
	uint32_t generation = 0;
	Residency state = Residency::UNMAPPED;
	uint32_t last_write_epoch = 0;
	uint32_t retired_epoch = 0;
};

enum class LookupReason : uint32_t {
	OK = 0,
	UNMAPPED,
	REQUESTED,
	ALLOCATED_NOT_COMMITTED,
	POOL_FULL,
	STALE_OWNER,
	STALE_GENERATION,
	OUT_OF_RANGE,
};

const char *lookup_reason_name(LookupReason r);

struct PageLookupResult {
	bool valid = false;
	LookupReason reason = LookupReason::UNMAPPED;
	uint32_t page_id = INVALID_PAGE;
	uint32_t generation = 0;
	Residency state = Residency::UNMAPPED;
	int local[3] = { 0, 0, 0 };
};

struct AllocatorCounters {
	uint64_t requests = 0;
	uint64_t allocations = 0;
	uint64_t commits = 0;
	uint64_t retires = 0;
	uint64_t releases = 0;
	uint64_t overflow_events = 0;
	uint64_t invalid_lookups = 0;
	uint64_t stale_owner_rejects = 0;
	uint64_t stale_generation_rejects = 0;
	uint64_t capacity_high_water = 0;
};

class BrickAllocator {
public:
	BrickAllocator(const GridLayout &p_layout, uint32_t p_capacity);

	// --- virtual side -------------------------------------------------------
	// Mark a world region as needed. Idempotent for an already-committed page that
	// still owns this key; a mismatched committed page is retired first.
	void request(int cascade, const WorldRegion &region, uint32_t epoch);

	// --- allocation ---------------------------------------------------------
	// Allocate every REQUESTED slot. Returns the number allocated. When the free
	// list is empty the slot is marked OVERFLOW and the counter rises; it is never
	// silently dropped and never aliases another page.
	int allocate_pending(uint32_t epoch);

	// ALLOCATED -> INITIALIZING -> COMMITTED. Zeroing happens between the two calls
	// in the GPU port; the oracle only requires that COMMITTED is never reached
	// without an explicit initialise step.
	void begin_initialize(uint32_t page_id);
	void commit(uint32_t page_id, uint32_t epoch);

	// --- lookup -------------------------------------------------------------
	// The shader-side path: only a wrapped coordinate is available, so the expected
	// world region is derived from the current cascade position.
	PageLookupResult lookup(const int position[3], int cascade, const WrappedVoxel &w) const;

	// Validation path used by tests: look up by the key the caller believes is there.
	PageLookupResult lookup_key(int cascade, const WorldRegion &region) const;

	// --- lifetime -----------------------------------------------------------
	void retire(uint32_t page_id, uint32_t epoch);
	// Returns pages whose retirement is older than the given epoch to the free list.
	// Nothing is reused while `epoch <= retired_epoch`.
	int release_retired(uint32_t epoch);

	// After a scroll, retire every committed page whose stored key no longer matches
	// the world region its virtual slot now names. Returns the number retired.
	int retire_mismatched(const int position[3], uint32_t epoch);

	// Teleport / DIRTY_ALL: retire everything. Returns the number retired.
	int invalidate_all(uint32_t epoch);

	// --- introspection ------------------------------------------------------
	const GridLayout &layout() const { return layout_; }
	uint32_t capacity() const { return capacity_; }
	uint32_t free_count() const { return uint32_t(free_list_.size()); }
	uint32_t allocated_count() const;
	uint32_t committed_count() const;
	uint32_t retired_pending_count() const;
	const PageEntry &table_entry(int virtual_slot) const { return table_[size_t(virtual_slot)]; }
	const BrickMeta &meta(uint32_t page_id) const { return meta_[page_id]; }
	Residency page_state(uint32_t page_id) const { return pages_[page_id].state; }
	uint32_t page_generation(uint32_t page_id) const { return pages_[page_id].generation; }
	uint32_t generation_cycle() const { return generation_cycle_; }
	bool needs_full_invalidation() const { return needs_full_invalidation_; }
	void clear_full_invalidation() { needs_full_invalidation_ = false; }
	const AllocatorCounters &counters() const { return counters_; }

	int virtual_slot_count() const { return layout_.virtual_pages(); }

	// Structural invariants. Returns an empty string when everything holds,
	// otherwise a human-readable description of the first violation.
	std::string check_invariants() const;

	// Force the generation counter to a value, for rollover tests only.
	void debug_set_next_generation(uint32_t v) { next_generation_ = v; }

	// Corruption hooks. They exist only so the negative tests can prove that
	// check_invariants() and lookup() actually reject bad state. Never call them
	// outside a test that asserts failure.
	// Lookup compares the generation the shader holds (the table entry) against the
	// generation recorded in the page metadata, so that is the pair to corrupt.
	void debug_corrupt_table_generation(int slot, uint32_t generation) {
		if (slot >= 0 && slot < int(table_.size())) {
			table_[size_t(slot)].generation = generation;
		}
	}
	void debug_alias_slot(int slot, uint32_t page_id) {
		if (slot >= 0 && slot < int(table_.size())) {
			table_[size_t(slot)].page_id = page_id;
			table_[size_t(slot)].state = Residency::COMMITTED;
		}
	}

private:
	uint32_t next_generation();
	int slot_for_key(int cascade, const WorldRegion &region) const;
	void retire_slot(int slot, uint32_t epoch);

	GridLayout layout_;
	uint32_t capacity_;
	std::vector<PageEntry> table_;
	std::vector<PageEntry> pages_;
	std::vector<BrickMeta> meta_;
	std::vector<PageKey> pending_;
	std::vector<int32_t> page_slot_;
	std::vector<uint32_t> free_list_;
	uint32_t next_generation_ = 1;
	uint32_t generation_cycle_ = 0;
	bool needs_full_invalidation_ = false;
	AllocatorCounters counters_;
};

} // namespace hddagi_sparse
