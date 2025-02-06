extends SubViewportContainer
class_name PreviewModel

# Константы для поддерживаемых форматов
const SUPPORTED_FORMATS = {
	"glb": "gltf",
	"gltf": "gltf",
	"obj": "obj"
}

# Определяем класс для материалов OBJ/MTL
class MTLMaterial:
	var name: String
	var albedo_color: Color = Color.WHITE
	var metallic: float = 0.0
	var roughness: float = 1.0
	var emission: Color = Color.BLACK
	var emission_energy: float = 0.0
	var normal_scale: float = 1.0
	var ao_strength: float = 1.0
	var alpha: float = 1.0
	var texture_paths: Dictionary = {
		"albedo": "",
		"normal": "",
		"metallic": "",
		"roughness": "",
		"emission": "",
		"ao": ""
	}

	func _init(material_name: String = ""):
		name = material_name
		alpha = 1.0  # Гарантируем непрозрачность
		
# Базовые сцены
@onready var preview_viewport = $SubViewport
@onready var preview_camera = $SubViewport/Camera3D

# Состояние камеры
var camera_horizontal_angle := 0.0
var camera_vertical_angle := PI/4
var camera_distance := 5.0
var camera_sensitivity := 0.01
var orbit_center := Vector3.ZERO

# Состояние модели
var current_model: Node3D = null
var saved_settings_loaded := false

# Состояние мыши
var mouse_in_viewport := false
var is_dragging := false
var dragging := false
var last_mouse_position := Vector2.ZERO

# Состояние вращения
var is_rotating := true
var auto_rotation_speed := 0.5
var initial_auto_rotation_speed := 0.5

# ----- Базовые функции -----
func _ready():
	print("Начало инициализации просмотрщика моделей")
	await get_tree().process_frame
	setup_environment()  # This will also call setup_lighting()

	mouse_entered.connect(_on_viewport_mouse_entered)
	mouse_exited.connect(_on_viewport_mouse_exited)
	
	# Устанавливаем начальные значения вращения
	is_rotating = true
	auto_rotation_speed = owner.settings.get_setting("rotation_speed")
	initial_auto_rotation_speed = auto_rotation_speed
	
func _process(delta: float) -> void:
	if current_model and is_rotating and !dragging:
		camera_horizontal_angle += delta * auto_rotation_speed
		update_camera_position()
		
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		owner.settings.set_setting("camera_horizontal_angle", camera_horizontal_angle)
		owner.settings.set_setting("camera_vertical_angle", camera_vertical_angle)

# ----- Загрузка и управление моделью -----
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
			is_rotating = true
		else:
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
		
		if owner and owner.settings:
			owner.settings.set_setting("auto_rotation", is_rotating)
			owner.settings.set_setting("rotation_speed", auto_rotation_speed)
		
		return "Модель загружена успешно"
	else:
		print("Failed to load model")
		return "Ошибка загрузки модели"
		
	if model is MeshInstance3D:
		model.mesh = model.mesh.create_convex_shape()

