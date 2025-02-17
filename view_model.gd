extends SubViewportContainer
class_name PreviewModel

@onready var preview_viewport = $SubViewport
@onready var preview_camera = $SubViewport/Camera3D
@onready var play_pause_button = get_node("../HSplitContainer_ControlsRow/PlayPauseButton")
@onready var timeline_slider = get_node("../HSplitContainer_ControlsRow/HSplitContainer_TimelineSlider")

const SUPPORTED_FORMATS = {
	"glb": "gltf",
	"gltf": "gltf",
	"obj": "obj"
}

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
		alpha = 1.0

var camera_horizontal_angle := 0.0
var camera_vertical_angle := PI/4
var camera_distance := 5.0
var camera_sensitivity := 0.01
var orbit_center := Vector3.ZERO

var current_model: Node3D = null
var saved_settings_loaded := false

var mouse_in_viewport := false
var is_dragging := false
var dragging := false
var last_mouse_position := Vector2.ZERO

var is_rotating := true
var auto_rotation_speed := 0.5
var initial_auto_rotation_speed := 0.5

var camera_move_speed := 10.0
var camera_pan_speed := 2.0
var middle_mouse_pressed := false
var zoom_speed := 1.2

var current_animation_player: AnimationPlayer
var current_animation: String
var is_playing: bool = false

func _ready():
	await get_tree().process_frame
	setup_environment()

	mouse_entered.connect(_on_viewport_mouse_entered)
	mouse_exited.connect(_on_viewport_mouse_exited)
	
	load_saved_settings()
	
	if !InputMap.has_action("camera_forward"):
		InputMap.add_action("camera_forward")
		var event = InputEventKey.new()
		event.keycode = KEY_W
		InputMap.action_add_event("camera_forward", event)
		
	if !InputMap.has_action("camera_backward"):
		InputMap.add_action("camera_backward")
		var event = InputEventKey.new()
		event.keycode = KEY_S
		InputMap.action_add_event("camera_backward", event)
		
	if !InputMap.has_action("camera_left"):
		InputMap.add_action("camera_left")
		var event = InputEventKey.new()
		event.keycode = KEY_A
		InputMap.action_add_event("camera_left", event)
		
	if !InputMap.has_action("camera_right"):
		InputMap.add_action("camera_right")
		var event = InputEventKey.new()
		event.keycode = KEY_D
		InputMap.action_add_event("camera_right", event)
		
	if play_pause_button:
		play_pause_button.pressed.connect(_on_play_pause_pressed)
	if timeline_slider:
		timeline_slider.value_changed.connect(_on_timeline_changed)
		
	if play_pause_button:
		play_pause_button.visible = false
	if timeline_slider:
		timeline_slider.visible = false

func _on_play_pause_pressed():
	if !current_animation_player or !current_animation:
		return
		
	if is_playing:
		current_animation_player.pause()
		play_pause_button.text = "▶"
	else:
		current_animation_player.play(current_animation)
		play_pause_button.text = "⏸"
	is_playing = !is_playing

	if owner and owner.settings:
		owner.settings.set_setting("animation_playing", is_playing)
		owner.settings.set_setting("current_animation", current_animation)

func _on_timeline_changed(value: float):
	if current_animation_player and current_animation:
		current_animation_player.seek(value)
		
		if owner and owner.settings:
			owner.settings.set_setting("animation_position", value)
		
func _process(delta: float) -> void:
	if !current_model:
		return
		
	if is_rotating and !dragging and !middle_mouse_pressed:
		camera_horizontal_angle += delta * auto_rotation_speed
		update_camera_position()
	
	var move_vec := Vector3.ZERO
	
	if Input.is_action_pressed("camera_forward"):
		move_vec.z -= 1
	if Input.is_action_pressed("camera_backward"):
		move_vec.z += 1
	if Input.is_action_pressed("camera_left"):
		move_vec.x -= 1
	if Input.is_action_pressed("camera_right"):
		move_vec.x += 1
	
	if move_vec != Vector3.ZERO:
		move_vec = move_vec.normalized()
		
		var cam_basis: Basis = preview_camera.global_transform.basis
		
		move_vec = cam_basis * move_vec
		move_vec.y = 0
		move_vec = move_vec.normalized() * camera_move_speed * delta
		
		orbit_center += move_vec
		preview_camera.global_position += move_vec
		
		if owner and owner.settings:
			owner.settings.set_setting("orbit_center_x", orbit_center.x)
			owner.settings.set_setting("orbit_center_y", orbit_center.y)
			owner.settings.set_setting("orbit_center_z", orbit_center.z)
			owner.settings.set_setting("wasd_position_x", preview_camera.global_position.x)
			owner.settings.set_setting("wasd_position_y", preview_camera.global_position.y)
			owner.settings.set_setting("wasd_position_z", preview_camera.global_position.z)
		
