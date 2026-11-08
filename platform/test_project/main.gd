extends Node3D

# HDDAGI smoke scene.
#
# Builds a minimal lit scene, enables dynamic GI, then captures two frames:
#   /tmp/hddagi_normal.png   normal shading
#   /tmp/hddagi_debug.png    Viewport.DEBUG_DRAW_HDDAGI, which renders the cascade
#                            volume by reading the HDDAGI textures directly
#
# An error-free run is not proof of anything: a black frame is also error-free.
# The captures are the actual check.

const OUT_NORMAL := "/tmp/hddagi_normal.png"
const OUT_DEBUG := "/tmp/hddagi_debug.png"

func _ready() -> void:
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

	var cam := Camera3D.new()
	add_child(cam)
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
	plane.size = Vector2(24.0, 24.0)
	ground.mesh = plane
	add_child(ground)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.72, 0.68)
	ground.material_override = mat

	# A room-like arrangement so indirect light has somewhere to bounce.
	for i in range(5):
		var wall := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.4, 2.0, 4.0)
		wall.mesh = bm
		wall.position = Vector3(float(i) * 1.6 - 3.2, 1.0, -1.5)
		add_child(wall)

	for i in range(6):
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.6, 0.6 + float(i % 4) * 0.4, 0.6)
		box.mesh = bm
		box.position = Vector3(float(i % 3) * 1.4 - 1.4, 0.5, float(i / 3) * 1.6)
		add_child(box)

	print("HDDAGI_SMOKE_READY")
	print("dynamic_gi_enabled = ", env.dynamic_gi_enabled)
	print("cascades = ", env.dynamic_gi_cascades)
	print("renderer = ", RenderingServer.get_current_rendering_method())

	# Let the GI pipeline converge a little before capturing.
	for i in range(60):
		await get_tree().process_frame
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
