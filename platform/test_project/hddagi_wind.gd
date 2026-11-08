extends Node

# Registers the global shader parameters the Foliage3D shaders expect, and drives a
# gust envelope on top of them.
#
# The foliage shaders declare these at the top of tree.gdshaderinc and grass.gdshader:
#
#   global uniform float wind_power;
#   global uniform vec4  wind_sway_amplitudes;
#   global uniform vec4  wind_sway_frequencies;
#   global uniform float wind_turbulence;
#   global uniform vec2  wind_velocity;
#
# and every foliage material already sets wind_enabled = true. Nothing in this fork
# registers the globals, so each material logged
#
#   WARNING: Shader uses global parameter 'wind_power', but it was removed at some point.
#
# on every frame and no foliage moved.
#
# ---------------------------------------------------------------------------
# What can be animated, and why only wind_power is
# ---------------------------------------------------------------------------
# The vertex shader computes its phase as
#
#   wind_time = TIME - dot(world_pos.xz, wind_effective_velocity)
#
# so wind_velocity and wind_turbulence are *phase* terms, not just amplitudes.
# Changing either shifts every instance's phase by dot(pos, delta): for a tree 50 m
# away, a 0.1 change in speed is a ~5 rad jump, which pops the entire forest at once.
# wind_sway_frequencies is worse still, because the phase is wind_time * frequency and
# TIME grows without bound, so any frequency change is a discontinuity.
#
# wind_power is a pure multiplier on the displacement, so it is the only parameter that
# can be varied continuously. All of the gusting below therefore rides on wind_power.
# Per-instance variation (different trees moving differently) is already provided by
# the shader's world-position noise through wind_turbulence, and per-vertex variation
# by the baked vertex colours, so a single global gust still looks varied.
#
# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
# One global_shader_parameter_set() every GUST_INTERVAL, and no per-vertex work added
# to the shaders. Measured cost is in artifacts/wind.md.
#
# HDDAGI_WIND=0 keeps the globals registered but pins wind_power to 0, so shaders
# take exactly the path they take with wind on while the foliage stays still. The
# benchmark runner sets it so timings stay comparable with the pre-wind baseline.
# (Skipping registration instead would bring back the "global parameter was removed"
# warning on every frame.)

const BASE_POWER := 5.0

# Gusts are updated at 10 Hz rather than per frame. The envelope's fastest component
# has a period of ~2.3 s, so 10 Hz is far above what is needed to resolve it, and it
# keeps the uniform-buffer update off the critical path.
const GUST_INTERVAL := 0.1

# Turbulence intensity: wind speed varies +/-30% around its mean. That is a normal
# value for open terrain and is what makes the motion read as wind rather than a
# fixed-rate oscillation.
const GUST_DEPTH := 0.30

# Never fully calm: a real forest in this scene should keep a residual breeze.
const MIN_POWER_FACTOR := 0.25

# These four values are Foliage3D's own defaults, taken verbatim from the addon's
# demo project.godot [shader_globals] block, so the sway shape is the asset author's
# rather than something invented here.
const SWAY_AMPLITUDES := Vector4(0.4, 0.1, 0.1, 0.1)
const SWAY_FREQUENCIES := Vector4(2.9, 5.4, 7.8, 10.2)
const TURBULENCE := 0.5
const WIND_VELOCITY := Vector2(1, 1)

# The addon's demo runs wind_power at 0.2, which is calibrated for its own scene and
# produces no visible motion here (measured: 0 px of leaf travel over 3 s). This scene
# has 8-17 m trees viewed from eye height, and a leaf tip displaces about
# 0.064 m per unit of wind_power, so 5.0 gives ~0.32 m on a 17 m oak - about 1.9% of
# its height, which is a moderate breeze. Peak gust reaches ~6.5.
#
# Grass is weighted by y^2 / wind_characteristic_height instead of by baked vertex
# colour, and its model is 0.77 m tall, so it responds ~3.5x more strongly per unit
# power. Its material wind_power_scale is therefore lowered from 1.0 to 0.15, which
# puts a blade tip at ~0.17 m. Without that, this power would flatten the grass.

