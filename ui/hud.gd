extends CanvasLayer
## Exploration HUD: title card, region name, compass, coordinates, focus prompt,
## discovery count and a collapsible controls panel.

var world
var player

var _region_label: Label
var _coord_label: Label
var _compass_label: Label
var _focus_label: Label
var _discover_label: Label
var _fps_label: Label
var _quality_label: Label
var _panel: PanelContainer
var _title: Label
var _toast: Label
var _toast_time := 0.0
var _refresh := 0.0
var _main
var _quality_text := "Ultra (PC)"
var _settings_button: Button


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.name = "HUDRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_region_label = _make_label(root, 26, Color(0.96, 0.93, 0.85))
	_region_label.position = Vector2(32, 22)
	_coord_label = _make_label(root, 13, Color(0.85, 0.82, 0.74, 0.8))
	_coord_label.position = Vector2(34, 58)

	_compass_label = _make_label(root, 18, Color(0.96, 0.93, 0.85))
	_compass_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_compass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_compass_label.position = Vector2(-230, 24)
	_discover_label = _make_label(root, 13, Color(0.85, 0.82, 0.74, 0.8))
	_discover_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_discover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_discover_label.position = Vector2(-230, 56)

	_focus_label = _make_label(root, 18, Color(1.0, 0.94, 0.78))
	_focus_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_focus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_focus_label.position = Vector2(-260, -128)
	_focus_label.size = Vector2(520, 40)

	_toast = _make_label(root, 16, Color(0.95, 0.9, 0.75))
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.position = Vector2(-260, -170)
	_toast.size = Vector2(520, 34)
	_toast.modulate.a = 0.0

	_fps_label = _make_label(root, 12, Color(0.8, 0.8, 0.76, 0.55))
	_fps_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.position = Vector2(-280, -32)
	_quality_label = _make_label(root, 12, Color(0.8, 0.8, 0.76, 0.45))
	_quality_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_quality_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_quality_label.position = Vector2(-280, -50)
	_quality_label.text = "quality Ultra (PC)  ·  F1 to cycle"

	_build_controls_panel(root)
	_build_title(root)
	_build_graphics_button(root)


func _build_graphics_button(root: Control) -> void:
	_settings_button = Button.new()
	_settings_button.text = "GRAPHICS"
	_settings_button.custom_minimum_size = Vector2(150, 48)
	_settings_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_settings_button.position = Vector2(-178, 92)
	_settings_button.pressed.connect(func():
		if _main != null:
			_main.open_graphics_settings()
	)
	root.add_child(_settings_button)


func _make_label(parent: Control, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.65))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _build_controls_panel(root: Control) -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.position = Vector2(28, -196)
	_panel.size = Vector2(430, 168)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.05, 0.55)
	style.border_color = Color(0.72, 0.62, 0.42, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	_panel.add_child(box)
	var title := _make_label(box, 14, Color(0.94, 0.86, 0.68))
	title.text = "EXPLORATION"
	var lines := [
		"WASD  walk      Shift  run",
		"Space  jump     Mouse  look",
		"E  interact     H  hide this panel",
		"Esc  release cursor  ·  click to recapture",
	]
	for line in lines:
		var l := _make_label(box, 13, Color(0.87, 0.86, 0.82, 0.92))
		l.text = line


func _build_title(root: Control) -> void:
	_title = _make_label(root, 40, Color(0.98, 0.94, 0.84))
	_title.text = "BEYOND THE HORIZON"
	_title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.position = Vector2(-400, 150)
	_title.size = Vector2(800, 60)
	var sub := _make_label(root, 18, Color(0.92, 0.86, 0.72, 0.9))
	sub.text = "Finding Peace  ·  Thornbury Valley"
	sub.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.position = Vector2(-400, 198)
	sub.size = Vector2(800, 30)
	var tween := create_tween()
	tween.tween_interval(3.2)
	tween.tween_property(_title, "modulate:a", 0.0, 2.2)
	tween.parallel().tween_property(sub, "modulate:a", 0.0, 2.2)


func bind(world_node, player_node, main_node = null) -> void:
	world = world_node
	player = player_node
	_main = main_node
	_update_labels()


func set_quality(name: String, label: String) -> void:
	_quality_text = "%s (%s)" % [label, name]
	if _quality_label != null:
		_quality_label.text = "graphics %s  ·  F1 to cycle" % _quality_text


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_help"):
		_panel.visible = not _panel.visible


func _process(delta: float) -> void:
	# Text is rebuilt at 10 Hz instead of every frame: the labels do not change
	# faster than that, and each rebuild allocates several strings.
	_refresh += delta
	if _refresh >= 0.1:
		_refresh = 0.0
		_update_labels()
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time, 0.0, 1.0)
	else:
		_toast.modulate.a = 0.0


func _update_labels() -> void:
	if world == null or player == null or not is_instance_valid(player):
		return
	var pos: Vector3 = player.global_position
	_region_label.text = String(world.field.region_at(pos))
	_coord_label.text = "X %d   Z %d   ALT %d m   ·   traveller %s m" % [
		int(pos.x), int(pos.z), int(pos.y), str(int(player.distance_travelled))]
	var bearing: float = player.camera_bearing()
	_compass_label.text = "%s   %d°" % [_cardinal(bearing), int(bearing)]
	_discover_label.text = "sites inspected %d / %d" % [player.discovered.size(), 9]
	_fps_label.text = "BTH valley benchmark  ·  %d fps  ·  %.1f ms  ·  %d chunks" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		world.loaded_chunk_count()]
	if player.current_focus != "":
		_focus_label.text = "E   inspect  %s" % String(player.current_focus)
	else:
		_focus_label.text = ""
	if _toast.modulate.a <= 0.01 and player.discovered.size() > 0:
		var last: String = player.discovered[player.discovered.size() - 1]
		if last != _last_toast:
			_last_toast = last
			_toast.text = "Recorded: " + last
			_toast_time = 3.0

var _last_toast := ""


func _cardinal(bearing: float) -> String:
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var idx := int(round(fposmod(bearing, 360.0) / 45.0)) % 8
	return names[idx]
