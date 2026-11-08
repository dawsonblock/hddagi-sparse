extends Node3D

# HDDAGI stress scene.
#
# Density is controlled by the HDDAGI_TREES environment variable so one project can
# sweep from an empty room to a dense canopy without editing files between runs.
#
# Captures /tmp/hddagi_normal.png and /tmp/hddagi_debug.png, and prints the
# process-cell demand per cascade via the engine-side readback.

const OUT_NORMAL := "/tmp/hddagi_normal.png"
const OUT_DEBUG := "/tmp/hddagi_debug.png"

func _ready() -> void:
	var trees := int(OS.get_environment("HDDAGI_TREES")) if OS.get_environment("HDDAGI_TREES") != "" else 0
	var capture := OS.get_environment("HDDAGI_CAPTURE") != "0"

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 6
	env.dynamic_gi_cascade_format = Environment.DYNAMIC_GI_CASCADE_FORMAT_16x8x16
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = true

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Dense forest at roughly one tree per 3 m^2, with the camera inside it at eye
	# height. That is the case that stresses the finest cascades: what matters is
	# geometry near the camera, not total tree count.
	var forest_radius := clampf(sqrt(float(trees) * 3.0 / PI), 8.0, 200.0)

	var cam := Camera3D.new()
	add_child(cam)
	if trees > 0:
		cam.position = Vector3(0.0, 1.8, 9.0)
		cam.look_at(Vector3(0.0, 1.6, 0.0), Vector3.UP)
	else:
		cam.position = Vector3(0.0, 2.5, 7.0)
		cam.look_at(Vector3(0.0, 0.5, 0.0), Vector3.UP)
	cam.current = true

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80.0, 80.0)
	ground.mesh = plane
	add_child(ground)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.45, 0.38)
	ground.material_override = mat

	# A fixed room so the low-density case stays comparable to the earlier run.
	for i in range(5):
		var wall := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.4, 2.0, 4.0)
		wall.mesh = bm
		wall.position = Vector3(float(i) * 1.6 - 3.2, 1.0, -1.5)
		add_child(wall)

	if trees > 0:
		_add_forest(trees, forest_radius)

	print("HDDAGI_SMOKE_READY trees=", trees)
	print("dynamic_gi_enabled = ", env.dynamic_gi_enabled)
	print("cascades = ", env.dynamic_gi_cascades)
	print("renderer = ", RenderingServer.get_current_rendering_method())

	for i in range(60):
		await get_tree().process_frame

	if not capture:
		get_tree().quit()
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
	rng.seed = 12345

	# Trunks: thin and tall, many surface voxels per unit of screen area.
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.08
	trunk_mesh.bottom_radius = 0.12
	trunk_mesh.height = 3.0
	trunk_mesh.radial_segments = 6

	var canopy_mesh := BoxMesh.new()
	canopy_mesh.size = Vector3(1.1, 1.4, 1.1)

	var trunk_mm := MultiMesh.new()
	trunk_mm.transform_format = MultiMesh.TRANSFORM_3D
	trunk_mm.mesh = trunk_mesh
	trunk_mm.instance_count = count

	var canopy_mm := MultiMesh.new()
	canopy_mm.transform_format = MultiMesh.TRANSFORM_3D
	canopy_mm.mesh = canopy_mesh
	canopy_mm.instance_count = count

	for i in range(count):
		var angle := rng.randf() * TAU
		var dist := sqrt(rng.randf()) * radius
		var pos := Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		var scale := 0.7 + rng.randf() * 0.8
		trunk_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(scale, scale, scale)), pos + Vector3(0, 1.5 * scale, 0)))
		canopy_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(scale, scale, scale)), pos + Vector3(0, 3.2 * scale, 0)))

	var trunk_node := MultiMeshInstance3D.new()
	trunk_node.multimesh = trunk_mm
	add_child(trunk_node)

	var canopy_node := MultiMeshInstance3D.new()
	canopy_node.multimesh = canopy_mm
	add_child(canopy_node)

	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.25, 0.19, 0.14)
	trunk_node.material_override = bark

	var leaf := StandardMaterial3D.new()
	leaf.albedo_color = Color(0.18, 0.32, 0.16)
	canopy_node.material_override = leaf

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
