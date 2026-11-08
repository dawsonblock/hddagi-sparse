// Negative tests required by RFC section 12.
//
// Each case deliberately breaks the model and asserts that *something notices*.
// A negative test that passes silently is worse than no test, so every case also
// checks that the failure is visible through a counter, a rejected lookup, or a
// non-empty invariant report.

#include "hddagi_brick_allocator.h"
#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <set>
#include <vector>

using namespace hddagi_sparse;

namespace {

const GridLayout kLayout = GridLayout::make(128, 64, 128, 1);

void commit_all(BrickAllocator &a, uint32_t epoch) {
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		const PageEntry &e = a.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			a.begin_initialize(e.page_id);
			a.commit(e.page_id, epoch);
		}
	}
}

} // namespace

TEST(negative_corrupted_generation_is_rejected) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);
	REQUIRE(a.lookup_key(0, WorldRegion{ 0, 0, 0 }).valid);

	const uint32_t pid = a.lookup_key(0, WorldRegion{ 0, 0, 0 }).page_id;
	int owner_slot = -1;
	for (int s = 0; s < a.virtual_slot_count(); s++) {
		if (a.table_entry(s).page_id == pid) {
			owner_slot = s;
			break;
		}
	}
	REQUIRE(owner_slot >= 0);
	a.debug_corrupt_table_generation(owner_slot, 0xDEADBEEF);

	PageLookupResult r = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	CHECK(!r.valid);
	CHECK_EQ(r.reason, LookupReason::STALE_GENERATION);

	// ...and the structural check must also notice.
	CHECK(!a.check_invariants().empty());
}

TEST(negative_aliased_page_is_rejected) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 1, 0, 0 }, 1);
	a.allocate_pending(1);
	commit_all(a, 1);

	const PageLookupResult first = a.lookup_key(0, WorldRegion{ 0, 0, 0 });
	const PageLookupResult second = a.lookup_key(0, WorldRegion{ 1, 0, 0 });
	REQUIRE(first.valid);
	REQUIRE(second.valid);
	REQUIRE(first.page_id != second.page_id);

	// Point the second slot at the first slot's page: two virtual owners, one page.
	const int slot = 0;
	(void)slot;
	// Find the slot that owns region 1 by scanning the table.
	int victim_slot = -1;
	for (int s = 0; s < a.virtual_slot_count(); s++) {
		if (a.table_entry(s).page_id == second.page_id) {
			victim_slot = s;
			break;
		}
	}
	REQUIRE(victim_slot >= 0);
	a.debug_alias_slot(victim_slot, first.page_id);

	const std::string violation = a.check_invariants();
	CHECK(!violation.empty());
	CHECK(violation.find("owned by slots") != std::string::npos);
}

TEST(negative_delayed_zeroing_blocks_commit) {
	BrickAllocator a(kLayout, 8);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.allocate_pending(1);

	// Skip begin_initialize: the zeroing pass never ran.
	for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
		const PageEntry &e = a.table_entry(slot);
		if (e.state == Residency::ALLOCATED) {
			a.commit(e.page_id, 1);
		}
	}
	CHECK_EQ(a.committed_count(), 0u);
	CHECK_EQ(a.lookup_key(0, WorldRegion{ 0, 0, 0 }).reason, LookupReason::ALLOCATED_NOT_COMMITTED);
}

TEST(negative_early_reuse_is_visible) {
	BrickAllocator a(kLayout, 2);
	a.request(0, WorldRegion{ 0, 0, 0 }, 10);
	a.allocate_pending(10);
	commit_all(a, 10);
	const uint32_t pid = a.lookup_key(0, WorldRegion{ 0, 0, 0 }).page_id;

	a.retire(pid, 10);
	// A reader from epoch 10 is still in flight; release must refuse.
	CHECK_EQ(a.release_retired(10), 0);
	CHECK_EQ(a.page_state(pid), Residency::RETIRED);
	// The page is still not reachable.
	CHECK(!a.lookup_key(0, WorldRegion{ 0, 0, 0 }).valid);
}

TEST(negative_omitted_writer_request_is_detectable) {
	// The RFC requires: every dense writer's non-trivial output must be covered by
	// sparse writable support. Model the check as a set comparison and show that an
	// omitted region is caught.
	BrickAllocator a(kLayout, 64);

	std::vector<WorldRegion> written = {
		{ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }
	};

	// Correct case: request everything that will be written.
	for (const WorldRegion &r : written) {
		a.request(0, r, 1);
	}
	a.allocate_pending(1);
	commit_all(a, 1);

	int missing = 0;
	for (const WorldRegion &r : written) {
		if (!a.lookup_key(0, r).valid) {
			missing++;
		}
	}
	CHECK_EQ(missing, 0);

	// Faulty case: drop one request. The subset check must fail.
	BrickAllocator b(kLayout, 64);
	for (size_t i = 0; i + 1 < written.size(); i++) {
		b.request(0, written[i], 1);
	}
	b.allocate_pending(1);
	commit_all(b, 1);

	int missing_b = 0;
	for (const WorldRegion &r : written) {
		if (!b.lookup_key(0, r).valid) {
			missing_b++;
		}
	}
	CHECK_EQ(missing_b, 1);
}

TEST(negative_overflow_recovers_when_capacity_frees) {
	BrickAllocator a(kLayout, 1);
	a.request(0, WorldRegion{ 0, 0, 0 }, 1);
	a.request(0, WorldRegion{ 1, 0, 0 }, 1);
	CHECK_EQ(a.allocate_pending(1), 1);
	CHECK_EQ(a.counters().overflow_events, 1u);
	commit_all(a, 1);

	// Free the live page, then re-issue the requests. The previously overflowed
	// region must become resident rather than staying stuck.
	const uint32_t pid = a.lookup_key(0, WorldRegion{ 0, 0, 0 }).page_id;
	REQUIRE(pid != INVALID_PAGE);
	a.retire(pid, 1);
	a.release_retired(2);

	a.request(0, WorldRegion{ 1, 0, 0 }, 2);
	CHECK_EQ(a.allocate_pending(2), 1);
	commit_all(a, 2);
	CHECK(a.lookup_key(0, WorldRegion{ 1, 0, 0 }).valid);
	CHECK_EQ(a.check_invariants(), std::string());
}
