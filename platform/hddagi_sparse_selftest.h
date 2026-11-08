// In-engine self-test for the sparse-brick GPU path (M2.02 - M2.05).
//
// Creates the physical atlas, the page table and the auxiliary buffers, runs the
// four kernels against CPU-generated fixtures, and reports pass/fail. It does not
// touch GI rendering: the point is to prove the resources and the kernels work
// inside RenderingDevice before anything depends on them.
//
// This file is copied into servers/rendering/renderer_rd/environment/ by
// platform/install_engine_changes.sh.

#pragma once

#include "core/math/vector3i.h"
#include "core/string/ustring.h"
#include "servers/rendering/rendering_device.h"

namespace hddagi_sparse {

struct SelfTestResult {
	bool ran = false;
	bool passed = false;

	int probe_records = 0;
	int probe_mismatches = 0;
	int probe_first_bad = -1;

	int canary_texels = 0;
	int canary_mismatches = 0;

	bool allocator_ok = false;
	uint32_t allocator_compacted = 0;
	uint32_t allocator_allocated = 0;
	uint32_t allocator_overflow = 0;
	uint32_t allocator_committed = 0;
	uint32_t allocator_duplicate_pages = 0;

	String error;
};

// p_fixture_path is a res:// or absolute path to probe_fixtures.bin (80-byte records).
SelfTestResult run_self_test(RD *p_rd, const String &p_fixture_path, uint32_t p_pages,
		int p_cascades, const Vector3i &p_grid);

} // namespace hddagi_sparse
