extends SubViewportContainer
class_name PreviewModel

## Emitted at each major stage of model loading so the UI can show progress.
signal loading_stage(text: String)

@onready var preview_viewport = $SubViewport
@onready var preview_camera = $SubViewport/Camera3D
@onready var play_pause_button = get_node("../HSplitContainer_ControlsRow/PlayPauseButton")
@onready var timeline_slider = get_node("../HSplitContainer_ControlsRow/HSplitContainer_TimelineSlider")

const SUPPORTED_FORMATS = {
	"glb": "gltf",
	"gltf": "gltf",
	"obj": "obj",
	"fbx": "fbx"
}

const GLTF_CACHE_DIR := "user://gltf_cache"
const GLTF_TEXTURE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga", "hdr", "exr"]
const FALLBACK_PNG_BASE64 := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
const FALLBACK_TEXTURE_FILE_NAME := "__missing_gltf_texture.png"

const WIREFRAME_SHADER_SRC := \
"shader_type spatial;\n" + \
"render_mode wireframe, unshaded, cull_disabled;\n" + \
"uniform vec4 wire_color : source_color = vec4(0.05, 0.9, 0.4, 1.0);\n" + \
"void fragment() { ALBEDO = wire_color.rgb; }"

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
var _resize_queued: bool = false

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

var current_animation_player: AnimationPlayer = null
var current_animation: String = ""
var is_playing: bool = false
var _timeline_updating: bool = false   # prevents seek() feedback loop

enum ViewPreset { FRONT = 0, BACK = 1, LEFT = 2, RIGHT = 3, TOP = 4, BOTTOM = 5 }

var _grid_instance: MeshInstance3D = null
var grid_visible:   bool           = true
var _gizmo_overlay: Control        = null
var gizmo_visible:  bool           = true

var wireframe_enabled:     bool         = false
var wireframe_mode:        int          = 0   # 0 = off, 1 = overlay, 2 = wireframe-only
var _wireframe_overlay_nodes: Array     = []
var _isolated_mesh_name:   String       = ""
var zoom_to_cursor:        bool         = true
var animation_speed_scale: float        = 1.0
var _speed_option_btn:     OptionButton = null

# ── Environment & light runtime references ────────────────────────────────────
var _main_light:         DirectionalLight3D = null
var _fill_light:         DirectionalLight3D = null
var _rim_light:          DirectionalLight3D = null
var _world_env_node:     WorldEnvironment   = null
var _light_azimuth_deg:  float = -30.0
var _light_elevation_deg:float = -60.0
var _light_energy:       float = 2.0

# ── FPS / stats overlay ───────────────────────────────────────────────────────
var _fps_label:   Label = null
var _fps_visible: bool  = false

# ── Texture channel debug view ────────────────────────────────────────────────
# 0 = full, 1 = albedo, 2 = roughness, 3 = normal, 4 = metallic
var _tex_channel: int = 0

func _ready():
	await get_tree().process_frame
	_setup_responsive_viewport()
	setup_environment()
	_create_gizmo_overlay()
	_create_speed_control()
	_create_fps_overlay()

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

func _setup_responsive_viewport() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(120, 100)
	clip_contents = true
	stretch = true

	if !resized.is_connected(_queue_viewport_resize):
		resized.connect(_queue_viewport_resize)

	_queue_viewport_resize()


func sync_viewport_size() -> void:
	_queue_viewport_resize()


func _queue_viewport_resize() -> void:
	if _resize_queued:
		return
	_resize_queued = true
	call_deferred("_sync_viewport_size")


func _sync_viewport_size() -> void:
	_resize_queued = false
	if !preview_viewport:
		return

	# If SubViewportContainer.stretch is true, Godot automatically makes the
	# SubViewport fill this container. Manual preview_viewport.size changes are
	# forbidden in that mode and produce debugger warnings.
	if !stretch:
		var viewport_width: int = int(maxf(32.0, floor(size.x)))
		var viewport_height: int = int(maxf(32.0, floor(size.y)))
		var next_size := Vector2i(viewport_width, viewport_height)
		if preview_viewport.size != next_size:
			preview_viewport.size = next_size

	if current_model:
		update_camera_position()


func _on_play_pause_pressed():
	if !current_animation_player \
			or !is_instance_valid(current_animation_player) \
			or !current_animation:
		return

	if is_playing:
		current_animation_player.pause()
		is_playing = false
		if play_pause_button:
			play_pause_button.text = "▶"
	else:
		current_animation_player.play(current_animation)
		is_playing = true
		if play_pause_button:
			play_pause_button.text = "⏸"

	if owner and owner.settings:
		owner.settings.set_setting("animation_playing", is_playing)
		owner.settings.set_setting("current_animation", current_animation)

func _on_timeline_changed(value: float):
	# Ignore programmatic updates from _process — only react to user input
	if _timeline_updating:
		return
	if current_animation_player and is_instance_valid(current_animation_player) \
			and current_animation:
		current_animation_player.seek(value, true)
		if owner and owner.settings:
			owner.settings.set_setting("animation_position", value)
		