func save_camera_settings() -> void:
	if owner and owner.settings:
		owner.settings.set_setting("camera_distance", camera_distance)
		owner.settings.set_setting("camera_horizontal_angle", camera_horizontal_angle)
		owner.settings.set_setting("camera_vertical_angle", camera_vertical_angle)
		
		owner.settings.set_setting("orbit_center_x", orbit_center.x)
		owner.settings.set_setting("orbit_center_y", orbit_center.y)
		owner.settings.set_setting("orbit_center_z", orbit_center.z)
		
		owner.settings.set_setting("wasd_position_x", preview_camera.global_position.x)
		owner.settings.set_setting("wasd_position_y", preview_camera.global_position.y)
		owner.settings.set_setting("wasd_position_z", preview_camera.global_position.z)
		
		owner.settings.set_setting("auto_rotation", is_rotating)
		owner.settings.set_setting("rotation_speed", auto_rotation_speed)

func load_saved_settings() -> void:
	if !owner or !owner.settings:
		return
	
	camera_horizontal_angle = owner.settings.get_setting("camera_horizontal_angle")
	camera_vertical_angle = owner.settings.get_setting("camera_vertical_angle")
	camera_distance = owner.settings.get_setting("camera_distance")
	
	orbit_center = Vector3(
		owner.settings.get_setting("orbit_center_x"),
		owner.settings.get_setting("orbit_center_y"),
		owner.settings.get_setting("orbit_center_z")
	)
	
	if preview_camera:
		preview_camera.global_position = Vector3(
			owner.settings.get_setting("wasd_position_x"),
			owner.settings.get_setting("wasd_position_y"),
			owner.settings.get_setting("wasd_position_z")
		)
	
	is_rotating = owner.settings.get_setting("auto_rotation")
	auto_rotation_speed = owner.settings.get_setting("rotation_speed")
	initial_auto_rotation_speed = auto_rotation_speed
	saved_settings_loaded = true
	update_camera_position()

func load_in_preview_portal(model_path: String) -> String:
	clear_model()
	
	var model = load_model_from_path(model_path)
	if !model:
		print("Failed to load model")
		return "Ошибка загрузки модели"

	current_model = model
	preview_viewport.add_child(current_model)
	
	current_model.transform = Transform3D.IDENTITY
	for child in _get_all_children(current_model):
		if child is Node3D:
			child.transform = Transform3D.IDENTITY

	var total_aabb := AABB()
	var has_mesh := false
	var extreme_scale := false
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			var mesh_aabb := mesh_instance.get_aabb()
			
			var size := mesh_aabb.size
			if size.length() > 1000.0 or size.length() < 0.001:
				extreme_scale = true
			
			if !has_mesh:
				total_aabb = mesh_aabb
				has_mesh = true
			else:
				total_aabb = total_aabb.merge(mesh_aabb)
	
	if has_mesh:
		var size: float
		var center: Vector3
		
		if extreme_scale:
			size = 5.0
			center = Vector3.ZERO
			current_model.scale = Vector3.ONE * (size / total_aabb.size.length())
		else:
			size = max(total_aabb.size.x, max(total_aabb.size.y, total_aabb.size.z))
			center = total_aabb.get_center()
			
		current_model.position = -center
		orbit_center = Vector3.ZERO
		
		if !saved_settings_loaded:
			camera_horizontal_angle = 0.0
			camera_vertical_angle = PI/4
			camera_distance = size * 2.0
			is_rotating = true
			auto_rotation_speed = 0.5
			initial_auto_rotation_speed = auto_rotation_speed
			saved_settings_loaded = true
		else:
			camera_horizontal_angle = owner.settings.get_setting("camera_horizontal_angle")
			camera_vertical_angle = owner.settings.get_setting("camera_vertical_angle")
			camera_distance = owner.settings.get_setting("camera_distance")
			auto_rotation_speed = owner.settings.get_setting("rotation_speed")
			initial_auto_rotation_speed = auto_rotation_speed
			
			var min_distance: float = size * 0.5
			var max_distance: float = size * 10.0
			camera_distance = clamp(camera_distance, min_distance, max_distance)
		
		update_camera_position()
	
	if owner and owner.settings:
		owner.settings.set_setting("auto_rotation", is_rotating)
		owner.settings.set_setting("rotation_speed", auto_rotation_speed)
		owner.settings.set_setting("camera_distance", camera_distance)
	
	return "Модель загружена успешно"

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
				
			"Kd":
				if current_material and parts.size() >= 4:
					current_material.albedo_color = Color(
						float(parts[1]),
						float(parts[2]),
						float(parts[3]),
						current_material.alpha
					)
					
			"Ka":
				if current_material and parts.size() >= 4:
					var ao_value = (float(parts[1]) + float(parts[2]) + float(parts[3])) / 3.0
					current_material.ao_strength = ao_value
					
			"Ks":
				if current_material and parts.size() >= 4:
					var specular = (float(parts[1]) + float(parts[2]) + float(parts[3])) / 3.0
					current_material.metallic = clamp(specular, 0.0, 1.0)
					
			"Ns":
				if current_material and parts.size() >= 2:
					var shininess = float(parts[1])
					current_material.roughness = clamp(1.0 - (shininess / 1000.0), 0.0, 1.0)
					
			"d", "Tr":
				if current_material and parts.size() >= 2:
					current_material.alpha = float(parts[1])
					current_material.albedo_color.a = float(parts[1])
					
			"map_Kd":
				if current_material and parts.size() >= 2:
					current_material.texture_paths["albedo"] = parts[1]
					
			"map_Ks":
				if current_material and parts.size() >= 2:
					current_material.texture_paths["metallic"] = parts[1]
					
			"map_Bump", "bump", "norm":
				if current_material and parts.size() >= 2:
					current_material.texture_paths["normal"] = parts[1]
					
			"map_Ns":
				if current_material and parts.size() >= 2:
					current_material.texture_paths["roughness"] = parts[1]
					
			"Ke":
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

