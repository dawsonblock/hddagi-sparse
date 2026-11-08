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
var _cam: Camera3D
var _sun: DirectionalLight3D

var _state := "setup"
var _frame_idx := 0
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
var _cut_frame := 10
var _snap_frames: Array = []
var _snap_dir := "/tmp/hddagi_snap"

func _ready() -> void:
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

	var vp := get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	if OS.get_environment("BENCH_MSAA") == "0":
		vp.msaa_3d = Viewport.MSAA_DISABLED

	print("BENCH_READY scene=", _scene_name, " camera=", _camera_mode, " gi=", _gi_on,
			" trees=", _tree_count, " warmup=", _warmup, " frames=", _frames, " tag=", _tag)
	print("BENCH_VIEWPORT size=", vp.get_visible_rect().size, " window=", DisplayServer.window_get_size())

	_start_usec = Time.get_ticks_usec()
	_last_usec = _start_usec
	_state = "warmup"

func _process(_delta: float) -> void:
	_update_camera()

	match _state:
		"warmup":
			_frame_idx += 1
			if _frame_idx >= _warmup:
				_state = "measure"
				_frame_idx = 0
				_samples.clear()
				_last_usec = Time.get_ticks_usec()
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

func _update_camera() -> void:
	if _cam == null:
		return
	var t := float(Time.get_ticks_usec() - _start_usec) / 1000000.0
	match _camera_mode:
		"move":
			# Continuous forward drift through the clearing, 1.4 m/s, with a slow yaw.
			var dist := fmod(t * 1.4, 24.0)
			var ang := t * 0.18
			var px := cos(ang) * (CLEARING + dist)
			var pz := sin(ang) * (CLEARING + dist)
			_cam.position = Vector3(px, 1.9 + _height(px, pz), pz)
			_cam.rotation = Vector3(deg_to_rad(-6.0), -ang + PI * 0.5, 0.0)
		"teleport":
			var idx := int(t / 1.0) % TELEPORT_POINTS.size()
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

func _add_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-22.0, 38.0, 0.0)
	_sun.light_energy = 2.0
	_sun.light_color = Color(1.0, 0.94, 0.84)
	_sun.shadow_enabled = _flag("BENCH_SHADOWS", true)
	_sun.directional_shadow_max_distance = 150.0
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
	if albedo is Texture2D:
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
			push_warning("could not load tree mesh: " + path)

	if meshes.is_empty():
		push_error("no tree meshes loaded")
		return

	# Distribute the remainder so exactly `count` trees are rendered. ceil() per
	# species renders up to two more than the label and the JSON report claim.
	var per_species := floori(float(count) / float(meshes.size()))
	var remainder := count % meshes.size()
	for species in range(meshes.size()):
		var instances := per_species + (1 if species < remainder else 0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = instances
		mm.mesh = meshes[species]

		for i in range(instances):
			var angle := rng.randf() * TAU
			var dist := CLEARING + sqrt(rng.randf()) * (radius - CLEARING)
			var px := cos(angle) * dist
			var pz := sin(angle) * dist
			var pos := Vector3(px, _height(px, pz) - 0.15, pz)
			var s := 0.70 + rng.randf() * 0.45
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			mm.set_instance_transform(i, Transform3D(basis, pos))

		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		if not _flag("BENCH_TREE_SHADOW", true):
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)

	var grass := load("res://demo/foliage/models/grass_lod0.res")
	if grass is Mesh:
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
