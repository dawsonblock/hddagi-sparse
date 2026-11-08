extends Node3D

# Phase 2 benchmark harness.
#
# Runs a fixed camera path over a fixed scene and records per-frame timings, then
# writes a JSON summary. Nothing here changes engine behaviour: it only reads the
# viewport render-time counters that RenderingDevice already maintains.
#
# Environment:
#   BENCH_SCENE    forest | empty | room          (default forest)
#   BENCH_CAMERA   static | move | teleport       (default static)
#   BENCH_WARMUP   frames discarded before measuring (default 120)
#   BENCH_FRAMES   frames measured                   (default 300)
#   BENCH_GI       on | off                          (default on)
#   BENCH_OUT      output json path                  (default /tmp/hddagi_bench.json)
#   BENCH_TAG      label copied into the summary
#   HDDAGI_TREES   tree count for the forest scene   (default 600)

const CLEARING := 9.0
const TERRAIN_SIZE := 400.0
const TERRAIN_RES := 96
const TERRAIN_AMPLITUDE := 1.8

const TREE_SPECIES := ["oak", "elm", "pine"]

# Distance rings for tree and shadow LOD, in metres from the scene origin. The
# static benchmark camera stands in the clearing, so this is distance from the
# viewer there; the teleport camera is an approximation (see artifacts/lod.md).
const LOD_NEAR := 35.0
const LOD_MID := 75.0

# Camera-relative rings are rebuilt when the camera moves this far, so the bands
# describe distance from the viewer rather than distance from the origin.
const LOD_REBUILD_DISTANCE := 5.0

# The move/teleport camera paths are indexed on the frame counter, not wall time,
# so every configuration visits the identical viewpoint on the identical frame.
# A faster configuration must not get a different (easier) camera path. The
# constants roughly reproduce the old 1.4 m/s wall-clock path at ~35 ms/frame.
const MOVE_M_PER_FRAME := 0.05
const MOVE_RAD_PER_FRAME := 0.0065

# preload rather than class_name: the harness must work on a project whose
# global script class cache has not been regenerated yet.
const CaptureStatsScript = preload("res://capture_stats.gd")

# BENCH_TREE_LOD selects which pre-authored LOD every tree uses, to price the cost of
# rendering the whole forest at full detail.
func _tree_paths() -> Array:
	var lod := int(_env("BENCH_TREE_LOD", "0"))
	var out: Array = []
	for species in TREE_SPECIES:
		out.append("res://demo/foliage/models/%s_lod%d.res" % [species, lod])
	return out

const TELEPORT_POINTS := [
	Vector3(0.0, 1.9, 0.0),
	Vector3(38.0, 2.4, -22.0),
	Vector3(-31.0, 2.1, 17.0),
	Vector3(12.0, 3.4, 44.0),
]

var _noise := FastNoiseLite.new()
var _lod_near := LOD_NEAR
var _lod_mid := LOD_MID

# Forest state kept for camera-relative LOD rebuilds. The transform arrays are
# generated once; only the per-ring instance lists are rewritten on movement.
var _forest_xforms: Array = []
var _forest_nodes: Array = []
var _forest_meshes: Array = []
var _forest_lods: Array = []
var _forest_rings := false
var _forest_lod_enabled := false
var _forest_shadow_lod := "off"
var _forest_tree_shadows := true
var _forest_built_at := Vector3.ZERO
var _forest_camera_relative := true
var _cam: Camera3D
var _sun: DirectionalLight3D
var _env_res: Environment

var _state := "setup"
var _failed := false
var _frame_idx := 0
var _frame_total := 0
var _teleport_period := 25
var _last_usec := 0
var _samples: Array = []
var _warmup := 120
var _frames := 300
var _camera_mode := "static"
var _tag := ""
var _out := "/tmp/hddagi_bench.json"
var _gi_on := true
var _scene_name := "forest"
var _tree_count := 600
var _start_usec := 0
var _t_ready_start := 0
var _t_scene_built := 0
var _t_measure_start := 0
var _t_measure_end := 0
var _cut_frame := 10
var _snap_frames: Array = []
var _snap_dir := "/tmp/hddagi_snap"

