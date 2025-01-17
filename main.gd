extends Control

@onready var model_list = $HSplitContainer/VBoxContainer/ModelList
@onready var preview_viewport = $HSplitContainer/SubViewportContainer/SubViewport
@onready var preview_camera = $HSplitContainer/SubViewportContainer/SubViewport/Camera3D
@onready var select_project_button = $HSplitContainer/VBoxContainer/SelectProjectButton
@onready var status_label = $HSplitContainer/VBoxContainer/StatusLabel

var model_paths: Array[String] = []
var current_model: Node3D = null
var file_dialog: FileDialog
var camera_rotation: float = 0.0
var camera_distance: float = 5.0
var camera_height: float = 2.0
var is_rotating: bool = true
var loading_dialog: AcceptDialog
var dragging := true
var camera_min_distance := 1.0
var camera_max_distance := 50.0
var orbit_center := Vector3.ZERO  # Центр вращения камеры
var camera_sensitivity := 0.005   # Чувствительность вращения камеры

func _ready():
	print("Начало инициализации просмотрщика моделей")
	# Change initialization order to ensure UI elements exist before we try to use them
	await get_tree().process_frame  # Wait one frame to ensure all nodes are ready
	_init_ui()
	_init_file_dialog()
	setup_preview_camera()
	setup_light()

func _init_file_dialog() -> void:
	# Check if dialog already exists to prevent duplicates
	if file_dialog != null:
		file_dialog.queue_free()
	
	# Create new dialog
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Выберите папку с моделями"
	file_dialog.size = Vector2(800, 600)
	file_dialog.min_size = Vector2(400, 300)  # Set minimum size
	
	# Make sure dialog appears on top
	file_dialog.exclusive = false  # Делаем диалог не эксклюзивным
	file_dialog.unresizable = false
	file_dialog.always_on_top = true
	file_dialog.close_requested.connect(func(): file_dialog.hide())  # Добавляем возможность закрыть
	
	# Add dialog to the scene tree
	get_tree().root.add_child(file_dialog)
	
	# Connect signals
	if !file_dialog.dir_selected.is_connected(_on_project_dir_selected):
		file_dialog.dir_selected.connect(_on_project_dir_selected)
	
	if !model_list.item_selected.is_connected(_on_model_selected):
		model_list.item_selected.connect(_on_model_selected)
	
	if !select_project_button.pressed.is_connected(_on_select_project_pressed):
		select_project_button.pressed.connect(_on_select_project_pressed)

func _init_ui() -> void:
	# Make sure required nodes exist
	var required_nodes = {
		"model_list": model_list,
		"preview_viewport": preview_viewport,
		"preview_camera": preview_camera,
		"select_project_button": select_project_button,
		"status_label": status_label
	}
	
	for node_name in required_nodes:
		if required_nodes[node_name] == null:
			push_error("Required node '%s' not found!" % node_name)
			return
	
	# Initialize UI elements
	status_label.text = "Готов к работе"
	
	# Setup loading dialog
	loading_dialog = AcceptDialog.new()
	loading_dialog.title = "Загрузка"
	loading_dialog.dialog_text = "Загрузка модели..."
	loading_dialog.size = Vector2(200, 100)
	loading_dialog.exclusive = false  # Делаем диалог не эксклюзивным
	loading_dialog.always_on_top = true
	loading_dialog.unresizable = true
	loading_dialog.close_requested.connect(func(): loading_dialog.hide())  # Добавляем возможность закрыть
	add_child(loading_dialog)
	
	# Configure viewport
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	preview_viewport.transparent_bg = false

# Add error handling helper
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Clean up dialogs when scene is being removed
		if file_dialog:
			file_dialog.queue_free()
		if loading_dialog:
			loading_dialog.queue_free()

func _on_model_selected(index: int) -> void:
	if index < 0 or index >= model_paths.size():
		return
	
	if loading_dialog:
		loading_dialog.dialog_text = "Загрузка модели...\nЭто может занять некоторое время"
		loading_dialog.popup_centered()
	status_label.text = "Загрузка модели..."
	
	var model_path = model_paths[index]
	print("Попытка загрузки файла: ", model_path)
	
	# Clear previous model
	if current_model:
		current_model.queue_free()
		current_model = null
	
	# Load new model with delay to allow UI update
	await get_tree().create_timer(0.1).timeout
	
	var model = load_model_from_path(model_path)
	if model:
		current_model = model
		preview_viewport.add_child(current_model)
		
		# Wait two frames to ensure model is fully initialized
		await get_tree().process_frame
		await get_tree().process_frame
		
		# Reset camera position
		camera_rotation = 0.0
		camera_height = 2.0
		orbit_center = Vector3.ZERO
		
		# Center model and setup camera
		center_camera_on_model()
		status_label.text = "Модель загружена успешно"
	else:
		status_label.text = "Ошибка загрузки модели"
	
	if loading_dialog:
		loading_dialog.hide()

