extends Panel

var content_root: VBoxContainer = null
var file_name_label: Label = null
var type_label: Label = null
var size_label: Label = null
var date_modified_label: Label = null
var vertices_label: Label = null
var faces_label: Label = null
var materials_label: Label = null
var path_label: Label = null

var materials_container: VBoxContainer = null
var textures_container: VBoxContainer = null
var animations_container: VBoxContainer = null

var current_material_preview: Window = null
var animation_player: AnimationPlayer = null


func _ready() -> void:
	_ensure_responsive_scroll_layout()
	_cache_nodes()

	if !file_name_label or !type_label or !size_label or !date_modified_label or \
		!vertices_label or !faces_label or !materials_label or !path_label:
		push_error("Some info labels are not properly connected!")
		return

	if !materials_container or !textures_container or !animations_container:
		push_error("Material/texture/animation containers not found!")
		return

	setup_ui()
	clear_info()


func _ensure_responsive_scroll_layout() -> void:
	custom_minimum_size = Vector2(0, 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var legacy_vbox: VBoxContainer = get_node_or_null("VBoxContainer") as VBoxContainer
	var existing_scroll: ScrollContainer = get_node_or_null("ScrollContainer") as ScrollContainer

	if legacy_vbox and !existing_scroll:
		remove_child(legacy_vbox)
		var scroll := ScrollContainer.new()
		scroll.name = "ScrollContainer"
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(scroll)
		scroll.add_child(legacy_vbox)

	existing_scroll = get_node_or_null("ScrollContainer") as ScrollContainer
	if existing_scroll:
		existing_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		existing_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		existing_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		existing_scroll.clip_contents = true

	content_root = get_node_or_null("ScrollContainer/VBoxContainer") as VBoxContainer
	if !content_root:
		content_root = get_node_or_null("VBoxContainer") as VBoxContainer

	if content_root:
		content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content_root.add_theme_constant_override("separation", 6)


func _cache_nodes() -> void:
	var base_path: String = "ScrollContainer/VBoxContainer" if has_node("ScrollContainer/VBoxContainer") else "VBoxContainer"

	file_name_label = get_node_or_null(base_path + "/FileNameLabel") as Label
	type_label = get_node_or_null(base_path + "/TypeLabel") as Label
	size_label = get_node_or_null(base_path + "/SizeLabel") as Label
	date_modified_label = get_node_or_null(base_path + "/DateModifiedLabel") as Label
	vertices_label = get_node_or_null(base_path + "/VerticesLabel") as Label
	faces_label = get_node_or_null(base_path + "/FacesLabel") as Label
	materials_label = get_node_or_null(base_path + "/MaterialsLabel") as Label
	path_label = get_node_or_null(base_path + "/PathLabel") as Label

	materials_container = get_node_or_null(base_path + "/MaterialsSection/MaterialsList") as VBoxContainer
	textures_container = get_node_or_null(base_path + "/TexturesSection/TexturesList") as VBoxContainer
	animations_container = get_node_or_null(base_path + "/AnimationsSection/AnimationsList") as VBoxContainer


func setup_ui() -> void:
	if content_root:
		content_root.custom_minimum_size = Vector2(0, 0)
		content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_setup_wrapping_label(file_name_label)
	_setup_wrapping_label(path_label)

	if materials_container:
		materials_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		materials_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if textures_container:
		textures_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		textures_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if animations_container:
		animations_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		animations_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _setup_wrapping_label(label: Label) -> void:
	if !label:
		return
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.clip_text = true


func update_info(model_info: Dictionary) -> void:
	if model_info.is_empty():
		clear_info()
		return

	file_name_label.text = "Файл: " + str(model_info.get("filename", "Неизвестно"))
	type_label.text = "Тип: " + str(model_info.get("type", "Неизвестно"))
	size_label.text = "Размер: " + str(model_info.get("size", "Неизвестно"))
	date_modified_label.text = "Изменен: " + str(model_info.get("date_modified", "Неизвестно"))
	vertices_label.text = "Вершин: " + str(model_info.get("vertices", "Неизвестно"))
	faces_label.text = "Граней: " + str(model_info.get("faces", "Неизвестно"))
	materials_label.text = "Материалов: " + str(model_info.get("materials", "Неизвестно"))
	path_label.text = "Путь: " + str(model_info.get("path", "Неизвестно"))

	update_materials_list(model_info.get("materials_data", []))
	update_textures_list(model_info.get("textures_data", []))
	update_animations_list(model_info.get("animations_data", []))


func update_materials_list(materials_data: Array) -> void:
	_clear_container(materials_container)
	if materials_data.is_empty():
		_add_empty_label(materials_container, "Нет материалов")
		return

	for material_info in materials_data:
		var item := Button.new()
		item.text = str(material_info.get("name", "Unnamed Material"))
		item.custom_minimum_size.y = 30
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.tooltip_text = str(material_info.get("type", "Material"))
		item.pressed.connect(_on_material_pressed.bind(material_info))
		materials_container.add_child(item)


func update_textures_list(textures_data: Array) -> void:
	_clear_container(textures_container)
	if textures_data.is_empty():
		_add_empty_label(textures_container, "Нет текстур")
		return

	for texture_info in textures_data:
		var item := Button.new()
		item.text = str(texture_info.get("name", "Unnamed Texture"))
		item.custom_minimum_size.y = 30
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.pressed.connect(_on_texture_pressed.bind(texture_info))
		textures_container.add_child(item)


func update_animations_list(animations_data: Array) -> void:
	_clear_container(animations_container)
	if animations_data.is_empty():
		_add_empty_label(animations_container, "Нет анимаций")
		return

	for animation_info in animations_data:
		var item := Button.new()
		var length_text := ""
		if animation_info.has("length"):
			length_text = " (%.2fs)" % float(animation_info["length"])
		item.text = str(animation_info.get("name", "Unnamed Animation")) + length_text
		item.custom_minimum_size.y = 30
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.pressed.connect(_on_animation_pressed.bind(animation_info))
		animations_container.add_child(item)


func _on_material_pressed(material_info: Dictionary) -> void:
	if is_instance_valid(current_material_preview):
		current_material_preview.queue_free()

	current_material_preview = Window.new()
	current_material_preview.title = "Material Preview: " + str(material_info.get("name", "Unknown"))
	current_material_preview.size = Vector2(440, 340)
	current_material_preview.close_requested.connect(_close_material_preview)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_create_material_preview(material_info))

	vbox.add_child(scroll)
	vbox.add_child(_create_close_button(current_material_preview))

	current_material_preview.add_child(vbox)
	add_child(current_material_preview)
	current_material_preview.popup_centered()