func load_mtl_file(mtl_path: String) -> Dictionary:
	var materials = {}
	var current_material: MTLMaterial = null
	
	if !FileAccess.file_exists(mtl_path):
		print("MTL file not found:", mtl_path)
		return materials
		
	var file = FileAccess.open(mtl_path, FileAccess.READ)
	if !file:
		print("Failed to open MTL file:", mtl_path)
		return materials
	
	while !file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
			
		var parts = line.split(" ", false)
		if parts.size() < 2:
			continue
			
		match parts[0]:
			"newmtl":
				current_material = MTLMaterial.new(parts[1])
				materials[parts[1]] = current_material
				
			"Kd": # Diffuse color
				if current_material and parts.size() >= 4:
					current_material.albedo_color = Color(
						float(parts[1]),
						float(parts[2]),
						float(parts[3]),
						current_material.alpha
					)
					
			"Ka": # Ambient color - используем для ambient occlusion
				if current_material and parts.size() >= 4:
					var ao_value = (float(parts[1]) + float(parts[2]) + float(parts[3])) / 3.0
					current_material.ao_strength = ao_value
					
			"Ks": # Specular color - влияет на metallic
				if current_material and parts.size() >= 4:
					var specular = (float(parts[1]) + float(parts[2]) + float(parts[3])) / 3.0
					current_material.metallic = clamp(specular, 0.0, 1.0)
					
			"Ns": # Specular exponent - влияет на roughness
				if current_material and parts.size() >= 2:
					var shininess = float(parts[1])
					current_material.roughness = clamp(1.0 - (shininess / 1000.0), 0.0, 1.0)
					
			"d", "Tr": # Прозрачность
				if current_material and parts.size() >= 2:
					current_material.alpha = float(parts[1])
					current_material.albedo_color.a = float(parts[1])
					
			"map_Kd": # Diffuse texture
				if current_material and parts.size() >= 2:
					current_material.texture_paths["albedo"] = parts[1]
					
			"map_Ks": # Specular map
				if current_material and parts.size() >= 2:
					current_material.texture_paths["metallic"] = parts[1]
					
			"map_Bump", "bump", "norm": # Normal map
				if current_material and parts.size() >= 2:
					current_material.texture_paths["normal"] = parts[1]
					
			"map_Ns": # Roughness map
				if current_material and parts.size() >= 2:
					current_material.texture_paths["roughness"] = parts[1]
					
			"Ke": # Emission
				if current_material and parts.size() >= 4:
					current_material.emission = Color(
						float(parts[1]),
						float(parts[2]),
						float(parts[3]),
						1.0
					)
					current_material.emission_energy = (float(parts[1]) + float(parts[2]) + float(parts[3])) / 3.0
					
	file.close()
	return materials