func _ready() -> void:
	_t_ready_start = Time.get_ticks_msec()
	print("BENCH_TIMING t_ready_start_ms=", _t_ready_start)
	_scene_name = _env("BENCH_SCENE", "forest")
	_camera_mode = _env("BENCH_CAMERA", "static")
	_warmup = int(_env("BENCH_WARMUP", "120"))
	_frames = int(_env("BENCH_FRAMES", "300"))
	_out = _env("BENCH_OUT", "/tmp/hddagi_bench.json")
	_tag = _env("BENCH_TAG", "")
	_gi_on = _env("BENCH_GI", "on") == "on"
	_tree_count = int(_env("HDDAGI_TREES", "600"))
	_cut_frame = int(_env("BENCH_CUT_FRAME", "10"))
	_snap_dir = _env("BENCH_SNAP_DIR", "/tmp/hddagi_snap")
	_lod_near = float(_env("BENCH_LOD_NEAR", str(LOD_NEAR)))
	_lod_mid = float(_env("BENCH_LOD_MID", str(LOD_MID)))
	_forest_camera_relative = _env("BENCH_LOD_CAMERA", "1") != "0"
	_teleport_period = maxi(1, int(_env("BENCH_TELEPORT_PERIOD", "25")))
	var snap_spec := _env("BENCH_SNAP", "")
	if snap_spec != "":
		for s in snap_spec.split(","):
			_snap_frames.append(int(s))
		DirAccess.make_dir_recursive_absolute(_snap_dir)

	# Uncapped so frame time reflects work, not the display refresh.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	# The window is clamped to the display work area otherwise, which silently changes
	# the render resolution between machines. Pin it and record what was actually used.
	var req_w := int(_env("BENCH_WIDTH", "1600"))
	var req_h := int(_env("BENCH_HEIGHT", "900"))
	DisplayServer.window_set_size(Vector2i(req_w, req_h))
	DisplayServer.window_set_position(Vector2i(40, 40))

	_noise.seed = 4242
	_noise.frequency = 0.012
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0

	var adapter := RenderingServer.get_video_adapter_name()
	if adapter.is_empty():
		_fail("no rendering adapter reported")
		return

	_add_environment()
	_add_sun()
	_add_camera()

	match _scene_name:
		"empty":
			pass
		"room":
			_add_room()
		_:
			_add_terrain()
			_add_backdrop()
			if _tree_count > 0:
				_add_forest(_tree_count, clampf(sqrt(float(_tree_count) * 26.0 / PI), 16.0, 190.0))

	if _failed:
		return

	_t_scene_built = Time.get_ticks_msec()
	print("BENCH_TIMING t_scene_built_ms=", _t_scene_built)

	var vp := get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	# BENCH_MSAA sets the Viewport.MSAA enum value directly (0 disables); unset
	# keeps the project value. The effective value is recorded in the JSON.
	var msaa_env := OS.get_environment("BENCH_MSAA")
	if msaa_env != "":
		vp.msaa_3d = int(msaa_env)

	print("BENCH_READY scene=", _scene_name, " camera=", _camera_mode, " gi=", _gi_on,
			" trees=", _tree_count, " warmup=", _warmup, " frames=", _frames, " tag=", _tag)
	print("BENCH_VIEWPORT size=", vp.get_visible_rect().size, " window=", DisplayServer.window_get_size())

	_start_usec = Time.get_ticks_usec()
	_last_usec = _start_usec
	_state = "warmup"

