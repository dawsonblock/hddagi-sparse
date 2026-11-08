#include "hddagi_brick_allocator.h"

#include <algorithm>
#include <cstdio>

namespace hddagi_sparse {

const char *residency_name(Residency r) {
	switch (r) {
		case Residency::UNMAPPED: return "UNMAPPED";
		case Residency::REQUESTED: return "REQUESTED";
		case Residency::ALLOCATED: return "ALLOCATED";
		case Residency::INITIALIZING: return "INITIALIZING";
		case Residency::COMMITTED: return "COMMITTED";
		case Residency::DIRTY: return "DIRTY";
		case Residency::RETIRED: return "RETIRED";
		case Residency::FREE: return "FREE";
		case Residency::OVERFLOWED: return "OVERFLOW";
	}
	return "?";
}

const char *lookup_reason_name(LookupReason r) {
	switch (r) {
		case LookupReason::OK: return "OK";
		case LookupReason::UNMAPPED: return "UNMAPPED";
		case LookupReason::REQUESTED: return "REQUESTED";
		case LookupReason::ALLOCATED_NOT_COMMITTED: return "ALLOCATED_NOT_COMMITTED";
		case LookupReason::POOL_FULL: return "POOL_FULL";
		case LookupReason::STALE_OWNER: return "STALE_OWNER";
		case LookupReason::STALE_GENERATION: return "STALE_GENERATION";
		case LookupReason::OUT_OF_RANGE: return "OUT_OF_RANGE";
	}
	return "?";
}

BrickAllocator::BrickAllocator(const GridLayout &p_layout, uint32_t p_capacity) :
		layout_(p_layout), capacity_(p_capacity) {
	table_.assign(size_t(layout_.virtual_pages()), PageEntry());
	pages_.assign(size_t(capacity_), PageEntry());
	meta_.assign(size_t(capacity_), BrickMeta());
	pending_.assign(size_t(layout_.virtual_pages()), PageKey());
	page_slot_.assign(size_t(capacity_), -1);
	free_list_.reserve(size_t(capacity_));
	// Deterministic order: page 0 first. The GPU port compacts in index order too.
	for (uint32_t i = capacity_; i > 0; i--) {
		free_list_.push_back(i - 1);
		pages_[i - 1].page_id = i - 1;
		pages_[i - 1].state = Residency::FREE;
	}
}

uint32_t BrickAllocator::next_generation() {
	return next_generation_++;
}

int BrickAllocator::slot_for_key(int cascade, const WorldRegion &region) const {
	// A world region always lands in the same wrapped slot, independent of scroll:
	// wrapped = (region * 8 + grid/2) & (grid - 1).
	WrappedVoxel w;
	const int64_t wx = int64_t(region.x) * BRICK_EDGE + layout_.size[0] / 2;
	const int64_t wy = int64_t(region.y) * BRICK_EDGE + layout_.size[1] / 2;
	const int64_t wz = int64_t(region.z) * BRICK_EDGE + layout_.size[2] / 2;
	w.x = int(wx) & (layout_.size[0] - 1);
	w.y = int(wy) & (layout_.size[1] - 1);
	w.z = int(wz) & (layout_.size[2] - 1);
	return virtual_slot_of(layout_, cascade, w);
}

void BrickAllocator::retire_slot(int slot, uint32_t epoch) {
	PageEntry &e = table_[size_t(slot)];
	if (e.page_id == INVALID_PAGE) {
		e.state = Residency::UNMAPPED;
		return;
	}
	const uint32_t pid = e.page_id;
	pages_[pid].state = Residency::RETIRED;
	meta_[pid].state = Residency::RETIRED;
	meta_[pid].retired_epoch = epoch;
	page_slot_[pid] = -1;
	e.page_id = INVALID_PAGE;
	e.generation = 0;
	e.state = Residency::UNMAPPED;
	counters_.retires++;
}

void BrickAllocator::request(int cascade, const WorldRegion &region, uint32_t epoch) {
	if (cascade < 0 || cascade >= layout_.cascade_count) {
		return;
	}
	const int slot = slot_for_key(cascade, region);
	PageEntry &e = table_[size_t(slot)];
	counters_.requests++;

	if (e.state == Residency::COMMITTED) {
		const BrickMeta &m = meta_[e.page_id];
		if (m.owner_cascade == cascade && m.world_region[0] == region.x &&
				m.world_region[1] == region.y && m.world_region[2] == region.z) {
			return; // already resident and still correct
		}
		retire_slot(slot, epoch);
	} else if (e.state == Residency::ALLOCATED || e.state == Residency::INITIALIZING) {
		return; // in flight this epoch
	}
	// OVERFLOWED falls through: the request is re-issued each frame, so a slot that
	// could not be satisfied recovers on its own once capacity frees up. It never
	// silently aliases another page.

	e.state = Residency::REQUESTED;
	pending_[slot] = { cascade, region };
}

int BrickAllocator::allocate_pending(uint32_t epoch) {
	if (needs_full_invalidation_) {
		return -1;
	}
	int allocated = 0;
	for (size_t slot = 0; slot < table_.size(); slot++) {
		if (table_[slot].state != Residency::REQUESTED) {
			continue;
		}
		if (free_list_.empty()) {
			table_[slot].state = Residency::OVERFLOWED;
			counters_.overflow_events++;
			continue;
		}
		if (next_generation_ == 0) {
			// 32-bit rollover. Rather than let a generation value recur while old
			// pages are still live, refuse to hand out new generations until a full
			// invalidation has retired every page. That makes the stale-address
			// invariant provable instead of probabilistic.
			generation_cycle_++;
			needs_full_invalidation_ = true;
			next_generation_ = 1;
			break;
		}
		const uint32_t pid = free_list_.back();
		free_list_.pop_back();

		const PageKey &key = pending_[slot];
		const uint32_t gen = next_generation();

		pages_[pid].page_id = pid;
		pages_[pid].generation = gen;
		pages_[pid].state = Residency::ALLOCATED;

		meta_[pid].world_region[0] = key.region.x;
		meta_[pid].world_region[1] = key.region.y;
		meta_[pid].world_region[2] = key.region.z;
		meta_[pid].owner_cascade = key.cascade;
		meta_[pid].generation = gen;
		meta_[pid].state = Residency::ALLOCATED;
		meta_[pid].last_write_epoch = epoch;
		meta_[pid].retired_epoch = 0;

		page_slot_[pid] = int(slot);

		table_[slot].page_id = pid;
		table_[slot].generation = gen;
		table_[slot].state = Residency::ALLOCATED;

		counters_.allocations++;
		counters_.capacity_high_water =
				std::max<uint64_t>(counters_.capacity_high_water, uint64_t(capacity_ - free_list_.size()));
		allocated++;
	}
	return allocated;
}

void BrickAllocator::begin_initialize(uint32_t page_id) {
	if (page_id >= capacity_) {
		return;
	}
	if (pages_[page_id].state == Residency::ALLOCATED) {
		pages_[page_id].state = Residency::INITIALIZING;
		meta_[page_id].state = Residency::INITIALIZING;
		const int slot = page_slot_[page_id];
		if (slot >= 0) {
			table_[size_t(slot)].state = Residency::INITIALIZING;
		}
	}
}

void BrickAllocator::commit(uint32_t page_id, uint32_t epoch) {
	if (page_id >= capacity_) {
		return;
	}
	// COMMITTED is only reachable through INITIALIZING, so a page can never be
	// sampled before its zeroing pass has been modelled.
	if (pages_[page_id].state != Residency::INITIALIZING) {
		return;
	}
	const int slot = page_slot_[page_id];
	if (slot < 0) {
		return;
	}
	pages_[page_id].state = Residency::COMMITTED;
	meta_[page_id].state = Residency::COMMITTED;
	meta_[page_id].last_write_epoch = epoch;
	table_[size_t(slot)].state = Residency::COMMITTED;
	counters_.commits++;
}

PageLookupResult BrickAllocator::lookup(const int position[3], int cascade, const WrappedVoxel &w) const {
	PageLookupResult r;
	if (cascade < 0 || cascade >= layout_.cascade_count) {
		r.reason = LookupReason::OUT_OF_RANGE;
		return r;
	}
	const int slot = virtual_slot_of(layout_, cascade, w);
	const PageEntry &e = table_[size_t(slot)];
	r.state = e.state;

	switch (e.state) {
		case Residency::COMMITTED:
		case Residency::DIRTY:
			break;
		case Residency::UNMAPPED: r.reason = LookupReason::UNMAPPED; return r;
		case Residency::REQUESTED: r.reason = LookupReason::REQUESTED; return r;
		case Residency::ALLOCATED:
		case Residency::INITIALIZING: r.reason = LookupReason::ALLOCATED_NOT_COMMITTED; return r;
		case Residency::OVERFLOWED: r.reason = LookupReason::POOL_FULL; return r;
		default: r.reason = LookupReason::UNMAPPED; return r;
	}

	const uint32_t pid = e.page_id;
	if (pid >= capacity_) {
		r.reason = LookupReason::STALE_OWNER;
		return r;
	}
	const BrickMeta &m = meta_[pid];
	if (m.owner_cascade != cascade) {
		r.reason = LookupReason::STALE_OWNER;
		return r;
	}

	int local[3];
	unwrap_to_local(layout_, w, position, local);
	const WorldRegion expected = world_region_of(layout_, local, position);
	if (m.world_region[0] != expected.x || m.world_region[1] != expected.y || m.world_region[2] != expected.z) {
		r.reason = LookupReason::STALE_OWNER;
		return r;
	}
	if (m.generation != e.generation) {
		r.reason = LookupReason::STALE_GENERATION;
		return r;
	}

	r.valid = true;
	r.reason = LookupReason::OK;
	r.page_id = pid;
	r.generation = e.generation;
	r.local[0] = local[0] & (BRICK_EDGE - 1);
	r.local[1] = local[1] & (BRICK_EDGE - 1);
	r.local[2] = local[2] & (BRICK_EDGE - 1);
	return r;
}

PageLookupResult BrickAllocator::lookup_key(int cascade, const WorldRegion &region) const {
	PageLookupResult r;
	if (cascade < 0 || cascade >= layout_.cascade_count) {
		r.reason = LookupReason::OUT_OF_RANGE;
		return r;
	}
	const int slot = slot_for_key(cascade, region);
	const PageEntry &e = table_[size_t(slot)];
	r.state = e.state;
	switch (e.state) {
		case Residency::COMMITTED:
		case Residency::DIRTY:
			break;
		case Residency::REQUESTED: r.reason = LookupReason::REQUESTED; return r;
		case Residency::ALLOCATED:
		case Residency::INITIALIZING: r.reason = LookupReason::ALLOCATED_NOT_COMMITTED; return r;
		case Residency::OVERFLOWED: r.reason = LookupReason::POOL_FULL; return r;
		default: r.reason = LookupReason::UNMAPPED; return r;
	}
	const BrickMeta &m = meta_[e.page_id];
	if (m.owner_cascade != cascade || m.world_region[0] != region.x ||
			m.world_region[1] != region.y || m.world_region[2] != region.z) {
		r.reason = LookupReason::STALE_OWNER;
		return r;
	}
	if (m.generation != e.generation) {
		r.reason = LookupReason::STALE_GENERATION;
		return r;
	}
	r.valid = true;
	r.reason = LookupReason::OK;
	r.page_id = e.page_id;
	r.generation = e.generation;
	return r;
}

void BrickAllocator::retire(uint32_t page_id, uint32_t epoch) {
	if (page_id >= capacity_) {
		return;
	}
	const Residency s = pages_[page_id].state;
	if (s != Residency::COMMITTED && s != Residency::DIRTY && s != Residency::ALLOCATED &&
			s != Residency::INITIALIZING) {
		return;
	}
	const int slot = page_slot_[page_id];
	if (slot >= 0) {
		retire_slot(slot, epoch);
	}
}

int BrickAllocator::release_retired(uint32_t epoch) {
	int released = 0;
	for (uint32_t pid = 0; pid < capacity_; pid++) {
		if (pages_[pid].state != Residency::RETIRED) {
			continue;
		}
		if (meta_[pid].retired_epoch >= epoch) {
			continue; // a reader from that epoch may still be using the page
		}
		pages_[pid].state = Residency::FREE;
		pages_[pid].generation = 0;
		meta_[pid] = BrickMeta();
		free_list_.push_back(pid);
		counters_.releases++;
		released++;
	}
	return released;
}

int BrickAllocator::retire_mismatched(const int position[3], uint32_t epoch) {
	int retired = 0;
	for (size_t slot = 0; slot < table_.size(); slot++) {
		if (table_[slot].state != Residency::COMMITTED && table_[slot].state != Residency::DIRTY) {
			continue;
		}
		const BrickMeta &m = meta_[table_[slot].page_id];
		// Reconstruct the slot's wrapped brick index, then invert the wrap to get the
		// local voxel that currently occupies it.
		const int bpc = layout_.bricks_per_cascade();
		const int cascade = int(slot) / bpc;
		const int index = int(slot) % bpc;
		const int bx = layout_.bricks_per_axis(0);
		const int by = layout_.bricks_per_axis(1);
		const int b[3] = { index % bx, (index / bx) % by, index / (bx * by) };
		int local[3];
		local_from_wrapped_brick(layout_, b, position, local);
		const WorldRegion expected = world_region_of(layout_, local, position);
		if (m.owner_cascade != cascade || m.world_region[0] != expected.x ||
				m.world_region[1] != expected.y || m.world_region[2] != expected.z) {
			retire_slot(int(slot), epoch);
			retired++;
		}
	}
	return retired;
}

int BrickAllocator::invalidate_all(uint32_t epoch) {
	int n = 0;
	for (size_t slot = 0; slot < table_.size(); slot++) {
		if (table_[slot].page_id != INVALID_PAGE) {
			retire_slot(int(slot), epoch);
			n++;
		}
	}
	return n;
}

uint32_t BrickAllocator::allocated_count() const {
	uint32_t n = 0;
	for (const PageEntry &p : pages_) {
		if (p.state == Residency::ALLOCATED || p.state == Residency::INITIALIZING ||
				p.state == Residency::COMMITTED || p.state == Residency::DIRTY) {
			n++;
		}
	}
	return n;
}

uint32_t BrickAllocator::committed_count() const {
	uint32_t n = 0;
	for (const PageEntry &p : pages_) {
		if (p.state == Residency::COMMITTED || p.state == Residency::DIRTY) {
			n++;
		}
	}
	return n;
}

uint32_t BrickAllocator::retired_pending_count() const {
	uint32_t n = 0;
	for (const PageEntry &p : pages_) {
		if (p.state == Residency::RETIRED) {
			n++;
		}
	}
	return n;
}

std::string BrickAllocator::check_invariants() const {
	char buf[256];

	// 1. Capacity is never exceeded, and every physical page is in exactly one bucket.
	uint32_t free_n = 0, retired_n = 0, live_n = 0, other_n = 0;
	for (uint32_t i = 0; i < capacity_; i++) {
		switch (pages_[i].state) {
			case Residency::FREE: free_n++; break;
			case Residency::RETIRED: retired_n++; break;
			case Residency::ALLOCATED:
			case Residency::INITIALIZING:
			case Residency::COMMITTED:
			case Residency::DIRTY: live_n++; break;
			default: other_n++; break;
		}
	}
	if (free_n + retired_n + live_n + other_n != capacity_) {
		std::snprintf(buf, sizeof(buf), "page accounting %u+%u+%u+%u != capacity %u",
				free_n, retired_n, live_n, other_n, capacity_);
		return buf;
	}
	if (free_n != free_list_.size()) {
		std::snprintf(buf, sizeof(buf), "free list %zu != FREE pages %u", free_list_.size(), free_n);
		return buf;
	}

	// 2. No physical page is referenced by more than one committed virtual slot.
	std::vector<int> owner(capacity_, -1);
	for (size_t slot = 0; slot < table_.size(); slot++) {
		const PageEntry &e = table_[slot];
		if (e.page_id == INVALID_PAGE) {
			continue;
		}
		if (e.page_id >= capacity_) {
			std::snprintf(buf, sizeof(buf), "slot %zu points outside capacity", slot);
			return buf;
		}
		if (owner[e.page_id] != -1) {
			std::snprintf(buf, sizeof(buf), "page %u owned by slots %d and %zu", e.page_id, owner[e.page_id], slot);
			return buf;
		}
		owner[e.page_id] = int(slot);

		// 3. A page matches its slot's owner and generation exactly, in every state
		// that holds a page, not only COMMITTED.
		const BrickMeta &m = meta_[e.page_id];
		if (m.generation != e.generation || m.state != e.state) {
			std::snprintf(buf, sizeof(buf), "slot %zu generation/state mismatch", slot);
			return buf;
		}
		if (pages_[e.page_id].state != e.state) {
			std::snprintf(buf, sizeof(buf), "slot %zu and page %u disagree on state", slot, e.page_id);
			return buf;
		}
		if (pages_[e.page_id].generation != e.generation) {
			std::snprintf(buf, sizeof(buf), "slot %zu and page %u disagree on generation", slot, e.page_id);
			return buf;
		}
		const int bpc = layout_.bricks_per_cascade();
		if (m.owner_cascade != int(slot) / bpc) {
			std::snprintf(buf, sizeof(buf), "slot %zu owner cascade mismatch", slot);
			return buf;
		}
	}

	// 4. A page in a live state must be reachable from exactly one slot.
	for (uint32_t pid = 0; pid < capacity_; pid++) {
		const Residency s = pages_[pid].state;
		if (s == Residency::COMMITTED || s == Residency::DIRTY || s == Residency::ALLOCATED ||
				s == Residency::INITIALIZING) {
			if (owner[pid] == -1) {
				std::snprintf(buf, sizeof(buf), "live page %u is unreachable", pid);
				return buf;
			}
		}
	}

	// 5. The free list contains no duplicates and no page that is not FREE.
	std::vector<uint8_t> seen(capacity_, 0);
	for (uint32_t pid : free_list_) {
		if (pid >= capacity_) {
			return "free list contains an out-of-range page";
		}
		if (seen[pid]) {
			std::snprintf(buf, sizeof(buf), "free list contains duplicate page %u", pid);
			return buf;
		}
		seen[pid] = 1;
		if (pages_[pid].state != Residency::FREE) {
			std::snprintf(buf, sizeof(buf), "free list contains page %u in state %s", pid, residency_name(pages_[pid].state));
			return buf;
		}
	}

	// 6. Nothing is sampled before initialisation.
	for (size_t slot = 0; slot < table_.size(); slot++) {
		const PageEntry &e = table_[slot];
		if ((e.state == Residency::COMMITTED || e.state == Residency::DIRTY) &&
				(meta_[e.page_id].last_write_epoch == 0 && counters_.commits > 0)) {
			// epoch 0 is only legal before the first commit ever happened
			return "committed page has no write epoch";
		}
	}

	return {};
}

} // namespace hddagi_sparse
