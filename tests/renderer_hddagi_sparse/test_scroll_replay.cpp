// M1.05 — scroll replay and deferred page release.
//
// Each frame mirrors the ordering the RFC proposes: freeze, retire owners that the
// scroll invalidated, request the writable support, allocate, initialise, commit,
// then release pages whose last reader epoch has passed.

#include "hddagi_brick_allocator.h"
#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <vector>

using namespace hddagi_sparse;

namespace {

const GridLayout kSimLayout = GridLayout::make(128, 64, 128, 2);

class ScrollSim {
public:
	explicit ScrollSim(uint32_t capacity) :
			alloc_(kSimLayout, capacity) {
		position_[0] = position_[1] = position_[2] = 0;
	}

	void frame(const int scroll[3]) {
		for (int i = 0; i < 3; i++) {
			position_[i] += scroll[i];
		}
		epoch_++;

		// 1. retire pages whose stored owner no longer matches this window
		alloc_.retire_mismatched(position_, epoch_);

		// 2. release pages retired strictly before this epoch
		alloc_.release_retired(epoch_);

		// 3. request every brick the slab will write
		const Slab slab = compute_update_slab(kSimLayout, scroll);
		std::vector<BrickCoord> bricks;
		bricks_intersecting_slab(kSimLayout, slab, bricks);
		for (const BrickCoord &b : bricks) {
			for (int cascade = 0; cascade < kSimLayout.cascade_count; cascade++) {
				int local[3] = { b.x * BRICK_EDGE, b.y * BRICK_EDGE, b.z * BRICK_EDGE };
				const WorldRegion region = world_region_of(kSimLayout, local, position_);
				alloc_.request(cascade, region, epoch_);
			}
		}

		// 4. allocate, initialise, commit
		alloc_.allocate_pending(epoch_);
		for (int slot = 0; slot < alloc_.virtual_slot_count(); slot++) {
			const PageEntry &e = alloc_.table_entry(slot);
			if (e.state == Residency::ALLOCATED) {
				alloc_.begin_initialize(e.page_id);
				alloc_.commit(e.page_id, epoch_);
			}
		}
	}

	void teleport(const int delta[3]) {
		for (int i = 0; i < 3; i++) {
			position_[i] += delta[i];
		}
		epoch_++;
		alloc_.invalidate_all(epoch_);
		alloc_.release_retired(epoch_);
	}

	// Every committed page must still describe a region inside the current window.
	bool all_committed_pages_are_in_window() const {
		for (int slot = 0; slot < alloc_.virtual_slot_count(); slot++) {
			const PageEntry &e = alloc_.table_entry(slot);
			if (e.state != Residency::COMMITTED) {
				continue;
			}
			const BrickMeta &m = alloc_.meta(e.page_id);
			const int bpc = kSimLayout.bricks_per_cascade();
			const int cascade = slot / bpc;
			const int index = slot % bpc;
			const int bx = kSimLayout.bricks_per_axis(0);
			const int by = kSimLayout.bricks_per_axis(1);
			const int brick[3] = { index % bx, (index / bx) % by, index / (bx * by) };
			int local[3];
			local_from_wrapped_brick(kSimLayout, brick, position_, local);
			const WorldRegion expected = world_region_of(kSimLayout, local, position_);
			if (m.owner_cascade != cascade || m.world_region[0] != expected.x ||
					m.world_region[1] != expected.y || m.world_region[2] != expected.z) {
				return false;
			}
		}
		return true;
	}

	BrickAllocator &alloc() { return alloc_; }
	const int *position() const { return position_; }

private:
	BrickAllocator alloc_;
	int position_[3];
	uint32_t epoch_ = 0;
};

} // namespace

TEST(single_axis_scroll_keeps_invariants) {
	ScrollSim sim(4096);
	const int steps[][3] = { { 8, 0, 0 }, { 8, 0, 0 }, { -8, 0, 0 }, { 8, 0, 0 } };
	for (const auto &s : steps) {
		sim.frame(s);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
		CHECK(sim.all_committed_pages_are_in_window());
	}
}

TEST(negative_axis_scroll_keeps_invariants) {
	ScrollSim sim(4096);
	const int steps[][3] = { { -8, 0, 0 }, { -8, 0, 0 }, { -8, 0, 0 }, { 8, 0, 0 } };
	for (const auto &s : steps) {
		sim.frame(s);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
		CHECK(sim.all_committed_pages_are_in_window());
	}
}

TEST(two_axis_and_corner_scroll) {
	ScrollSim sim(4096);
	const int steps[][3] = {
		{ 8, 8, 0 },
		{ 0, -8, 8 },
		{ -8, 0, -8 },
		{ 8, -8, 8 }, // all three axes in one frame
	};
	for (const auto &s : steps) {
		sim.frame(s);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
		CHECK(sim.all_committed_pages_are_in_window());
	}
}

TEST(repeated_forward_back_does_not_leak_pages) {
	ScrollSim sim(4096);
	for (int i = 0; i < 40; i++) {
		const int forward[3] = { 8, 0, 0 };
		sim.frame(forward);
		const int back[3] = { -8, 0, 0 };
		sim.frame(back);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
	}
	// The pool must be fully recoverable: nothing is permanently lost to the churn.
	CHECK(sim.alloc().retired_pending_count() <= 4096u);
	CHECK(sim.alloc().free_count() + sim.alloc().allocated_count() +
					sim.alloc().retired_pending_count() ==
			sim.alloc().capacity());
}

TEST(long_walk_crosses_the_torus_period) {
	// 16 regions per axis is one full period. Walking past it must not resurrect a
	// stale owner: the exact world-region tag is what catches this.
	ScrollSim sim(8192);
	for (int i = 0; i < 40; i++) {
		const int forward[3] = { 8, 0, 0 };
		sim.frame(forward);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
		CHECK(sim.all_committed_pages_are_in_window());
	}
}

TEST(teleport_invalidates_and_recovers) {
	ScrollSim sim(4096);
	const int forward[3] = { 8, 0, 0 };
	for (int i = 0; i < 4; i++) {
		sim.frame(forward);
	}
	CHECK(sim.alloc().committed_count() > 0u);

	const int jump[3] = { 4096, 0, -2048 };
	sim.teleport(jump);
	CHECK_EQ(sim.alloc().committed_count(), 0u);
	CHECK_EQ(sim.alloc().check_invariants(), std::string());

	// Rebuild after the teleport.
	const int still[3] = { 0, 0, 0 };
	sim.frame(still);
	CHECK_EQ(sim.alloc().check_invariants(), std::string());
	CHECK(sim.all_committed_pages_are_in_window());
}

TEST(pool_of_one_page_stays_consistent) {
	ScrollSim sim(1);
	const int forward[3] = { 8, 0, 0 };
	for (int i = 0; i < 5; i++) {
		sim.frame(forward);
		CHECK_EQ(sim.alloc().check_invariants(), std::string());
	}
	CHECK(sim.alloc().committed_count() <= 1u);
	CHECK(sim.alloc().counters().overflow_events > 0u);
}