func _process(_delta: float) -> void:
	if _state == "done":
		return
	_frame_total += 1
	_update_camera()
	_maybe_rebuild_lod()

	match _state:
		"warmup":
			_frame_idx += 1
			if _frame_idx >= _warmup:
				_state = "measure"
				_frame_idx = 0
				_samples.clear()
				_last_usec = Time.get_ticks_usec()
				_t_measure_start = Time.get_ticks_msec()
				print("BENCH_TIMING t_measure_start_ms=", _t_measure_start)
		"measure":
			var now := Time.get_ticks_usec()
			var frame_ms := float(now - _last_usec) / 1000.0
			_last_usec = now
			_frame_idx += 1

			# The counters report the previously completed frame; over hundreds of
			# samples the one-frame offset is irrelevant, so they are sampled as-is.
			var vp_rid := get_viewport().get_viewport_rid()
			_samples.append({
				"frame_ms": frame_ms,
				"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(vp_rid),
				"cpu_render_ms": RenderingServer.viewport_get_measured_render_time_cpu(vp_rid),
				"static_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
				"objects": float(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
				"prims": float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			})

			if _frame_idx >= _frames:
				_finish()
				return

			if _snap_frames.has(_frame_idx):
				_snap(_frame_idx)
		"capture":
			# The capture is deliberately after the measured frames: the synchronous
			# readback costs ~700 ms and must not be in the timings.
			_state = "done"
			_capture_and_quit()

func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	print("BENCH_FAILED reason=", reason)
	_state = "done"
	get_tree().quit(2)

func _update_camera() -> void:
	if _cam == null:
		return
	# Indexed on _frame_total: the viewpoint on frame N is a pure function of N,
	# identical for every configuration. Wall-clock indexing would let a faster
	# config visit viewpoints a slower one never reaches.
	match _camera_mode:
		"move":
			var dist := fmod(_frame_total * MOVE_M_PER_FRAME, 24.0)
			var ang := _frame_total * MOVE_RAD_PER_FRAME
			var px := cos(ang) * (CLEARING + dist)
			var pz := sin(ang) * (CLEARING + dist)
			_cam.position = Vector3(px, 1.9 + _height(px, pz), pz)
			_cam.rotation = Vector3(deg_to_rad(-6.0), -ang + PI * 0.5, 0.0)
		"teleport":
			var idx := int(_frame_total / _teleport_period) % TELEPORT_POINTS.size()
			var p: Vector3 = TELEPORT_POINTS[idx]
			_cam.position = Vector3(p.x, p.y + _height(p.x, p.z), p.z)
			_cam.rotation = Vector3(deg_to_rad(-8.0), float(idx) * 1.1, 0.0)
		"cut":
			# One deterministic cut at a known measurement frame, so frames either side
			# of it can be captured and compared across configurations.
			var idx := 1 if (_state == "measure" and _frame_idx >= _cut_frame) else 0
			var p: Vector3 = TELEPORT_POINTS[idx]
			_cam.position = Vector3(p.x, p.y + _height(p.x, p.z), p.z)
			_cam.rotation = Vector3(deg_to_rad(-8.0), float(idx) * 1.1, 0.0)

func _finish() -> void:
	_state = "done"
	_t_measure_end = Time.get_ticks_msec()
	print("BENCH_TIMING t_measure_end_ms=", _t_measure_end)
	var ft: Array = []
	var gp: Array = []
	for s in _samples:
		ft.append(s["frame_ms"])
		gp.append(s["gpu_ms"])

	var summary := {
		"tag": _tag,
		"scene": _scene_name,
		"camera": _camera_mode,
		"gi": _gi_on,
		"trees": _tree_count,
		"warmup_frames": _warmup,
		"measured_frames": _samples.size(),
		"viewport": str(get_viewport().get_visible_rect().size),
		"window": str(DisplayServer.window_get_size()),
		"device": RenderingServer.get_video_adapter_name(),
		"frame_ms": _stats(ft),
		"gpu_ms": _stats(gp),
		# Metal in this fork has no timestamp queries, so gpu_ms is structurally 0.
		# Recorded explicitly so a reader cannot mistake 0.0 for "free".
		"gpu_timing_available": _mean(gp) > 0.0,
		"cpu_render_ms": _stats(_column("cpu_render_ms")),
		"fps_from_frame_ms": 1000.0 / maxf(_mean(ft), 0.001),
		"static_mb": _stats(_column("static_mb")),
		"objects": _mean(_column("objects")),
		"prims": _mean(_column("prims")),
		# Process-relative milliseconds, so cold start and the measurement window can
		# be read back from the artifact without timestamps in the log.
		"timing_ms": {
			"ready_start": _t_ready_start,
			"scene_built": _t_scene_built,
			"measure_start": _t_measure_start,
			"measure_end": _t_measure_end,
		},
		# A run that snaps frames does a synchronous readback inside the measured
		# window, so its timings are labelled unusable rather than silently
		# contaminated. Timing runs never set BENCH_SNAP.
		"run_kind": "quality" if not _snap_frames.is_empty() else "timing",
		"timing_usable": _snap_frames.is_empty(),
		"snap_frames": _snap_frames,
		# cache_state is supplied by the runner (cold = Godot shader cache moved
		# aside; warm = present from a prior run; unknown = not recorded).
		"cache_state": _env("BENCH_CACHE_STATE", "unknown"),
		"settings": _effective_settings(),
		"trajectory": _trajectory_info(),
	}
	# Raw samples kept only for the offline percentile check, not in the summary.
	summary["raw_frame_ms"] = ft

	var f := FileAccess.open(_out, FileAccess.WRITE)
	if f == null:
		print("BENCH_FAILED cannot write ", _out)
	else:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
		print("BENCH_WROTE ", _out)

	print("BENCH_RESULT tag=", _tag, " scene=", _scene_name, " camera=", _camera_mode,
			" gi=", _gi_on, " trees=", _tree_count,
			" frame_p50=", "%.3f" % summary["frame_ms"]["p50"],
			" frame_p95=", "%.3f" % summary["frame_ms"]["p95"],
			" cpu_render_p50=", "%.3f" % summary["cpu_render_ms"]["p50"],
			" fps=", "%.1f" % summary["fps_from_frame_ms"],
			" gpu_timing=", summary["gpu_timing_available"],
			" viewport=", summary["viewport"],
			" static_mb=", "%.1f" % summary["static_mb"]["p50"])

	# Capture proof of content after the measurement, then quit. A run that loaded
	# no trees or lost its textures can otherwise look like a very fast benchmark.
	_state = "capture"

# The effective toggle set the run actually used, read back from the live nodes
# rather than the requested environment, so the JSON cannot drift from reality.
func _effective_settings() -> Dictionary:
	var d := {
		"scene": _scene_name,
		"camera": _camera_mode,
		"trees": _tree_count,
		"warmup": _warmup,
		"frames": _frames,
		"cut_frame": _cut_frame,
		"tree_lod_mode": "rings" if _forest_lod_enabled else "off",
		"tree_lod_mesh_level": int(_env("BENCH_TREE_LOD", "0")),
		"lod_camera_relative": _forest_camera_relative,
		"lod_near_m": _lod_near,
		"lod_mid_m": _lod_mid,
		"shadow_lod": _forest_shadow_lod,
		"sun_shadow": _sun.shadow_enabled if _sun != null else false,
		"tree_cast_shadow": _forest_tree_shadows,
		"grass_cast_shadow": _flag("BENCH_GRASS_SHADOW", false),
		"shadow_distance_m": _sun.directional_shadow_max_distance if _sun != null else 0.0,
	}
	var vp := get_viewport()
	if vp != null:
		d["msaa_3d"] = vp.msaa_3d
		d["viewport_size"] = str(vp.get_visible_rect().size)
	if _env_res != null:
		d["gi"] = _env_res.dynamic_gi_enabled
		d["gi_cascades"] = _env_res.dynamic_gi_cascades
		d["ssao"] = _env_res.ssao_enabled
		d["fog"] = _env_res.fog_enabled
		d["volumetric_fog"] = _env_res.volumetric_fog_enabled
		d["glow"] = _env_res.glow_enabled
	return d

func _trajectory_info() -> Dictionary:
	var jumps: Array = []
	if _camera_mode == "teleport":
		for i in range(1, _frames + 1):
			if int((_warmup + i) / _teleport_period) != int((_warmup + i - 1) / _teleport_period):
				jumps.append(i)
	return {
		"indexed_by": "frame",
		"move_m_per_frame": MOVE_M_PER_FRAME,
		"move_rad_per_frame": MOVE_RAD_PER_FRAME,
		"teleport_period_frames": _teleport_period,
		"teleport_measured_frames": jumps,
	}

func _capture_and_quit() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("BENCH_FAILED reason=capture readback returned null")
		get_tree().quit(2)
		return
	print("BENCH_CAPTURE_STATS %s" % JSON.stringify(CaptureStatsScript.of(img)))
	get_tree().quit()

func _snap(idx: int) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("SNAP_FAILED ", idx)
		return
	var label := _tag if _tag != "" else "snap"
	var path := _snap_dir.path_join("%s_f%03d.png" % [label, idx])
	var err := img.save_png(path)
	print("SNAP ", path, " err=", err)

func _column(key: String) -> Array:
	var out: Array = []
	for s in _samples:
		out.append(s[key])
	return out

func _mean(v: Array) -> float:
	if v.is_empty():
		return 0.0
	var total := 0.0
	for x in v:
		total += float(x)
	return total / float(v.size())

func _stats(v: Array) -> Dictionary:
	if v.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "min": 0.0, "max": 0.0}
	var sorted := v.duplicate()
	sorted.sort()
	return {
		"mean": _mean(sorted),
		"p50": _pct(sorted, 0.50),
		"p95": _pct(sorted, 0.95),
		"p99": _pct(sorted, 0.99),
		"min": float(sorted[0]),
		"max": float(sorted[sorted.size() - 1]),
	}

