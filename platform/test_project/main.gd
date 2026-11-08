extends Node3D

# HDDAGI forest scene: real Foliage3D tree assets, displaced terrain with the demo's
# ground albedo, volumetric fog and bloom.
#
# HDDAGI_TREES sets density, HDDAGI_CAPTURE=1 writes frames and exits.

const CLEARING := 9.0
const TERRAIN_SIZE := 400.0
const TERRAIN_RES := 96
const TERRAIN_AMPLITUDE := 1.8

const OUT_NORMAL := "/tmp/hddagi_normal.png"
const OUT_DEBUG := "/tmp/hddagi_debug.png"

const TREE_MESHES := [
	"res://demo/foliage/models/oak_lod0.res",
	"res://demo/foliage/models/elm_lod0.res",
	"res://demo/foliage/models/pine_lod0.res",
]

var _noise := FastNoiseLite.new()

func _ready() -> void:
	var trees := int(OS.get_environment("HDDAGI_TREES")) if OS.get_environment("HDDAGI_TREES") != "" else 600
	var capture := OS.get_environment("HDDAGI_CAPTURE") == "1"

	# Captures are compared pixel for pixel, so neither the overlay nor the animated
	# foliage may appear in them. The autoloads are already up by the time the scene
	# runs, so they are switched off here rather than through the environment.
	if capture:
		var hud := get_node_or_null("/root/Hud")
		if hud:
			hud.set_hud_visible(false)
		var wind := get_node_or_null("/root/Wind")
		if wind:
			wind.set_wind_enabled(false)

	_noise.seed = 4242
	_noise.frequency = 0.012
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0

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

	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6

	# Volumetric fog is what turns a lit forest into shafts of light.
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.85, 0.87, 0.90)
	env.volumetric_fog_emission = Color(0.02, 0.02, 0.02)
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_length = 96.0

	env.fog_enabled = true
	env.fog_light_color = Color(0.66, 0.70, 0.74)
	env.fog_density = 0.004

	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.0

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05

	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 6
	env.dynamic_gi_cascade_format = Environment.DYNAMIC_GI_CASCADE_FORMAT_16x8x16
	env.dynamic_gi_min_cell_size = 0.15
	env.dynamic_gi_read_sky_light = true

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-22.0, 38.0, 0.0) # low sun for longer shafts
	sun.light_energy = 2.0
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_blend_splits = true
	add_child(sun)

	var forest_radius := clampf(sqrt(float(trees) * 26.0 / PI), 16.0, 190.0)

	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0.0, 1.9 + _height(0.0, 0.0), 0.0)
	cam.look_at(Vector3(0.0, 7.0, -16.0), Vector3.UP)
	cam.current = true
	cam.fov = 72.0

	_add_terrain()
	_add_backdrop()

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

func _height(x: float, z: float) -> float:
	# Flatten toward the origin so the clearing stays walkable and trees do not
	# intersect the camera.
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
	# The detailed terrain stops at TERRAIN_SIZE/2; without this the sky shows through
	# as a bright band at the horizon. A large low plane fills it and fog blends it.
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
			var px := cos(angle) * dist
			var pz := sin(angle) * dist
			var pos := Vector3(px, _height(px, pz) - 0.15, pz)
			var s := 0.70 + rng.randf() * 0.45
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			mm.set_instance_transform(i, Transform3D(basis, pos))

		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
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
		# Grass casting shadows costs 4.44 ms/frame (15.5% of a 28.6 ms frame) and
		# changes 0.01% of pixels in this scene: the floor is already in foliage shade.
		gn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
