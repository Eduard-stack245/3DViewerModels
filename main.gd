extends Control

@onready var model_list = $HSplitContainer/VBoxContainer/ModelContainer/ModelList
@onready var select_project_button = $HSplitContainer/VBoxContainer/ButtonContainer/SelectProjectButton
@onready var viewport_container = $HSplitContainer/HBoxContainer2/VBoxContainer2/SubViewportContainer
@onready var search_box = $HSplitContainer/VBoxContainer/SearchLineEdit
@onready var settings = preload("res://settings.gd").new()
@onready var model_info_panel = $HSplitContainer/HBoxContainer2/HBoxContainer/ModelInfoPanel
@onready var button_container = $HSplitContainer/VBoxContainer/ButtonContainer

var model_paths: Array[String] = []
var filtered_model_paths: Array[String] = []
var file_dialog: FileDialog
var loading_dialog: AcceptDialog
const SUPPORTED_EXTENSIONS = ["glb", "gltf", "obj"]

var model_info = {}

func _ready():
	add_child(settings)
	
	if model_list:
		model_list.clear()
		model_list.item_selected.connect(_on_model_selected)
	
	if select_project_button:
		select_project_button.pressed.connect(_on_select_project_pressed)
	
	var export_import_container = HBoxContainer.new()
	export_import_container.size_flags_horizontal = Control.SIZE_SHRINK_END
	button_container.add_child(export_import_container)

	var export_button = Button.new()
	export_button.text = "Export"
	export_button.custom_minimum_size.x = 80
	export_button.pressed.connect(_on_export_pressed)
	export_import_container.add_child(export_button)

	var import_button = Button.new()
	import_button.text = "Import"
	import_button.custom_minimum_size.x = 80
	import_button.pressed.connect(_on_import_pressed)
	export_import_container.add_child(import_button)
	
	$HSplitContainer/VBoxContainer/ButtonContainer.add_child(export_button)
	$HSplitContainer/VBoxContainer/ButtonContainer.add_child(import_button)
	
	if search_box:
		search_box.text_changed.connect(_on_search_text_changed)
	
	if !InputMap.has_action("toggle_rotation"):
		InputMap.add_action("toggle_rotation")
		var event = InputEventKey.new()
		event.keycode = KEY_SPACE
		InputMap.action_add_event("toggle_rotation", event)
	
	await get_tree().process_frame
	_init_ui()
	_init_file_dialog()
	_load_saved_settings()

func _init_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Выберите папку с моделями"
	file_dialog.size = Vector2(800, 600)
	file_dialog.min_size = Vector2(400, 300)
	
	file_dialog.dir_selected.connect(_on_project_dir_selected)
	file_dialog.canceled.connect(func(): file_dialog.hide())
	
	add_child(file_dialog)

func _init_ui() -> void:
	var required_nodes = {
		"model_list": model_list,
		"preview_viewport": viewport_container.preview_viewport,
		"preview_camera": viewport_container.preview_camera,
		"select_project_button": select_project_button,
		"search_box": search_box
	}
	
	for node_name in required_nodes:
		if required_nodes[node_name] == null:
			push_error("Required node '%s' not found!" % node_name)
			return
	
	loading_dialog = AcceptDialog.new()
	loading_dialog.title = "Загрузка"
	loading_dialog.dialog_text = "Загрузка модели..."
	loading_dialog.size = Vector2(200, 100)
	loading_dialog.exclusive = false
	loading_dialog.always_on_top = true
	loading_dialog.canceled.connect(func(): loading_dialog.hide())
	add_child(loading_dialog)
	
	viewport_container.preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.preview_viewport.transparent_bg = false
	
func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if viewport_container and viewport_container.preview_viewport:
			viewport_container.preview_viewport.size = viewport_container.size
			viewport_container.save_camera_settings()
			
			if file_dialog and file_dialog.current_dir:
				settings.set_setting("last_directory", file_dialog.current_dir)
			
			if viewport_container.current_model and !model_paths.is_empty() and model_list.get_selected_items().size() > 0:
				var current_model_path = filtered_model_paths[model_list.get_selected_items()[0]]
				settings.set_setting("last_model", current_model_path)
			
			settings.save_settings()
		
		get_tree().quit()