func _pct(sorted: Array, p: float) -> float:
	var idx := int(round(p * float(sorted.size() - 1)))
	return float(sorted[clampi(idx, 0, sorted.size() - 1)])

func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key)
	return v if v != "" else fallback

# Feature toggle: BENCH_<NAME>=0 disables, =1 enables, unset returns `fallback`.
# Used to price individual render features.
func _flag(key: String, fallback: bool) -> bool:
	var v := OS.get_environment(key)
	if v == "":
		return fallback
	return v != "0"

func _add_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.30, 0.44, 0.62)
	sky_mat.sky_horizon_color = Color(0.72, 0.72, 0.70)
	sky_mat.ground_horizon_color = Color(0.42, 0.40, 0.34)
	sky_mat.ground_bottom_color = Color(0.20, 0.19, 0.16)
	sky_mat.sun_angle_max = 12.0
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.2

	env.ssao_enabled = _flag("BENCH_SSAO", true)
	env.ssao_radius = 1.6
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6

	env.volumetric_fog_enabled = _flag("BENCH_VOLFOG", true)
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.85, 0.87, 0.90)
	env.volumetric_fog_emission = Color(0.02, 0.02, 0.02)
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_length = 96.0

	env.fog_enabled = _flag("BENCH_FOG", true)
	env.fog_light_color = Color(0.66, 0.70, 0.74)
	env.fog_density = 0.004

	env.glow_enabled = _flag("BENCH_GLOW", true)
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.0

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05

	env.dynamic_gi_enabled = _gi_on
	env.dynamic_gi_cascades = int(_env("BENCH_CASCADES", "6"))
	env.dynamic_gi_cascade_format = Environment.DYNAMIC_GI_CASCADE_FORMAT_16x8x16
	env.dynamic_gi_min_cell_size = 0.15
	env.dynamic_gi_read_sky_light = true

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_env_res = env

