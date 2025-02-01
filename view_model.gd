extends SubViewportContainer
class_name PreviewModel

@onready var preview_viewport = %SubViewport
@onready var preview_camera = %Camera3D

var last_mouse_position: Vector2 = Vector2.ZERO
var current_model: Node3D = null
var is_dragging := false
var camera_horizontal_angle := 0.0     # Горизонтальный угол поворота
var camera_vertical_angle := PI/4      # Вертикальный угол (начинаем с 45 градусов)
var camera_distance := 5.0             # Расстояние от камеры до цели
var camera_sensitivity := 0.01         # Чувствительность мыши
var orbit_center := Vector3.ZERO       # Центр вращения
var dragging := false                  # Флаг перетаскивания
var is_rotating := true                # Автовращение
var mouse_in_viewport := false
var auto_rotation_speed := 0.5  # Скорость автовращения
var initial_auto_rotation_speed := 0.5  # Начальная скорость для восстановления
var saved_settings_loaded := false

func _ready():
	print("Начало инициализации просмотрщика моделей")
	await get_tree().process_frame
	setup_preview_camera()
	setup_light()

	mouse_entered.connect(_on_viewport_mouse_entered)
	mouse_exited.connect(_on_viewport_mouse_exited)
	
	# Устанавливаем начальные значения вращения
	is_rotating = true  # Автовращение включено по умолчанию
	auto_rotation_speed = owner.settings.get_setting("rotation_speed")
	initial_auto_rotation_speed = auto_rotation_speed
	
func _process(delta: float) -> void:
	if current_model and is_rotating and !dragging:
		# Прямое вращение без плавности для отладки
		camera_horizontal_angle += delta * auto_rotation_speed
		update_camera_position()
		print("Rotating: angle=", camera_horizontal_angle, " speed=", auto_rotation_speed)
		
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		owner.settings.set_setting("camera_horizontal_angle", camera_horizontal_angle)
		owner.settings.set_setting("camera_vertical_angle", camera_vertical_angle)

func load_in_preview_portal(model_path):
	print("Loading model from path:", model_path)
	clear_model()
	var model = load_model_from_path(model_path)
	if model:
		current_model = model
		preview_viewport.add_child(current_model)
		print("Model loaded successfully")
		
		# Загружаем сохраненные настройки камеры
		if !saved_settings_loaded:
			print("Loading saved camera settings...")
			camera_horizontal_angle = owner.settings.get_setting("camera_horizontal_angle")
			camera_vertical_angle = owner.settings.get_setting("camera_vertical_angle")
			camera_distance = owner.settings.get_setting("camera_distance")
			auto_rotation_speed = owner.settings.get_setting("rotation_speed")
			initial_auto_rotation_speed = auto_rotation_speed
			saved_settings_loaded = true
			
			# Всегда включаем автовращение при первой загрузке
			is_rotating = true
		else:
			# При загрузке последующих моделей сохраняем текущий угол поворота
			print("Using current camera angles")
		
		print("Camera settings:")
		print("- Horizontal angle:", camera_horizontal_angle)
		print("- Vertical angle:", camera_vertical_angle)
		print("- Distance:", camera_distance)
		print("- Auto rotation:", is_rotating)
		print("- Rotation speed:", auto_rotation_speed)
		
		orbit_center = Vector3.ZERO
		center_camera_on_model()
		update_camera_position()
		
		# Сохраняем настройки
		if owner and owner.settings:
			owner.settings.set_setting("auto_rotation", is_rotating)
			owner.settings.set_setting("rotation_speed", auto_rotation_speed)
		
		return "Модель загружена успешно"
	else:
		print("Failed to load model")
		return "Ошибка загрузки модели"

func load_model_from_path(path: String) -> Node3D:
	var extension = path.get_extension().to_lower()
	
	if extension in ["gltf", "glb"]:
		var doc = GLTFDocument.new()
		var state = GLTFState.new()
		
		# Настраиваем параметры загрузки
		state.handle_binary_image = true  # Обрабатываем бинарные изображения
		state.use_named_skin_binds = true  # Используем именованные привязки скелета
		
		# Читаем файл
		var file = FileAccess.open(path, FileAccess.READ)
		if !file:
			print("Failed to open file: ", path)
			return null
			
		var bytes = file.get_buffer(file.get_length())
		file.close()
		
		# Загружаем модель
		var err = doc.append_from_buffer(bytes, path.get_base_dir(), state)
		if err != OK:
			print("Error parsing GLTF data: ", err)
			return null
		
		# Генерируем сцену
		var scene = doc.generate_scene(state)
		if scene:
			var root = Node3D.new()
			root.add_child(scene)
			scene.owner = root
			
			# Применяем материалы и текстуры
			for node in _get_all_children(root):
				if node is MeshInstance3D:
					_apply_materials(node)
			
			# Сбрасываем трансформации
			root.transform = Transform3D.IDENTITY
			scene.transform = Transform3D.IDENTITY
			
			print("Model successfully loaded via GLTFDocument")
			return root
			
		print("Failed to generate scene")
		return null
	
	print("Unsupported file format: ", extension)
	return null