func _close_material_preview() -> void:
	if is_instance_valid(current_material_preview):
		current_material_preview.queue_free()
	current_material_preview = null


func _on_texture_pressed(texture_info: Dictionary) -> void:
	var preview_window := Window.new()
	preview_window.title = "Texture Preview: " + str(texture_info.get("name", "Unknown"))
	preview_window.size = Vector2(440, 440)
	preview_window.close_requested.connect(func(): preview_window.queue_free())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)

	var texture_rect := TextureRect.new()
	if texture_info.has("texture"):
		texture_rect.texture = texture_info["texture"]
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.custom_minimum_size = Vector2(360, 340)
	texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL

	vbox.add_child(texture_rect)
	vbox.add_child(_create_close_button(preview_window))

	preview_window.add_child(vbox)
	add_child(preview_window)
	preview_window.popup_centered()


func _on_animation_pressed(animation_info: Dictionary) -> void:
	if !animation_info.has("player") or !animation_info.has("name"):
		return

	var player := animation_info["player"] as AnimationPlayer
	var animation_name := str(animation_info["name"])
	if !player:
		return

	var preview_node = get_node_or_null("../../VBoxContainer2/SubViewportContainer")
	if preview_node and preview_node.has_method("play_animation"):
		preview_node.play_animation(animation_name, player)
	else:
		player.play(animation_name)

	animation_player = player


func _create_material_preview(material_info: Dictionary) -> Control:
	var preview := VBoxContainer.new()
	preview.add_theme_constant_override("separation", 6)

	var header := Label.new()
	header.text = str(material_info.get("type", "Material"))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview.add_child(header)

	var properties: Dictionary = material_info.get("properties", {})
	if properties.is_empty():
		_add_empty_label(preview, "Нет дополнительных свойств")
		return preview

	for property_name in properties.keys():
		var property_label := Label.new()
		property_label.text = str(property_name) + ": " + str(properties[property_name])
		property_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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

	_clear_container(materials_container)
	_clear_container(textures_container)
	_clear_container(animations_container)
	_add_empty_label(materials_container, "Нет материалов")
	_add_empty_label(textures_container, "Нет текстур")
	_add_empty_label(animations_container, "Нет анимаций")

	_close_material_preview()


func _clear_container(container: Container) -> void:
	if !container:
		return
	for child in container.get_children():
		child.queue_free()


func _add_empty_label(container: Container, text: String) -> void:
	if !container:
		return
	var label := Label.new()
	label.text = text
	label.modulate.a = 0.65
	container.add_child(label)


func _create_close_button(window_ref: Window) -> Button:
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func():
		if is_instance_valid(window_ref):
			window_ref.queue_free()
		if window_ref == current_material_preview:
			current_material_preview = null
	)
	return close_button