func load_obj_model(path: String) -> Node3D:
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
	
	var materials = {}
	var mtl_path = path.get_basename() + ".mtl"
	if FileAccess.file_exists(mtl_path):
		materials = load_mtl_file(mtl_path)
	
	while !file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		
		var parts = line.split(" ", false)
		if parts.size() == 0:
			continue
		
		match parts[0]:
			"v":
				if parts.size() >= 4:
					vertices.append(Vector3(
						float(parts[1]),
						float(parts[2]),
						float(parts[3])
					))
			"vn":
				if parts.size() >= 4:
					normals.append(Vector3(
						float(parts[1]),
						float(parts[2]),
						float(parts[3])
					).normalized())
			"vt":
				if parts.size() >= 3:
					uvs.append(Vector2(
						float(parts[1]),
						1.0 - float(parts[2])
					))
			"usemtl":
				if parts.size() >= 2:
					current_material_name = parts[1]
			"f":
				var face = []
				for i in range(1, parts.size()):
					var indices = parts[i].split("/")
					
					if indices.size() >= 1 and indices[0].length() > 0:
						var vertex_idx = int(indices[0]) - 1
						var uv_idx = -1
						var normal_idx = -1
						
						if indices.size() >= 2 and indices[1].length() > 0:
							uv_idx = int(indices[1]) - 1
						
						if indices.size() >= 3 and indices[2].length() > 0:
							normal_idx = int(indices[2]) - 1
						
						if vertex_idx >= 0 and vertex_idx < vertices.size():
							if uv_idx >= 0 and uv_idx >= uvs.size():
								uv_idx = -1
							if normal_idx >= 0 and normal_idx >= normals.size():
								normal_idx = -1
								
							face.append({
								"vertex": vertex_idx,
								"uv": uv_idx,
								"normal": normal_idx
							})
				
				if face.size() >= 3:
					faces.append(face)
					materials_by_face.append(current_material_name)
	
	file.close()
	
	var root = Node3D.new()
	root.name = path.get_file().get_basename()
	
	var faces_by_material = {}
	for i in range(faces.size()):
		var material_name = materials_by_face[i]
		if !faces_by_material.has(material_name):
			faces_by_material[material_name] = []
		faces_by_material[material_name].append(faces[i])
	
	for material_name in faces_by_material:
		var material_faces = faces_by_material[material_name]
		
		var final_vertices = PackedVector3Array()
		var final_normals = PackedVector3Array()
		var final_uvs = PackedVector2Array()
		
		for face in material_faces:
			if face.size() < 3:
				continue
				
			var face_normal = Vector3.ZERO
			if face[0].normal == -1:
				var v1 = vertices[face[0].vertex]
				var v2 = vertices[face[1].vertex]
				var v3 = vertices[face[2].vertex]
				face_normal = (v2 - v1).cross(v3 - v1).normalized()
			
			for i in range(1, face.size() - 1):
				final_vertices.append(vertices[face[0].vertex])
				final_vertices.append(vertices[face[i].vertex])
				final_vertices.append(vertices[face[i + 1].vertex])
				
				if face[0].normal != -1:
					final_normals.append(normals[face[0].normal])
					final_normals.append(normals[face[i].normal])
					final_normals.append(normals[face[i + 1].normal])
				else:
					final_normals.append(face_normal)
					final_normals.append(face_normal)
					final_normals.append(face_normal)
				
				if face[0].uv != -1:
					final_uvs.append(uvs[face[0].uv])
					final_uvs.append(uvs[face[i].uv])
					final_uvs.append(uvs[face[i + 1].uv])
		
		if final_vertices.size() > 0:
			var mesh = ArrayMesh.new()
			var surface_arrays = []
			surface_arrays.resize(Mesh.ARRAY_MAX)
			
			surface_arrays[Mesh.ARRAY_VERTEX] = final_vertices
			surface_arrays[Mesh.ARRAY_NORMAL] = final_normals
			if final_uvs.size() == final_vertices.size():
				surface_arrays[Mesh.ARRAY_TEX_UV] = final_uvs
			
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
			
			var material = StandardMaterial3D.new()
			material.vertex_color_use_as_albedo = true
			material.metallic_specular = 0.1
			material.roughness = 0.7
			material.metallic = 0.0
			mesh.surface_set_material(0, material)
			
			var mesh_instance = MeshInstance3D.new()
			mesh_instance.mesh = mesh
			mesh_instance.name = "Mesh_" + material_name
			
			var mtl_data = materials.get(material_name)
			_apply_materials(mesh_instance)
			if mtl_data:
				_apply_material_properties(mesh_instance, mtl_data, path)
			
			root.add_child(mesh_instance)
			mesh_instance.owner = root
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	
	return root if root.get_child_count() > 0 else null

