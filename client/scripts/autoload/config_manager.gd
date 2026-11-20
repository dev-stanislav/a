extends Node
## Canonical ConfigManager autoload for Phantom Court Online.
## Persists graphics, audio, gameplay (including touch_controls_mode), and network settings in user://settings.cfg.

signal settings_changed(section: String, key: String, value: Variant)

const SETTINGS_PATH := "user://settings.cfg"

var settings: Dictionary = {
	"graphics": {
		"fullscreen": false,
		"vsync": true,
		"quality": "high",
		"shadows_enabled": true,
		"render_scale": 1.0,
	},
	"audio": {
		"master_volume": 0.85,
		"sfx_volume": 0.90,
		"music_volume": 0.70,
		"ambience_volume": 0.65,
	},
	"gameplay": {
		"mouse_sensitivity": 0.0028,
		"camera_fov": 72.0,
		"camera_shake_scale": 1.0,
		"invert_y": false,
		"touch_controls_mode": "auto", # "auto" | "on" | "off"
	},
	"network": {
		"default_host": "127.0.0.1",
		"default_udp_port": 7777,
		"default_http_port": 8080,
		"player_name": "PhantomPlayer",
	},
}


func _ready() -> void:
	load_settings()
	apply_settings()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	var err: int = cfg.load(SETTINGS_PATH)
	if err != OK:
		return
	for section in settings.keys():
		var sec_dict: Dictionary = settings[section]
		for key in sec_dict.keys():
			if cfg.has_section_key(section, key):
				sec_dict[key] = cfg.get_value(section, key, sec_dict[key])


func save_settings() -> int:
	var cfg := ConfigFile.new()
	for section in settings.keys():
		var sec_dict: Dictionary = settings[section]
		for key in sec_dict.keys():
			cfg.set_value(section, key, sec_dict[key])
	return cfg.save(SETTINGS_PATH)


func get_setting(section: String, key: String, default_value: Variant = null) -> Variant:
	if settings.has(section):
		var sec_dict: Dictionary = settings[section]
		if sec_dict.has(key):
			return sec_dict[key]
	return default_value


func set_setting(section: String, key: String, value: Variant, persist: bool = true) -> void:
	if not settings.has(section):
		settings[section] = {}
	settings[section][key] = value
	apply_settings()
	if persist:
		save_settings()
	settings_changed.emit(section, key, value)


func should_show_touch_controls() -> bool:
	var mode: String = str(get_setting("gameplay", "touch_controls_mode", "auto")).strip_edges().to_lower()
	if mode == "on":
		return true
	if mode == "off":
		return false
	# "auto": enable automatically on iOS / mobile builds
	return OS.has_feature("ios") or OS.has_feature("mobile")


func apply_settings() -> void:
	# Skip display/audio hardware updates in headless test mode
	if DisplayServer.get_name() == "headless":
		return

	# Windowed/fullscreen mode applies only on desktop platforms
	if not (OS.has_feature("ios") or OS.has_feature("mobile")):
		var gfx: Dictionary = settings.get("graphics", {})
		var fullscreen: bool = bool(gfx.get("fullscreen", false))
		var target_mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != target_mode:
			DisplayServer.window_set_mode(target_mode)

		var vsync: bool = bool(gfx.get("vsync", true))
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
		)

	var audio: Dictionary = settings.get("audio", {})
	_apply_bus_linear("Master", float(audio.get("master_volume", 0.85)))
	_apply_bus_linear("SFX", float(audio.get("sfx_volume", 0.90)))
	_apply_bus_linear("Music", float(audio.get("music_volume", 0.70)))
	_apply_bus_linear("Ambience", float(audio.get("ambience_volume", 0.65)))


func _apply_bus_linear(bus_name: String, linear_val: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	if linear_val <= 0.0001:
		AudioServer.set_bus_volume_db(idx, -80.0)
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear_val, 0.0001, 1.5)))
