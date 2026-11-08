// CPU reference for HDDAGI sparse-brick addressing (RFC M1.01, M1.02).
//
// Every function here mirrors a specific line of the engine source. The point of
// the oracle is that it can be run without a GPU and disagreed with, so the
// citations matter as much as the arithmetic.
//
// Source anchors (godot-dynamic_gi_2):
//   gi.h:748-750            MAX_CASCADES / CASCADE_SIZE / REGION_CELLS
//   gi.cpp:362-380          cascade_size.y is 64 for the default 16x8x16 format
//   gi.cpp:1110-1144        position moves in drag_margin*2 = 8 voxel steps
//   gi.cpp:1540-1560        dirty slab widened by 2 voxels on the retained side
//   gi.cpp:1597-1599        region_world_offset = position / REGION_CELLS
//   hddagi_integrate.glsl:566-572   wrap, then spos.y += cascade * grid_size.y
//   hddagi_screen_probe.glsl:1803   read_cell = (cell + offset*8) & (grid-1)

#pragma once

#include <cstdint>
#include <vector>

namespace hddagi_sparse {

constexpr int REGION_CELLS = 8;
constexpr int BRICK_EDGE = 8;
constexpr int MAX_CASCADES = 8;

// Floor division. C++ integer division truncates toward zero, which is wrong for
// negative world coordinates; the engine never sees this because its positions are
// exact multiples of the brick edge, but the oracle must be correct in general so
// that the test can prove the multiple-of-8 assumption is load-bearing.
inline int floor_div(int a, int b) {
	int q = a / b;
	const int r = a % b;
	if (r != 0 && ((r < 0) != (b < 0))) {
		--q;
	}
	return q;
}

inline bool is_power_of_two(int v) { return v > 0 && (v & (v - 1)) == 0; }

struct GridLayout {
	int size[3] = { 128, 64, 128 };
	int cascade_count = 6;

	static GridLayout make(int x, int y, int z, int cascades) {
		GridLayout l;
		l.size[0] = x;
		l.size[1] = y;
		l.size[2] = z;
		l.cascade_count = cascades;
		return l;
	}

	// The wrap uses `& (grid - 1)`, so every axis must be a power of two and a whole
	// number of bricks. A violation here is a source-level bug, not a runtime case.
	bool valid() const {
		if (cascade_count < 1 || cascade_count > MAX_CASCADES) {
			return false;
		}
		for (int i = 0; i < 3; i++) {
			if (!is_power_of_two(size[i]) || size[i] % BRICK_EDGE != 0) {
				return false;
			}
		}
		return true;
	}

	int bricks_per_axis(int axis) const { return size[axis] / BRICK_EDGE; }

	int bricks_per_cascade() const {
		return bricks_per_axis(0) * bricks_per_axis(1) * bricks_per_axis(2);
	}

	int virtual_pages() const { return bricks_per_cascade() * cascade_count; }

	int voxels_per_cascade() const { return size[0] * size[1] * size[2]; }
};

// Absolute world region index, i.e. a fixed 8^3 cell of the infinite world.
struct WorldRegion {
	int32_t x = 0;
	int32_t y = 0;
	int32_t z = 0;

	bool operator==(const WorldRegion &o) const { return x == o.x && y == o.y && z == o.z; }
	bool operator!=(const WorldRegion &o) const { return !(*this == o); }
};

// Identity of the content a physical page is allowed to hold.
struct PageKey {
	int32_t cascade = -1;
	WorldRegion region;

	bool operator==(const PageKey &o) const { return cascade == o.cascade && region == o.region; }
	bool operator!=(const PageKey &o) const { return !(*this == o); }
	bool valid() const { return cascade >= 0; }
};

// A voxel coordinate after toroidal wrapping, still inside one cascade.
struct WrappedVoxel {
	int x = 0;
	int y = 0;
	int z = 0;