func _apply_materials(mesh_instance: MeshInstance3D) -> void:
	var mesh = mesh_instance.mesh
	if mesh:
		for surface_idx in range(mesh.get_surface_count()):
			var material = mesh.surface_get_material(surface_idx)
			if material:
				# Убедимся, что материал правильно настроен
				if material is StandardMaterial3D:
					material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					material.cull_mode = BaseMaterial3D.CULL_BACK
					material.vertex_color_use_as_albedo = true

func clear_model():
	if current_model:
			current_model.queue_free()
			current_model = null

func _on_viewport_mouse_entered() -> void:
	mouse_in_viewport = true
	print("Mouse entered viewport")

func _on_viewport_mouse_exited() -> void:
	mouse_in_viewport = false
	dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("Mouse exited viewport")

func _input(event: InputEvent) -> void:
	if !current_model:
		return
		
	if event.is_action_pressed("toggle_rotation"):
		print("Space pressed in view_model.gd")
		toggle_rotation()
		get_viewport().set_input_as_handled()
		
	if !mouse_in_viewport:
		return
		
	if event is InputEventMouseButton:
		print("Mouse button event: ", event.button_index, " pressed: ", event.pressed)
		
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_dragging = event.pressed
			if is_dragging:
				last_mouse_position = event.position
				print("Started dragging at: ", last_mouse_position)
				# Временно останавливаем вращение при перетаскивании
				if is_rotating:
					auto_rotation_speed = 0.0
			else:
				print("Stopped dragging")
				# Восстанавливаем вращение после перетаскивания
				if is_rotating:
					auto_rotation_speed = initial_auto_rotation_speed
				
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and mouse_in_viewport:
			var model_size = get_model_size()
			camera_distance = max(model_size * 0.5, camera_distance * 0.9)
			update_camera_position()
			get_viewport().set_input_as_handled()
			
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_in_viewport:
			var model_size = get_model_size()
			camera_distance = min(model_size * 10.0, camera_distance * 1.1)
			update_camera_position()
			get_viewport().set_input_as_handled()
			
	elif event is InputEventMouseMotion and is_dragging:
		var delta = event.position - last_mouse_position
		print("Mouse delta: ", delta)
		
		camera_horizontal_angle -= delta.x * 0.005
		camera_vertical_angle = clamp(
			camera_vertical_angle - delta.y * 0.005,
			0.1,
			PI - 0.1
		)
		
		print("Camera angles - H: ", camera_horizontal_angle, " V: ", camera_vertical_angle)
		last_mouse_position = event.position
		update_camera_position()

# Обновляем функцию _unhandled_input
func _unhandled_input(event: InputEvent) -> void:
	if !current_model or !mouse_in_viewport:  # Проверяем наличие модели и положение мыши
		return
	
	if event is InputEventMouseButton:
		print("Mouse button event detected: ", event.button_index)
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				dragging = event.pressed
				print("Left mouse button: ", "pressed" if dragging else "released")
				if dragging:
					print("Setting mouse mode to confined")
					Input.mouse_mode = Input.MOUSE_MODE_CONFINED
					is_rotating = false
				else:
					print("Setting mouse mode to visible")
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					
			MOUSE_BUTTON_WHEEL_UP:
				if mouse_in_viewport:  # Дополнительная проверка для колеса мыши
					print("Mouse wheel up")
					var model_size = get_model_size()
					var min_distance = model_size * 0.5
					camera_distance = max(min_distance, camera_distance * 0.9)
					update_camera_position()
					get_viewport().set_input_as_handled()  # Помечаем событие как обработанное
			
			MOUSE_BUTTON_WHEEL_DOWN:
				if mouse_in_viewport:  # Дополнительная проверка для колеса мыши
					print("Mouse wheel down")
					var model_size = get_model_size()
					var max_distance = model_size * 10.0
					camera_distance = min(max_distance, camera_distance * 1.1)
					update_camera_position()
					get_viewport().set_input_as_handled()  # Помечаем событие как обработанное
	
	elif event is InputEventMouseMotion:
		if dragging:
			print("Mouse motion while dragging: ", event.relative)
			camera_sensitivity = 0.003
			
			camera_horizontal_angle -= event.relative.x * camera_sensitivity
			
			camera_vertical_angle = clamp(
				camera_vertical_angle - event.relative.y * camera_sensitivity,
				0.1,
				PI - 0.1
			)
			
			print("Camera angles - Horizontal: ", camera_horizontal_angle, " Vertical: ", camera_vertical_angle)
			update_camera_position()