func _process(delta: float) -> void:
	# FPS/draw-calls overlay — runs even without a loaded model
	if _fps_visible and _fps_label:
		var fps:   int = int(Engine.get_frames_per_second())
		var draws: int = int(RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		_fps_label.text = "FPS: %d\nDraw calls: %d" % [fps, draws]

	# ── Sync timeline slider with animation playback position ────────────────
	if is_playing \
			and current_animation_player \
			and is_instance_valid(current_animation_player) \
			and timeline_slider and timeline_slider.visible:
		_timeline_updating = true
		timeline_slider.value = current_animation_player.current_animation_position
		_timeline_updating = false

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

	if _gizmo_overlay and gizmo_visible:
		_gizmo_overlay.queue_redraw()

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

func _get_transformed_aabb(mesh_instance: MeshInstance3D) -> AABB:
	var local_aabb := mesh_instance.get_aabb()
	var transform := mesh_instance.global_transform
	var corners := [
		local_aabb.position,
		local_aabb.position + Vector3(local_aabb.size.x, 0, 0),
		local_aabb.position + Vector3(0, local_aabb.size.y, 0),
		local_aabb.position + Vector3(0, 0, local_aabb.size.z),
		local_aabb.position + Vector3(local_aabb.size.x, local_aabb.size.y, 0),
		local_aabb.position + Vector3(local_aabb.size.x, 0, local_aabb.size.z),
		local_aabb.position + Vector3(0, local_aabb.size.y, local_aabb.size.z),
		local_aabb.position + local_aabb.size
	]

	var result := AABB(transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		result = result.expand(transform * corners[i])
	return result


func _get_model_aabb(model: Node3D) -> Dictionary:
	var combined_aabb := AABB()
	var has_mesh := false

	for child in _get_all_children(model):
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if !mesh_instance.mesh:
				continue
			var mesh_aabb := _get_transformed_aabb(mesh_instance)
			if !has_mesh:
				combined_aabb = mesh_aabb
				has_mesh = true
			else:
				combined_aabb = combined_aabb.merge(mesh_aabb)

	return {
		"has_mesh": has_mesh,
		"aabb": combined_aabb
	}


func _get_aabb_max_axis(aabb: AABB) -> float:
	return max(aabb.size.x, max(aabb.size.y, aabb.size.z))


func load_in_preview_portal(model_path: String) -> String:
	loading_stage.emit("Очистка сцены...")
	clear_model()

	var ext := model_path.get_extension().to_upper()
	loading_stage.emit("Чтение %s — %s..." % [ext, model_path.get_file()])
	var model = load_model_from_path(model_path)
	if !model:
		loading_stage.emit("Ошибка загрузки")
		print("Failed to load model")
		return "Ошибка загрузки модели"

	loading_stage.emit("Добавление в сцену...")
	current_model = model
	preview_viewport.add_child(current_model)

	current_model.transform = Transform3D.IDENTITY

	loading_stage.emit("Настройка камеры...")
	var aabb_info := _get_model_aabb(current_model)
	if bool(aabb_info["has_mesh"]):
		var total_aabb: AABB = aabb_info["aabb"]
		var model_extent := _get_aabb_max_axis(total_aabb)

		if model_extent > 1000.0 or model_extent < 0.001:
			var target_extent := 5.0
			current_model.scale = Vector3.ONE * (target_extent / max(model_extent, 0.0001))
			aabb_info = _get_model_aabb(current_model)
			total_aabb = aabb_info["aabb"]
			model_extent = _get_aabb_max_axis(total_aabb)

		var center := total_aabb.get_center()
		current_model.global_position -= center
		orbit_center = Vector3.ZERO

		if !saved_settings_loaded:
			camera_horizontal_angle = 0.0
			camera_vertical_angle = PI / 4
			camera_distance = max(model_extent * 2.0, 2.0)
			is_rotating = true
			auto_rotation_speed = 0.5
			initial_auto_rotation_speed = auto_rotation_speed
			saved_settings_loaded = true
		else:
			camera_horizontal_angle = owner.settings.get_setting("camera_horizontal_angle")
			camera_vertical_angle = owner.settings.get_setting("camera_vertical_angle")
			camera_distance = owner.settings.get_setting("camera_distance")
			is_rotating = owner.settings.get_setting("auto_rotation")
			initial_auto_rotation_speed = owner.settings.get_setting("rotation_speed")
			auto_rotation_speed = initial_auto_rotation_speed if is_rotating else 0.0

		var min_distance: float = maxf(model_extent * 0.5, 0.1)
		var max_distance: float = maxf(model_extent * 10.0, min_distance + 1.0)
		camera_distance = clamp(camera_distance, min_distance, max_distance)
		update_camera_position()

	if owner and owner.settings:
		owner.settings.set_setting("auto_rotation", is_rotating)
		owner.settings.set_setting("rotation_speed", auto_rotation_speed)
		owner.settings.set_setting("camera_distance", camera_distance)

	_update_grid()

	# Restore wireframe mode for newly loaded model
	if wireframe_mode == 1:
		loading_stage.emit("Построение wireframe...")
		_build_wireframe_overlay()
	elif wireframe_mode == 2:
		if preview_viewport:
			preview_viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME

	loading_stage.emit("")   # clear — caller sets the "done" message
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
					current_material.metallic = clampf(specular, 0.0, 1.0)
					
			"Ns":
				if current_material and parts.size() >= 2:
					var shininess = float(parts[1])
					current_material.roughness = clampf(1.0 - (shininess / 1000.0), 0.0, 1.0)
					
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
			
			var generated_material := StandardMaterial3D.new()
			generated_material.vertex_color_use_as_albedo = true
			generated_material.metallic_specular = 0.1
			generated_material.roughness = 0.7
			generated_material.metallic = 0.0
			mesh.surface_set_material(0, generated_material)
			
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
	if !model:
		return

	for child in _get_all_children(model):
		if child is MeshInstance3D:
			_configure_mesh_materials(child)
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _configure_mesh_materials(mesh_instance: MeshInstance3D) -> void:
	if !mesh_instance.mesh:
		return

	for surface_idx in range(mesh_instance.mesh.get_surface_count()):
		var surface_material = mesh_instance.mesh.surface_get_material(surface_idx)
		if surface_material and surface_material is StandardMaterial3D:
			surface_material.resource_local_to_scene = true
			surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			surface_material.no_depth_test = false
			continue

		if surface_material == null:
			var default_material := StandardMaterial3D.new()
			default_material.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
			default_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			default_material.roughness = 0.7
			default_material.metallic = 0.0
			mesh_instance.mesh.surface_set_material(surface_idx, default_material)


func _normalize_uri_path(uri: String) -> String:
	return uri.uri_decode().replace("\\", "/")


func _is_supported_image_file(path: String) -> bool:
	return GLTF_TEXTURE_EXTENSIONS.has(path.get_extension().to_lower())


func _extract_texture_file_name(uri: String) -> String:
	var file_name := _normalize_uri_path(uri).get_file()
	if file_name.is_empty():
		return ""

	var lower_name := file_name.to_lower()
	if lower_name.ends_with(".import"):
		file_name = file_name.substr(0, file_name.length() - ".import".length())
		lower_name = file_name.to_lower()

	if lower_name.ends_with(".ctex"):
		file_name = file_name.substr(0, file_name.length() - ".ctex".length())
		lower_name = file_name.to_lower()

	for extension in GLTF_TEXTURE_EXTENSIONS:
		var extension_text: String = str(extension)
		var marker: String = "." + extension_text + "-"
		var marker_pos: int = lower_name.find(marker)
		if marker_pos >= 0:
			return file_name.substr(0, marker_pos + extension_text.length() + 1)

	return file_name


func _get_asset_search_roots(base_path: String) -> Array:
	var roots: Array = []
	var current_dir := base_path

	for _i in range(5):
		if current_dir.is_empty():
			break
		if !roots.has(current_dir) and DirAccess.open(current_dir) != null:
			roots.append(current_dir)

		var parent_dir := current_dir.get_base_dir()
		if parent_dir == current_dir or parent_dir.is_empty():
			break
		current_dir = parent_dir

	return roots


func _find_file_recursive(root_path: String, target_file_lower: String, depth_left: int) -> String:
	if depth_left < 0 or root_path.is_empty() or target_file_lower.is_empty():
		return ""

	var dir := DirAccess.open(root_path)
	if dir == null:
		return ""

	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name.is_empty():
			break
		if entry_name == "." or entry_name == "..":
			continue

		var entry_path := root_path.path_join(entry_name)
		if dir.current_is_dir():
			var lower_dir_name := entry_name.to_lower()
			if lower_dir_name in [".git", ".godot", "node_modules", "bin", "obj"]:
				continue
			var found_path := _find_file_recursive(entry_path, target_file_lower, depth_left - 1)
			if !found_path.is_empty():
				dir.list_dir_end()
				return found_path
		else:
			if entry_name.to_lower() == target_file_lower:
				dir.list_dir_end()
				return entry_path

	dir.list_dir_end()
	return ""


func _get_direct_asset_candidates(uri: String, base_path: String) -> Array:
	var normalized_uri := _normalize_uri_path(uri)
	var candidates: Array = []

	if normalized_uri.begins_with("res://godotimported/") or normalized_uri.get_extension().to_lower() == "ctex":
		return candidates

	if normalized_uri.begins_with("res://") or normalized_uri.begins_with("user://") or normalized_uri.is_absolute_path():
		candidates.append(normalized_uri)
	else:
		candidates.append(base_path.path_join(normalized_uri))
		candidates.append(base_path.path_join(normalized_uri.get_file()))

	return candidates


func _resolve_external_asset_path(uri: String, base_path: String, must_be_image: bool) -> String:
	var normalized_uri := _normalize_uri_path(uri)
	var file_name := _extract_texture_file_name(normalized_uri) if must_be_image else normalized_uri.get_file()

	for candidate in _get_direct_asset_candidates(normalized_uri, base_path):
		if FileAccess.file_exists(candidate):
			if !must_be_image or _is_supported_image_file(candidate):
				return candidate

	for root_path in _get_asset_search_roots(base_path):
		var found_path := _find_file_recursive(root_path, file_name.to_lower(), 6)
		if !found_path.is_empty() and FileAccess.file_exists(found_path):
			if !must_be_image or _is_supported_image_file(found_path):
				return found_path

	return ""


func _ensure_gltf_cache_dir() -> String:
	var cache_dir := ProjectSettings.globalize_path(GLTF_CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	return cache_dir


func _get_or_create_fallback_texture_path(cache_dir: String) -> String:
	var fallback_path := cache_dir.path_join(FALLBACK_TEXTURE_FILE_NAME)
	if FileAccess.file_exists(fallback_path):
		return fallback_path

	var fallback_file := FileAccess.open(fallback_path, FileAccess.WRITE)
	if fallback_file == null:
		return ""

	fallback_file.store_buffer(Marshalls.base64_to_raw(FALLBACK_PNG_BASE64))
	fallback_file.close()
	return fallback_path


func _copy_file_to_path(source_path: String, target_path: String) -> bool:
	var source_file := FileAccess.open(source_path, FileAccess.READ)
	if source_file == null:
		return false

	var bytes := source_file.get_buffer(source_file.get_length())
	source_file.close()

	var target_file := FileAccess.open(target_path, FileAccess.WRITE)
	if target_file == null:
		return false

	target_file.store_buffer(bytes)
	target_file.close()
	return true


func _make_cached_asset_name(model_path: String, asset_type: String, index: int, source_path: String) -> String:
	var model_name := model_path.get_file().get_basename().replace(" ", "_")
	var source_name := source_path.get_file().replace(" ", "_")
	return "%s_%s_%d_%s" % [model_name, asset_type, index, source_name]


func _get_image_mime_type(image_path: String) -> String:
	match image_path.get_extension().to_lower():
		"jpg", "jpeg":
			return "image/jpeg"
		"webp":
			return "image/webp"
		"bmp":
			return "image/bmp"
		"tga":
			return "image/tga"
		"hdr":
			return "image/vnd.radiance"
		"exr":
			return "image/aces"
		_:
			return "image/png"


func _prepare_gltf_for_loading(path: String) -> String:
	if path.get_extension().to_lower() != "gltf":
		return path

	var source_file := FileAccess.open(path, FileAccess.READ)
	if source_file == null:
		return path

	var gltf_text := source_file.get_as_text()
	source_file.close()

	var parsed = JSON.parse_string(gltf_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return path

	var gltf_data: Dictionary = parsed
	var base_path := path.get_base_dir()
	var cache_dir := _ensure_gltf_cache_dir()
	var fallback_texture_path := _get_or_create_fallback_texture_path(cache_dir)
	var changed := false

	var images: Array = gltf_data.get("images", [])
	for i in range(images.size()):
		if typeof(images[i]) != TYPE_DICTIONARY:
			continue

		var image_info: Dictionary = images[i]
		if !image_info.has("uri"):
			continue

		var image_uri := str(image_info["uri"])
		if image_uri.begins_with("data:"):
			continue

		var resolved_image_path := _resolve_external_asset_path(image_uri, base_path, true)
		if resolved_image_path.is_empty():
			if fallback_texture_path.is_empty():
				push_warning("glTF texture not found and fallback texture could not be created: " + image_uri)
				continue
			push_warning("glTF texture not found, fallback texture will be used: " + image_uri)
			image_info["uri"] = fallback_texture_path.get_file()
			image_info["mimeType"] = "image/png"
			image_info.erase("bufferView")
			images[i] = image_info
			changed = true
			continue

		var cached_image_name := _make_cached_asset_name(path, "image", i, resolved_image_path)
		var cached_image_path := cache_dir.path_join(cached_image_name)
		if _copy_file_to_path(resolved_image_path, cached_image_path):
			image_info["uri"] = cached_image_name
			image_info["mimeType"] = _get_image_mime_type(resolved_image_path)
			image_info.erase("bufferView")
			images[i] = image_info
			changed = true
			print("glTF texture resolved: ", image_uri, " -> ", resolved_image_path)
		else:
			if fallback_texture_path.is_empty():
				push_warning("Could not copy glTF texture and fallback texture could not be created: " + resolved_image_path)
				continue
			push_warning("Could not copy glTF texture, fallback texture will be used: " + resolved_image_path)
			image_info["uri"] = fallback_texture_path.get_file()
			image_info["mimeType"] = "image/png"
			image_info.erase("bufferView")
			images[i] = image_info
			changed = true

	gltf_data["images"] = images

	if changed:
		var buffers: Array = gltf_data.get("buffers", [])
		for i in range(buffers.size()):
			if typeof(buffers[i]) != TYPE_DICTIONARY:
				continue

			var buffer_info: Dictionary = buffers[i]
			if !buffer_info.has("uri"):
				continue

			var buffer_uri := str(buffer_info["uri"])
			if buffer_uri.begins_with("data:"):
				continue

			var resolved_buffer_path := _resolve_external_asset_path(buffer_uri, base_path, false)
			if resolved_buffer_path.is_empty():
				var normalized_buffer_uri := _normalize_uri_path(buffer_uri)
				var absolute_buffer_candidate: String = normalized_buffer_uri if normalized_buffer_uri.is_absolute_path() else base_path.path_join(normalized_buffer_uri)
				push_warning("glTF buffer could not be copied. Keeping absolute buffer reference: " + absolute_buffer_candidate)
				buffer_info["uri"] = absolute_buffer_candidate
				buffers[i] = buffer_info
				continue

			var cached_buffer_name := _make_cached_asset_name(path, "buffer", i, resolved_buffer_path)
			var cached_buffer_path := cache_dir.path_join(cached_buffer_name)
			if _copy_file_to_path(resolved_buffer_path, cached_buffer_path):
				buffer_info["uri"] = cached_buffer_name
			else:
				push_warning("Could not copy glTF buffer. Keeping absolute buffer reference: " + resolved_buffer_path)
				buffer_info["uri"] = resolved_buffer_path
			buffers[i] = buffer_info

		gltf_data["buffers"] = buffers

	if !changed:
		return path

	var patched_path := cache_dir.path_join(path.get_file().get_basename() + "_patched.gltf")
	var patched_file := FileAccess.open(patched_path, FileAccess.WRITE)
	if patched_file == null:
		return path

	patched_file.store_string(JSON.stringify(gltf_data, "\t"))
	patched_file.close()
	return patched_path

func load_gltf_model(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := ERR_FILE_NOT_FOUND
	var extension := path.get_extension().to_lower()
	var load_path := path
	var base_path := path.get_base_dir()

	state.handle_binary_image = true
	state.use_named_skin_binds = true

	if extension == "gltf":
		load_path = _prepare_gltf_for_loading(path)
		base_path = load_path.get_base_dir()

	if extension == "glb":
		var file := FileAccess.open(path, FileAccess.READ)
		if !file:
			push_error("Failed to open GLB file: " + path)
			return null
		var bytes := file.get_buffer(file.get_length())
		file.close()
		err = doc.append_from_buffer(bytes, base_path, state)
	else:
		err = doc.append_from_file(load_path, state)

	if err != OK:
		push_error("Error parsing GLTF/GLB file: " + str(err))
		return null

	var scene := doc.generate_scene(state)
	if !scene:
		push_error("Failed to generate scene")
		return null

	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	root.add_child(scene)
	scene.owner = root

	for node in _get_all_children(root):
		if node is MeshInstance3D:
			_configure_mesh_materials(node)
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	root.transform = Transform3D.IDENTITY
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
	var extension := path.get_extension().to_lower()

	if extension == "obj":
		model = load_obj_model(path)
	elif extension in ["gltf", "glb"]:
		model = load_gltf_model(path)
	elif extension == "fbx":
		model = load_fbx_model(path)

	if model:
		model.transform = Transform3D.IDENTITY
		setup_model_defaults(model)

	return model


func load_fbx_model(path: String) -> Node3D:
	# FBXDocument is available in Godot 4.4+.
	# Falls back gracefully if the class does not exist in the build.
	if !ClassDB.class_exists("FBXDocument"):
		push_error("FBXDocument not available in this Godot build.")
		return null

	var doc  = ClassDB.instantiate("FBXDocument")
	var state = ClassDB.instantiate("FBXState")
	if !doc or !state:
		push_error("Failed to instantiate FBXDocument/FBXState.")
		return null

	# Mirror the same state flags used by load_gltf_model for best compatibility.
	state.set("use_named_skin_binds", true)

	# Allow the importer to find textures next to the FBX file.
	var base_path := path.get_base_dir()
	var err: int = doc.append_from_file(path, state, 0, base_path)
	# err != OK usually means some textures couldn't be loaded via ResourceLoader
	# (absolute paths from another machine, etc.).  The mesh geometry is still
	# present inside `state`, so always attempt generate_scene().
	if err != OK:
		push_warning("FBX: append_from_file code %d for '%s' — continuing." % [err, path.get_file()])

	var scene: Node = doc.generate_scene(state)
	if !scene:
		push_error("FBX generate_scene failed (err=%d): %s" % [err, path])
		return null

	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	root.add_child(scene)

	# FBXDocument generates ImporterMeshInstance3D nodes instead of MeshInstance3D.
	# Convert them so the rest of the pipeline (materials, shadows, AABB) works.
	_convert_importer_meshes(root)

	for node in _get_all_children(root):
		if node is MeshInstance3D:
			_configure_mesh_materials(node)
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	root.transform = Transform3D.IDENTITY

	# Textures in FBX often use absolute paths from the original machine.
	# Scan the folder next to the FBX and apply matching images manually
	# using Image.load_from_file() which bypasses ResourceLoader restrictions.
	_apply_fbx_textures(root, base_path)

	return root


## FBXDocument produces ImporterMeshInstance3D nodes at runtime.
## This function replaces every such node with a proper MeshInstance3D so that
## the rest of the viewer pipeline (AABB, materials, shadows) works correctly.
func _convert_importer_meshes(root: Node) -> void:
	# Snapshot the list first — we'll be modifying the tree during iteration.
	var all_nodes: Array = _get_all_children(root)

	for node in all_nodes:
		# Check validity FIRST — node.free() in a previous iteration may have
		# recursively freed child nodes that are also in this snapshot array.
		if !is_instance_valid(node):
			continue
		if node.get_class() != "ImporterMeshInstance3D":
			continue

		# ImporterMeshInstance3D.mesh → ImporterMesh → get_mesh() → ArrayMesh
		var importer_mesh: Object = node.get("mesh")
		if !importer_mesh:
			continue
		var array_mesh: ArrayMesh = importer_mesh.call("get_mesh")
		if !array_mesh:
			continue

		var mi := MeshInstance3D.new()
		mi.name        = node.name
		mi.transform   = (node as Node3D).transform
		mi.mesh        = array_mesh

		# Transfer skeletal skinning so animations deform the mesh correctly.
		var skin: Object = node.get("skin")
		if skin is Skin:
			mi.skin = skin as Skin
		var skel_path: NodePath = node.get("skeleton_path") as NodePath
		if skel_path and !skel_path.is_empty():
			mi.skeleton = skel_path

		var parent: Node = node.get_parent()
		if parent:
			var idx: int = node.get_index()
			parent.add_child(mi)
			parent.move_child(mi, idx)

		node.get_parent().remove_child(node)
		node.free()


## Scans base_dir (and its sub-folders) for image files and tries to match
## them to untextured StandardMaterial3D surfaces by name similarity.
func _apply_fbx_textures(root: Node3D, base_dir: String) -> void:
	var tex_map: Dictionary = {}   # basename_lower → full_path
	_scan_images_recursive(base_dir, tex_map)
	if tex_map.is_empty():
		return

	for node in _get_all_children(root):
		if not node is MeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		if !mi.mesh:
			continue
		for surf in range(mi.mesh.get_surface_count()):
			var mat = mi.get_active_material(surf)
			if not mat is StandardMaterial3D:
				continue
			var sm := mat as StandardMaterial3D
			if sm.albedo_texture:
				continue  # already has a texture

			# Build candidate names from mesh / material / surface names.
			var candidates: Array[String] = []
			if mi.name:            candidates.append(mi.name.to_lower())
			if sm.resource_name:   candidates.append(sm.resource_name.to_lower())

			# First try exact/contains match, then fall back to any "color"
			# or "diffuse" texture found in the folder.
			var chosen := _find_best_texture(candidates, tex_map)
			if chosen.is_empty():
				chosen = _find_texture_keyword(["color", "diffuse", "albedo",
												"col", "base"], tex_map)
			if chosen.is_empty():
				continue

			var img := Image.load_from_file(chosen)
			if img:
				sm.albedo_texture = ImageTexture.create_from_image(img)


func _find_best_texture(candidates: Array[String],
						tex_map: Dictionary) -> String:
	for cand in candidates:
		if cand.is_empty():
			continue
		for k: String in tex_map:
			if k.contains(cand) or cand.contains(k):
				return tex_map[k]
	return ""


func _find_texture_keyword(keywords: Array[String],
							tex_map: Dictionary) -> String:
	for kw in keywords:
		for k: String in tex_map:
			if k.contains(kw):
				return tex_map[k]
	return ""


func _scan_images_recursive(dir_path: String, result: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if !dir:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var full := dir_path.path_join(fname)
			if dir.current_is_dir():
				_scan_images_recursive(full, result)
			else:
				var ext := fname.get_extension().to_lower()
				if ext in ["jpg", "jpeg", "png", "webp", "bmp", "tga", "hdr"]:
					var base := fname.get_basename().to_lower()
					if not result.has(base):
						result[base] = full
		fname = dir.get_next()
	dir.list_dir_end()


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

	var generated_material := StandardMaterial3D.new()
	generated_material.vertex_color_use_as_albedo = true
	generated_material.metallic_specular = 0.1
	generated_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	generated_material.no_depth_test = false

	generated_material.albedo_color = mtl_data.albedo_color
	generated_material.metallic = mtl_data.metallic
	generated_material.roughness = mtl_data.roughness
	generated_material.emission = mtl_data.emission
	generated_material.emission_energy = mtl_data.emission_energy

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
			for path_candidate in possible_paths:
				if FileAccess.file_exists(path_candidate):
					valid_path = path_candidate
					break

			if valid_path != "":
				var image = Image.new()
				var err = image.load(valid_path)
				if err == OK:
					var texture = ImageTexture.create_from_image(image)
					match texture_type:
						"albedo":
							generated_material.albedo_texture = texture
						"normal":
							generated_material.normal_texture = texture
							generated_material.normal_enabled = true
							generated_material.normal_scale = mtl_data.normal_scale
						"metallic":
							generated_material.metallic_texture = texture
						"roughness":
							generated_material.roughness_texture = texture
						"emission":
							generated_material.emission_texture = texture
							generated_material.emission_enabled = true
						"ao":
							generated_material.ao_texture = texture
							generated_material.ao_enabled = true
							generated_material.ao_light_affect = mtl_data.ao_strength

	if mtl_data.alpha < 1.0:
		generated_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		generated_material.alpha_scissor_threshold = 0.1
	else:
		generated_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	generated_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	generated_material.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	generated_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX

	for i in range(mesh_instance.mesh.get_surface_count()):
		mesh_instance.mesh.surface_set_material(i, generated_material)


func _setup_material_properties(surface_material: StandardMaterial3D) -> void:
	surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	if surface_material.albedo_color.a < 1.0:
		surface_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		surface_material.alpha_scissor_threshold = 0.5
		surface_material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	else:
		surface_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	if surface_material.albedo_texture:
		surface_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		surface_material.texture_repeat = true


func fix_materials(model: Node3D):
	for child in model.get_children():
		if child is MeshInstance3D:
			var override_material = child.get_surface_override_material(0)
			if override_material == null:
				override_material = StandardMaterial3D.new()
			override_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			child.set_surface_override_material(0, override_material)
			
func clear_model():
	# ── Reset animation state BEFORE freeing the model ────────────────────────
	if current_animation_player and is_instance_valid(current_animation_player):
		if current_animation_player.animation_finished.is_connected(_on_animation_finished):
			current_animation_player.animation_finished.disconnect(_on_animation_finished)
		current_animation_player.stop()
	current_animation_player = null
	current_animation        = ""
	is_playing               = false
	_timeline_updating       = false

	if play_pause_button:
		play_pause_button.visible = false
		play_pause_button.text    = "▶"
	if timeline_slider:
		timeline_slider.visible = false
		timeline_slider.value   = 0.0
	if _grid_instance:
		_grid_instance.visible = false
	# Reset wireframe overlay and mesh isolation before freeing model
	_remove_wireframe_overlay()
	_isolated_mesh_name = ""

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
			dragging = is_dragging
			if is_dragging:
				last_mouse_position = event.position
				if is_rotating:
					auto_rotation_speed = 0.0
			else:
				if is_rotating:
					auto_rotation_speed = initial_auto_rotation_speed
				
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and mouse_in_viewport:
			_do_zoom(true, event.position)
			get_viewport().set_input_as_handled()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_in_viewport:
			_do_zoom(false, event.position)
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
					_do_zoom(true, event.position)
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_WHEEL_DOWN:
				if mouse_in_viewport:
					_do_zoom(false, event.position)
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
		"textures_data":  [],
		"animations_data":[],
		"meshes_data":    [],
		"aabb_size":      Vector3.ZERO,
		"vertices":       "0",
		"faces":          "0",
		"materials":      "0",
	}

	var _ad := _get_model_aabb(current_model)
	if bool(_ad["has_mesh"]):
		details["aabb_size"] = (_ad["aabb"] as AABB).size

	var vertex_count  := 0
	var face_count    := 0
	var mat_rid_seen  := {}   # RID → true, to de-duplicate shared materials

	for child in _get_all_children(current_model):
		if not child is MeshInstance3D:
			continue
		var mi := child as MeshInstance3D
		# Skip the wireframe overlay duplicates
		if mi.get_meta("_wf_overlay", false):
			continue
		if !mi.mesh:
			continue

		# Prefer the mesh-resource name; fall back to the node name
		var _mesh_display: String = mi.name
		if mi.mesh and not mi.mesh.resource_name.is_empty():
			_mesh_display = mi.mesh.resource_name
		details.meshes_data.append({"name": mi.name, "display": _mesh_display})

		var mesh: Mesh = mi.mesh

		for surface_idx in range(mesh.get_surface_count()):
			# ── geometry counts ──────────────────────────────────────────
			var arrays: Array = mesh.surface_get_arrays(surface_idx)
			if arrays and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
				var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
				vertex_count += verts.size()
				if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
					var idx_arr := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
					face_count += int(idx_arr.size() / 3.0)
				else:
					face_count += int(verts.size() / 3.0)

			# ── material info ────────────────────────────────────────────
			var surface_material: Material = mesh.surface_get_material(surface_idx)
			if !surface_material:
				continue

			# Count unique materials by RID so shared ones aren't doubled.
			var rid: RID = surface_material.get_rid()
			if !mat_rid_seen.has(rid):
				mat_rid_seen[rid] = true

			var mat_info := {
				"name": surface_material.resource_name \
						if surface_material.resource_name \
						else "Material " + str(surface_idx),
				"type":       surface_material.get_class(),
				"properties": {}
			}

			if surface_material is StandardMaterial3D:
				var sm := surface_material as StandardMaterial3D
				mat_info.properties = {
					"albedo_color":     sm.albedo_color,
					"metallic":         sm.metallic,
					"roughness":        sm.roughness,
					"emission_enabled": sm.emission_enabled,
					"normal_enabled":   sm.normal_enabled
				}
				if sm.albedo_texture:
					details.textures_data.append({
						"name":    "Albedo " + mat_info.name,
						"texture": sm.albedo_texture
					})
				if sm.normal_texture:
					details.textures_data.append({
						"name":    "Normal " + mat_info.name,
						"texture": sm.normal_texture
					})

			details.materials_data.append(mat_info)

	details["vertices"]  = str(vertex_count)
	details["faces"]     = str(face_count)
	details["materials"] = str(mat_rid_seen.size())

	var animation_player := _find_animation_player(current_model)
	if animation_player:
		for anim_name in animation_player.get_animation_list():
			var animation: Animation = animation_player.get_animation(anim_name)
			if animation:
				details.animations_data.append({
					"name":   anim_name,
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

func _create_material_preview(material_info: Dictionary) -> Control:
	var preview = VBoxContainer.new()
	preview.add_theme_constant_override("separation", 10)

	if material_info.has("properties"):
		for prop_name in material_info.properties:
			var prop_value = material_info.properties[prop_name]
			var property_label = Label.new()
			property_label.text = str(prop_name) + ": " + str(prop_value)
			preview.add_child(property_label)

	return preview


func _get_material_info(surface_material: Material) -> Dictionary:
	var info = {
		"name": surface_material.resource_name if surface_material.resource_name else "Unnamed Material",
		"type": surface_material.get_class()
	}

	if surface_material is StandardMaterial3D:
		info["properties"] = {
			"albedo_color": surface_material.albedo_color,
			"metallic": surface_material.metallic,
			"metallic_specular": surface_material.metallic_specular,
			"roughness": surface_material.roughness,
			"emission_enabled": surface_material.emission_enabled,
			"emission": surface_material.emission,
			"normal_enabled": surface_material.normal_enabled,
			"rim_enabled": surface_material.rim_enabled,
			"clearcoat_enabled": surface_material.clearcoat_enabled,
			"ao_enabled": surface_material.ao_enabled,
			"transparency": surface_material.transparency
		}

	return info

func play_animation(animation_name: String, player: AnimationPlayer):
	if !player or !is_instance_valid(player):
		return
	if !player.has_animation(animation_name):
		push_warning("AnimationPlayer: animation '%s' not found." % animation_name)
		return

	# Disconnect previous player's signal to avoid ghost callbacks
	if current_animation_player \
			and is_instance_valid(current_animation_player) \
			and current_animation_player.animation_finished.is_connected(_on_animation_finished):
		current_animation_player.animation_finished.disconnect(_on_animation_finished)

	current_animation_player = player
	current_animation        = animation_name
	animation_speed_scale    = 1.0
	player.speed_scale       = 1.0

	# Connect animation_finished so the button resets when clip ends
	if not player.animation_finished.is_connected(_on_animation_finished):
		player.animation_finished.connect(_on_animation_finished)

	var anim: Animation = player.get_animation(animation_name)
	var anim_len: float  = anim.length if anim else 1.0

	if play_pause_button:
		play_pause_button.visible = true
	if _speed_option_btn:
		_speed_option_btn.visible = true
		_speed_option_btn.selected = 2  # ×1
	if timeline_slider:
		_timeline_updating        = true
		timeline_slider.visible   = true
		timeline_slider.min_value = 0.0
		timeline_slider.max_value = anim_len
		timeline_slider.step      = 0.01   # smooth sub-second movement
		timeline_slider.value     = 0.0
		_timeline_updating        = false

	_play_animation()


func _on_animation_finished(anim_name: String) -> void:
	# Called when a non-looping animation reaches its end.
	# For looping animations this fires at each loop boundary — ignore it.
	if !current_animation_player or !is_instance_valid(current_animation_player):
		return
	var anim: Animation = current_animation_player.get_animation(anim_name) \
			if current_animation_player.has_animation(anim_name) else null
	if anim and anim.loop_mode != Animation.LOOP_NONE:
		return   # looping — don't reset state
	is_playing = false
	if play_pause_button:
		play_pause_button.text = "▶"
	if timeline_slider:
		_timeline_updating    = true
		timeline_slider.value = 0.0
		_timeline_updating    = false


func _play_animation():
	if current_animation_player \
			and is_instance_valid(current_animation_player) \
			and current_animation:
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

	var aabb_info := _get_model_aabb(current_model)
	if bool(aabb_info["has_mesh"]):
		var model_extent := _get_aabb_max_axis(aabb_info["aabb"])
		return clamp(model_extent, 0.1, 1000.0)

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

	var aabb_info := _get_model_aabb(current_model)
	if !bool(aabb_info["has_mesh"]):
		print("Warning: No meshes found in model")
		return

	var combined_aabb: AABB = aabb_info["aabb"]
	var model_extent := _get_aabb_max_axis(combined_aabb)
	var model_center := combined_aabb.get_center()

	current_model.global_position -= model_center
	orbit_center = Vector3.ZERO

	if !saved_settings_loaded:
		camera_distance = max(model_extent * 2.0, 2.0)
		camera_horizontal_angle = 0.0
		camera_vertical_angle = PI / 4

	camera_distance = clamp(
		camera_distance,
		max(model_extent * 0.5, 0.1),
		max(model_extent * 10.0, 1.0)
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
	
	# SSR/SSAO are disabled here because they warn or do not work under Mobile/Compatibility renderers.
	environment.ssr_enabled = false
	environment.ssao_enabled = false
	environment.glow_enabled = true
	environment.glow_intensity = 0.5
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.0
	
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.0
	
	_world_env_node = WorldEnvironment.new()
	_world_env_node.environment = environment
	preview_viewport.add_child(_world_env_node)

	_main_light = DirectionalLight3D.new()
	_main_light.rotation_degrees = Vector3(_light_elevation_deg, _light_azimuth_deg, 0.0)
	_main_light.light_energy     = _light_energy
	_main_light.light_color      = Color(1.0, 0.98, 0.95)
	_main_light.shadow_enabled   = true
	_main_light.shadow_bias      = 0.01
	_main_light.shadow_normal_bias = 1.0
	_main_light.shadow_blur      = 1.0
	preview_viewport.add_child(_main_light)
	
	_fill_light = DirectionalLight3D.new()
	_fill_light.rotation_degrees = Vector3(-30, 150, 0)
	_fill_light.light_energy = 1.0
	_fill_light.light_color = Color(0.95, 0.95, 1.0)
	_fill_light.shadow_enabled = false
	preview_viewport.add_child(_fill_light)

	_rim_light = DirectionalLight3D.new()
	_rim_light.rotation_degrees = Vector3(-15, -135, 0)
	_rim_light.light_energy = 0.4
	_rim_light.light_color = Color(1.0, 1.0, 1.0)
	_rim_light.shadow_enabled = false
	preview_viewport.add_child(_rim_light)

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
	_queue_viewport_resize()

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
	
	environment.ssao_enabled = false
	# environment.ssao_radius = 0.5
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


# ══════════════════════════════════════════════════════════════════════════════
#  Camera presets & reset
# ══════════════════════════════════════════════════════════════════════════════
func reset_camera() -> void:
	if !current_model:
		return
	var aabb_info := _get_model_aabb(current_model)
	if bool(aabb_info["has_mesh"]):
		var extent := _get_aabb_max_axis(aabb_info["aabb"])
		camera_horizontal_angle = 0.0
		camera_vertical_angle   = PI / 4.0
		camera_distance         = max(extent * 2.0, 2.0)
		orbit_center            = Vector3.ZERO
		update_camera_position()


## Fit model into view keeping current angle — only adjusts distance & orbit center.
func fit_to_view() -> void:
	if !current_model:
		return
	var aabb_info := _get_model_aabb(current_model)
	if bool(aabb_info["has_mesh"]):
		var total_aabb: AABB = aabb_info["aabb"]
		orbit_center    = total_aabb.get_center()
		var extent: float = _get_aabb_max_axis(total_aabb)
		camera_distance = maxf(extent * 2.0, 0.5)
		update_camera_position()


## Capture the current viewport as a thumbnail of the given pixel size.
func capture_thumbnail(thumb_size: Vector2i) -> ImageTexture:
	if !preview_viewport:
		return null
	var img: Image = preview_viewport.get_texture().get_image()
	if !img or img.is_empty():
		return null
	img.resize(thumb_size.x, thumb_size.y, Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(img)


## Return the raw viewport image at its current resolution (for saving to disk).
func get_screenshot_image() -> Image:
	if !preview_viewport:
		return null
	return preview_viewport.get_texture().get_image()


func set_view_preset(preset: int) -> void:
	if !current_model:
		return
	is_rotating         = false
	auto_rotation_speed = 0.0
	match preset:
		ViewPreset.FRONT:
			camera_horizontal_angle = 0.0
			camera_vertical_angle   = PI / 2.0
		ViewPreset.BACK:
			camera_horizontal_angle = PI
			camera_vertical_angle   = PI / 2.0
		ViewPreset.RIGHT:
			camera_horizontal_angle = PI / 2.0
			camera_vertical_angle   = PI / 2.0
		ViewPreset.LEFT:
			camera_horizontal_angle = -PI / 2.0
			camera_vertical_angle   = PI / 2.0
		ViewPreset.TOP:
			camera_horizontal_angle = 0.0
			camera_vertical_angle   = 0.01
		ViewPreset.BOTTOM:
			camera_horizontal_angle = 0.0
			camera_vertical_angle   = PI - 0.01
	update_camera_position()


# ══════════════════════════════════════════════════════════════════════════════
#  Grid floor
# ══════════════════════════════════════════════════════════════════════════════
func toggle_grid() -> void:
	grid_visible = !grid_visible
	if _grid_instance:
		_grid_instance.visible = grid_visible


func _update_grid() -> void:
	if _grid_instance:
		_grid_instance.queue_free()
		_grid_instance = null

	if !current_model or !preview_viewport:
		return

	var aabb_info := _get_model_aabb(current_model)
	var grid_y    := 0.0
	var cell_size := 1.0
	var half_cells := 10

	if bool(aabb_info["has_mesh"]):
		var total_aabb: AABB = aabb_info["aabb"]
		grid_y = total_aabb.position.y
		var half_span: float = maxf(_get_aabb_max_axis(total_aabb) * 1.5, 5.0)
		# Pick a "nice" cell size so we get ≤ 15 cells per half-axis.
		var _steps: Array[float] = [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0]
		for candidate: float in _steps:
			if half_span / candidate <= 15.0:
				cell_size = candidate
				break
		half_cells = clampi(int(ceil(half_span / cell_size)), 5, 20)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.55, 0.55, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED

	var half_span_w := half_cells * cell_size
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i: int in range(-half_cells, half_cells + 1):
		var p := i * cell_size
		mesh.surface_add_vertex(Vector3(p,           grid_y, -half_span_w))
		mesh.surface_add_vertex(Vector3(p,           grid_y,  half_span_w))
		mesh.surface_add_vertex(Vector3(-half_span_w, grid_y,  p))
		mesh.surface_add_vertex(Vector3( half_span_w, grid_y,  p))
	mesh.surface_end()

	_grid_instance         = MeshInstance3D.new()
	_grid_instance.mesh    = mesh
	_grid_instance.visible = grid_visible
	preview_viewport.add_child(_grid_instance)


# ══════════════════════════════════════════════════════════════════════════════
#  XYZ axis gizmo overlay
# ══════════════════════════════════════════════════════════════════════════════
func toggle_gizmo() -> void:
	gizmo_visible = !gizmo_visible
	if _gizmo_overlay:
		_gizmo_overlay.visible = gizmo_visible


func _create_gizmo_overlay() -> void:
	_gizmo_overlay             = Control.new()
	_gizmo_overlay.name        = "GizmoOverlay"
	_gizmo_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gizmo_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gizmo_overlay.draw.connect(_on_gizmo_draw)
	add_child(_gizmo_overlay)


func _on_gizmo_draw() -> void:
	if !preview_camera or !current_model or !_gizmo_overlay:
		return

	var arm    := 36.0
	var pad    := 14.0
	var ov     := _gizmo_overlay
	var origin := Vector2(pad + arm, ov.size.y - pad - arm)
	var basis: Basis = preview_camera.global_transform.basis
	var font   := ThemeDB.fallback_font

	# Project world axes: screen_right = cam.basis.x, screen_up = cam.basis.y (negated for screen Y)
	var axes: Array = [
		[Vector2(basis.x.x, -basis.y.x), Color(0.90, 0.22, 0.22), "X", basis.z.x],
		[Vector2(basis.x.y, -basis.y.y), Color(0.22, 0.78, 0.22), "Y", basis.z.y],
		[Vector2(basis.x.z, -basis.y.z), Color(0.28, 0.52, 1.00), "Z", basis.z.z],
	]
	# Painter's sort: draw axes pointing away from camera first
	axes.sort_custom(func(a: Array, b: Array) -> bool: return a[3] > b[3])

	for ax: Array in axes:
		var end := origin + (ax[0] as Vector2) * arm
		ov.draw_line(origin, end, ax[1], 2.0)
		ov.draw_circle(end, 4.0, ax[1])
		ov.draw_string(font, end + Vector2(7, 4), ax[2],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ax[1])

	ov.draw_circle(origin, 3.5, Color(0.85, 0.85, 0.85, 0.9))


# ══════════════════════════════════════════════════════════════════════════════
#  Wireframe  (0 = off | 1 = overlay solid+wire | 2 = wireframe-only)
# ══════════════════════════════════════════════════════════════════════════════
func toggle_wireframe() -> void:
	set_wireframe_mode((wireframe_mode + 1) % 3)


func set_wireframe_mode(mode: int) -> void:
	wireframe_mode    = mode
	wireframe_enabled = (mode == 2)
	match mode:
		0:  # Solid only — remove overlay, restore normal draw
			_remove_wireframe_overlay()
			if preview_viewport:
				preview_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		1:  # Overlay — solid rendered normally, wireframe mesh on top
			if preview_viewport:
				preview_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
			_build_wireframe_overlay()
		2:  # Wireframe only via viewport debug draw
			_remove_wireframe_overlay()
			if preview_viewport:
				preview_viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME


func _build_wireframe_overlay() -> void:
	_remove_wireframe_overlay()
	if !current_model:
		return

	# ── Pass 1: collect all real mesh instances iteratively (BFS, no recursion) ──
	var real_meshes: Array[MeshInstance3D] = []
	var queue: Array[Node] = [current_model]
	while queue.size() > 0:
		var n: Node = queue.pop_front()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if !mi.get_meta("_wf_overlay", false) and mi.mesh:
				real_meshes.append(mi)
		# Only queue children that existed before we added any duplicates
		for c in n.get_children():
			if not c.get_meta("_wf_overlay", false):
				queue.append(c)

	# ── Pass 2: create wireframe duplicates now that the list is frozen ──────────
	var wf_shader := Shader.new()
	wf_shader.code = WIREFRAME_SHADER_SRC
	var wf_mat := ShaderMaterial.new()
	wf_mat.shader = wf_shader

	for mi in real_meshes:
		var dup := MeshInstance3D.new()
		dup.set_meta("_wf_overlay", true)
		dup.mesh = mi.mesh
		dup.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for s in range(mi.mesh.get_surface_count()):
			dup.set_surface_override_material(s, wf_mat)
		mi.add_child(dup)
		_wireframe_overlay_nodes.append(dup)


func _remove_wireframe_overlay() -> void:
	for node in _wireframe_overlay_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_wireframe_overlay_nodes.clear()


# ══════════════════════════════════════════════════════════════════════════════
#  Mesh isolation — click a mesh name to hide all others; click again to restore
# ══════════════════════════════════════════════════════════════════════════════
func isolate_mesh(mesh_name: String) -> void:
	if !current_model:
		return
	if _isolated_mesh_name == mesh_name:
		show_all_meshes()
		return
	_isolated_mesh_name = mesh_name
	for child in _get_all_children(current_model):
		if child is MeshInstance3D and not child.get_meta("_wf_overlay", false):
			child.visible = (child.name == mesh_name)


func show_all_meshes() -> void:
	_isolated_mesh_name = ""
	if !current_model:
		return
	for child in _get_all_children(current_model):
		if child is MeshInstance3D and not child.get_meta("_wf_overlay", false):
			child.visible = true


# ══════════════════════════════════════════════════════════════════════════════
#  Associated file paths (textures / materials) for the loaded model
# ══════════════════════════════════════════════════════════════════════════════
func get_texture_file_paths() -> Array[String]:
	var paths: Array[String] = []
	if !current_model:
		return paths
	for child in _get_all_children(current_model):
		if not child is MeshInstance3D:
			continue
		var mi := child as MeshInstance3D
		if !mi.mesh:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var mat: Material = mi.mesh.surface_get_material(s)
			if not mat is StandardMaterial3D:
				continue
			var sm := mat as StandardMaterial3D
			for tex: Texture2D in [
					sm.albedo_texture,   sm.normal_texture,
					sm.metallic_texture, sm.roughness_texture,
					sm.emission_texture, sm.ao_texture]:
				if not tex or tex.resource_path.is_empty():
					continue
				var abs_path := ProjectSettings.globalize_path(tex.resource_path)
				if FileAccess.file_exists(abs_path) and abs_path not in paths:
					paths.append(abs_path)
	return paths


# ══════════════════════════════════════════════════════════════════════════════
#  Zoom to cursor
# ══════════════════════════════════════════════════════════════════════════════
func toggle_zoom_to_cursor() -> void:
	zoom_to_cursor = !zoom_to_cursor


func _do_zoom(zoom_in: bool, mouse_pos: Vector2) -> void:
	var model_size := get_model_size()
	var old_dist   := camera_distance

	if zoom_in:
		camera_distance = max(model_size * 0.1, camera_distance / zoom_speed)
	else:
		camera_distance = min(model_size * 20.0, camera_distance * zoom_speed)

	if zoom_to_cursor and preview_camera:
		var dist_change := camera_distance - old_dist
		var ray_dir: Vector3 = preview_camera.project_ray_normal(mouse_pos)
		orbit_center    -= ray_dir * dist_change * 0.45

	update_camera_position()


# ══════════════════════════════════════════════════════════════════════════════
#  Screenshot
# ══════════════════════════════════════════════════════════════════════════════
func take_screenshot() -> Image:
	if !preview_viewport:
		return null
	return preview_viewport.get_texture().get_image()


# ══════════════════════════════════════════════════════════════════════════════
#  Animation speed control
# ══════════════════════════════════════════════════════════════════════════════
func _create_speed_control() -> void:
	var controls_row := get_node_or_null("../HSplitContainer_ControlsRow")
	if !controls_row:
		return

	_speed_option_btn = OptionButton.new()
	_speed_option_btn.add_item("×0.25", 0)
	_speed_option_btn.add_item("×0.5",  1)
	_speed_option_btn.add_item("×1",    2)
	_speed_option_btn.add_item("×2",    3)
	_speed_option_btn.add_item("×4",    4)
	_speed_option_btn.selected          = 2
	_speed_option_btn.custom_minimum_size.x = 68
	_speed_option_btn.tooltip_text      = "Скорость анимации"
	_speed_option_btn.visible           = false
	_speed_option_btn.item_selected.connect(func(idx: int) -> void:
		const SPEEDS: Array = [0.25, 0.5, 1.0, 2.0, 4.0]
		animation_speed_scale = SPEEDS[idx]
		if current_animation_player:
			current_animation_player.speed_scale = animation_speed_scale
	)
	controls_row.add_child(_speed_option_btn)


# ══════════════════════════════════════════════════════════════════════════════
#  Environment presets & HDRI
# ══════════════════════════════════════════════════════════════════════════════
func set_env_preset(preset: int) -> void:
	if !_world_env_node or !_world_env_node.environment:
		return
	var env: Environment = _world_env_node.environment
	match preset:
		0:  # Default gray
			env.background_mode        = Environment.BG_COLOR
			env.background_color       = Color(0.2, 0.2, 0.2)
			env.ambient_light_source   = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color    = Color(0.4, 0.4, 0.4)
			env.ambient_light_energy   = 1.5
			env.sky = null
		1:  # Dark studio
			env.background_mode        = Environment.BG_COLOR
			env.background_color       = Color(0.05, 0.05, 0.05)
			env.ambient_light_source   = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color    = Color(0.1, 0.1, 0.1)
			env.ambient_light_energy   = 0.5
			env.sky = null
		2:  # White
			env.background_mode        = Environment.BG_COLOR
			env.background_color       = Color(0.92, 0.92, 0.92)
			env.ambient_light_source   = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color    = Color(0.85, 0.85, 0.85)
			env.ambient_light_energy   = 2.0
			env.sky = null
		3:  # Procedural sky
			var sky_mat := ProceduralSkyMaterial.new()
			var sky     := Sky.new()
			sky.sky_material           = sky_mat
			env.sky                    = sky
			env.background_mode        = Environment.BG_SKY
			env.ambient_light_source   = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy   = 1.0


func load_env_hdri(path: String) -> void:
	if !_world_env_node or !_world_env_node.environment:
		return
	var img := Image.load_from_file(path)
	if !img:
		push_error("load_env_hdri: failed to load " + path)
		return
	var panorama_mat := PanoramaSkyMaterial.new()
	panorama_mat.panorama = ImageTexture.create_from_image(img)
	var sky := Sky.new()
	sky.sky_material = panorama_mat
	var env: Environment = _world_env_node.environment
	env.sky                  = sky
	env.background_mode      = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0


# ══════════════════════════════════════════════════════════════════════════════
#  Light control
# ══════════════════════════════════════════════════════════════════════════════
func _apply_light_transform() -> void:
	if _main_light:
		_main_light.rotation_degrees = Vector3(_light_elevation_deg, _light_azimuth_deg, 0.0)


func set_light_azimuth(deg: float) -> void:
	_light_azimuth_deg = deg
	_apply_light_transform()


func set_light_elevation(deg: float) -> void:
	_light_elevation_deg = deg
	_apply_light_transform()


func set_light_energy(energy: float) -> void:
	_light_energy = energy
	if _main_light:
		_main_light.light_energy = energy


func set_light_color(color: Color) -> void:
	if _main_light:
		_main_light.light_color = color


func set_shadow_enabled(on: bool) -> void:
	if _main_light:
		_main_light.shadow_enabled = on


func set_fill_light_energy(energy: float) -> void:
	if _fill_light:
		_fill_light.light_energy = energy


func set_fill_light_enabled(on: bool) -> void:
	if _fill_light:
		_fill_light.visible = on


func set_rim_light_energy(energy: float) -> void:
	if _rim_light:
		_rim_light.light_energy = energy


func set_rim_light_enabled(on: bool) -> void:
	if _rim_light:
		_rim_light.visible = on


func set_ambient_energy(energy: float) -> void:
	if _world_env_node and _world_env_node.environment:
		_world_env_node.environment.ambient_light_energy = energy


## preset: 0 = Studio (3-point), 1 = Outdoor, 2 = Night, 3 = Rimlight
func apply_light_preset(preset: int) -> void:
	match preset:
		0:  # Studio — warm key, cool fill, white rim
			_light_azimuth_deg   = -30.0
			_light_elevation_deg = -55.0
			_light_energy        = 2.0
			if _main_light:
				_main_light.light_energy = _light_energy
				_main_light.light_color  = Color(1.0, 0.98, 0.95)
				_main_light.shadow_enabled = true
			if _fill_light:
				_fill_light.light_energy = 1.0
				_fill_light.light_color  = Color(0.88, 0.92, 1.0)
				_fill_light.visible      = true
			if _rim_light:
				_rim_light.light_energy = 0.6
				_rim_light.light_color  = Color(1.0, 1.0, 1.0)
				_rim_light.visible      = true
			set_ambient_energy(1.0)
		1:  # Outdoor — bright sun, sky fill, no rim
			_light_azimuth_deg   = 45.0
			_light_elevation_deg = -50.0
			_light_energy        = 3.0
			if _main_light:
				_main_light.light_energy = _light_energy
				_main_light.light_color  = Color(1.0, 0.97, 0.88)
				_main_light.shadow_enabled = true
			if _fill_light:
				_fill_light.light_energy = 0.5
				_fill_light.light_color  = Color(0.7, 0.85, 1.0)
				_fill_light.visible      = true
			if _rim_light:
				_rim_light.light_energy = 0.0
				_rim_light.visible      = false
			set_ambient_energy(1.4)
		2:  # Night — dim blue-toned key, no fill, strong rim
			_light_azimuth_deg   = -60.0
			_light_elevation_deg = -20.0
			_light_energy        = 0.4
			if _main_light:
				_main_light.light_energy = _light_energy
				_main_light.light_color  = Color(0.7, 0.78, 1.0)
				_main_light.shadow_enabled = true
			if _fill_light:
				_fill_light.light_energy = 0.0
				_fill_light.visible      = false
			if _rim_light:
				_rim_light.light_energy = 0.8
				_rim_light.light_color  = Color(0.5, 0.65, 1.0)
				_rim_light.visible      = true
			set_ambient_energy(0.3)
		3:  # Rimlight only
			_light_elevation_deg = -30.0
			_light_energy        = 0.2
			if _main_light:
				_main_light.light_energy = _light_energy
				_main_light.shadow_enabled = false
			if _fill_light:
				_fill_light.light_energy = 0.0
				_fill_light.visible      = false
			if _rim_light:
				_rim_light.light_energy = 2.0
				_rim_light.light_color  = Color(1.0, 1.0, 1.0)
				_rim_light.visible      = true
			set_ambient_energy(0.5)
	_apply_light_transform()


# ══════════════════════════════════════════════════════════════════════════════
#  FPS / stats overlay
# ══════════════════════════════════════════════════════════════════════════════
func _create_fps_overlay() -> void:
	_fps_label = Label.new()
	_fps_label.name    = "FPSOverlayLabel"
	_fps_label.visible = false
	_fps_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_fps_label.offset_left  = -160
	_fps_label.offset_right = -8
	_fps_label.offset_top   = 8
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.add_theme_font_size_override("font_size", 13)
	_fps_label.add_theme_color_override("font_color",        Color(1.0, 0.95, 0.2))
	_fps_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_fps_label.add_theme_constant_override("shadow_offset_x", 1)
	_fps_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_fps_label)


func toggle_fps_counter() -> bool:
	_fps_visible = !_fps_visible
	if _fps_label:
		_fps_label.visible = _fps_visible
	return _fps_visible


# ══════════════════════════════════════════════════════════════════════════════
#  Texture channel debug view
# ══════════════════════════════════════════════════════════════════════════════
func set_texture_channel(ch: int) -> void:
	_tex_channel = ch
	if !current_model:
		return
	for node in _get_all_children(current_model):
		if not node is MeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		if !mi.mesh:
			continue
		for i: int in range(mi.mesh.get_surface_count()):
			if ch == 0:
				mi.set_surface_override_material(i, null)   # restore original
			else:
				var orig: Material = mi.mesh.surface_get_material(i)
				mi.set_surface_override_material(i, _make_channel_material(orig, ch))


func _make_channel_material(orig: Material, ch: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	if not orig is StandardMaterial3D:
		mat.albedo_color = Color(0.5, 0.5, 0.5)
		return mat
	var sm := orig as StandardMaterial3D
	match ch:
		1:  # Albedo — show with lighting for correct colour read
			mat.shading_mode   = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.albedo_color   = sm.albedo_color
			mat.albedo_texture = sm.albedo_texture
		2:  # Roughness → grayscale
			mat.albedo_color   = Color(sm.roughness, sm.roughness, sm.roughness)
			if sm.roughness_texture:
				mat.albedo_texture = sm.roughness_texture
		3:  # Normal map → shown as colour
			if sm.normal_texture:
				mat.albedo_texture = sm.normal_texture
			else:
				mat.albedo_color   = Color(0.5, 0.5, 1.0)
		4:  # Metallic → grayscale
			mat.albedo_color   = Color(sm.metallic, sm.metallic, sm.metallic)
			if sm.metallic_texture:
				mat.albedo_texture = sm.metallic_texture
	return mat
