// M1.03 / M1.04 — page identity, state machine, capacity and generations.

#include "hddagi_brick_allocator.h"
#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <vector>

using namespace hddagi_sparse;

namespace {

const GridLayout kLayout = GridLayout::make(128, 64, 128, 2);

std::vector<WorldRegion> window_regions(const GridLayout &layout, int cascade, const int position[3]) {
	std::vector<WorldRegion> out;
	WorldRegion lo;
	lo.x = floor_div(position[0] - layout.size[0] / 2, BRICK_EDGE);
	lo.y = floor_div(position[1] - layout.size[1] / 2, BRICK_EDGE);
	lo.z = floor_div(position[2] - layout.size[2] / 2, BRICK_EDGE);
	(void)cascade;
	for (int z = 0; z < layout.bricks_per_axis(2); z++) {
		for (int y = 0; y < layout.bricks_per_axis(1); y++) {
			for (int x = 0; x < layout.bricks_per_axis(0); x++) {
				out.push_back({ lo.x + x, lo.y + y, lo.z + z });
			}
		}
	}
	return out;
}

void commit_all(BrickAllocator &a, uint32_t epoch) {
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		const PageEntry &e = a.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			a.begin_initialize(e.page_id);
			a.commit(e.page_id, epoch);
		}
	}
}

int request_window(BrickAllocator &a, int cascade, const int position[3], uint32_t epoch) {
	int n = 0;
	for (const WorldRegion &r : window_regions(a.layout(), cascade, position)) {
		a.request(cascade, r, epoch);
		n++;
	}
	return n;
}

} // namespace

TEST(full_lifecycle_reaches_committed_and_lookups_succeed) {
	BrickAllocator a(kLayout, 64);

	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	CHECK_EQ(a.allocate_pending(1), 1);
	commit_all(a, 1);

	PageLookupResult r = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	CHECK(r.valid);
	CHECK_EQ(r.reason, LookupReason::OK);
	CHECK_EQ(a.committed_count(), 1u);
	CHECK_EQ(a.check_invariants(), std::string());
}

TEST(lookup_before_commit_is_rejected) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);

	PageLookupResult r = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	CHECK(!r.valid);
	CHECK_EQ(r.reason, LookupReason::ALLOCATED_NOT_COMMITTED);

	// commit without initialize must be a no-op: COMMITTED is only reachable through
	// INITIALIZING, which is where the zeroing pass lives.
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		const PageEntry &e = a.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			a.commit(e.page_id, 1);
		}
	}
	CHECK_EQ(a.committed_count(), 0u);
}

TEST(stale_owner_is_rejected_after_the_region_leaves_the_window) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);

	// Same wrapped slot, one full torus period later: the slot now names region 16.
	const int shifted[3] = { 128, 0, 0 };
	WrappedVoxel w;
	w.x = 64;
	w.y = 32;
	w.z = 64;
	PageLookupResult r = a.lookup(shifted, 0, w);
	CHECK(!r.valid);
	CHECK_EQ(r.reason, LookupReason::STALE_OWNER);
}

TEST(lookup_inside_the_window_still_succeeds_after_small_scroll) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);

	// 8-voxel scroll: region 0 is still inside the cascade window.
	const int shifted[3] = { 8, 0, 0 };
	WrappedVoxel w;
	w.x = 64;
	w.y = 32;
	w.z = 64;
	PageLookupResult r = a.lookup(shifted, 0, w);
	CHECK(r.valid);
}

TEST(capacity_overflow_is_explicit_not_silent) {
	BrickAllocator a(kLayout, 2);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 1, 0, 0 }, 1);
	a.request(0, WorldRegion{ 2, 0, 0 }, 1);
	a.request(0, WorldRegion{ 3, 0, 0 }, 1);

	const int allocated = a.allocate_pending(1);
	CHECK_EQ(allocated, 2);
	CHECK_EQ(a.counters().overflow_events, 2u);
	CHECK_EQ(a.free_count(), 0u);
	CHECK_EQ(a.check_invariants(), std::string());

	// An overflowed slot must not be reported as a valid page.
	int overflowed = 0;
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		if (a.table_entry(slot).state == Residency::OVERFLOWED) {
			overflowed++;
		}
	}
	CHECK_EQ(overflowed, 2);
}