func get_model_info(path: String) -> Dictionary:
	var info = {
		"filename": path.get_file(),
		"path": path,
		"size": "0 B",
		"date_modified": "",
		"type": path.get_extension().to_upper(),
		"vertices": "0",
		"faces": "0",
		"materials": "0"
	}
	
	var model_file = FileAccess.open(path, FileAccess.READ)
	if model_file:
		var file_size = model_file.get_length()
		info["size"] = _format_size(file_size)
		
		var file_modified = FileAccess.get_modified_time(path)
		var datetime = Time.get_datetime_dict_from_unix_time(file_modified)
		info["date_modified"] = "%d-%02d-%02d %02d:%02d:%02d" % [
			datetime["year"],
			datetime["month"],
			datetime["day"],
			datetime["hour"],
			datetime["minute"],
			datetime["second"]
		]
		
		match path.get_extension().to_lower():
			"obj":
				var vertex_count = 0
				var face_count = 0
				var material_count = 0
				var current_material = ""
				var materials = {}
				
				while !model_file.eof_reached():
					var line = model_file.get_line().strip_edges()
					if line.is_empty() or line.begins_with("#"):
						continue
						
					var parts = line.split(" ", false)
					if parts.size() < 2:
						continue
						
					match parts[0]:
						"v ":
							vertex_count += 1
						"f ":
							face_count += 1
						"usemtl ":
							var mat_name = parts[1]
							if !materials.has(mat_name):
								materials[mat_name] = true
								material_count += 1
				
				info["vertices"] = str(vertex_count)
				info["faces"] = str(face_count)
				info["materials"] = str(material_count)
				
			"gltf", "glb":
				var vertex_count = 0
				var face_count = 0
				var content = model_file.get_buffer(model_file.get_length())
				
				if path.ends_with(".glb"):
					var json_start = 20
					var json_length = content.decode_u32(8)
					var json_chunk = content.slice(json_start, json_start + json_length)
					var json_text = json_chunk.get_string_from_utf8()
					var json = JSON.parse_string(json_text)
					
					if json:
						if json.has("meshes"):
							for mesh in json["meshes"]:
								if mesh.has("primitives"):
									for primitive in mesh["primitives"]:
										if primitive.has("attributes"):
											if primitive["attributes"].has("POSITION"):
												var accessor_idx = primitive["attributes"]["POSITION"]
												if json.has("accessors") and accessor_idx < json["accessors"].size():
													vertex_count += json["accessors"][accessor_idx]["count"]
											
										if primitive.has("indices"):
											var indices_idx = primitive["indices"]
											if json.has("accessors") and indices_idx < json["accessors"].size():
												face_count += json["accessors"][indices_idx]["count"] / 3
						
						info["materials"] = str(json.get("materials", []).size())
				else:
					var json = JSON.parse_string(model_file.get_as_text())
					if json:
						if json.has("meshes"):
							for mesh in json["meshes"]:
								if mesh.has("primitives"):
									for primitive in mesh["primitives"]:
										if primitive.has("attributes"):
											if primitive["attributes"].has("POSITION"):
												var accessor_idx = primitive["attributes"]["POSITION"]
												if json.has("accessors") and accessor_idx < json["accessors"].size():
													vertex_count += json["accessors"][accessor_idx]["count"]
											
										if primitive.has("indices"):
											var indices_idx = primitive["indices"]
											if json.has("accessors") and indices_idx < json["accessors"].size():
												face_count += json["accessors"][indices_idx]["count"] / 3
						
						info["materials"] = str(json.get("materials", []).size())
				
				info["vertices"] = str(vertex_count)
				info["faces"] = str(face_count)
		
		model_file.close()
	
	return info

func _on_search_text_changed(new_text: String) -> void:
	update_model_list(new_text)

func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1024 * 1024:
		return "%.2f KB" % (bytes / 1024.0)
	else:
		return "%.2f MB" % (bytes / (1024.0 * 1024.0))

func show_model_info(index: int) -> void:
	if index < 0 or index >= filtered_model_paths.size():
		return
	
	var model_path = filtered_model_paths[index]
	var info = get_model_info(model_path)
	
	var details = viewport_container.get_model_details()
	info.merge(details)
	
	model_info_panel.update_info(info)

func update_model_list(search_text: String = "") -> void:
	model_list.clear()
	filtered_model_paths.clear()
	
	var search_text_lower = search_text.to_lower()
	
	for path in model_paths:
		var file_name = path.get_file().to_lower()
		if search_text_lower.is_empty() or file_name.contains(search_text_lower):
			filtered_model_paths.append(path)
			var idx = model_list.add_item(path.get_file())

func _load_saved_settings():
	var last_dir = settings.get_setting("last_directory")
	
	if last_dir != "" and DirAccess.dir_exists_absolute(last_dir):
		file_dialog.current_dir = last_dir
		scan_project_models(last_dir)
		
		var last_model = settings.get_setting("last_model")
		if last_model != "" and FileAccess.file_exists(last_model):
			update_model_list()
			
			var model_index = filtered_model_paths.find(last_model)
			if model_index != -1:
				if model_index < model_list.item_count:
					model_list.select(model_index)
					await get_tree().create_timer(0.1).timeout
					
					viewport_container.load_in_preview_portal(last_model)
					show_model_info(model_index)
					
					viewport_container.is_rotating = settings.get_setting("auto_rotation")
					viewport_container.auto_rotation_speed = settings.get_setting("rotation_speed")
					viewport_container.initial_auto_rotation_speed = settings.get_setting("rotation_speed")
					
				else:
					print("Invalid model index:", model_index)
			else:
				print("Model not found in filtered paths:", last_model)

