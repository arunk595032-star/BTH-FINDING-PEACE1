extends Node
## Conservative mobile adaptive-resolution controller.
## This is NOT frame generation: it lowers 3D render resolution during sustained
## frame-time pressure while leaving the 2D HUD at native viewport resolution.

const MIN_SCALE := 0.62
const DOWN_STEP := 0.05
const UP_STEP := 0.025
const SAMPLE_INTERVAL := 1.25
const RECOVERY_HOLD := 4.0

var _viewport: Viewport
var _base_scale := 0.85
var _current_scale := 0.85
var _frame_time_ema := 1.0 / 45.0
var _sample_elapsed := 0.0
var _slow_elapsed := 0.0
var _fast_elapsed := 0.0
var _target_fps := 45.0


func configure(viewport: Viewport, profile: Dictionary) -> void:
	_viewport = viewport
	_base_scale = clampf(float(profile.get("render_scale", 0.85)), MIN_SCALE, 1.0)
	_current_scale = _base_scale
	_target_fps = minf(maxf(float(profile.get("max_fps", 45)), 30.0), 45.0)
	_frame_time_ema = 1.0 / _target_fps
	_apply_scale()


func set_profile(profile: Dictionary) -> void:
	_base_scale = clampf(float(profile.get("render_scale", _base_scale)), MIN_SCALE, 1.0)
	_target_fps = maxf(float(profile.get("max_fps", _target_fps)), 30.0)
	_current_scale = minf(_current_scale, _base_scale)
	_apply_scale()


func _process(delta: float) -> void:
	if _viewport == null or delta <= 0.0:
		return
	# EMA rejects isolated spikes; decisions are made only over sustained samples.
	_frame_time_ema = lerpf(_frame_time_ema, delta, 0.08)
	_sample_elapsed += delta
	if _sample_elapsed < SAMPLE_INTERVAL:
		return
	_sample_elapsed = 0.0

	if _frame_time_ema > (1.0 / _target_fps) * 1.08:
		_slow_elapsed += SAMPLE_INTERVAL
		_fast_elapsed = 0.0
		if _slow_elapsed >= SAMPLE_INTERVAL:
			_set_scale(maxf(MIN_SCALE, _current_scale - DOWN_STEP))
			_slow_elapsed = 0.0
	elif _frame_time_ema < (1.0 / _target_fps) * 0.84:
		_fast_elapsed += SAMPLE_INTERVAL
		_slow_elapsed = 0.0
		if _fast_elapsed >= RECOVERY_HOLD and _current_scale < _base_scale:
			_set_scale(minf(_base_scale, _current_scale + UP_STEP))
			_fast_elapsed = 0.0
	else:
		_slow_elapsed = 0.0
		_fast_elapsed = 0.0


func _set_scale(value: float) -> void:
	_current_scale = clampf(value, MIN_SCALE, _base_scale)
	_apply_scale()
	print("[BTH][MobilePacer] 3D render scale %.2f (frame EMA %.1f ms)" % [
		_current_scale, _frame_time_ema * 1000.0])


func _apply_scale() -> void:
	if _viewport != null:
		_viewport.scaling_3d_scale = _current_scale