func load_model_from_path(path: String) -> Node3D:
	var extension = path.get_extension().to_lower()
	
	if extension in ["gltf", "glb"]:
		var doc = GLTFDocument.new()
		var state = GLTFState.new()
		
		# Read file bytes
		var file = FileAccess.open(path, FileAccess.READ)
		if !file:
			print("Failed to open file: ", path)
			return null
			
		var bytes = file.get_buffer(file.get_length())
		file.close()
		
		# Parse GLTF with proper base path for textures
		var base_path = path.get_base_dir()
		var err = doc.append_from_buffer(bytes, base_path, state)
		if err != OK:
			print("Error parsing GLTF data: ", err)
			return null
		
		# Generate scene with proper setup
		var scene = doc.generate_scene(state)
		if scene:
			var root = Node3D.new()
			root.add_child(scene)
			scene.owner = root
			
			# Reset transform
			root.transform = Transform3D.IDENTITY
			scene.transform = Transform3D.IDENTITY
			
			# Adjust model scale if needed (переименовываем переменную чтобы избежать конфликта)
			var model_scale = 1.0
			root.scale = Vector3(model_scale, model_scale, model_scale)
			
			print("Model successfully loaded via GLTFDocument")
			return root
			
		print("Failed to generate scene")
		return null
	
	print("Unsupported file format: ", extension)
	return null

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
			if extension in ["glb", "gltf"]:  # Пока работаем только с этими форматами
				print("Найдена модель: ", full_path)
				model_paths.append(full_path)
				model_list.add_item(file_name)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _on_select_project_pressed() -> void:
	file_dialog.popup_centered()

func _on_project_dir_selected(dir: String) -> void:
	print("Выбрана папка: ", dir)
	model_list.clear()
	model_paths.clear()
	if current_model:
		current_model.queue_free()
		current_model = null
	
	scan_project_models(dir)
	print("Найдено моделей: ", model_paths.size())

func setup_preview_camera() -> void:
	if !preview_camera:
		return
		
	# Setup better initial camera position
	preview_camera.position = Vector3(0, camera_height, camera_distance)
	preview_camera.look_at(Vector3.ZERO)
	
	# Configure camera properties
	preview_camera.fov = 45.0  # More reasonable field of view
	preview_camera.near = 0.1
	preview_camera.far = 1000.0

func update_camera_position() -> void:
	if !current_model:
		return
		
	# Вычисляем позицию камеры в сферических координатах
	var x = cos(camera_rotation) * camera_distance
	var z = sin(camera_rotation) * camera_distance
	
	# Устанавливаем позицию камеры
	preview_camera.global_position = orbit_center + Vector3(x, camera_height, z)
	preview_camera.look_at(orbit_center)  # Всегда смотрим на центр

func get_model_center() -> Vector3:
	if !current_model:
		return Vector3.ZERO

	var aabb = AABB()
	var has_mesh = false
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_aabb = child.get_aabb()
			if !has_mesh:
				aabb = mesh_aabb
				has_mesh = true
			else:
				aabb = aabb.merge(mesh_aabb)

	if has_mesh:
		return aabb.position + aabb.size * 0.5
	return Vector3.ZERO

func center_camera_on_model() -> void:
	if !current_model:
		return
	
	await get_tree().process_frame  # Даем время на инициализацию
	
	var aabb = AABB()
	var has_mesh = false
	
	# Получаем все MeshInstance3D
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_aabb = (child as MeshInstance3D).get_aabb()
			var global_pos = child.global_position
			
			# Учитываем глобальную позицию
			mesh_aabb.position += global_pos
			
			if !has_mesh:
				aabb = mesh_aabb
				has_mesh = true
			else:
				aabb = aabb.merge(mesh_aabb)
	
	if has_mesh:
		# Вычисляем размеры и центр модели
		var model_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		orbit_center = aabb.get_center()  # Устанавливаем центр вращения
		
		# Настраиваем камеру
		camera_distance = model_size * 2.5
		camera_height = 0  # Начинаем с центра
		
		# Центрируем модель
		current_model.global_position = -orbit_center
		orbit_center = Vector3.ZERO  # Сбрасываем центр вращения после центрирования
		
		# Обновляем позицию камеры
		update_camera_position()
		
		print("Model size: ", model_size)
		print("Camera distance: ", camera_distance)

func _unhandled_input(event: InputEvent) -> void:
	if !current_model:
		return
		
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:  # Вращение камеры
				dragging = event.pressed
				# Сбрасываем поворот при начале вращения
				if dragging:
					orbit_center = Vector3.ZERO
					
			MOUSE_BUTTON_WHEEL_UP:  # Приближение
				camera_distance = max(camera_min_distance, camera_distance * 0.9)
				update_camera_position()
				
			MOUSE_BUTTON_WHEEL_DOWN:  # Отдаление
				camera_distance = min(camera_max_distance, camera_distance * 1.1)
				update_camera_position()
			
	elif event is InputEventMouseMotion and dragging:
		# Вращение вокруг модели
		camera_rotation -= event.relative.x * camera_sensitivity
		var vertical_rotation = event.relative.y * camera_sensitivity
		
		# Ограничиваем вертикальное вращение
		camera_height = clamp(
			camera_height - vertical_rotation * camera_distance,
			-camera_distance * 0.8,  # Минимальная высота
			camera_distance * 0.8    # Максимальная высота
		)
		
		update_camera_position()

# Helper function to recursively get all children
func _get_all_children(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(_get_all_children(child))
	return children

func setup_light() -> void:
	if !preview_viewport:
		return
		
	# Remove existing light if any
	var existing_light = preview_viewport.get_node_or_null("DirectionalLight3D")
	if existing_light:
		existing_light.queue_free()
	
	# Create main directional light
	var main_light = DirectionalLight3D.new()
	main_light.name = "MainLight"
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.2
	preview_viewport.add_child(main_light)
	
	# Add fill light from opposite direction
	var fill_light = DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.rotation_degrees = Vector3(-45, 135, 0)
	fill_light.light_energy = 0.5
	preview_viewport.add_child(fill_light)
