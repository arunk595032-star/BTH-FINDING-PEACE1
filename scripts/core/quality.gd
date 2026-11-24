extends RefCounted
## PC and phone quality profiles plus persistent manual graphics settings.

const SETTINGS_PATH := "user://bth_settings.cfg"
const SECTION := "video"

const PROFILES := {
	"ultra": {"label":"Ultra","render_scale":1.0,"msaa":2,"shadow_distance":520.0,"shadow_blur":1.25,"shadows":true,"ssao":true,"ssil":true,"volumetric_fog":true,"glow":true,"stream_radius":480.0,"chunk_budget":3,"stream_budget_us":4000,"collision_radius":232.0,"terrain_lod_near":208.0,"terrain_lod_mid":352.0,"terrain_detail_distance":110.0,"vegetation_scale":1.0,"tree_end":900.0,"tree_lod":260.0,"water_detail_distance":110.0,"mist_amount":90,"max_fps":0,"vsync":1},
	"high": {"label":"High","render_scale":1.0,"msaa":1,"shadow_distance":340.0,"shadow_blur":1.0,"shadows":true,"ssao":true,"ssil":false,"volumetric_fog":true,"glow":true,"stream_radius":400.0,"chunk_budget":3,"stream_budget_us":3500,"collision_radius":208.0,"terrain_lod_near":184.0,"terrain_lod_mid":312.0,"terrain_detail_distance":95.0,"vegetation_scale":0.9,"tree_end":800.0,"tree_lod":220.0,"water_detail_distance":95.0,"mist_amount":72,"max_fps":0,"vsync":1},
	"medium": {"label":"Medium","render_scale":0.85,"msaa":0,"shadow_distance":240.0,"shadow_blur":0.9,"shadows":true,"ssao":true,"ssil":false,"volumetric_fog":false,"glow":true,"stream_radius":320.0,"chunk_budget":2,"stream_budget_us":2600,"collision_radius":176.0,"terrain_lod_near":152.0,"terrain_lod_mid":256.0,"terrain_detail_distance":75.0,"vegetation_scale":0.75,"tree_end":650.0,"tree_lod":160.0,"water_detail_distance":70.0,"mist_amount":56,"max_fps":60,"vsync":1},
	"low": {"label":"Low","render_scale":0.75,"msaa":0,"shadow_distance":150.0,"shadow_blur":0.7,"shadows":true,"ssao":false,"ssil":false,"volumetric_fog":false,"glow":true,"stream_radius":256.0,"chunk_budget":2,"stream_budget_us":1800,"collision_radius":144.0,"terrain_lod_near":120.0,"terrain_lod_mid":208.0,"terrain_detail_distance":55.0,"vegetation_scale":0.55,"tree_end":480.0,"tree_lod":110.0,"water_detail_distance":50.0,"mist_amount":40,"max_fps":45,"vsync":1}
}
const ORDER := ["ultra","high","medium","low"]

static func has_profile(name: String) -> bool:
	return PROFILES.has(name)

static func profile(name: String) -> Dictionary:
	return PROFILES.get(name, PROFILES["ultra"]).duplicate(true)

static func resolve_mode() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var stored := str(cfg.get_value(SECTION, "platform_mode", ""))
		if stored in ["pc", "phone"]:
			return stored
	return "phone" if OS.has_feature("mobile") else "pc"

static func default_profile(mode: String) -> String:
	return "medium" if mode == "phone" else "ultra"

static func resolve() -> String:
	var mode := resolve_mode()
	var name := default_profile(mode)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var stored := str(cfg.get_value(SECTION, "quality", name))
		if PROFILES.has(stored):
			name = stored
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var cli := arg.substr(10).to_lower()
			if PROFILES.has(cli):
				name = cli
	return name

static func resolve_saved_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var stored := str(cfg.get_value(SECTION, "quality", ""))
		if stored == "custom" or PROFILES.has(stored):
			return stored
	return resolve()

static func load_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var saved: Variant = cfg.get_value(SECTION, "manual_settings", {})
		if saved is Dictionary:
			return saved.duplicate(true)
	return {}

static func save_state(mode: String, name: String, settings: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, "platform_mode", mode)
	cfg.set_value(SECTION, "quality", name if PROFILES.has(name) else "custom")
	cfg.set_value(SECTION, "manual_settings", settings.duplicate(true))
	cfg.save(SETTINGS_PATH)

static func save_mode(mode: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, "platform_mode", mode)
	cfg.set_value(SECTION, "quality", default_profile(mode))
	cfg.set_value(SECTION, "manual_settings", {})
	cfg.save(SETTINGS_PATH)

static func next(name: String) -> String:
	var idx := ORDER.find(name)
	if idx < 0:
		idx = 0
	return ORDER[(idx + 1) % ORDER.size()]
