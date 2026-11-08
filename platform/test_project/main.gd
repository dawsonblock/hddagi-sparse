extends Node3D

# HDDAGI forest scene using the real Foliage3D tree assets rather than placeholder
# primitives. Density comes from HDDAGI_TREES; HDDAGI_CAPTURE=1 writes frames and
# exits, otherwise the scene stays open for inspection.

const CLEARING := 8.0
const OUT_NORMAL := "/tmp/hddagi_normal.png"
const OUT_DEBUG := "/tmp/hddagi_debug.png"

const TREE_MESHES := [
	"res://demo/foliage/models/oak_lod0.res",
	"res://demo/foliage/models/elm_lod0.res",
	"res://demo/foliage/models/pine_lod0.res",
]

func _ready() -> void:
	var trees := int(OS.get_environment("HDDAGI_TREES")) if OS.get_environment("HDDAGI_TREES") != "" else 600
	var capture := OS.get_environment("HDDAGI_CAPTURE") == "1"

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.45, 0.62)
	sky_mat.sky_horizon_color = Color(0.68, 0.70, 0.72)
	sky_mat.ground_horizon_color = Color(0.45, 0.42, 0.38)
	sky_mat.ground_bottom_color = Color(0.22, 0.20, 0.18)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.35

	# Quality: SSAO and fog give the depth cues that make a forest read as solid.
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.0
	env.ssao_power = 1.5
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.66, 0.70)
	env.fog_density = 0.005
	env.tonemap_mode = Environment.TONE_MAPPER_ACES

	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 6
	env.dynamic_gi_cascade_format = Environment.DYNAMIC_GI_CASCADE_FORMAT_16x8x16
	env.dynamic_gi_min_cell_size = 0.15
	env.dynamic_gi_read_sky_light = true

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 42.0, 0.0)
	sun.light_energy = 1.5
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	var forest_radius := clampf(sqrt(float(trees) * 26.0 / PI), 14.0, 200.0)

	var cam := Camera3D.new()
	add_child(cam)
	# Stand in a clearing: trees are excluded within CLEARING metres of the origin,
	# otherwise the camera ends up inside a trunk at this density.
	cam.position = Vector3(0.0, 1.9, 0.0)
	cam.look_at(Vector3(0.0, 6.0, -14.0), Vector3.UP)
	cam.current = true
	cam.fov = 70.0

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600.0, 600.0) # large enough that its edge is never in shot
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.20, 0.26, 0.14)
	ground_mat.roughness = 0.95
	ground.material_override = ground_mat
	add_child(ground)

	if trees > 0:
		_add_forest(trees, forest_radius)

	print("HDDAGI_SMOKE_READY trees=", trees, " radius=", forest_radius)
	print("dynamic_gi_enabled = ", env.dynamic_gi_enabled)
	print("renderer = ", RenderingServer.get_current_rendering_method())

	for i in range(90):
		await get_tree().process_frame

	if not capture:
		return

	await RenderingServer.frame_post_draw
	_capture(OUT_NORMAL)
	print("CAPTURED_NORMAL ", OUT_NORMAL)

	var vp := get_viewport()
	if vp != null:
		vp.debug_draw = Viewport.DEBUG_DRAW_HDDAGI
		for i in range(10):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_capture(OUT_DEBUG)
		print("CAPTURED_DEBUG ", OUT_DEBUG)

	get_tree().quit()

func _add_forest(count: int, radius: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 987654

	var meshes: Array[Mesh] = []
	for path in TREE_MESHES:
		var m := load(path)
		if m is Mesh:
			meshes.append(m)
		else:
			push_warning("could not load tree mesh: " + path)

	if meshes.is_empty():
		push_error("no tree meshes loaded")
		return

	var per_species := int(ceil(float(count) / float(meshes.size())))
	for species in range(meshes.size()):
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = per_species
		mm.mesh = meshes[species]

		for i in range(per_species):
			var angle := rng.randf() * TAU
			var dist := CLEARING + sqrt(rng.randf()) * (radius - CLEARING)
			var pos := Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
			var s := 0.70 + rng.randf() * 0.40
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			mm.set_instance_transform(i, Transform3D(basis, pos))

		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		add_child(node)

	# A little ground cover so the floor is not bare.
	var grass := load("res://demo/foliage/models/grass_lod0.res")
	if grass is Mesh:
		var gm := MultiMesh.new()
		gm.transform_format = MultiMesh.TRANSFORM_3D
		gm.instance_count = count * 4
		gm.mesh = grass
		for i in range(count * 4):
			var angle := rng.randf() * TAU
			var dist := sqrt(rng.randf()) * radius
			var pos := Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
			var s := 0.8 + rng.randf() * 0.5
			gm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s, s)), pos))
		var gn := MultiMeshInstance3D.new()
		gn.multimesh = gm
		add_child(gn)

func _capture(path: String) -> void:
	var vp := get_viewport()
	if vp == null:
		print("CAPTURE_FAILED no viewport")
		return
	var img := vp.get_texture().get_image()
	if img == null:
		print("CAPTURE_FAILED no image")
		return
	var err := img.save_png(path)
	if err != OK:
		print("CAPTURE_FAILED save err ", err)
