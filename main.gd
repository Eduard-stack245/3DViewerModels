extends Control

@onready var model_list = $HSplitContainer/VBoxContainer/ModelList
@onready var select_project_button = $HSplitContainer/VBoxContainer/SelectProjectButton
@onready var status_label = $HSplitContainer/VBoxContainer/StatusLabel
@onready var viewport_container = $HSplitContainer/SubViewportContainer
@onready var settings = preload("res://settings.gd").new()

# Основные переменные 
var model_paths: Array[String] = []
var file_dialog: FileDialog
var loading_dialog: AcceptDialog

func _ready():
	add_child(settings)
	print("Начало инициализации просмотрщика моделей")
	
	# Регистрируем действие для пробела
	if !InputMap.has_action("toggle_rotation"):
		print("Registering toggle_rotation action")
		InputMap.add_action("toggle_rotation")
		var event = InputEventKey.new()
		event.keycode = KEY_SPACE
		InputMap.action_add_event("toggle_rotation", event)
		print("Toggle rotation action registered")
	
	await get_tree().process_frame
	_init_ui()
	_init_file_dialog()
	_load_saved_settings()

func _init_file_dialog() -> void:
	if file_dialog != null:
		file_dialog.queue_free()
	
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Выберите папку с моделями"
	file_dialog.size = Vector2(800, 600)
	file_dialog.min_size = Vector2(400, 300)
	file_dialog.set_current_dir("/")
	
	file_dialog.dir_selected.connect(_on_project_dir_selected)
	file_dialog.canceled.connect(func(): file_dialog.hide())
	
	get_tree().root.add_child(file_dialog)
	
	model_list.item_selected.connect(_on_model_selected)
	select_project_button.pressed.connect(_on_select_project_pressed)

func _init_ui() -> void:
	var required_nodes = {
		"model_list": model_list,
		"preview_viewport": viewport_container.preview_viewport,
		"preview_camera": viewport_container.preview_camera,
		"select_project_button": select_project_button,
		"status_label": status_label
	}
	
	for node_name in required_nodes:
		if required_nodes[node_name] == null:
			push_error("Required node '%s' not found!" % node_name)
			return
	
	status_label.text = "Готов к работе"
	
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

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		print("=== Saving settings before exit ===")
		if viewport_container:
			print("Saving viewport settings...")
			settings.set_setting("auto_rotation", viewport_container.is_rotating)
			settings.set_setting("rotation_speed", viewport_container.auto_rotation_speed)
			settings.set_setting("camera_distance", viewport_container.camera_distance)
			settings.set_setting("camera_horizontal_angle", viewport_container.camera_horizontal_angle)
			settings.set_setting("camera_vertical_angle", viewport_container.camera_vertical_angle)
			
			# Сохраняем последнюю открытую модель
			if viewport_container.current_model and !model_paths.is_empty() and model_list.get_selected_items().size() > 0:
				var current_model_path = model_paths[model_list.get_selected_items()[0]]
				print("Saving last model path:", current_model_path)
				settings.set_setting("last_model", current_model_path)
			
		print("=== Settings saved ===")
		get_tree().quit()

func _load_saved_settings():
	print("=== Starting to load saved settings ===")
	var last_dir = settings.get_setting("last_directory")
	
	if last_dir != "" and DirAccess.dir_exists_absolute(last_dir):
		print("Loading directory:", last_dir)
		file_dialog.current_dir = last_dir
		scan_project_models(last_dir)
		
		var last_model = settings.get_setting("last_model")
		if last_model != "" and FileAccess.file_exists(last_model):
			var model_index = model_paths.find(last_model)
			if model_index != -1:
				model_list.select(model_index)
				await get_tree().create_timer(0.1).timeout
				viewport_container.load_in_preview_portal(last_model)
				
				# Устанавливаем настройки вращения
				viewport_container.is_rotating = settings.get_setting("auto_rotation")
				viewport_container.auto_rotation_speed = settings.get_setting("rotation_speed")
				viewport_container.initial_auto_rotation_speed = settings.get_setting("rotation_speed")
				print("Rotation settings loaded:")
				print("- Auto rotation:", viewport_container.is_rotating)
				print("- Speed:", viewport_container.auto_rotation_speed)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_rotation"):
		print("Space pressed in main.gd")
		if viewport_container.current_model:
			print("Toggling rotation")
			viewport_container.toggle_rotation()
			get_viewport().set_input_as_handled()

func _on_model_selected(index: int) -> void:
	if index < 0 or index >= model_paths.size():
		return
	
	if loading_dialog:
		loading_dialog.popup_centered()
	status_label.text = "Загрузка модели..."
	
	var model_path = model_paths[index]
	print("Попытка загрузки файла: ", model_path)
	
	status_label.text = viewport_container.load_in_preview_portal(model_path)
	
	await get_tree().create_timer(0.1).timeout
	
	if loading_dialog:
		loading_dialog.hide()

func _on_select_project_pressed() -> void:
	file_dialog.popup_centered()

func _on_project_dir_selected(dir: String) -> void:
	print("Выбрана папка: ", dir)
	settings.set_setting("last_directory", dir)
	
	if dir.ends_with(":") or dir.ends_with(":\\"):
		file_dialog.current_dir = dir
		file_dialog.popup_centered()
		return
	
	model_list.clear()
	model_paths.clear()
	viewport_container.clear_model()
	scan_project_models(dir)

func scan_project_models(path: String) -> void:
	var dir = DirAccess.open(path)
	if !dir:
		status_label.text = "Ошибка: не удалось открыть папку"
		return
		
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		var full_path = path.path_join(file_name)
		
		if dir.current_is_dir() and file_name != "." and file_name != "..":
			scan_project_models(full_path)
		else:
			var extension = file_name.get_extension().to_lower()
			if extension in ["glb", "gltf"]:
				print("Найдена модель: ", full_path)
				model_paths.append(full_path)
				model_list.add_item(file_name)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
