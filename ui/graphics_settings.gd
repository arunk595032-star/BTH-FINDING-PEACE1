extends CanvasLayer
## Touch-friendly graphics settings panel for desktop and Android.

var _main
var _panel: PanelContainer
var _mode: OptionButton
var _preset: OptionButton
var _controls: Dictionary = {}
var _values: Dictionary = {}

func _ready() -> void:
	layer = 30
	_build()

func bind(main_node) -> void:
	_main = main_node

func open_settings(mode: String, preset: String, values: Dictionary) -> void:
	_values = values.duplicate(true)
	_mode.select(1 if mode == "phone" else 0)
	var idx := ["ultra", "high", "medium", "low"].find(preset)
	_preset.select(maxi(idx, 0))
	_sync_controls()
	_panel.visible = true

func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 12
	_panel.offset_top = 12
	_panel.offset_right = -12
	_panel.offset_bottom = -12
	_panel.visible = false
	root.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var heading := Label.new()
	heading.text = "GRAPHICS SETTINGS"
	heading.add_theme_font_size_override("font_size", 24)
	box.add_child(heading)
	var mode_label := Label.new()
	mode_label.text = "Platform"
	box.add_child(mode_label)
	_mode = OptionButton.new()
	_mode.add_item("PC")
	_mode.add_item("Phone")
	_mode.custom_minimum_size.y = 48
	_mode.item_selected.connect(_on_mode_selected)
	box.add_child(_mode)
	var preset_label := Label.new()
	preset_label.text = "Graphics preset"
	box.add_child(preset_label)
	_preset = OptionButton.new()
	for p in ["Ultra", "High", "Medium", "Low"]:
		_preset.add_item(p)
	_preset.custom_minimum_size.y = 48
	_preset.item_selected.connect(_on_preset_selected)
	box.add_child(_preset)
	_add_slider(box, "Resolution scale", "render_scale", 0.5, 1.0, 0.05)
	_add_slider(box, "Shadow distance", "shadow_distance", 50.0, 450.0, 10.0)
	_add_slider(box, "Vegetation distance", "tree_end", 100.0, 1000.0, 25.0)
	_add_slider(box, "Vegetation density", "vegetation_scale", 0.25, 1.0, 0.05)
	_add_slider(box, "World view distance", "stream_radius", 160.0, 448.0, 16.0)
	_add_slider(box, "Terrain detail distance", "terrain_detail_distance", 25.0, 120.0, 5.0)
	_add_slider(box, "Water detail distance", "water_detail_distance", 25.0, 120.0, 5.0)
	_add_slider(box, "Tree LOD distance", "tree_lod", 50.0, 300.0, 10.0)
	_add_msaa(box)
	_add_slider(box, "FPS limit (0 = unlimited)", "max_fps", 0.0, 120.0, 5.0)
	_add_toggle(box, "Shadows", "shadows")
	_add_toggle(box, "Ambient occlusion (SSAO)", "ssao")
	_add_toggle(box, "Indirect lighting (SSIL)", "ssil")
	_add_toggle(box, "Volumetric fog", "volumetric_fog")
	_add_toggle(box, "Glow", "glow")
	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size.y = 52
	close.pressed.connect(func(): _panel.visible = false)
	box.add_child(close)

func _add_slider(parent: VBoxContainer, title: String, key: String, low: float, high: float, step: float) -> void:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.custom_minimum_size.y = 42
	slider.value_changed.connect(_on_slider_changed.bind(key))
	parent.add_child(slider)
	_controls[key] = slider

func _add_msaa(parent: VBoxContainer) -> void:
	var label := Label.new()
	label.text = "Anti-aliasing"
	parent.add_child(label)
	var choice := OptionButton.new()
	for item in ["Off", "2x MSAA", "4x MSAA", "8x MSAA"]:
		choice.add_item(item)
	choice.custom_minimum_size.y = 48
	choice.item_selected.connect(func(index: int):
		_values["msaa"] = index
		_apply()
	)
	parent.add_child(choice)
	_controls["msaa"] = choice

func _add_toggle(parent: VBoxContainer, title: String, key: String) -> void:
	var toggle := CheckButton.new()
	toggle.text = title
	toggle.custom_minimum_size.y = 44
	toggle.toggled.connect(_on_toggle_changed.bind(key))
	parent.add_child(toggle)
	_controls[key] = toggle

func _sync_controls() -> void:
	for key in _controls:
		var control = _controls[key]
		if control is HSlider:
			control.set_value_no_signal(float(_values.get(key, 0.0)))
		elif control is CheckButton:
			control.set_pressed_no_signal(bool(_values.get(key, false)))
		elif control is OptionButton:
			control.select(clampi(int(_values.get(key, 0)), 0, control.item_count - 1))

func _on_mode_selected(index: int) -> void:
	if _main != null:
		_main.set_graphics_mode("phone" if index == 1 else "pc")
		_values = _main.quality.duplicate(true)
		_preset.select(["ultra", "high", "medium", "low"].find(_main.quality_name) if _main.quality_name in ["ultra","high","medium","low"] else 0)
		_sync_controls()

func _on_preset_selected(index: int) -> void:
	if _main != null:
		_main.apply_quality(["ultra", "high", "medium", "low"][index])
		_values = _main.quality.duplicate(true)
		_sync_controls()

func _on_slider_changed(value: float, key: String) -> void:
	_values[key] = int(value) if key == "max_fps" else value
	_apply()

func _on_toggle_changed(value: bool, key: String) -> void:
	_values[key] = value
	_apply()

func _apply() -> void:
	if _main != null:
		_main.apply_graphics_settings(_values)