# Four octaves, amplitude and frequency both falling off, with phase offsets so they
# do not all cross zero together. Sums to a range of about [-1, 1].
const GUST_OCTAVES := [
	Vector3(0.50, 0.21, 0.00),
	Vector3(0.28, 0.53, 1.70),
	Vector3(0.15, 1.19, 4.10),
	Vector3(0.07, 2.71, 2.30),
]

var _registered := false
var _enabled := true
var _strength := 1.0
var _gust_depth := GUST_DEPTH
var _t := 0.0
var _acc := 0.0
var _power := 0.0

func _ready() -> void:
	_register()
	_registered = true
	if OS.get_environment("HDDAGI_WIND") == "0":
		_enabled = false
	_apply()
	if not _enabled:
		set_process(false)
	print("HDDAGI_WIND %s velocity=%.2f,%.2f turbulence=%.2f gust_depth=%.2f" % [
		"enabled" if _enabled else "disabled by env",
		WIND_VELOCITY.x, WIND_VELOCITY.y, TURBULENCE, GUST_DEPTH])

# Runtime controls, used by the settings menu. Only wind_power is varied; see the
# phase-term note above for why the others are fixed.
func set_wind_enabled(p_enabled: bool) -> void:
	_enabled = p_enabled
	set_process(p_enabled)
	_apply()

func set_strength(p_strength: float) -> void:
	_strength = clampf(p_strength, 0.0, 4.0)
	_apply()

func set_gust_depth(p_depth: float) -> void:
	_gust_depth = clampf(p_depth, 0.0, 1.0)
	_apply()

func is_wind_enabled() -> bool:
	return _enabled

func get_strength() -> float:
	return _strength

func get_gust_depth() -> float:
	return _gust_depth

func _register() -> void:
	_add("wind_power", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, BASE_POWER)
	_add("wind_sway_amplitudes", RenderingServer.GLOBAL_VAR_TYPE_VEC4, SWAY_AMPLITUDES)
	_add("wind_sway_frequencies", RenderingServer.GLOBAL_VAR_TYPE_VEC4, SWAY_FREQUENCIES)
	_add("wind_turbulence", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, TURBULENCE)
	_add("wind_velocity", RenderingServer.GLOBAL_VAR_TYPE_VEC2, WIND_VELOCITY)

# Registration has to be runtime-safe. global_shader_parameter_get_list() is
# editor-only: outside the editor it logs an error and returns nothing, so it cannot
# be used to test whether a parameter exists. add() on an existing name is an
# ERR_FAIL_COND. remove() is a no-op when the name is absent, so remove-then-add is
# idempotent and works in a running game.
func _add(name: String, type: int, value: Variant) -> void:
	RenderingServer.global_shader_parameter_remove(name)
	RenderingServer.global_shader_parameter_add(name, type, value)

func _process(delta: float) -> void:
	if not _registered:
		return

	_t += delta
	_acc += delta
	if _acc < GUST_INTERVAL:
		return
	_acc = 0.0
	_apply()

func _apply() -> void:
	if not _registered:
		return
	if not _enabled:
		_power = 0.0
	else:
		_power = BASE_POWER * _strength * maxf(1.0 + _gust_depth * _gust_envelope(_t), MIN_POWER_FACTOR)
	RenderingServer.global_shader_parameter_set("wind_power", _power)

# Sum of incommensurate octaves, roughly in [-1, 1]. No single period, so the wind
# never settles into a visible loop.
func _gust_envelope(t: float) -> float:
	var g := 0.0
	for o in GUST_OCTAVES:
		g += o.x * sin(t * o.y + o.z)
	return g

# Current gusted power, for debugging or tests.
func get_wind_power() -> float:
	return _power
