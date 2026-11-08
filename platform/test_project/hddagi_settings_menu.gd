extends CanvasLayer

# Settings menu, toggled with F1.
#
# Wind, lighting, fog and the performance overlay, all applied live to whatever scene
# is running. It finds the scene's WorldEnvironment and DirectionalLight3D on open
# rather than requiring the scene to register them, so it works unchanged in both
# main.tscn and bench.tscn.
#
# HDDAGI_MENU=0 disables it; the benchmark runner sets that so timings are clean.

const MARGIN := 14.0
const PANEL_W := 360.0

const LABEL_W := 118.0
const VALUE_W := 46.0
const FONT := 13

var _panel: PanelContainer
var _root: VBoxContainer
var _env: Environment
var _sun: DirectionalLight3D
var _open := false
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE

var _wind: Node
var _hud: Node

# Controls that need to be re-synced from the scene when the menu opens.
var _sliders := {}
var _checks := {}

func _ready() -> void:
	if OS.get_environment("HDDAGI_MENU") == "0":
		queue_free()
		return

	layer = 140
	_wind = get_node_or_null("/root/Wind")
	_hud = get_node_or_null("/root/Hud")
	_build()
	visible = false
	set_process(false)
	print("HDDAGI_MENU enabled (F1 opens)")

	# Screenshot / smoke-test hook: open without a keypress.
	if OS.get_environment("HDDAGI_MENU_OPEN") == "1":
		await get_tree().process_frame
		await get_tree().process_frame
		_open_menu()

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build() -> void:
	_panel = PanelContainer.new()
	# Full-height sidebar rather than a fixed 660 px panel: a fixed height clips on a
	# window shorter than the panel, and the ScrollContainer inside it cannot help
	# because the clipping happens outside it.
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -(PANEL_W + MARGIN)
	_panel.offset_right = -MARGIN
	_panel.offset_top = MARGIN
	_panel.offset_bottom = -MARGIN
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.94)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)

	_root = VBoxContainer.new()
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_theme_constant_override("separation", 5)
	scroll.add_child(_root)

	_title("Settings")
	_hint("F1 closes")

	_section("Wind")
	_check("wind_on", "Wind enabled", true, _on_wind_enabled)
	_slider("wind_strength", "Strength", 0.0, 3.0, 0.05, 1.0, _on_wind_strength)
	_slider("wind_gusts", "Gusts", 0.0, 1.0, 0.01, 0.30, _on_wind_gusts)

	_section("Lighting")
	_check("gi_on", "HDDAGI indirect", true, _on_gi_enabled)
	_slider("gi_energy", "GI energy", 0.0, 4.0, 0.05, 1.0, _on_gi_energy)
	_slider("sun_energy", "Sun energy", 0.0, 8.0, 0.05, 2.0, _on_sun_energy)
	_slider("sun_elev", "Sun elevation", -90.0, 0.0, 1.0, -22.0, _on_sun_elevation)
	_slider("sun_azim", "Sun azimuth", 0.0, 360.0, 1.0, 38.0, _on_sun_azimuth)
	_slider("ambient", "Ambient", 0.0, 4.0, 0.05, 1.2, _on_ambient)
	_slider("exposure", "Exposure", 0.2, 3.0, 0.01, 1.05, _on_exposure)

	_section("Fog")
	_check("fog_on", "Depth fog", true, _on_fog_enabled)
	_slider("fog_density", "Fog density", 0.0, 0.02, 0.001, 0.004, _on_fog_density)
	_check("vol_on", "Volumetric fog", true, _on_volumetric_enabled)
	_slider("vol_density", "Vol. density", 0.0, 0.05, 0.001, 0.008, _on_volumetric_density)
	_slider("vol_length", "Vol. length", 8.0, 200.0, 1.0, 96.0, _on_volumetric_length)
	_slider("vol_aniso", "Anisotropy", -1.0, 1.0, 0.01, 0.35, _on_volumetric_anisotropy)

	_section("Overlay")
	_check("hud_on", "Show CPU / GPU / FPS", true, _on_hud_toggled)

func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	_root.add_child(l)

func _hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
	_root.add_child(l)

func _section(text: String) -> void:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	_root.add_child(sep)

	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.45, 0.72, 1.0))
	_root.add_child(l)

func _check(key: String, text: String, value: bool, cb: Callable) -> void:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = value
	c.add_theme_font_size_override("font_size", FONT)
	c.toggled.connect(cb)
	_root.add_child(c)
	_checks[key] = c

