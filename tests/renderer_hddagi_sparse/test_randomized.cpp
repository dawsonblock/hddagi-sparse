// M1.06 — reproducible randomised operation stream.
//
// The PRNG is splitmix64 with a fixed seed and modulo reduction, so the sequence is
// identical on every platform and compiler. std::uniform_int_distribution is not
// portable and is deliberately not used.

#include "hddagi_brick_allocator.h"
#include "hddagi_brick_layout.h"
#include "test_harness.h"

#include <vector>

using namespace hddagi_sparse;

namespace {

const GridLayout kLayout = GridLayout::make(128, 64, 128, 3);

struct Rng {
	uint64_t state;
	explicit Rng(uint64_t seed) :
			state(seed) {}

	uint64_t next() {
		state += 0x9E3779B97F4A7C15ull;
		uint64_t z = state;
		z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
		z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
		return z ^ (z >> 31);
	}

	uint32_t below(uint32_t n) { return n == 0 ? 0 : uint32_t(next() % n); }
	int range(int lo, int hi) { return lo + int(below(uint32_t(hi - lo + 1))); }
};

} // namespace

TEST(randomised_stream_holds_every_invariant) {
	const uint64_t kSeed = 0x5EED1234ABCDull;
	const int kOperations = 100000;
	const uint32_t kCapacity = 512;

	BrickAllocator a(kLayout, kCapacity);
	Rng rng(kSeed);

	int position[3] = { 0, 0, 0 };
	uint32_t epoch = 1;
	int commits = 0;
	int lookups_ok = 0;

	for (int op = 0; op < kOperations; op++) {
		const uint32_t kind = rng.below(100);

		if (kind < 45) {
			// request a random region inside the current window
			const int cascade = rng.range(0, kLayout.cascade_count - 1);
			WorldRegion r;
			r.x = floor_div(position[0] - kLayout.size[0] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(0) - 1);
			r.y = floor_div(position[1] - kLayout.size[1] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(1) - 1);
			r.z = floor_div(position[2] - kLayout.size[2] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(2) - 1);
			a.request(cascade, r, epoch);
		} else if (kind < 70) {
			const int n = a.allocate_pending(epoch);
			if (n > 0) {
				for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
					const PageEntry &e = a.table_entry(slot);
					if (e.state == Residency::ALLOCATED) {
						a.begin_initialize(e.page_id);
						a.commit(e.page_id, epoch);
						commits++;
					}
				}
			}
		} else if (kind < 80) {
			// retire a random live page
			for (int tries = 0; tries < 8; tries++) {
				const uint32_t pid = rng.below(kCapacity);
				const Residency s = a.page_state(pid);
				if (s == Residency::COMMITTED || s == Residency::ALLOCATED || s == Residency::INITIALIZING) {
					a.retire(pid, epoch);
					break;
				}
			}
		} else if (kind < 88) {
			a.release_retired(epoch);
		} else if (kind < 96) {
			// scroll by one region on a random axis
			const int axis = rng.range(0, 2);
			const int dir = rng.below(2) == 0 ? 8 : -8;
			position[axis] += dir;
			epoch++;
			a.retire_mismatched(position, epoch);
		} else if (kind < 98) {
			// teleport
			position[0] += rng.range(-4096, 4096);
			position[1] += rng.range(-4096, 4096);
			position[2] += rng.range(-4096, 4096);
			epoch++;
			a.invalidate_all(epoch);
		} else {
			// lookup a random wrapped voxel
			WrappedVoxel w;
			w.x = rng.range(0, kLayout.size[0] - 1);
			w.y = rng.range(0, kLayout.size[1] - 1);
			w.z = rng.range(0, kLayout.size[2] - 1);
			const int cascade = rng.range(0, kLayout.cascade_count - 1);
			PageLookupResult r = a.lookup(position, cascade, w);
			if (r.valid) {
				lookups_ok++;
				CHECK(r.page_id < kCapacity);
				CHECK(r.local[0] < BRICK_EDGE && r.local[1] < BRICK_EDGE && r.local[2] < BRICK_EDGE);
			}
		}

		if (op % 500 == 0) {
			const std::string violation = a.check_invariants();
			if (!violation.empty()) {
				test::report_failure(__FILE__, __LINE__, "op " + std::to_string(op) + ": " + violation);
				return;
			}
			CHECK(a.allocated_count() + a.free_count() + a.retired_pending_count() == kCapacity);
		}
	}

	CHECK_EQ(a.check_invariants(), std::string());
	CHECK(commits > 0);
	CHECK(lookups_ok > 0);
	CHECK(a.counters().capacity_high_water <= kCapacity);
}

TEST(negative_heavy_random_stream) {
	// Bias every scroll negative so that the world coordinate arithmetic is exercised
	// on the side where truncating division would silently differ from floor.
	BrickAllocator a(kLayout, 256);
	Rng rng(0xC0FFEEull);
	int position[3] = { 0, 0, 0 };
	uint32_t epoch = 1;

	for (int op = 0; op < 20000; op++) {
		const uint32_t kind = rng.below(10);
		if (kind < 6) {
			const int axis = rng.range(0, 2);
			position[axis] -= 8;
			epoch++;
			a.retire_mismatched(position, epoch);
			a.release_retired(epoch);
		} else {
			const int cascade = rng.range(0, kLayout.cascade_count - 1);
			WorldRegion r;
			r.x = floor_div(position[0] - kLayout.size[0] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(0) - 1);
			r.y = floor_div(position[1] - kLayout.size[1] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(1) - 1);
			r.z = floor_div(position[2] - kLayout.size[2] / 2, BRICK_EDGE) + rng.range(0, kLayout.bricks_per_axis(2) - 1);
			a.request(cascade, r, epoch);
			a.allocate_pending(epoch);
			for (int slot = 0; slot < a.virtual_slot_count(); slot++) {
				const PageEntry &e = a.table_entry(slot);
				if (e.state == Residency::ALLOCATED) {
					a.begin_initialize(e.page_id);
					a.commit(e.page_id, epoch);
				}
			}
		}

		if (op % 250 == 0) {
			const std::string violation = a.check_invariants();
			if (!violation.empty()) {
				test::report_failure(__FILE__, __LINE__, "op " + std::to_string(op) + ": " + violation);
				return;
			}
		}
	}
	CHECK_EQ(a.check_invariants(), std::string());
}
