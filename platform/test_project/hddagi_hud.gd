extends CanvasLayer

# Performance HUD, top-left of the running window.
#
#   FPS     measured wall-clock frame rate
#   frame   mean frame time over the refresh window, plus the worst frame seen
#   cpu     RenderingServer's measured CPU render time, and its share of the frame
#   gpu     measured GPU render time where the backend supports it, otherwise an
#           estimate of frame time minus CPU render time
#   mem     Performance.MEMORY_STATIC
#
# GPU timing caveat: RenderingDeviceDriverMetal::timestamp_query_pool_get_results()
# clears the buffer because Metal timestamps are unimplemented in this fork, so
# viewport_get_measured_render_time_gpu() returns 0 and the GPU line is an estimate.
# It is marked "est" whenever that happens so it is never mistaken for a measurement.
#
# Toggle with F3. Disable entirely with HDDAGI_HUD=0 (the benchmark runner does this
# so timings are not perturbed by the overlay).

const REFRESH_SEC := 0.15

const FPS_GOOD := 55.0
const FPS_WARN := 30.0

var _panel: PanelContainer
var _label: RichTextLabel
var _vp_rid: RID

var _last_usec := 0
var _elapsed := 0.0
var _frames := 0
var _peak_ms := 0.0
var _sum_cpu := 0.0
var _sum_gpu := 0.0
var _hud_visible := true

func _ready() -> void:
	layer = 128
	_vp_rid = get_viewport().get_viewport_rid()
	_build()

	# Hidden rather than freed when disabled, so the settings menu can turn it back on.
	var start_visible := OS.get_environment("HDDAGI_HUD") != "0"
	set_hud_visible(start_visible)
	print("HDDAGI_HUD %s (F3 toggles)" % ("enabled" if start_visible else "disabled by env"))

# Runtime control, used by the settings menu. Hiding also stops the per-frame work and
# turns off the viewport render-time measurement, so a hidden HUD costs nothing.
func set_hud_visible(p_visible: bool) -> void:
	_hud_visible = p_visible
	visible = p_visible
	set_process(p_visible)
	RenderingServer.viewport_set_measure_render_time(_vp_rid, p_visible)
	if p_visible:
		# Start the window at the moment the HUD appears, so the time spent hidden is
		# not reported as one enormous frame.
		_last_usec = Time.get_ticks_usec()
		_elapsed = 0.0
		_frames = 0
		_peak_ms = 0.0
		_sum_cpu = 0.0
		_sum_gpu = 0.0

func is_hud_visible() -> bool:
	return _hud_visible

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 12)
	_panel.grow_horizontal = Control.GROW_DIRECTION_END
	_panel.grow_vertical = Control.GROW_DIRECTION_END
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.72)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	# Without this the label word-wraps against a zero-width parent and collapses to
	# a one-character column, which reads as "the HUD never appeared".
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(190, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 14)
	_label.add_theme_font_size_override("bold_font_size", 16)
	_label.add_theme_constant_override("line_separation", 2)
	_panel.add_child(_label)

func _process(_delta: float) -> void:
	# Wall clock, not delta: delta is scaled by Engine.time_scale, so the frame rate
	# would read wrong whenever time is slowed, paused or scaled.
	var now := Time.get_ticks_usec()
	var this_ms := float(now - _last_usec) / 1000.0
	_last_usec = now

	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	var gpu_measured := gpu_ms > 0.0
	if not gpu_measured:
		gpu_ms = maxf(this_ms - cpu_ms, 0.0)

	_elapsed += this_ms / 1000.0
	_frames += 1
	_peak_ms = maxf(_peak_ms, this_ms)
	_sum_cpu += cpu_ms
	_sum_gpu += gpu_ms
	if _elapsed < REFRESH_SEC:
		return

	var frame_ms := (_elapsed / float(_frames)) * 1000.0
	var fps := float(_frames) / _elapsed
	var peak_ms := _peak_ms
	var mean_cpu := _sum_cpu / float(_frames)
	var mean_gpu := _sum_gpu / float(_frames)

	var cpu_pct := 100.0 * mean_cpu / maxf(frame_ms, 0.001)
	var gpu_pct := 100.0 * mean_gpu / maxf(frame_ms, 0.001)
	var mem_mb := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0

	var fps_color := "#7fe08a"
	if fps < FPS_WARN:
		fps_color = "#ff7b72"
	elif fps < FPS_GOOD:
		fps_color = "#e3b341"

	# A frame much worse than the window mean is a hitch; call it out rather than
	# averaging it away.
	var peak_note := ""
	if peak_ms > frame_ms * 2.0:
		peak_note = "  [color=#ff7b72]peak %.1f[/color]" % peak_ms

	var gpu_suffix := "" if gpu_measured else " [color=#8b949e](est)[/color]"

	_label.text = (
		"[color=%s][b]%5.1f FPS[/b][/color]%s\n" % [fps_color, fps, peak_note]
		+ "[color=#8b949e]frame[/color] %6.2f ms\n" % frame_ms
		+ "[color=#8b949e]cpu  [/color] %6.2f ms  %3.0f%%\n" % [mean_cpu, cpu_pct]
		+ "[color=#8b949e]gpu  [/color] %6.2f ms  %3.0f%%%s\n" % [mean_gpu, gpu_pct, gpu_suffix]
		+ "[color=#8b949e]mem  [/color] %6.1f MB" % mem_mb
	)

	_elapsed = 0.0
	_frames = 0
	_peak_ms = 0.0
	_sum_cpu = 0.0
	_sum_gpu = 0.0

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		set_hud_visible(not _hud_visible)
