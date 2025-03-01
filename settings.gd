extends Node

const SETTINGS_FILE = "user://viewer_settings.cfg"
const DEFAULT_SETTINGS = {
	"last_directory": "",
	"last_model": "",
	"auto_rotation": true,
	"rotation_speed": 0.5,
	"camera_distance": 5.0,
	"camera_horizontal_angle": 0.0,
	"camera_vertical_angle": PI/4,
	"orbit_center_x": 0.0,
	"orbit_center_y": 0.0,
	"orbit_center_z": 0.0,
	"camera_position_x": 0.0,
	"camera_position_y": 0.0,
	"camera_position_z": 0.0,
	"wasd_position_x": 0.0,
	"wasd_position_y": 0.0,
	"wasd_position_z": 0.0
}

var config = ConfigFile.new()
var current_settings = {}

func _ready():
	load_settings()

func get_setting(key: String):
	var value = current_settings.get(key, DEFAULT_SETTINGS.get(key))
	return value

func load_settings():
	if not FileAccess.file_exists(SETTINGS_FILE):
		print("Settings file does not exist, using defaults")
		current_settings = DEFAULT_SETTINGS.duplicate()
		return
		
	var err = config.load(SETTINGS_FILE)
	if err != OK:
		print("Failed to load settings, using defaults")
		current_settings = DEFAULT_SETTINGS.duplicate()
		return
		
	current_settings = {}
	for key in DEFAULT_SETTINGS:
		var value = config.get_value("Settings", key, DEFAULT_SETTINGS[key])
		
		if typeof(value) != typeof(DEFAULT_SETTINGS[key]):
			print("Invalid type for setting", key, ", using default")
			current_settings[key] = DEFAULT_SETTINGS[key]
			continue
			
		match key:
			"rotation_speed":
				if value < 0.1 or value > 2.0:
					value = DEFAULT_SETTINGS[key]
			"camera_distance":
				if value <= 0:
					value = DEFAULT_SETTINGS[key]
			"camera_vertical_angle":
				if value < 0.1 or value > PI - 0.1:
					value = DEFAULT_SETTINGS[key]
					
		current_settings[key] = value

func save_settings():
	var dir = DirAccess.open("user://")
	if not dir:
		print("Failed to access user directory")
		return
		
	for key in current_settings:
		if key in DEFAULT_SETTINGS:
			config.set_value("Settings", key, current_settings[key])
			
	var err = config.save(SETTINGS_FILE)
	if err != OK:
		print("Failed to save settings:", err)
	else:
		print("=== Settings saved successfully ===")

func set_setting(key: String, value):
	current_settings[key] = value
	save_settings()