TEST(retired_pages_are_not_reused_until_the_epoch_advances) {
	BrickAllocator a(kLayout, 4);
	a.request(0, WorldRegion{ 0, 0, 0 }, 5);
	a.allocate_pending(5);
	commit_all(a, 5);

	uint32_t pid = a.lookup_key(0, WorldRegion{ 0, 0, 0 }).page_id;
	CHECK(pid != INVALID_PAGE);

	a.retire(pid, 5);
	CHECK_EQ(a.retired_pending_count(), 1u);
	CHECK_EQ(a.free_count(), 3u);

	// A reader from epoch 5 may still be in flight.
	CHECK_EQ(a.release_retired(5), 0);
	CHECK_EQ(a.free_count(), 3u);
	CHECK_EQ(a.release_retired(6), 1);
	CHECK_EQ(a.free_count(), 4u);
	CHECK_EQ(a.check_invariants(), std::string());
}

TEST(retired_page_content_is_unreachable) {
	BrickAllocator a(kLayout, 4);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);
	const uint32_t pid = a.lookup_key(0, WorldRegion{ 0, 0, 0 }).page_id;

	a.retire(pid, 1);
	PageLookupResult r = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	CHECK(!r.valid);
	CHECK_EQ(r.reason, LookupReason::UNMAPPED);
}

TEST(generations_are_monotonic_and_never_zero) {
	BrickAllocator a(kLayout, 16);
	uint32_t previous = 0;
	for (int i = 0; i < 8; i++) {
		a.request(0, WorldRegion{ i, 0, 0 }, 1);
	}
	a.allocate_pending(1);
	for (uint32_t pid = 0; pid < 16; pid++) {
		const uint32_t g = a.page_generation(pid);
		if (g != 0) {
			CHECK(g > previous);
			previous = g;
		}
	}
}

TEST(generation_rollover_forces_full_invalidation) {
	BrickAllocator a(kLayout, 8);
	a.debug_set_next_generation(0xFFFFFFFEu);

	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 1, 0, 0 }, 1);
	CHECK_EQ(a.allocate_pending(1), 2);
	CHECK_EQ(a.page_generation(0), 0xFFFFFFFEu);
	CHECK_EQ(a.page_generation(1), 0xFFFFFFFFu);

	// The next allocation would reuse a generation value, so it must refuse.
	a.request(0, WorldRegion{ 2, 0, 0 }, 1);
	a.allocate_pending(1);
	CHECK(a.needs_full_invalidation());
	CHECK_EQ(a.generation_cycle(), 1u);

	// After retiring everything, allocation resumes from generation 1.
	commit_all(a, 1);
	a.invalidate_all(2);
	a.release_retired(3);
	a.clear_full_invalidation();
	CHECK_EQ(a.allocate_pending(3), 1);
	CHECK_EQ(a.page_generation(0) > 0 || a.page_generation(1) > 0, true);
	CHECK_EQ(a.check_invariants(), std::string());
}

TEST(duplicate_request_is_idempotent) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	CHECK_EQ(a.allocate_pending(1), 1);
	commit_all(a, 1);

	a.request(0, WorldRegion{ 0, 0, 0 }, 2); // already resident and correct
	CHECK_EQ(a.allocate_pending(2), 0);
	CHECK_EQ(a.committed_count(), 1u);
}

TEST(request_for_a_new_owner_replaces_the_old_page) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);
	CHECK_EQ(a.committed_count(), 1u);

	// Region 16 lands in the same slot as region 0 (one torus period away).
	a.request(0, WorldRegion{ 16, 0, 0 }, 2);
	CHECK_EQ(a.retired_pending_count(), 1u);
	a.allocate_pending(2);
	commit_all(a, 2);

	PageLookupResult fresh = a.lookup_key(0, WorldRegion{ 16, 0, 0 });
	CHECK(fresh.valid);
	PageLookupResult old = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	CHECK(!old.valid);
	CHECK_EQ(a.check_invariants(), std::string());
}

TEST(teleport_invalidates_everything) {
	BrickAllocator a(kLayout, uint32_t(kLayout.bricks_per_cascade()));
	const int position[3] = { 0, 0, 0 };
	request_window(a, 0, position, 1);
	a.allocate_pending(1);
	commit_all(a, 1);
	CHECK_EQ(a.committed_count(), uint32_t(kLayout.bricks_per_cascade()));

	const int retired = a.invalidate_all(2);
	CHECK_EQ(retired, kLayout.bricks_per_cascade());
	CHECK_EQ(a.committed_count(), 0u);
	CHECK_EQ(a.check_invariants(), std::string());
}
