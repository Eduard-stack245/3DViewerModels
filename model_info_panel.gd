extends Panel

@onready var file_name_label = $VBoxContainer/FileNameLabel
@onready var type_label = $VBoxContainer/TypeLabel
@onready var size_label = $VBoxContainer/SizeLabel
@onready var date_modified_label = $VBoxContainer/DateModifiedLabel
@onready var vertices_label = $VBoxContainer/VerticesLabel
@onready var faces_label = $VBoxContainer/FacesLabel
@onready var materials_label = $VBoxContainer/MaterialsLabel
@onready var path_label = $VBoxContainer/PathLabel

@onready var materials_container = $VBoxContainer/MaterialsSection/MaterialsList
@onready var textures_container = $VBoxContainer/TexturesSection/TexturesList
@onready var animations_container = $VBoxContainer/AnimationsSection/AnimationsList

var current_material_preview: Window
var animation_player: AnimationPlayer

func _ready():
	if !file_name_label or !type_label or !size_label or !date_modified_label or \
	   !vertices_label or !faces_label or !materials_label or !path_label:
		push_error("Some labels are not properly connected!")
		return
		
	if !materials_container or !textures_container or !animations_container:
		push_error("Material/texture/animation containers not found!")
		return
		
	setup_ui()

func setup_ui():
	if materials_container:
		materials_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if textures_container:
		textures_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if animations_container:
		animations_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

func update_info(model_info: Dictionary) -> void:
	if model_info.is_empty():
		clear_info()
		return

	if file_name_label:
		file_name_label.text = "Файл: " + model_info.get("filename", "Неизвестно")
	if type_label:
		type_label.text = "Тип: " + model_info.get("type", "Неизвестно")
	if size_label:
		size_label.text = "Размер: " + model_info.get("size", "Неизвестно")
	if date_modified_label:
		date_modified_label.text = "Изменен: " + model_info.get("date_modified", "Неизвестно")
	if vertices_label:
		vertices_label.text = "Вершин: " + model_info.get("vertices", "Неизвестно")
	if faces_label:
		faces_label.text = "Граней: " + model_info.get("faces", "Неизвестно")
	if materials_label:
		materials_label.text = "Материалов: " + str(model_info.get("materials", "Неизвестно"))
	if path_label:
		path_label.text = "Путь: " + model_info.get("path", "Неизвестно")
	
	if materials_container:
		update_materials_list(model_info.get("materials_data", []))
	if textures_container:
		update_textures_list(model_info.get("textures_data", []))
	if animations_container:
		update_animations_list(model_info.get("animations_data", []))

func update_materials_list(materials: Array):
	if !materials_container:
		return
	
	for child in materials_container.get_children():
		child.queue_free()
	
	for material in materials:
		var item = Button.new()
		item.text = material.get("name", "Unnamed Material")
		item.custom_minimum_size.y = 30
		item.pressed.connect(_on_material_pressed.bind(material))
		materials_container.add_child(item)

func update_textures_list(textures: Array):
	if !textures_container:
		return
	
	for child in textures_container.get_children():
		child.queue_free()
	
	for texture in textures:
		var item = Button.new()
		item.text = texture.get("name", "Unnamed Texture")
		item.custom_minimum_size.y = 30
		item.pressed.connect(_on_texture_pressed.bind(texture))
		textures_container.add_child(item)

func update_animations_list(animations: Array):
	if !animations_container:
		return
	
	for child in animations_container.get_children():
		child.queue_free()
	
	for animation in animations:
		var item = Button.new()
		item.text = animation.get("name", "Unnamed Animation")
		item.custom_minimum_size.y = 30
		item.pressed.connect(_on_animation_pressed.bind(animation))
		animations_container.add_child(item)

func _on_material_pressed(material: Dictionary):
	if is_instance_valid(current_material_preview):
		current_material_preview.queue_free()
	
	current_material_preview = Window.new()
	current_material_preview.title = "Material Preview: " + material.get("name", "Unknown")
	current_material_preview.size = Vector2(400, 300)
	
	current_material_preview.close_requested.connect(
		func():
			if is_instance_valid(current_material_preview):
				current_material_preview.queue_free()
				current_material_preview = null
	)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	
	var close_button = Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(
		func():
			if is_instance_valid(current_material_preview):
				current_material_preview.queue_free()
				current_material_preview = null
	)
	
	vbox.add_child(_create_material_preview(material))
	vbox.add_child(close_button)
	
	current_material_preview.add_child(vbox)
	add_child(current_material_preview)
	current_material_preview.popup_centered()

func _on_texture_pressed(texture: Dictionary):
	var preview_window = Window.new()
	preview_window.title = "Texture Preview: " + texture.get("name", "Unknown")
	preview_window.size = Vector2(400, 400)
	
	var window_ref = preview_window
	preview_window.close_requested.connect(
		func():
			if is_instance_valid(window_ref):
				window_ref.queue_free()
	)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	
	var texture_rect = TextureRect.new()
	if texture.has("texture"):
		texture_rect.texture = texture.texture
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.custom_minimum_size = Vector2(300, 300)
	
	var close_button = Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(
		func():
			if is_instance_valid(window_ref):
				window_ref.queue_free()
	)
	
	vbox.add_child(texture_rect)
	vbox.add_child(close_button)
	
	preview_window.add_child(vbox)
	add_child(preview_window)
	preview_window.popup_centered()

func _on_animation_pressed(animation: Dictionary):
	if !animation.has("player") or !animation.has("name"):
		return
	
	var viewport_container = get_node("/root/Control/HSplitContainer/HBoxContainer2/VBoxContainer2/SubViewportContainer")
	if viewport_container:
		viewport_container.play_animation(animation.name, animation.player)
		
	animation_player = animation.player
	if animation_player:
		animation_player.play(animation.name)

func _create_material_preview(material: Dictionary) -> Control:
	var preview = VBoxContainer.new()
	
	if material.has("properties"):
		for property in material.properties:
			var property_label = Label.new()
			property_label.text = str(property) + ": " + str(material.properties[property])
			preview.add_child(property_label)
	
	return preview

func clear_info() -> void:
	if file_name_label:
		file_name_label.text = "Файл: -"
	if type_label:
		type_label.text = "Тип: -"
	if size_label:
		size_label.text = "Размер: -"
	if date_modified_label:
		date_modified_label.text = "Изменен: -"
	if vertices_label:
		vertices_label.text = "Вершин: -"
	if faces_label:
		faces_label.text = "Граней: -"
	if materials_label:
		materials_label.text = "Материалов: -"
	if path_label:
		path_label.text = "Путь: -"
	
	if materials_container:
		for child in materials_container.get_children():
			child.queue_free()
	if textures_container:
		for child in textures_container.get_children():
			child.queue_free()
	if animations_container:
		for child in animations_container.get_children():
			child.queue_free()
	
	if current_material_preview:
		current_material_preview.queue_free()
		current_material_preview = null

	if is_instance_valid(current_material_preview):
		current_material_preview.queue_free()
		current_material_preview = null