# Получаем минимальное расстояние камеры на основе размера модели
func get_model_min_distance() -> float:
	var model_size = get_model_size()
	return model_size * 0.8  # Минимальное расстояние - 80% от размера модели

# Получаем максимальное расстояние камеры на основе размера модели
func get_model_max_distance() -> float:
	var model_size = get_model_size()
	return model_size * 5.0  # Максимальное расстояние - в 5 раз больше размера модели

func _get_all_children(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(_get_all_children(child))
	return children

# Получаем размер модели
func get_model_size() -> float:
	if !current_model:
		return 5.0  # Значение по умолчанию
	
	var aabb = AABB()
	var has_mesh = false
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_aabb = (child as MeshInstance3D).get_aabb()
			if !has_mesh:
				aabb = mesh_aabb
				has_mesh = true
			else:
				aabb = aabb.merge(mesh_aabb)
	
	if has_mesh:
		return max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	return 5.0  # Значение по умолчанию

func toggle_rotation() -> void:
	print("Toggle rotation called")
	is_rotating = !is_rotating
	
	if is_rotating:
		print("Enabling rotation with speed:", initial_auto_rotation_speed)
		auto_rotation_speed = initial_auto_rotation_speed
	else:
		print("Disabling rotation")
		auto_rotation_speed = 0.0
		
	if owner and owner.settings:
		owner.settings.set_setting("auto_rotation", is_rotating)
		owner.settings.set_setting("rotation_speed", initial_auto_rotation_speed)
	
	print("Rotation state:", "ON" if is_rotating else "OFF")
	print("Current speed:", auto_rotation_speed)

func _init_camera_controls() -> void:
	last_mouse_position = Vector2.ZERO
	is_dragging = false
	camera_horizontal_angle = 0.0
	camera_vertical_angle = PI/4
	camera_distance = 10.0
	update_camera_position()

func update_camera_position() -> void:
	if !preview_camera or !current_model:
		return
	
	var x = sin(camera_horizontal_angle) * sin(camera_vertical_angle) * camera_distance
	var y = cos(camera_vertical_angle) * camera_distance
	var z = cos(camera_horizontal_angle) * sin(camera_vertical_angle) * camera_distance
	
	var new_position = orbit_center + Vector3(x, y, z)
	print("Camera moved to: ", new_position)
	
	preview_camera.global_position = new_position
	preview_camera.look_at(orbit_center)
	
	if owner and owner.settings:
		owner.settings.set_setting("camera_horizontal_angle", camera_horizontal_angle)
		owner.settings.set_setting("camera_vertical_angle", camera_vertical_angle)
		owner.settings.set_setting("camera_distance", camera_distance)

func center_camera_on_model() -> void:
	if !current_model:
		return
	
	var aabb = AABB()
	var has_mesh = false
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_aabb = (child as MeshInstance3D).get_aabb()
			var global_pos = child.global_position
			mesh_aabb.position += global_pos
			
			if !has_mesh:
				aabb = mesh_aabb
				has_mesh = true
			else:
				aabb = aabb.merge(mesh_aabb)
	
	if has_mesh:
		var model_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		orbit_center = aabb.get_center()
		
		# Устанавливаем начальные значения только если это первая загрузка
		if !saved_settings_loaded:
			camera_horizontal_angle = 0.0
			camera_vertical_angle = PI/4  # 45 градусов
			camera_distance = model_size * 2.0  # Расстояние зависит от размера модели
		
		# Центрируем модель
		current_model.global_position = -orbit_center
		orbit_center = Vector3.ZERO
		
		update_camera_position()
		
		print("Model centered. Size:", model_size)
		print("Camera settings after centering:")
		print("- Horizontal angle:", camera_horizontal_angle)
		print("- Vertical angle:", camera_vertical_angle)
		print("- Distance:", camera_distance)

func setup_preview_camera() -> void:
	if !preview_camera:
		return
		
	# Устанавливаем начальную позицию камеры
	camera_horizontal_angle = 0.0
	camera_vertical_angle = PI/4
	preview_camera.position = Vector3(0, camera_distance * sin(camera_vertical_angle), camera_distance * cos(camera_vertical_angle))
	preview_camera.look_at(Vector3.ZERO)
	
	# Настраиваем параметры камеры
	preview_camera.fov = 45.0
	preview_camera.near = 0.1
	preview_camera.far = 1000.0

func setup_light() -> void:
	if !preview_viewport:
		return
		
	var existing_light = preview_viewport.get_node_or_null("DirectionalLight3D")
	if existing_light:
		existing_light.queue_free()
	
	var main_light = DirectionalLight3D.new()
	main_light.name = "MainLight"
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.2
	preview_viewport.add_child(main_light)
	
	var fill_light = DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.rotation_degrees = Vector3(-45, 135, 0)
	fill_light.light_energy = 0.5
	preview_viewport.add_child(fill_light)