func setup_model_defaults(model: Node3D) -> void:
	if model:
		for child in _get_all_children(model):
			if child is MeshInstance3D:
				_apply_materials(child)
				child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func load_gltf_model(path: String) -> Node3D:
	var doc = GLTFDocument.new()
	var state = GLTFState.new()
	var err = ERR_FILE_NOT_FOUND
	
	state.handle_binary_image = true
	state.use_named_skin_binds = true
	
	var base_path = path.get_base_dir()
	
	var texture_path = base_path.path_join("spacebits_texture.png")
	if FileAccess.file_exists(texture_path):
		print("Found texture at:", texture_path)
	else:
		print("Texture not found at:", texture_path)
		var parent_dir = base_path.get_base_dir()
		texture_path = parent_dir.path_join("spacebits_texture.png")
		if FileAccess.file_exists(texture_path):
			print("Found texture in parent dir:", texture_path)
	
	if path.get_extension().to_lower() == "glb":
		var file = FileAccess.open(path, FileAccess.READ)
		if !file:
			push_error("Failed to open GLB file: " + path)
			return null
		var bytes = file.get_buffer(file.get_length())
		file.close()
		err = doc.append_from_buffer(bytes, base_path, state)
	else:
		err = doc.append_from_file(path, state)
	
	if err != OK:
		push_error("Error parsing GLTF/GLB file: " + str(err))
		return null
	
	var scene = doc.generate_scene(state)
	if !scene:
		push_error("Failed to generate scene")
		return null
	
	var root = Node3D.new()
	root.add_child(scene)
	scene.owner = root
	
	for node in _get_all_children(root):
		if node is MeshInstance3D:
			for surface_idx in range(node.mesh.get_surface_count()):
				var material = node.mesh.surface_get_material(surface_idx)
				if material:
					material.resource_local_to_scene = true
					if material is StandardMaterial3D:
						material.cull_mode = BaseMaterial3D.CULL_DISABLED
						if material.albedo_texture == null and material.get_name() == "spacebits_texture":
							if FileAccess.file_exists(texture_path):
								var image = Image.new()
								var err2 = image.load(texture_path)
								if err2 == OK:
									var texture = ImageTexture.create_from_image(image)
									material.albedo_texture = texture
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	
	root.transform = Transform3D.IDENTITY
	scene.transform = Transform3D.IDENTITY
	
	return root