func _slider(key: String, text: String, min_v: float, max_v: float, step: float, value: float, cb: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_l := Label.new()
	name_l.text = text
	name_l.custom_minimum_size = Vector2(LABEL_W, 0)
	name_l.add_theme_font_size_override("font_size", FONT)
	name_l.add_theme_color_override("font_color", Color(0.80, 0.84, 0.90))
	row.add_child(name_l)

	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(s)

	var v := Label.new()
	v.custom_minimum_size = Vector2(VALUE_W, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_theme_font_size_override("font_size", FONT)
	v.add_theme_color_override("font_color", Color(0.62, 0.68, 0.76))
	v.text = _fmt(value, step)
	row.add_child(v)

	s.value_changed.connect(func(x: float) -> void:
		v.text = _fmt(x, step)
		cb.call(x))
	_root.add_child(row)
	_sliders[key] = s

# Show as many decimals as the slider's step justifies, so 1.05 does not read as 1.1.
# Trailing zeros are kept: a fixed width per control is steadier to read while dragging.
func _fmt(v: float, step: float) -> String:
	var decimals := int(maxf(0.0, ceil(-log(step) / log(10.0))))
	return String.num(v, decimals)

# ---------------------------------------------------------------------------
# Applying values
# ---------------------------------------------------------------------------

func _on_wind_enabled(v: bool) -> void:
	if _wind:
		_wind.set_wind_enabled(v)

func _on_wind_strength(v: float) -> void:
	if _wind:
		_wind.set_strength(v)

func _on_wind_gusts(v: float) -> void:
	if _wind:
		_wind.set_gust_depth(v)

func _on_gi_enabled(v: bool) -> void:
	if _env:
		_env.dynamic_gi_enabled = v

func _on_gi_energy(v: float) -> void:
	if _env:
		_env.dynamic_gi_energy = v

func _on_sun_energy(v: float) -> void:
	if _sun:
		_sun.light_energy = v

func _on_sun_elevation(v: float) -> void:
	if _sun:
		var r := _sun.rotation_degrees
		_sun.rotation_degrees = Vector3(v, r.y, r.z)

func _on_sun_azimuth(v: float) -> void:
	if _sun:
		var r := _sun.rotation_degrees
		_sun.rotation_degrees = Vector3(r.x, v, r.z)

func _on_ambient(v: float) -> void:
	if _env:
		_env.ambient_light_energy = v

func _on_exposure(v: float) -> void:
	if _env:
		_env.tonemap_exposure = v

func _on_fog_enabled(v: bool) -> void:
	if _env:
		_env.fog_enabled = v

func _on_fog_density(v: float) -> void:
	if _env:
		_env.fog_density = v

func _on_volumetric_enabled(v: bool) -> void:
	if _env:
		_env.volumetric_fog_enabled = v

func _on_volumetric_density(v: float) -> void:
	if _env:
		_env.volumetric_fog_density = v

func _on_volumetric_length(v: float) -> void:
	if _env:
		_env.volumetric_fog_length = v

func _on_volumetric_anisotropy(v: float) -> void:
	if _env:
		_env.volumetric_fog_anisotropy = v

func _on_hud_toggled(v: bool) -> void:
	if _hud:
		_hud.set_hud_visible(v)

# ---------------------------------------------------------------------------
# Scene discovery and syncing
# ---------------------------------------------------------------------------

func _find_nodes(node: Node) -> void:
	if node is WorldEnvironment and _env == null:
		var we := node as WorldEnvironment
		if we.environment:
			_env = we.environment
	elif node is DirectionalLight3D and _sun == null:
		_sun = node as DirectionalLight3D

	for child in node.get_children():
		_find_nodes(child)

func _resolve() -> void:
	_env = null
	_sun = null
	var scene := get_tree().current_scene
	if scene:
		_find_nodes(scene)

# Pull current values out of the live scene so the controls never lie about state.
func _sync() -> void:
	if _env:
		_set_slider("gi_energy", _env.dynamic_gi_energy)
		_set_slider("ambient", _env.ambient_light_energy)
		_set_slider("exposure", _env.tonemap_exposure)
		_set_slider("fog_density", _env.fog_density)
		_set_slider("vol_density", _env.volumetric_fog_density)
		_set_slider("vol_length", _env.volumetric_fog_length)
		_set_slider("vol_aniso", _env.volumetric_fog_anisotropy)
		_set_check("gi_on", _env.dynamic_gi_enabled)
		_set_check("fog_on", _env.fog_enabled)
		_set_check("vol_on", _env.volumetric_fog_enabled)

	if _sun:
		_set_slider("sun_energy", _sun.light_energy)
		_set_slider("sun_elev", _sun.rotation_degrees.x)
		_set_slider("sun_azim", _sun.rotation_degrees.y)

	if _wind:
		_set_check("wind_on", _wind.is_wind_enabled())
		_set_slider("wind_strength", _wind.get_strength())
		_set_slider("wind_gusts", _wind.get_gust_depth())

	if _hud:
		_set_check("hud_on", _hud.is_hud_visible())

func _set_slider(key: String, value: float) -> void:
	var s: HSlider = _sliders.get(key)
	if s:
		s.set_value_no_signal(value)

func _set_check(key: String, value: bool) -> void:
	var c: CheckButton = _checks.get(key)
	if c:
		c.set_pressed_no_signal(value)

# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func _toggle() -> void:
	if _open:
		_close()
	else:
		_open_menu()

func _open_menu() -> void:
	_resolve()
	_sync()
	_open = true
	visible = true
	set_process(true)
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close() -> void:
	_open = false
	visible = false
	set_process(false)
	Input.mouse_mode = _prev_mouse_mode

# Only runs while the menu is open. Keeps the HUD checkbox honest if the user presses
# F3 while the menu is up, since F3 is handled by the HUD, not by this menu.
func _process(_delta: float) -> void:
	if _hud:
		_set_check("hud_on", _hud.is_hud_visible())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_toggle()
		get_viewport().set_input_as_handled()