# Обновленная функция load_obj_model с оптимизацией производительности
func load_obj_model(path: String) -> Node3D:
	print("Loading OBJ file:", path)
	var file = FileAccess.open(path, FileAccess.READ)
	if !file:
		print("Failed to open OBJ file")
		return null
	
	var vertices = []
	var normals = []
	var uvs = []
	var faces = []
	var current_material_name = ""
	var materials_by_face = []
	
	# Load materials if available
	var materials = {}
	var mtl_path = path.get_basename() + ".mtl"
	if FileAccess.file_exists(mtl_path):
		materials = load_mtl_file(mtl_path)
		print("Loaded materials:", materials.keys())
	
	while !file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		
		var parts = line.split(" ", false)
		if parts.size() == 0:
			continue
		
		match parts[0]:
			"v":  # Vertex
				if parts.size() >= 4:
					vertices.append(Vector3(
						float(parts[1]),
						float(parts[2]),
						float(parts[3])
					))
			"vn":  # Normal
				if parts.size() >= 4:
					normals.append(Vector3(
						float(parts[1]),
						float(parts[2]),
						float(parts[3])
					).normalized())
			"vt":  # UV
				if parts.size() >= 3:
					uvs.append(Vector2(
						float(parts[1]),
						1.0 - float(parts[2])
					))
			"usemtl":  # Material
				if parts.size() >= 2:
					current_material_name = parts[1]
			"f":  # Face
				var face = []
				for i in range(1, parts.size()):
					var indices = parts[i].split("/")
					if indices.size() >= 1 and indices[0].length() > 0:
						face.append({
							"vertex": int(indices[0]) - 1,
							"uv": int(indices[1]) - 1 if indices.size() >= 2 and indices[1].length() > 0 else -1,
							"normal": int(indices[2]) - 1 if indices.size() >= 3 and indices[2].length() > 0 else -1
						})
				faces.append(face)
				materials_by_face.append(current_material_name)
	
	file.close()
	
	var root = Node3D.new()
	root.name = path.get_file().get_basename()
	
	# Group faces by material
	var faces_by_material = {}
	for i in range(faces.size()):
		var material_name = materials_by_face[i]
		if !faces_by_material.has(material_name):
			faces_by_material[material_name] = []
		faces_by_material[material_name].append(faces[i])
	
	# Create mesh for each material
	for material_name in faces_by_material:
		var material_faces = faces_by_material[material_name]
		var mesh = ArrayMesh.new()
		var surface_arrays = []
		surface_arrays.resize(Mesh.ARRAY_MAX)
		
		var final_vertices = PackedVector3Array()
		var final_normals = PackedVector3Array()
		var final_uvs = PackedVector2Array()
		
		# Process faces for this material
		for face in material_faces:
			# Calculate face normal if no vertex normals provided
			var face_normal = Vector3.ZERO
			if face[0].normal == -1:
				var v1 = vertices[face[0].vertex]
				var v2 = vertices[face[1].vertex]
				var v3 = vertices[face[2].vertex]
				face_normal = (v2 - v1).cross(v3 - v1).normalized()
			
			# Triangulate the face
			for i in range(1, face.size() - 1):
				# Add vertices
				final_vertices.append(vertices[face[0].vertex])
				final_vertices.append(vertices[face[i].vertex])
				final_vertices.append(vertices[face[i + 1].vertex])
				
				# Add normals
				if face[0].normal != -1:
					final_normals.append(normals[face[0].normal])
					final_normals.append(normals[face[i].normal])
					final_normals.append(normals[face[i + 1].normal])
				else:
					final_normals.append(face_normal)
					final_normals.append(face_normal)
					final_normals.append(face_normal)
				
				# Add UVs if available
				if face[0].uv != -1:
					final_uvs.append(uvs[face[0].uv])
					final_uvs.append(uvs[face[i].uv])
					final_uvs.append(uvs[face[i + 1].uv])
		
		if final_vertices.size() > 0:
			# Create mesh arrays
			surface_arrays[Mesh.ARRAY_VERTEX] = final_vertices
			surface_arrays[Mesh.ARRAY_NORMAL] = final_normals
			if final_uvs.size() > 0:
				surface_arrays[Mesh.ARRAY_TEX_UV] = final_uvs
			
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
			
			var mesh_instance = MeshInstance3D.new()
			mesh_instance.mesh = mesh
			mesh_instance.name = "Mesh_" + material_name
			
			# Get material data and apply materials
			var mtl_data = materials.get(material_name)
			_apply_materials(mesh_instance)
			if mtl_data:
				_apply_material_properties(mesh_instance, mtl_data, path)
			
			root.add_child(mesh_instance)
			mesh_instance.owner = root
			
			# Enable shadows
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	
	return root if root.get_child_count() > 0 else null

# Add this function to your view_model.gd class
func setup_model_defaults(model: Node3D) -> void:
	if model:
		# Iterate through all mesh instances
		for child in _get_all_children(model):
			if child is MeshInstance3D:
				# Apply proper material settings
				_apply_materials(child)
				# Enable proper shadow casting
				child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	
# ----- Функции загрузки моделей -----
func load_gltf_model(path: String) -> Node3D:
	var doc = GLTFDocument.new()
	var state = GLTFState.new()
	
	state.handle_binary_image = true
	state.use_named_skin_binds = true
	
	var file = FileAccess.open(path, FileAccess.READ)
	if !file:
		print("Failed to open GLTF file: ", path)
		return null
		
	var bytes = file.get_buffer(file.get_length())
	file.close()
	
	var err = doc.append_from_buffer(bytes, path.get_base_dir(), state)
	if err != OK:
		print("Error parsing GLTF data: ", err)
		return null
	
	var scene = doc.generate_scene(state)
	if scene:
		var root = Node3D.new()
		root.add_child(scene)
		scene.owner = root
		
		for node in _get_all_children(root):
			if node is MeshInstance3D:
				_apply_materials(node)
		
		root.transform = Transform3D.IDENTITY
		scene.transform = Transform3D.IDENTITY
		
		print("Model successfully loaded via GLTFDocument")
		return root
	
	print("Failed to generate scene")
	return null