func _setup_gltf_materials(mesh_instance: MeshInstance3D) -> void:
	if !mesh_instance.mesh:
		return
		
	for surface_idx in range(mesh_instance.mesh.get_surface_count()):
		var current_material = mesh_instance.mesh.surface_get_material(surface_idx)
		if current_material and current_material is StandardMaterial3D:
			current_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		else:
			var new_material = StandardMaterial3D.new()
			new_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			new_material.vertex_color_use_as_albedo = true
			new_material.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
			new_material.metallic = 0.0
			new_material.roughness = 0.7
			mesh_instance.mesh.surface_set_material(surface_idx, new_material)

func load_model_from_path(path: String) -> Node3D:
	var model: Node3D = null
	var extension = path.get_extension().to_lower()
	
	if extension == "obj":
		model = load_obj_model(path)
	elif extension in ["gltf", "glb"]:
		model = load_gltf_model(path)
	
	if model:
		var saved_orbit_center = orbit_center
		
		model.transform = Transform3D.IDENTITY
		for child in _get_all_children(model):
			if child is Node3D:
				child.transform = Transform3D.IDENTITY
		
		var meshes := []
		for child in _get_all_children(model):
			if child is MeshInstance3D:
				meshes.append(child)
		
		if meshes.is_empty():
			return model
			
		var aabb := AABB()
		var first = true
		
		for mesh_instance in meshes:
			var mesh_aabb := (mesh_instance as MeshInstance3D).get_aabb()
			if first:
				aabb = mesh_aabb
				first = false
			else:
				aabb = aabb.merge(mesh_aabb)
		
		var offset := -aabb.get_center()
		model.position = offset
		
		if saved_settings_loaded and saved_orbit_center.length() > 0.001:
			model.position = offset + saved_orbit_center
			orbit_center = saved_orbit_center
		else:
			orbit_center = Vector3.ZERO
	
	if model:
		var model_details = get_model_details()
		if owner and owner.model_info_panel:
			owner.model_info_panel.update_info(model_details)
	
	return model
	
	if model:
		var model_details = get_model_details()
		if owner and owner.model_info_panel:
			owner.model_info_panel.update_info(model_details)
	
	return model

func _apply_materials(mesh_instance: MeshInstance3D) -> void:
	if !mesh_instance.mesh:
		return
		
	for surface_idx in range(mesh_instance.mesh.get_surface_count()):
		var surface_mat = mesh_instance.mesh.surface_get_material(surface_idx)
		if surface_mat and surface_mat is StandardMaterial3D:
			surface_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			surface_mat.no_depth_test = false
			
			surface_mat.vertex_color_use_as_albedo = true
			
			surface_mat.metallic_specular = 0.1
			surface_mat.roughness = 0.7
			surface_mat.metallic = 0.0
			
			surface_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			
			surface_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			surface_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			surface_mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		else:
			var new_mat = StandardMaterial3D.new()
			
			new_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			new_mat.no_depth_test = false
			new_mat.vertex_color_use_as_albedo = true
			new_mat.metallic_specular = 0.1
			new_mat.roughness = 0.7
			new_mat.metallic = 0.0
			new_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			new_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			new_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			new_mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			
			new_mat.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
			
			mesh_instance.mesh.surface_set_material(surface_idx, new_mat)

func _apply_material_properties(mesh_instance: MeshInstance3D, mtl_data: MTLMaterial, model_path: String) -> void:
	if !mesh_instance.mesh:
		return
	
	var material = StandardMaterial3D.new()
	
	material.vertex_color_use_as_albedo = true
	material.metallic_specular = 0.1
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	
	material.albedo_color = mtl_data.albedo_color
	material.metallic = mtl_data.metallic
	material.roughness = mtl_data.roughness
	material.emission = mtl_data.emission
	material.emission_energy = mtl_data.emission_energy
	
	for texture_type in mtl_data.texture_paths:
		var texture_path = mtl_data.texture_paths[texture_type]
		if !texture_path.is_empty():
			var normalized_texture_path = texture_path.replace("\\", "/")
			var base_dir = model_path.get_base_dir()
			var full_path = base_dir.path_join(normalized_texture_path)
			
			var possible_paths = [
				full_path,
				base_dir.path_join(normalized_texture_path.get_file()),
				normalized_texture_path,
				base_dir.path_join(normalized_texture_path.to_lower()),
				base_dir.path_join(normalized_texture_path.to_upper())
			]
			
			var valid_path = ""
			for path in possible_paths:
				if FileAccess.file_exists(path):
					valid_path = path
					break
					
			if valid_path != "":
				var image = Image.new()
				var err = image.load(valid_path)
				if err == OK:
					var texture = ImageTexture.create_from_image(image)
					match texture_type:
						"albedo":
							material.albedo_texture = texture
						"normal":
							material.normal_texture = texture
							material.normal_enabled = true
						"metallic":
							material.metallic_texture = texture
						"roughness":
							material.roughness_texture = texture
				else:
					push_error("Failed to load texture: %s, error: %s" % [valid_path, err])
			else:
				push_warning("Could not find texture: %s" % texture_path)
	
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	
	for i in range(mesh_instance.mesh.get_surface_count()):
		mesh_instance.mesh.surface_set_material(i, material)

