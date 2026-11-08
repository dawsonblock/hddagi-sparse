// Shared sparse-brick definitions for the M2 GPU micro-tests.
//
// This file is concatenated ahead of each shader by build.sh, because Godot's
// shader preprocessor is the real include mechanism and glslang's #include
// support depends on the target environment. Keeping the text identical avoids
// the two paths diverging.
//
// Layout contract (must match hddagi_sparse_gpu_model.h byte for byte):
//   PageEntry  16 bytes: page_id, generation, state, reserved
//   BrickMeta  32 bytes: region_x, region_y, region_z, owner_cascade,
//                        generation, state, last_write_epoch, retired_epoch
// Vec3 is deliberately spelled as three scalars: std430 vec3 alignment rules are
// a common source of silent layout drift.

#define SB_INVALID_PAGE 0xFFFFFFFFu

#define SB_STATE_UNMAPPED 0u
#define SB_STATE_REQUESTED 1u
#define SB_STATE_ALLOCATED 2u
#define SB_STATE_INITIALIZING 3u
#define SB_STATE_COMMITTED 4u
#define SB_STATE_RETIRED 6u
#define SB_STATE_FREE 7u
#define SB_STATE_OVERFLOWED 8u

struct PageEntry {
	uint page_id;
	uint generation;
	uint state;
	uint reserved;
};

struct BrickMeta {
	int region_x;
	int region_y;
	int region_z;
	int owner_cascade;
	uint generation;
	uint state;
	uint last_write_epoch;
	uint retired_epoch;
};

// Floor division by the brick edge. Only exact multiples reach here in the engine,
// but the shader must agree with the CPU oracle for negative world coordinates.
int sb_floor_div8(int v) {
	return (v >= 0) ? (v >> 3) : -(((-v) + 7) >> 3);
}

// Wrapped storage coordinate: (local + position) & (grid - 1).
ivec3 sb_wrap(ivec3 local_cell, ivec3 position, ivec3 grid) {
	return (local_cell + position) & (grid - 1);
}

// World region of a local voxel. The cascade origin is position - grid/2.
ivec3 sb_world_region(ivec3 local_cell, ivec3 position, ivec3 grid) {
	ivec3 world = position + local_cell - grid / 2;
	return ivec3(sb_floor_div8(world.x), sb_floor_div8(world.y), sb_floor_div8(world.z));
}

// Dense virtual slot, x fastest.
uint sb_slot(ivec3 wrapped_cell, uint cascade, ivec3 brick_dims) {
	ivec3 b = wrapped_cell >> 3;
	return cascade * (uint(brick_dims.x) * uint(brick_dims.y) * uint(brick_dims.z)) +
			uint(b.x) + uint(b.y) * uint(brick_dims.x) + uint(b.z) * uint(brick_dims.x) * uint(brick_dims.y);
}

// Physical atlas texel for a page id and a local-in-brick coordinate.
ivec3 sb_atlas_texel(uint page_id, ivec3 local_in_brick, ivec2 page_slots_xy) {
	uint px = uint(page_slots_xy.x);
	uint py = uint(page_slots_xy.y);
	uint bx = page_id % px;
	uint by = (page_id / px) % py;
	uint bz = page_id / (px * py);
	return ivec3(int(bx) * 8 + local_in_brick.x,
			int(by) * 8 + local_in_brick.y,
			int(bz) * 8 + local_in_brick.z);
}

// Identity canary. Not the engine's E5B9G9R9 or rgbe packer; it exists so a swapped
// page or wrong voxel is obvious rather than merely different.
uint sb_canary(uint cascade, ivec3 region, ivec3 local_in_brick, uint generation) {
	return ((cascade & 7u) << 29) | ((uint(region.x) & 7u) << 26) | ((uint(region.y) & 7u) << 23) |
			((uint(region.z) & 7u) << 20) | ((uint(local_in_brick.x) & 7u) << 17) |
			((uint(local_in_brick.y) & 7u) << 14) | ((uint(local_in_brick.z) & 7u) << 11) |
			(generation & 0x7FFu);
}