func _add_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-22.0, 38.0, 0.0)
	_sun.light_energy = 2.0
	_sun.light_color = Color(1.0, 0.94, 0.84)
	_sun.shadow_enabled = _flag("BENCH_SHADOWS", true)
	_sun.directional_shadow_max_distance = float(_env("BENCH_SHADOW_DISTANCE", "150"))
	_sun.directional_shadow_blend_splits = true
	add_child(_sun)

func _add_camera() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.position = Vector3(0.0, 1.9 + _height(0.0, 0.0), 0.0)
	_cam.look_at(Vector3(0.0, 7.0, -16.0), Vector3.UP)
	_cam.current = true
	_cam.fov = 72.0

func _height(x: float, z: float) -> float:
	var d := sqrt(x * x + z * z)
	var fade := clampf((d - CLEARING) / 18.0, 0.0, 1.0)
	return _noise.get_noise_2d(x, z) * TERRAIN_AMPLITUDE * fade

func _add_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step := TERRAIN_SIZE / float(TERRAIN_RES)
	var half := TERRAIN_SIZE * 0.5
	var uv_scale := 26.0

	for z in range(TERRAIN_RES):
		for x in range(TERRAIN_RES):
			var x0 := -half + x * step
			var z0 := -half + z * step
			var x1 := x0 + step
			var z1 := z0 + step
			var p00 := Vector3(x0, _height(x0, z0), z0)
			var p10 := Vector3(x1, _height(x1, z0), z0)
			var p01 := Vector3(x0, _height(x0, z1), z1)
			var p11 := Vector3(x1, _height(x1, z1), z1)

			st.set_uv(Vector2(x0, z0) / uv_scale)
			st.add_vertex(p00)
			st.set_uv(Vector2(x1, z0) / uv_scale)
			st.add_vertex(p10)
			st.set_uv(Vector2(x0, z1) / uv_scale)
			st.add_vertex(p01)

			st.set_uv(Vector2(x1, z0) / uv_scale)
			st.add_vertex(p10)
			st.set_uv(Vector2(x1, z1) / uv_scale)
			st.add_vertex(p11)
			st.set_uv(Vector2(x0, z1) / uv_scale)
			st.add_vertex(p01)

	st.generate_normals()
	st.generate_tangents()
	var mesh := st.commit()

	var node := MeshInstance3D.new()
	node.mesh = mesh

	var mat := StandardMaterial3D.new()
	var albedo := load("res://demo/terrain/forest_ah.png")
	if not (albedo is Texture2D):
		_fail("terrain albedo failed to load: res://demo/terrain/forest_ah.png")
		return
	mat.albedo_texture = albedo
	mat.albedo_color = Color(0.78, 0.80, 0.74)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(1, 1, 1)
	node.material_override = mat
	add_child(node)