func _setup_material_properties(material: StandardMaterial3D) -> void:
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.vertex_color_use_as_albedo = true
	
	if material.albedo_color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		material.alpha_scissor_threshold = 0.5
		material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	else:
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	
	if material.albedo_texture:
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		material.texture_repeat = true

func fix_materials(model: Node3D):
	for child in model.get_children():
		if child is MeshInstance3D:
			var material = child.get_surface_override_material(0)
			if material == null:
				material = StandardMaterial3D.new()
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
			child.set_surface_override_material(0, material)
			
func clear_model():
	if current_model:
		for child in _get_all_children(current_model):
			if child is MeshInstance3D:
				var mesh = child.mesh
				if mesh:
					for i in range(mesh.get_surface_count()):
						var surface_mat = mesh.surface_get_material(i)
						if surface_mat and surface_mat is StandardMaterial3D:
							surface_mat.albedo_texture = null
							surface_mat.normal_texture = null
							surface_mat.metallic_texture = null
							surface_mat.roughness_texture = null
							mesh.surface_set_material(i, null)
				
				child.mesh = null
		
		current_model.queue_free()
		current_model = null

func _on_viewport_mouse_entered() -> void:
	mouse_in_viewport = true

func _on_viewport_mouse_exited() -> void:
	mouse_in_viewport = false
	dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _input(event: InputEvent) -> void:
	if !current_model:
		return
		
	if event.is_action_pressed("toggle_rotation"):
		toggle_rotation()
		get_viewport().set_input_as_handled()
		
	if !mouse_in_viewport:
		return
		
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_dragging = event.pressed
			if is_dragging:
				last_mouse_position = event.position
				if is_rotating:
					auto_rotation_speed = 0.0
			else:
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
		
		camera_horizontal_angle -= delta.x * 0.005
		camera_vertical_angle = clamp(
			camera_vertical_angle - delta.y * 0.005,
			0.1,
			PI - 0.1
		)
		
		last_mouse_position = event.position
		update_camera_position()

func _unhandled_input(event: InputEvent) -> void:
	if !current_model or !mouse_in_viewport:
		return
	
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_MIDDLE:
				middle_mouse_pressed = event.pressed
				if middle_mouse_pressed:
					last_mouse_position = event.position
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				else:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					
			MOUSE_BUTTON_WHEEL_UP:
				if mouse_in_viewport:
					var model_size := get_model_size()
					camera_distance = max(model_size * 0.1, camera_distance / zoom_speed)
					update_camera_position()
					get_viewport().set_input_as_handled()
					
			MOUSE_BUTTON_WHEEL_DOWN:
				if mouse_in_viewport:
					var model_size := get_model_size()
					camera_distance = min(model_size * 20.0, camera_distance * zoom_speed)
					update_camera_position()
					get_viewport().set_input_as_handled()
					
	elif event is InputEventMouseMotion:
		if middle_mouse_pressed:
			var delta: Vector2 = event.relative
			var cam_basis: Basis = preview_camera.global_transform.basis
			orbit_center -= cam_basis.x * delta.x * camera_pan_speed * 0.01
			orbit_center += cam_basis.y * delta.y * camera_pan_speed * 0.01
			update_camera_position()
			
		elif dragging:
			camera_sensitivity = 0.003
			camera_horizontal_angle -= event.relative.x * camera_sensitivity
			camera_vertical_angle = clamp(
				camera_vertical_angle - event.relative.y * camera_sensitivity,
				0.1,
				PI - 0.1
			)
			update_camera_position()

func get_model_min_distance() -> float:
	var model_size = get_model_size()
	return model_size * 0.8

func get_model_max_distance() -> float:
	var model_size = get_model_size()
	return model_size * 5.0

