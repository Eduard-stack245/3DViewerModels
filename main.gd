extends Control

@onready var model_list = $HSplitContainer/VBoxContainer/ModelList
@onready var select_project_button = $HSplitContainer/VBoxContainer/SelectProjectButton
@onready var status_label = $HSplitContainer/VBoxContainer/StatusLabel
@onready var viewport_container = $HSplitContainer/SubViewportContainer

# Основные переменные 
var model_paths: Array[String] = []
var file_dialog: FileDialog
var loading_dialog: AcceptDialog

func _ready():
	print("Начало инициализации просмотрщика моделей")
	await get_tree().process_frame
	_init_ui()
	_init_file_dialog()

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
	if what == NOTIFICATION_PREDELETE:
		if is_instance_valid(file_dialog):
			file_dialog.queue_free()
		if is_instance_valid(loading_dialog):
			loading_dialog.queue_free()

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
	
	if dir.ends_with(":") or dir.ends_with(":\\"):
		print("Выбран диск, устанавливаю его в качестве текущей папки...")
		file_dialog.set_current_dir(dir)
		file_dialog.popup_centered()
		return
	
	model_list.clear()
	model_paths.clear()
	viewport_container.clear_model()
	
	scan_project_models(dir)
	print("Найдено моделей: ", model_paths.size())

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