	bool operator==(const WrappedVoxel &o) const { return x == o.x && y == o.y && z == o.z; }
	int local(int axis) const { return axis == 0 ? x : (axis == 1 ? y : z); }
};

// Wrapped storage coordinate. Matches `(local + region_world_offset * 8) & (grid - 1)`.
inline WrappedVoxel wrap_local(const GridLayout &layout, const int local[3], const int position[3]) {
	WrappedVoxel w;
	w.x = (local[0] + position[0]) & (layout.size[0] - 1);
	w.y = (local[1] + position[1]) & (layout.size[1] - 1);
	w.z = (local[2] + position[2]) & (layout.size[2] - 1);
	return w;
}

// Inverse of wrap_local for a position that is an exact multiple of the grid.
// Returns false when several locals map to the same wrapped voxel, which can only
// happen if the caller passed a position that is not brick-aligned.
inline bool unwrap_to_local(const GridLayout &layout, const WrappedVoxel &w, const int position[3], int out_local[3]) {
	for (int i = 0; i < 3; i++) {
		const int v = w.local(i) - position[i];
		out_local[i] = v & (layout.size[i] - 1);
	}
	return true;
}

// World voxel coordinate. gi.cpp:1550 places the cascade origin at
// `position - cascade_size / 2`, so a local voxel's world position is
// `position + local - grid/2`.
inline int world_voxel_axis(int local, int position, int grid) {
	return position + local - grid / 2;
}

inline WorldRegion world_region_of(const GridLayout &layout, const int local[3], const int position[3]) {
	WorldRegion r;
	r.x = floor_div(world_voxel_axis(local[0], position[0], layout.size[0]), BRICK_EDGE);
	r.y = floor_div(world_voxel_axis(local[1], position[1], layout.size[1]), BRICK_EDGE);
	r.z = floor_div(world_voxel_axis(local[2], position[2], layout.size[2]), BRICK_EDGE);
	return r;
}

inline PageKey key_of(const GridLayout &layout, int cascade, const int local[3], const int position[3]) {
	PageKey k;
	k.cascade = cascade;
	k.region = world_region_of(layout, local, position);
	return k;
}

// Brick coordinate inside a cascade, from a wrapped voxel.
inline void brick_of_wrapped(const WrappedVoxel &w, int out[3]) {
	out[0] = w.x / BRICK_EDGE;
	out[1] = w.y / BRICK_EDGE;
	out[2] = w.z / BRICK_EDGE;
}

// Inverse of brick_of_wrapped: the local voxel that occupies a wrapped brick under
// the current scroll. Omitting the `- position` term here is the classic bug: the
// brick index lives in wrapped space, the local coordinate does not.
inline void local_from_wrapped_brick(const GridLayout &layout, const int brick[3], const int position[3], int out[3]) {
	for (int i = 0; i < 3; i++) {
		out[i] = (brick[i] * BRICK_EDGE - position[i]) & (layout.size[i] - 1);
	}
}

// Local voxel inside a brick, i.e. `voxel_in_cascade & (7,7,7)`.
inline void local_of_wrapped(const WrappedVoxel &w, int out[3]) {
	out[0] = w.x & (BRICK_EDGE - 1);
	out[1] = w.y & (BRICK_EDGE - 1);
	out[2] = w.z & (BRICK_EDGE - 1);
}

// Dense virtual slot index. x is the fastest-varying axis.
inline int virtual_slot_of(const GridLayout &layout, int cascade, const WrappedVoxel &w) {
	int b[3];
	brick_of_wrapped(w, b);
	const int bx = layout.bricks_per_axis(0);
	const int by = layout.bricks_per_axis(1);
	const int index = b[0] + b[1] * bx + b[2] * bx * by;
	return cascade * layout.bricks_per_cascade() + index;
}

inline int virtual_slot_of_brick(const GridLayout &layout, int cascade, const int brick[3]) {
	const int bx = layout.bricks_per_axis(0);
	const int by = layout.bricks_per_axis(1);
	return cascade * layout.bricks_per_cascade() + brick[0] + brick[1] * bx + brick[2] * bx * by;
}

// Physical atlas texel for a page id (RFC section 7, option A).
inline void atlas_texel_of(uint32_t page_id, int px, int py, const int local[3], int out[3]) {
	const uint32_t bx = page_id % uint32_t(px);
	const uint32_t by = (page_id / uint32_t(px)) % uint32_t(py);
	const uint32_t bz = page_id / (uint32_t(px) * uint32_t(py));
	out[0] = int(bx) * BRICK_EDGE + local[0];
	out[1] = int(by) * BRICK_EDGE + local[1];
	out[2] = int(bz) * BRICK_EDGE + local[2];
}

// ---------------------------------------------------------------------------
// Dirty slab, mirroring gi.cpp:1540-1560.
// ---------------------------------------------------------------------------

struct Slab {
	bool all = false;
	int from[3] = { 0, 0, 0 };
	int size[3] = { 0, 0, 0 };
};

// `scroll` is the per-axis dirty_regions value: positive means the window moved
// toward -axis and the new data is filled from the beginning, negative the reverse.
// The retained side is widened by two voxels because light rebuild needs the border.
inline Slab compute_update_slab(const GridLayout &layout, const int scroll[3]) {
	Slab s;
	for (int i = 0; i < 3; i++) {
		s.from[i] = 0;
		s.size[i] = layout.size[i];
	}
	for (int i = 0; i < 3; i++) {
		if (scroll[i] == 0) {
			continue;
		}
		if (scroll[i] > 0) {
			s.from[i] = 0;
			s.size[i] = scroll[i] + 2;
		} else {
			s.from[i] = layout.size[i] + scroll[i] - 2;
			s.size[i] = -scroll[i] + 2;
		}
	}
	return s;
}

struct BrickCoord {
	int x = 0;
	int y = 0;
	int z = 0;
};

// Every brick intersecting the slab. This is the set a correct implementation must
// treat as writable; an implementation that only covers `scroll` voxels misses the
// last brick whenever `scroll` is not a multiple of the brick edge, or when the
// +2 border pushes past a boundary.
inline void bricks_intersecting_slab(const GridLayout &layout, const Slab &s, std::vector<BrickCoord> &out) {
	out.clear();
	int lo[3], hi[3];
	for (int i = 0; i < 3; i++) {
		lo[i] = s.from[i] / BRICK_EDGE;
		hi[i] = (s.from[i] + s.size[i] - 1) / BRICK_EDGE;
	}
	for (int z = lo[2]; z <= hi[2]; z++) {
		for (int y = lo[1]; y <= hi[1]; y++) {
			for (int x = lo[0]; x <= hi[0]; x++) {
				out.push_back({ x, y, z });
			}
		}
	}
}

} // namespace hddagi_sparse
