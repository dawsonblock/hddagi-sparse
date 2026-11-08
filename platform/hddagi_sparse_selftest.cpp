#include "hddagi_sparse_selftest.h"

#include "core/io/file_access.h"
#include "hddagi_sparse_plan.h"
#include "hddagi_sparse_shaders.inc"

#include <cstring>

namespace hddagi_sparse {

namespace {

constexpr uint32_t FIXTURE_RECORD_BYTES = 80;
constexpr uint32_t PROBE_RESULT_BYTES = 48;

RID compile_compute(RD *p_rd, const char *p_body, String *r_error) {
	String source = "#version 450\n";
	source += String(SPARSE_COMMON_GLSL);
	source += String(p_body);

	String error;
	Vector<uint8_t> spirv = p_rd->shader_compile_spirv_from_source(
			RD::SHADER_STAGE_COMPUTE, source, RD::SHADER_LANGUAGE_GLSL, &error);
	if (spirv.is_empty()) {
		*r_error = "shader compile failed: " + error;
		return RID();
	}

	Vector<RD::ShaderStageSPIRVData> stages;
	RD::ShaderStageSPIRVData stage;
	stage.shader_stage = RD::SHADER_STAGE_COMPUTE;
	stage.spirv = spirv;
	stages.push_back(stage);
	return p_rd->shader_create_from_spirv(stages);
}

void free_if_valid(RD *p_rd, RID p_rid) {
	if (p_rid.is_valid() && p_rd->uniform_set_is_valid(p_rid)) {
		p_rd->free_rid(p_rid);
		return;
	}
	if (p_rid.is_valid()) {
		p_rd->free_rid(p_rid);
	}
}

} // namespace

SelfTestResult run_self_test(RD *p_rd, const String &p_fixture_path, uint32_t p_pages,
		int p_cascades, const Vector3i &p_grid) {
	SelfTestResult result;

	// --- compile ------------------------------------------------------------
	String error;
	RID probe_shader = compile_compute(p_rd, SPARSE_PROBE_GLSL, &error);
	if (probe_shader.is_null()) {
		result.error = error;
		return result;
	}
	RID canary_write_shader = compile_compute(p_rd, SPARSE_CANARY_WRITE_GLSL, &error);
	RID canary_check_shader = compile_compute(p_rd, SPARSE_CANARY_CHECK_GLSL, &error);
	RID manage_shader = compile_compute(p_rd, SPARSE_MANAGE_GLSL, &error);
	if (canary_write_shader.is_null() || canary_check_shader.is_null() || manage_shader.is_null()) {
		result.error = error;
		p_rd->free_rid(probe_shader);
		return result;
	}

	RID probe_pipeline = p_rd->compute_pipeline_create(probe_shader);
	RID canary_write_pipeline = p_rd->compute_pipeline_create(canary_write_shader);
	RID canary_check_pipeline = p_rd->compute_pipeline_create(canary_check_shader);
	RID manage_pipeline = p_rd->compute_pipeline_create(manage_shader);
	if (probe_pipeline.is_null() || canary_write_pipeline.is_null() ||
			canary_check_pipeline.is_null() || manage_pipeline.is_null()) {
		result.error = "compute pipeline creation failed";
		return result;
	}

	// --- probe: translation parity against the CPU oracle -------------------
	{
		Error ferr = OK;
		Vector<uint8_t> fixtures = FileAccess::get_file_as_bytes(p_fixture_path, &ferr);
		if (fixtures.is_empty()) {
			result.error = vformat("fixture file unreadable: %s (err %d)", p_fixture_path, int(ferr));
		} else {
			const uint32_t count = uint32_t(fixtures.size()) / FIXTURE_RECORD_BYTES;
			result.probe_records = int(count);

			RID fixture_buf = p_rd->storage_buffer_create(uint32_t(fixtures.size()), fixtures);
			Vector<uint8_t> zero_results;
			zero_results.resize(count * PROBE_RESULT_BYTES);
			RID result_buf = p_rd->storage_buffer_create(uint32_t(zero_results.size()), zero_results);

			Vector<RD::Uniform> uniforms;
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, fixture_buf));
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, result_buf));
			RID uniform_set = p_rd->uniform_set_create(uniforms, probe_shader, 0);

			ProbePushConstants pc{};
			pc.count = count;
			pc.grid_x = uint32_t(p_grid.x);
			pc.grid_y = uint32_t(p_grid.y);
			pc.grid_z = uint32_t(p_grid.z);
			pc.cascade_count = uint32_t(p_cascades);
			pc.brick_dim_x = uint32_t(p_grid.x / BRICK_EDGE);
			pc.brick_dim_y = uint32_t(p_grid.y / BRICK_EDGE);
			pc.brick_dim_z = uint32_t(p_grid.z / BRICK_EDGE);
			pc.page_slots_x = 8;
			pc.page_slots_y = 8;

			RD::ComputeListID cl = p_rd->compute_list_begin();
			p_rd->compute_list_bind_compute_pipeline(cl, probe_pipeline);
			p_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);
			p_rd->compute_list_set_push_constant(cl, &pc, sizeof(pc));
			p_rd->compute_list_dispatch(cl, groups_for(count), 1, 1);
			p_rd->compute_list_end();

			Vector<uint8_t> out = p_rd->buffer_get_data(result_buf);
			if (out.size() >= count * PROBE_RESULT_BYTES) {
				for (uint32_t i = 0; i < count; i++) {
					uint32_t parity = 0;
					memcpy(&parity, out.ptr() + i * PROBE_RESULT_BYTES + 40, 4);
					if (parity != 1) {
						result.probe_mismatches++;
						if (result.probe_first_bad < 0) {
							result.probe_first_bad = int(i);
						}
					}
				}
			} else {
				result.error = "probe readback short";
			}

			p_rd->free_rid(uniform_set);
			p_rd->free_rid(fixture_buf);
			p_rd->free_rid(result_buf);
		}
	}

	// --- canary: atlas addressing on a real 3D texture ----------------------
	{
		const uint32_t slots_x = 8, slots_y = 8, slots_z = 16;
		RD::TextureFormat tf;
		tf.format = RD::DATA_FORMAT_R32_UINT;
		tf.texture_type = RD::TEXTURE_TYPE_3D;
		tf.width = slots_x * BRICK_EDGE;
		tf.height = slots_y * BRICK_EDGE;
		tf.depth = slots_z * BRICK_EDGE;
		// CAN_COPY_FROM is required for texture_get_data; without it the readback
		// silently returns zero bytes.
		tf.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT |
				RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		RID atlas = p_rd->texture_create(tf, RD::TextureView());

		if (atlas.is_null()) {
			result.error = "atlas texture creation failed";
		} else {
			const uint32_t pages = slots_x * slots_y * slots_z;
			result.canary_texels = int(pages * VOXELS_PER_BRICK);

			Vector<RD::Uniform> write_uniforms;
			write_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 0, atlas));
			RID write_set = p_rd->uniform_set_create(write_uniforms, canary_write_shader, 0);

			CanaryPushConstants pc{};
			pc.page_count = pages;
			pc.page_slots_x = slots_x;
			pc.page_slots_y = slots_y;
			pc.offset = 0;

			const uint32_t groups = groups_for(pages * VOXELS_PER_BRICK);

			RD::ComputeListID cl = p_rd->compute_list_begin();
			p_rd->compute_list_bind_compute_pipeline(cl, canary_write_pipeline);
			p_rd->compute_list_bind_uniform_set(cl, write_set, 0);
			p_rd->compute_list_set_push_constant(cl, &pc, sizeof(pc));
			p_rd->compute_list_dispatch(cl, groups, 1, 1);
			p_rd->compute_list_end();

			// Verify by reading the atlas back and comparing on the CPU. This is
			// stronger than a second kernel: it checks the texels that were actually
			// written, and cannot be fooled by a check pass that silently no-ops.
			Vector<uint8_t> texels = p_rd->texture_get_data(atlas, 0);
			if (texels.size() < int64_t(pages) * VOXELS_PER_BRICK * 4) {
				result.error = vformat("atlas readback short: %d bytes", int(texels.size()));
				result.canary_mismatches = -1;
			} else {
				const uint32_t *t = reinterpret_cast<const uint32_t *>(texels.ptr());
				int bad = 0;
				for (uint32_t page = 0; page < pages; page++) {
					for (uint32_t local_index = 0; local_index < VOXELS_PER_BRICK; local_index++) {
						const uint32_t lx = local_index & 7u;
						const uint32_t ly = (local_index >> 3) & 7u;
						const uint32_t lz = (local_index >> 6) & 7u;
						const uint32_t bx = page % slots_x;
						const uint32_t by = (page / slots_x) % slots_y;
						const uint32_t bz = page / (slots_x * slots_y);
						const uint32_t x = bx * BRICK_EDGE + lx;
						const uint32_t y = by * BRICK_EDGE + ly;
						const uint32_t z = bz * BRICK_EDGE + lz;
						const size_t offset = size_t(x) + size_t(y) * tf.width + size_t(z) * size_t(tf.width) * size_t(tf.height);
						const uint32_t expected = (page << 9) | local_index;
						if (t[offset] != expected) {
							bad++;
						}
					}
				}
				result.canary_mismatches = bad;
			}

			p_rd->free_rid(write_set);
			p_rd->free_rid(atlas);
		}
	}

	// --- allocator: compaction, allocation, commit -------------------------
	{
		const uint32_t slot_count = 4096;
		const uint32_t capacity = 256;
		const uint32_t request_count = 300;

		Vector<uint8_t> table_bytes;
		table_bytes.resize(slot_count * PAGE_ENTRY_BYTES);
		memset(table_bytes.ptrw(), 0, table_bytes.size());
		{
			uint32_t *p = reinterpret_cast<uint32_t *>(table_bytes.ptrw());
			for (uint32_t i = 0; i < slot_count; i++) {
				p[i * 4 + 0] = 0xFFFFFFFFu; // page_id = INVALID
				p[i * 4 + 2] = 0; // UNMAPPED
			}
		}

		Vector<uint8_t> free_bytes;
		free_bytes.resize(capacity * 4);
		{
			uint32_t *p = reinterpret_cast<uint32_t *>(free_bytes.ptrw());
			for (uint32_t i = 0; i < capacity; i++) {
				p[i] = i;
			}
		}

		const uint32_t word_count = (slot_count + 31) / 32;
		Vector<uint8_t> request_bytes;
		request_bytes.resize(word_count * 4);
		memset(request_bytes.ptrw(), 0, request_bytes.size());
		{
			uint32_t *p = reinterpret_cast<uint32_t *>(request_bytes.ptrw());
			for (uint32_t i = 0; i < request_count; i++) {
				const uint32_t slot = 100 + i;
				p[slot / 32] |= (1u << (slot % 32));
			}
		}

		Vector<uint8_t> zeros_counters;
		zeros_counters.resize(COUNTERS_BYTES);
		Vector<uint8_t> zeros_cursor;
		zeros_cursor.resize(4);
		Vector<uint8_t> compacted_bytes;
		compacted_bytes.resize(slot_count * 4);
		Vector<uint8_t> allocated_bytes;
		allocated_bytes.resize(capacity * 4);
		Vector<uint8_t> meta_bytes;
		meta_bytes.resize(capacity * BRICK_META_BYTES);

		RID table_buf = p_rd->storage_buffer_create(uint32_t(table_bytes.size()), table_bytes);
		RID meta_buf = p_rd->storage_buffer_create(uint32_t(meta_bytes.size()), meta_bytes);
		RID free_buf = p_rd->storage_buffer_create(uint32_t(free_bytes.size()), free_bytes);
		RID cursor_buf = p_rd->storage_buffer_create(4, zeros_cursor);
		RID request_buf = p_rd->storage_buffer_create(uint32_t(request_bytes.size()), request_bytes);
		RID compacted_buf = p_rd->storage_buffer_create(uint32_t(compacted_bytes.size()), compacted_bytes);
		RID counters_buf = p_rd->storage_buffer_create(COUNTERS_BYTES, zeros_counters);
		RID allocated_buf = p_rd->storage_buffer_create(uint32_t(allocated_bytes.size()), allocated_bytes);

		Vector<RD::Uniform> uniforms;
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, table_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, meta_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, free_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, cursor_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, request_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 5, compacted_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 6, counters_buf));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 7, allocated_buf));
		RID manage_set = p_rd->uniform_set_create(uniforms, manage_shader, 0);

		ManagePushConstants pc{};
		pc.word_count = word_count;
		pc.slot_count = slot_count;
		pc.capacity = capacity;
		pc.epoch = 1;
		pc.generation_base = 1000;
		pc.bricks_per_cascade = uint32_t((p_grid.x / BRICK_EDGE) * (p_grid.y / BRICK_EDGE) * (p_grid.z / BRICK_EDGE));
		pc.brick_dim_x = uint32_t(p_grid.x / BRICK_EDGE);
		pc.brick_dim_y = uint32_t(p_grid.y / BRICK_EDGE);
		pc.brick_dim_z = uint32_t(p_grid.z / BRICK_EDGE);

		RD::ComputeListID cl = p_rd->compute_list_begin();
		p_rd->compute_list_bind_compute_pipeline(cl, manage_pipeline);
		p_rd->compute_list_bind_uniform_set(cl, manage_set, 0);

		pc.mode = MODE_COMPACT;
		p_rd->compute_list_set_push_constant(cl, &pc, sizeof(pc));
		p_rd->compute_list_dispatch(cl, groups_for(word_count), 1, 1);
		p_rd->compute_list_add_barrier(cl);

		// Allocate is dispatched over every slot, not just capacity: the compacted
		// list can be longer than the pool, and the overflow branch must be reachable.
		pc.mode = MODE_ALLOCATE;
		p_rd->compute_list_set_push_constant(cl, &pc, sizeof(pc));
		p_rd->compute_list_dispatch(cl, groups_for(slot_count), 1, 1);
		p_rd->compute_list_add_barrier(cl);

		pc.mode = MODE_INITIALIZE;
		p_rd->compute_list_set_push_constant(cl, &pc, sizeof(pc));
		p_rd->compute_list_dispatch(cl, groups_for(capacity), 1, 1);
		p_rd->compute_list_end();

		Vector<uint8_t> counters = p_rd->buffer_get_data(counters_buf);
		Vector<uint8_t> table_out = p_rd->buffer_get_data(table_buf);
		if (counters.size() >= 20 && table_out.size() >= slot_count * PAGE_ENTRY_BYTES) {
			uint32_t c[5] = { 0, 0, 0, 0, 0 };
			memcpy(c, counters.ptr(), 20);
			result.allocator_compacted = c[1];
			result.allocator_allocated = c[2];
			result.allocator_overflow = c[3];
			result.allocator_committed = c[4];

			// Duplicate-page check over the requested slots.
			const uint32_t *table = reinterpret_cast<const uint32_t *>(table_out.ptr());
			bool seen[256] = { false };
			for (uint32_t i = 0; i < request_count; i++) {
				const uint32_t slot = 100 + i;
				const uint32_t page = table[slot * 4 + 0];
				const uint32_t state = table[slot * 4 + 2];
				if (state == 4 && page < capacity) { // COMMITTED
					if (seen[page]) {
						result.allocator_duplicate_pages++;
					}
					seen[page] = true;
				}
			}

			result.allocator_ok = result.allocator_compacted == request_count &&
					result.allocator_allocated == MIN(request_count, capacity) &&
					result.allocator_overflow == request_count - MIN(request_count, capacity) &&
					result.allocator_committed == MIN(request_count, capacity) &&
					result.allocator_duplicate_pages == 0;
		} else {
			result.error = "allocator readback short";
		}

		p_rd->free_rid(manage_set);
		p_rd->free_rid(table_buf);
		p_rd->free_rid(meta_buf);
		p_rd->free_rid(free_buf);
		p_rd->free_rid(cursor_buf);
		p_rd->free_rid(request_buf);
		p_rd->free_rid(compacted_buf);
		p_rd->free_rid(counters_buf);
		p_rd->free_rid(allocated_buf);
	}

	p_rd->free_rid(probe_pipeline);
	p_rd->free_rid(canary_write_pipeline);
	p_rd->free_rid(canary_check_pipeline);
	p_rd->free_rid(manage_pipeline);
	p_rd->free_rid(probe_shader);
	p_rd->free_rid(canary_write_shader);
	p_rd->free_rid(canary_check_shader);
	p_rd->free_rid(manage_shader);

	result.ran = true;
	result.passed = result.error.is_empty() && result.probe_mismatches == 0 &&
			result.canary_mismatches == 0 && result.allocator_ok;
	return result;
}

} // namespace hddagi_sparse