# Заменим функцию load_model_from_path:
func load_model_from_path(path: String) -> Node3D:
	var extension = path.get_extension().to_lower()
	if extension == "obj":
		return load_obj_model(path)
	elif extension in ["gltf", "glb"]:
		return load_gltf_model(path)
	print("Unsupported file format: ", extension)
	return null

# Удалите обе существующие версии функции _apply_obj_materials и замените их этой:
func _apply_materials(mesh_instance: MeshInstance3D) -> void:
	if !mesh_instance.mesh:
		return
		
	for surface_idx in range(mesh_instance.mesh.get_surface_count()):
		var material = mesh_instance.mesh.surface_get_material(surface_idx)
		if material and material is StandardMaterial3D:
			# Enable double-sided rendering
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
			material.no_depth_test = false
			
			# Enable vertex coloring if available
			material.vertex_color_use_as_albedo = true
			
			# Basic material settings
			material.metallic_specular = 0.1
			material.roughness = 0.7
			material.metallic = 0.0
			
			# Disable transparency
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			
			# Set shading modes
			material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			material.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		else:
			# Create new material if none exists
			var new_material = StandardMaterial3D.new()
			
			# Set all basic properties
			new_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			new_material.no_depth_test = false
			new_material.vertex_color_use_as_albedo = true
			new_material.metallic_specular = 0.1
			new_material.roughness = 0.7
			new_material.metallic = 0.0
			new_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			new_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			new_material.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			new_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			
			# Apply default color
			new_material.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
			
			# Apply new material
			mesh_instance.mesh.surface_set_material(surface_idx, new_material)

func _apply_material_properties(mesh_instance: MeshInstance3D, mtl_data: MTLMaterial, model_path: String) -> void:
	if !mesh_instance.mesh:
		return
	
	var material = StandardMaterial3D.new()
	
	# Basic settings
	material.vertex_color_use_as_albedo = true
	material.metallic_specular = 0.1
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	
	# Set MTL properties
	material.albedo_color = mtl_data.albedo_color
	material.metallic = mtl_data.metallic
	material.roughness = mtl_data.roughness
	material.emission = mtl_data.emission
	material.emission_energy = mtl_data.emission_energy
	
	# Load textures
	for texture_type in mtl_data.texture_paths:
		var texture_path = mtl_data.texture_paths[texture_type]
		if !texture_path.is_empty():
			var full_path = model_path.get_base_dir().path_join(texture_path)
			if FileAccess.file_exists(full_path):
				print("Loading texture: ", full_path)
				var image = Image.new()
				if image.load(full_path) == OK:
					var texture = ImageTexture.create_from_image(image)
					match texture_type:
						"albedo":
							material.albedo_texture = texture
						"normal":
							material.normal_texture = texture
						"metallic":
							material.metallic_texture = texture
						"roughness":
							material.roughness_texture = texture
	
	# Set shading modes
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	
	# Apply to all surfaces
	for i in range(mesh_instance.mesh.get_surface_count()):
		mesh_instance.mesh.surface_set_material(i, material)

func fix_materials(model: Node3D):
	for child in model.get_children():
		if child is MeshInstance3D:
			var material = child.get_surface_override_material(0)
			if material == null:
				material = StandardMaterial3D.new()
			material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Включает отображение обеих сторон
			child.set_surface_override_material(0, material)
			
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