func _on_export_pressed():
	var export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "Сохранить настройки"
	export_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	export_dialog.current_file = "viewer_settings.json"
	export_dialog.add_filter("*.json", "JSON files")
	
	export_dialog.file_selected.connect(func(path):
		var data = {
			"camera_settings": {
				"distance": viewport_container.camera_distance,
				"horizontal_angle": viewport_container.camera_horizontal_angle,
				"vertical_angle": viewport_container.camera_vertical_angle,
				"orbit_center": {
					"x": viewport_container.orbit_center.x,
					"y": viewport_container.orbit_center.y,
					"z": viewport_container.orbit_center.z
				}
			},
			"rotation_settings": {
				"enabled": viewport_container.is_rotating,
				"speed": viewport_container.auto_rotation_speed
			},
			"directory": file_dialog.current_dir if file_dialog else "",
			"current_model": model_list.get_selected_items()[0] if model_list.get_selected_items().size() > 0 else -1
		}
		
		var settings_file = FileAccess.open(path, FileAccess.WRITE)
		if settings_file:
			settings_file.store_string(JSON.stringify(data, "  "))
			settings_file.close()
	)
	
	add_child(export_dialog)
	export_dialog.popup_centered(Vector2(800, 600))

func _on_import_pressed():
	var import_dialog = FileDialog.new()
	import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	import_dialog.title = "Загрузить настройки"
	import_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	import_dialog.add_filter("*.json", "JSON files")
	
	import_dialog.file_selected.connect(func(path):
		var settings_file = FileAccess.open(path, FileAccess.READ)
		if settings_file:
			var json_string = settings_file.get_as_text()
			settings_file.close()
			
			var data = JSON.parse_string(json_string)
			if data:
				if data.has("camera_settings"):
					viewport_container.camera_distance = data.camera_settings.distance
					viewport_container.camera_horizontal_angle = data.camera_settings.horizontal_angle
					viewport_container.camera_vertical_angle = data.camera_settings.vertical_angle
					viewport_container.orbit_center = Vector3(
						data.camera_settings.orbit_center.x,
						data.camera_settings.orbit_center.y,
						data.camera_settings.orbit_center.z
					)
				
				if data.has("rotation_settings"):
					viewport_container.is_rotating = data.rotation_settings.enabled
					viewport_container.auto_rotation_speed = data.rotation_settings.speed
				
				if data.has("directory") and data.directory != "":
					if DirAccess.dir_exists_absolute(data.directory):
						file_dialog.current_dir = data.directory
						scan_project_models(data.directory)
						
						if data.has("current_model") and data.current_model >= 0:
							if data.current_model < model_list.item_count:
								model_list.select(data.current_model)
								_on_model_selected(data.current_model)
				
				viewport_container.update_camera_position()
	)
	
	add_child(import_dialog)
	import_dialog.popup_centered(Vector2(800, 600))

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_rotation"):
		if viewport_container.current_model:
			viewport_container.toggle_rotation()
			get_viewport().set_input_as_handled()

func _on_model_selected(index: int) -> void:
	if index < 0 or index >= filtered_model_paths.size():
		return
	
	if loading_dialog:
		loading_dialog.popup_centered()
	
	var model_path = filtered_model_paths[index]
	
	var result = viewport_container.load_in_preview_portal(model_path)
	
	show_model_info(index)
	
	if loading_dialog:
		loading_dialog.hide()

func _on_select_project_pressed() -> void:
	file_dialog.popup_centered()

func _on_project_dir_selected(dir: String) -> void:
	settings.set_setting("last_directory", dir)
	file_dialog.current_dir = dir
	
	model_paths.clear()
	filtered_model_paths.clear()
	model_list.clear()
	viewport_container.clear_model()
	
	scan_project_models(dir)

func scan_project_models(path: String) -> void:
	var dir = DirAccess.open(path)
	if !dir:
		print("Error: Failed to open directory")
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path.path_join(file_name)
			
			if dir.current_is_dir():
				scan_project_models(full_path)
			else:
				var extension = file_name.get_extension().to_lower()
				if extension in SUPPORTED_EXTENSIONS:
					model_paths.append(full_path)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	
	call_deferred("update_model_list", search_box.text if search_box else "")