func _add_backdrop() -> void:
	var node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3000.0, 3000.0)
	node.mesh = plane
	node.position = Vector3(0.0, -1.5, 0.0)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.20, 0.12)
	mat.roughness = 1.0
	node.material_override = mat
	add_child(node)

func _add_forest(count: int, radius: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 987654

	var meshes: Array[Mesh] = []
	for path in _tree_paths():
		var m := load(path)
		if m is Mesh:
			meshes.append(m)
		else:
			_fail("tree mesh failed to load: " + path)
			return

	if meshes.size() != TREE_SPECIES.size():
		_fail("expected %d tree species, loaded %d" % [TREE_SPECIES.size(), meshes.size()])
		return

	# Distribute the remainder so exactly `count` trees are rendered. ceil() per
	# species renders up to two more than the label and the JSON report claim.
	var per_species := floori(float(count) / float(meshes.size()))
	var remainder := count % meshes.size()
	var made := 0
	_forest_tree_shadows = _flag("BENCH_TREE_SHADOW", true)
	_forest_lod_enabled = _env("BENCH_LOD", "off") == "rings"
	_forest_shadow_lod = _env("BENCH_SHADOW_LOD", "off")
	_forest_rings = _forest_lod_enabled or _forest_shadow_lod != "off"
	_forest_meshes = meshes
	_forest_lods = []
	if _forest_lod_enabled:
		_forest_lods = _load_lod_meshes()
		if _failed:
			return

	for species in range(meshes.size()):
		var instances := per_species + (1 if species < remainder else 0)
		made += instances
		# Generate every transform before splitting so the RNG stream does not
		# depend on the ring configuration: LOD on and off place every tree
		# identically, which is what makes the image comparison meaningful.
		var xforms: Array[Transform3D] = []
		for i in range(instances):
			var angle := rng.randf() * TAU
			var dist := CLEARING + sqrt(rng.randf()) * (radius - CLEARING)
			var px := cos(angle) * dist
			var pz := sin(angle) * dist
			var pos := Vector3(px, _height(px, pz) - 0.15, pz)
			var s := 0.70 + rng.randf() * 0.45
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			xforms.append(Transform3D(basis, pos))
		_forest_xforms.append(xforms)

		if not _forest_rings:
			_add_multimesh(meshes[species], xforms, _forest_tree_shadows)
			continue

		# Create one node per ring up front. Camera movement rewrites instance
		# transforms and meshes; it never creates or frees nodes.
		var nodes: Array = []
		for band in range(3):
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = 0
			mm.mesh = meshes[species]
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			add_child(node)
			nodes.append(node)
		_forest_nodes.append(nodes)

	if _forest_rings:
		_forest_built_at = _cam.position if _cam else Vector3.ZERO
		_apply_forest_rings(_forest_built_at)

	if made != count:
		_fail("tree instances %d != requested %d" % [made, count])
		return

	var grass := load("res://demo/foliage/models/grass_lod0.res")
	if not (grass is Mesh):
		_fail("grass mesh failed to load: res://demo/foliage/models/grass_lod0.res")
		return
	var gm := MultiMesh.new()
	gm.transform_format = MultiMesh.TRANSFORM_3D
	gm.instance_count = count * 8
	gm.mesh = grass
	for i in range(count * 8):
		var angle := rng.randf() * TAU
		var dist := sqrt(rng.randf()) * radius
		var px := cos(angle) * dist
		var pz := sin(angle) * dist
		var pos := Vector3(px, _height(px, pz) - 0.05, pz)
		var s := 0.8 + rng.randf() * 0.6
		gm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s, s)), pos))
	var gn := MultiMeshInstance3D.new()
	gn.multimesh = gm
	if not _flag("BENCH_GRASS_SHADOW", false):
		gn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gn)