func setup_environment() -> void:
	if !preview_viewport:
		return
		
	for child in preview_viewport.get_children():
		if child is Light3D or child is WorldEnvironment:
			child.queue_free()
	
	# Настройка окружения для более яркого освещения
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.2, 0.2, 0.2)  # Более светлый фон
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.4, 0.4, 0.4)  # Увеличена яркость фонового освещения
	environment.ambient_light_energy = 1.5  # Увеличена энергия фонового света
	
	# Отключаем ненужные эффекты
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	environment.glow_enabled = false
	environment.ssr_enabled = false
	environment.sdfgi_enabled = false
	environment.ssao_enabled = false
	
	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	preview_viewport.add_child(world_environment)
	
	# Основной свет (направленный вниз и вперед)
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-60, -30, 0)
	main_light.light_energy = 2.0  # Увеличена яркость основного света
	main_light.light_color = Color(1.0, 0.98, 0.95)  # Слегка теплый оттенок
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.01
	main_light.shadow_normal_bias = 1.0
	main_light.shadow_blur = 1.0
	preview_viewport.add_child(main_light)
	
	# Заполняющий свет (с противоположной стороны)
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 150, 0)
	fill_light.light_energy = 1.0  # Увеличена яркость заполняющего света
	fill_light.light_color = Color(0.95, 0.95, 1.0)  # Слегка холодный оттенок
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)
	
	# Подсветка снизу для лучшей видимости деталей
	var rim_light = DirectionalLight3D.new()
	rim_light.rotation_degrees = Vector3(45, -120, 0)
	rim_light.light_energy = 0.5
	rim_light.light_color = Color(1.0, 1.0, 1.0)
	rim_light.shadow_enabled = false
	preview_viewport.add_child(rim_light)

func setup_viewport() -> void:
	if !preview_viewport:
		return
	
	preview_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	preview_viewport.positional_shadow_atlas_size = 4096
	preview_viewport.transparent_bg = false
	preview_viewport.use_debanding = true
	preview_viewport.mesh_lod_threshold = 0.0
	preview_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func setup_lighting() -> void:
	# Main directional light
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.5
	main_light.light_color = Color(1.0, 1.0, 1.0)
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.02
	main_light.shadow_normal_bias = 1.0  # Added to help with shadow artifacts
	main_light.shadow_blur = 2.0  # Increased for softer shadows
	preview_viewport.add_child(main_light)
	
	# Fill light for better object detail
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 135, 0)
	fill_light.light_energy = 0.5
	fill_light.light_color = Color(1.0, 1.0, 1.0)
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)
	
	# Rim light for better object separation
	var rim_light = DirectionalLight3D.new()
	rim_light.rotation_degrees = Vector3(-15, -135, 0)
	rim_light.light_energy = 0.3
	rim_light.light_color = Color(1.0, 1.0, 1.0)
	rim_light.shadow_enabled = false
	preview_viewport.add_child(rim_light)
	
func setup_light() -> void:
	if !preview_viewport:
		return
		
	for child in preview_viewport.get_children():
		if child is Light3D or child is WorldEnvironment:
			child.queue_free()
	
	# Настройка окружения
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.1, 0.1, 0.1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.2, 0.2, 0.2)
	environment.ambient_light_energy = 1.0
	
	# Отключаем эффекты, которые могут влиять на цвета
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	environment.glow_enabled = false
	environment.ssr_enabled = false
	environment.sdfgi_enabled = false
	
	# Улучшаем тени
	environment.ssao_enabled = true
	environment.ssao_radius = 0.5
	environment.ssao_intensity = 1.0
	environment.ssao_detail = 1.0
	environment.ssao_horizon = 0.06
	environment.ssao_sharpness = 0.98
	
	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	preview_viewport.add_child(world_environment)
	
	# Основной свет
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.5
	main_light.light_color = Color(1.0, 1.0, 1.0)
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.02
	main_light.shadow_blur = 0.0
	preview_viewport.add_child(main_light)
	
	# Дополнительный свет
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 135, 0)
	fill_light.light_energy = 0.5
	fill_light.light_color = Color(1.0, 1.0, 1.0)
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)
