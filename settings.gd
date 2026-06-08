extends Node

const SETTINGS_FILE := "user://viewer_settings.cfg"
const SAVE_DEBOUNCE_SECONDS := 0.6
const DEFAULT_SETTINGS := {
	"last_directory": "",
	"last_model": "",
	"auto_rotation": true,
	"rotation_speed": 0.5,
	"camera_distance": 5.0,
	"camera_horizontal_angle": 0.0,
	"camera_vertical_angle": PI / 4,
	"orbit_center_x": 0.0,
	"orbit_center_y": 0.0,
	"orbit_center_z": 0.0,
	"camera_position_x": 0.0,
	"camera_position_y": 0.0,
	"camera_position_z": 0.0,
	"wasd_position_x": 0.0,
	"wasd_position_y": 0.0,
	"wasd_position_z": 0.0,
	"animation_playing": false,
	"current_animation": "",
	"animation_position": 0.0,
	"recent_models": "[]",
	"recent_folders": "[]",
	"favorites": "[]"
}

var config := ConfigFile.new()
var current_settings := {}
var _save_timer: Timer


func _ready() -> void:
	load_settings()
	_init_save_timer()


func _init_save_timer() -> void:
	if _save_timer:
		return
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DEBOUNCE_SECONDS
	_save_timer.timeout.connect(save_settings)
	add_child(_save_timer)


func get_setting(key: String):
	return current_settings.get(key, DEFAULT_SETTINGS.get(key))


func load_settings() -> void:
	if !FileAccess.file_exists(SETTINGS_FILE):
		current_settings = DEFAULT_SETTINGS.duplicate(true)
		return

	var err := config.load(SETTINGS_FILE)
	if err != OK:
		push_warning("Failed to load settings, using defaults. Error: %s" % err)
		current_settings = DEFAULT_SETTINGS.duplicate(true)
		return

	current_settings = {}
	for key in DEFAULT_SETTINGS:
		var value: Variant = config.get_value("Settings", key, DEFAULT_SETTINGS[key])
		current_settings[key] = _sanitize_setting(key, value)


func _sanitize_setting(key: String, value):
	var default_value: Variant = DEFAULT_SETTINGS[key]
	if typeof(value) != typeof(default_value):
		return default_value

	match key:
		"rotation_speed":
			return clamp(float(value), 0.1, 2.0)
		"camera_distance":
			return max(float(value), 0.1)
		"camera_vertical_angle":
			return clamp(float(value), 0.1, PI - 0.1)
		_:
			return value


func save_settings() -> void:
	if _save_timer and !_save_timer.is_stopped():
		_save_timer.stop()

	for key in current_settings:
		if key in DEFAULT_SETTINGS:
			config.set_value("Settings", key, current_settings[key])

	var err := config.save(SETTINGS_FILE)
	if err != OK:
		push_warning("Failed to save settings: %s" % err)


func set_setting(key: String, value, save_now: bool = false) -> void:
	current_settings[key] = value
	if save_now:
		save_settings()
	else:
		_schedule_save()


func _schedule_save() -> void:
	if !is_inside_tree():
		return
	_init_save_timer()
	_save_timer.start(SAVE_DEBOUNCE_SECONDS)


# ── Recent models ──────────────────────────────────────────────────────────────
func get_recent_models() -> Array:
	var parsed: Variant = JSON.parse_string(str(get_setting("recent_models")))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	return parsed


func add_recent_model(path: String, max_count: int = 10) -> void:
	var recent: Array = get_recent_models()
	recent.erase(path)
	recent.insert(0, path)
	while recent.size() > max_count:
		recent.pop_back()
	set_setting("recent_models", JSON.stringify(recent))


# ── Recent folders ────────────────────────────────────────────────────────────
func get_recent_folders() -> Array:
	var parsed: Variant = JSON.parse_string(str(get_setting("recent_folders")))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	return parsed


func add_recent_folder(path: String, max_count: int = 8) -> void:
	var folders: Array = get_recent_folders()
	folders.erase(path)
	folders.insert(0, path)
	while folders.size() > max_count:
		folders.pop_back()
	set_setting("recent_folders", JSON.stringify(folders))


# ── Favorites ──────────────────────────────────────────────────────────────────
func get_favorites() -> Array:
	var parsed: Variant = JSON.parse_string(str(get_setting("favorites")))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	return parsed


func set_favorites(favs: Array) -> void:
	set_setting("favorites", JSON.stringify(favs))


func is_favorite(path: String) -> bool:
	return path in get_favorites()


func add_favorite(path: String) -> void:
	var favs: Array = get_favorites()
	if path not in favs:
		favs.append(path)
		set_favorites(favs)


func remove_favorite(path: String) -> void:
	var favs: Array = get_favorites()
	if path in favs:
		favs.erase(path)
		set_favorites(favs)