func get_model_details() -> Dictionary:
	if !current_model:
		return {}
		
	var details = {
		"materials_data": [],
		"textures_data": [],
		"animations_data": []
	}
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh = child.mesh
			if mesh:
				for surface_idx in range(mesh.get_surface_count()):
					var material = mesh.surface_get_material(surface_idx)
					if material:
						var mat_info = {
							"name": material.resource_name if material.resource_name else "Material " + str(surface_idx),
							"type": material.get_class(),
							"properties": {}
						}
						
						if material is StandardMaterial3D:
							mat_info.properties = {
								"albedo_color": material.albedo_color,
								"metallic": material.metallic,
								"roughness": material.roughness,
								"emission_enabled": material.emission_enabled,
								"normal_enabled": material.normal_enabled
							}
							
							if material.albedo_texture:
								details.textures_data.append({
									"name": "Albedo " + mat_info.name,
									"texture": material.albedo_texture
								})
							if material.normal_texture:
								details.textures_data.append({
									"name": "Normal " + mat_info.name,
									"texture": material.normal_texture
								})
						
						details.materials_data.append(mat_info)

	var animation_player = _find_animation_player(current_model)
	if animation_player:
		for anim_name in animation_player.get_animation_list():
			var animation = animation_player.get_animation(anim_name)
			if animation:
				details.animations_data.append({
					"name": anim_name,
					"length": animation.length,
					"player": animation_player
				})
	return details

func _on_texture_pressed(texture: Dictionary):
	var preview_window = Window.new()
	preview_window.title = "Texture Preview: " + texture.name
	preview_window.size = Vector2(400, 400)
	
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 10)
	
	if texture.has("texture"):
		var texture_rect = TextureRect.new()
		texture_rect.texture = texture.texture
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = Vector2(300, 300)
		container.add_child(texture_rect)
	
	preview_window.add_child(container)
	add_child(preview_window)
	preview_window.popup_centered()

func _create_material_preview(material: Dictionary) -> Control:
	var preview = VBoxContainer.new()
	preview.add_theme_constant_override("separation", 10)
	
	if material.has("properties"):
		for prop_name in material.properties:
			var prop_value = material.properties[prop_name]
			var property_label = Label.new()
			property_label.text = str(prop_name) + ": " + str(prop_value)
			preview.add_child(property_label)
	
	return preview

func _get_material_info(material: Material) -> Dictionary:
	var info = {
		"name": material.resource_name if material.resource_name else "Unnamed Material",
		"type": material.get_class()
	}
	
	if material is StandardMaterial3D:
		info["properties"] = {
			"albedo_color": material.albedo_color,
			"metallic": material.metallic,
			"metallic_specular": material.metallic_specular,
			"roughness": material.roughness,
			"emission_enabled": material.emission_enabled,
			"emission": material.emission,
			"normal_enabled": material.normal_enabled,
			"rim_enabled": material.rim_enabled,
			"clearcoat_enabled": material.clearcoat_enabled,
			"ao_enabled": material.ao_enabled,
			"transparency": material.transparency
		}
	
	return info

func play_animation(animation_name: String, player: AnimationPlayer):
	current_animation_player = player
	current_animation = animation_name
	
	if play_pause_button:
		play_pause_button.visible = true
	if timeline_slider:
		timeline_slider.visible = true
		timeline_slider.min_value = 0
		timeline_slider.max_value = player.get_animation(animation_name).length
		timeline_slider.value = 0
	
	_play_animation()

func _play_animation():
	if current_animation_player and current_animation:
		current_animation_player.play(current_animation)
		is_playing = true
		if play_pause_button:
			play_pause_button.text = "⏸"
			
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
	
	for child in node.get_children():
		var found = _find_animation_player(child)
		if found:
			return found
	
	return null