# Near/mid/far by distance from the viewer. `center` is the camera position used
# for the current ring build; camera-relative rebuilds replace it when the camera
# moves more than LOD_REBUILD_DISTANCE.
func _split_bands(xforms: Array, center: Vector3) -> Array:
	var bands: Array = [[], [], []]
	for t in xforms:
		var d := Vector2(t.origin.x - center.x, t.origin.z - center.z).length()
		var band := 0
		if d >= _lod_mid:
			band = 2
		elif d >= _lod_near:
			band = 1
		bands[band].append(t)
	return bands

func _band_mesh(species: int, band: int) -> Mesh:
	if _forest_lod_enabled:
		var lods: Array = _forest_lods[species]
		if not lods.is_empty():
			return lods[mini(band, lods.size() - 1)]
	return _forest_meshes[species]

func _apply_forest_rings(center: Vector3) -> void:
	for species in range(_forest_xforms.size()):
		var bands := _split_bands(_forest_xforms[species], center)
		for band in range(3):
			var node: MultiMeshInstance3D = _forest_nodes[species][band]
			var mm := node.multimesh
			var xforms: Array = bands[band]
			mm.instance_count = xforms.size()
			mm.mesh = _band_mesh(species, band)
			for i in range(xforms.size()):
				mm.set_instance_transform(i, xforms[i])
			var shadows := _forest_tree_shadows
			if _forest_shadow_lod == "far" and band == 2:
				shadows = false
			elif _forest_shadow_lod == "near" and band > 0:
				shadows = false
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _maybe_rebuild_lod() -> void:
	if not _forest_rings or not _forest_camera_relative or _cam == null:
		return
	var d := Vector2(_cam.position.x - _forest_built_at.x,
			_cam.position.z - _forest_built_at.z).length()
	if d < LOD_REBUILD_DISTANCE:
		return
	_forest_built_at = _cam.position
	_apply_forest_rings(_forest_built_at)

func _add_multimesh(mesh: Mesh, xforms: Array, shadows: bool) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = xforms.size()
	mm.mesh = mesh
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	if not shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)

# Oak and pine ship lod0..lod3, elm lod0..lod2; three rings only need lod0..lod2.
func _load_lod_meshes() -> Array:
	var out: Array = []
	for species in TREE_SPECIES:
		var lods: Array[Mesh] = []
		for lod in range(3):
			var path := "res://demo/foliage/models/%s_lod%d.res" % [species, lod]
			var m := load(path)
			if not (m is Mesh):
				_fail("tree LOD mesh failed to load: " + path)
				return []
			lods.append(m)
		out.append(lods)
	return out

func _add_room() -> void:
	# Small enclosed room: stresses bounce lighting rather than foliage.
	var floor_node := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(12.0, 0.2, 12.0)
	floor_node.mesh = floor_mesh
	floor_node.position = Vector3(0.0, -0.1, 0.0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.72, 0.68, 0.60)
	floor_mat.roughness = 0.9
	floor_node.material_override = floor_mat
	add_child(floor_node)

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.80, 0.76, 0.70)
	wall_mat.roughness = 0.95

	var walls := [
		[Vector3(12.0, 4.0, 0.2), Vector3(0.0, 2.0, -6.0)],
		[Vector3(12.0, 4.0, 0.2), Vector3(0.0, 2.0, 6.0)],
		[Vector3(0.2, 4.0, 12.0), Vector3(-6.0, 2.0, 0.0)],
		[Vector3(0.2, 4.0, 12.0), Vector3(6.0, 2.0, 0.0)],
		[Vector3(12.0, 0.2, 12.0), Vector3(0.0, 4.0, 0.0)],
	]
	for w in walls:
		var n := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = w[0]
		n.mesh = b
		n.position = w[1]
		n.material_override = wall_mat
		add_child(n)

	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = Color(0.85, 0.30, 0.22)
	accent_mat.roughness = 0.5
	for i in range(5):
		var n := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = Vector3(0.8, 1.2, 0.8)
		n.mesh = b
		n.position = Vector3(-3.0 + i * 1.5, 0.6, -2.0 + i * 0.9)
		n.material_override = accent_mat
		add_child(n)

	_cam.position = Vector3(0.0, 1.6, 4.0)
	_cam.look_at(Vector3(0.0, 1.4, -4.0), Vector3.UP)