func _get_all_children(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(_get_all_children(child))
	return children

func get_model_size() -> float:
	if !current_model:
		return 2.0
	
	var aabb := AABB()
	var has_mesh := false
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			var mesh_aabb := mesh_instance.get_aabb()
			
			if !has_mesh:
				aabb = mesh_aabb
				has_mesh = true
			else:
				aabb = aabb.merge(mesh_aabb)
	
	if has_mesh:
		var size: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if size < 0.1:
			return 2.0
		elif size > 1000.0:
			return 10.0
		return size
	
	return 2.0

func toggle_rotation() -> void:
	is_rotating = !is_rotating
	
	if is_rotating:
		auto_rotation_speed = initial_auto_rotation_speed
	else:
		auto_rotation_speed = 0.0
		
	if owner and owner.settings:
		owner.settings.set_setting("auto_rotation", is_rotating)
		owner.settings.set_setting("rotation_speed", initial_auto_rotation_speed)

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
	
	var camera_position = orbit_center + Vector3(x, y, z)
	preview_camera.global_position = camera_position
	preview_camera.look_at(orbit_center)
	
	var model_size := get_model_size()
	preview_camera.near = model_size * 0.01
	preview_camera.far = model_size * 100.0
	
	if owner and owner.settings:
		owner.settings.set_setting("camera_horizontal_angle", camera_horizontal_angle)
		owner.settings.set_setting("camera_vertical_angle", camera_vertical_angle)
		owner.settings.set_setting("camera_distance", camera_distance)

func center_camera_on_model() -> void:
	if !current_model:
		return
	
	var combined_aabb := AABB()
	var first_mesh := true
	var mesh_count := 0
	
	for child in _get_all_children(current_model):
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			var mesh_aabb := mesh_instance.get_aabb()
			var global_transform := mesh_instance.global_transform
			
			var transformed_aabb := AABB(
				global_transform * mesh_aabb.position,
				mesh_aabb.size
			)
			
			if first_mesh:
				combined_aabb = transformed_aabb
				first_mesh = false
			else:
				combined_aabb = combined_aabb.merge(transformed_aabb)
			
			mesh_count += 1
	
	if mesh_count == 0:
		print("Warning: No meshes found in model")
		return
		
	var model_size := combined_aabb.size.length()
	var model_center := combined_aabb.get_center()
	
	current_model.global_position = -model_center
	orbit_center = Vector3.ZERO
	
	if !saved_settings_loaded:
		camera_distance = model_size * 2.0
		camera_horizontal_angle = 0.0
		camera_vertical_angle = PI/4
	
	camera_distance = clamp(
		camera_distance,
		model_size * 0.5,
		model_size * 10.0
	)
	
	update_camera_position()

func setup_preview_camera() -> void:
	if !preview_camera:
		return
		
	camera_horizontal_angle = 0.0
	camera_vertical_angle = PI/4
	preview_camera.position = Vector3(0, camera_distance * sin(camera_vertical_angle), camera_distance * cos(camera_vertical_angle))
	preview_camera.look_at(Vector3.ZERO)
	
	preview_camera.fov = 45.0
	preview_camera.near = 0.1
	preview_camera.far = 1000.0

func setup_environment() -> void:
	if !preview_viewport:
		return
		
	for child in preview_viewport.get_children():
		if child is Light3D or child is WorldEnvironment:
			child.queue_free()
	
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.2, 0.2, 0.2)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.4, 0.4, 0.4)
	environment.ambient_light_energy = 1.5
	
	environment.ssr_enabled = true
	environment.ssao_enabled = true
	environment.glow_enabled = true
	environment.glow_intensity = 0.5
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.0
	
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.0
	
	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	preview_viewport.add_child(world_environment)
	
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-60, -30, 0)
	main_light.light_energy = 2.0
	main_light.light_color = Color(1.0, 0.98, 0.95)
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.01
	main_light.shadow_normal_bias = 1.0
	main_light.shadow_blur = 1.0
	preview_viewport.add_child(main_light)
	
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 150, 0)
	fill_light.light_energy = 1.0
	fill_light.light_color = Color(0.95, 0.95, 1.0)
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)

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
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.5
	main_light.light_color = Color(1.0, 1.0, 1.0)
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.02
	main_light.shadow_normal_bias = 1.0
	main_light.shadow_blur = 2.0
	preview_viewport.add_child(main_light)
	
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 135, 0)
	fill_light.light_energy = 0.5
	fill_light.light_color = Color(1.0, 1.0, 1.0)
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)
	
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
	
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.1, 0.1, 0.1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.2, 0.2, 0.2)
	environment.ambient_light_energy = 1.0
	

	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	environment.glow_enabled = false
	environment.ssr_enabled = false
	environment.sdfgi_enabled = false
	
	environment.ssao_enabled = true
	environment.ssao_radius = 0.5
	environment.ssao_intensity = 1.0
	environment.ssao_detail = 1.0
	environment.ssao_horizon = 0.06
	environment.ssao_sharpness = 0.98
	
	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	preview_viewport.add_child(world_environment)
	
	var main_light = DirectionalLight3D.new()
	main_light.rotation_degrees = Vector3(-45, -45, 0)
	main_light.light_energy = 1.5
	main_light.light_color = Color(1.0, 1.0, 1.0)
	main_light.shadow_enabled = true
	main_light.shadow_bias = 0.02
	main_light.shadow_blur = 0.0
	preview_viewport.add_child(main_light)
	
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-30, 135, 0)
	fill_light.light_energy = 0.5
	fill_light.light_color = Color(1.0, 1.0, 1.0)
	fill_light.shadow_enabled = false
	preview_viewport.add_child(fill_light)
