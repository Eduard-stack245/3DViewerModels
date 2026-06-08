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

var dimensions_label: Label = null

var materials_container: VBoxContainer = null
var textures_container: VBoxContainer = null
var animations_container: VBoxContainer = null
var meshes_container: VBoxContainer = null

var current_material_preview: Window = null
var animation_player: AnimationPlayer = null
var _current_model_path: String = ""


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

	_create_dimensions_label()
	_create_path_copy_button()
	_create_meshes_section()
	setup_ui()
	clear_info()


func _ensure_responsive_scroll_layout() -> void:
	custom_minimum_size = Vector2(0, 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true   # panel itself never draws outside its rect

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
		existing_scroll.size_flags_horizontal        = Control.SIZE_EXPAND_FILL
		existing_scroll.size_flags_vertical          = Control.SIZE_EXPAND_FILL
		existing_scroll.clip_contents                = true
		# Disable horizontal scroll — forces all content to wrap within panel width
		existing_scroll.horizontal_scroll_mode       = ScrollContainer.SCROLL_MODE_DISABLED

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
		content_root.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# Apply wrapping + clipping to every info label so long paths/names
	# never overflow the right panel.
	for lbl in [file_name_label, type_label, size_label, date_modified_label,
				vertices_label, faces_label, materials_label, dimensions_label,
				path_label]:
		_setup_wrapping_label(lbl)

	for container in [materials_container, textures_container, animations_container, meshes_container]:
		if container:
			container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			container.size_flags_vertical   = Control.SIZE_EXPAND_FILL

func _setup_wrapping_label(label: Label) -> void:
	if !label:
		return
	label.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text            = false   # let it wrap, not clip mid-character


func update_info(model_info: Dictionary) -> void:
	if model_info.is_empty():
		clear_info()
		return

	_current_model_path = str(model_info.get("path", ""))
	file_name_label.text = "Файл: " + str(model_info.get("filename", "Неизвестно"))
	type_label.text = "Тип: " + str(model_info.get("type", "Неизвестно"))
	size_label.text = "Размер: " + str(model_info.get("size", "Неизвестно"))
	date_modified_label.text = "Изменен: " + str(model_info.get("date_modified", "Неизвестно"))
	vertices_label.text = "Вершин: " + str(model_info.get("vertices", "Неизвестно"))
	faces_label.text = "Граней: " + str(model_info.get("faces", "Неизвестно"))
	materials_label.text = "Материалов: " + str(model_info.get("materials", "Неизвестно"))
	path_label.text = "Путь: " + _current_model_path

	var aabb_sz: Vector3 = model_info.get("aabb_size", Vector3.ZERO)
	if dimensions_label:
		if aabb_sz != Vector3.ZERO:
			dimensions_label.text = "Размеры: %.2f × %.2f × %.2f" % [aabb_sz.x, aabb_sz.y, aabb_sz.z]
		else:
			dimensions_label.text = "Размеры: -"

	update_materials_list(model_info.get("materials_data", []))
	update_textures_list(model_info.get("textures_data", []))
	update_animations_list(model_info.get("animations_data", []))
	update_meshes_list(model_info.get("meshes_data", []))


func update_materials_list(materials_data: Array) -> void:
	_clear_container(materials_container)
	if materials_data.is_empty():
		_add_empty_label(materials_container, "Нет материалов")
		return

	for material_info in materials_data:
		var item := Button.new()
		item.text = str(material_info.get("name", "Unnamed Material"))
		item.custom_minimum_size = Vector2(0, 30)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.clip_text = true
		item.tooltip_text = str(material_info.get("name", "")) + "\n" + str(material_info.get("type", "Material"))
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
		item.custom_minimum_size = Vector2(0, 30)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.clip_text = true
		item.tooltip_text = str(texture_info.get("name", ""))
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
		item.custom_minimum_size = Vector2(0, 30)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.clip_text = true
		item.tooltip_text = str(animation_info.get("name", "")) + length_text
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
	var tex: Texture2D = texture_info.get("texture", null) as Texture2D

	# Pick an initial window size that fits the texture but caps at 80% of screen.
	var screen_size: Vector2 = DisplayServer.screen_get_size()
	var max_w := screen_size.x * 0.8
	var max_h := screen_size.y * 0.8
	var win_w  := 512.0
	var win_h  := 512.0
	if tex:
		var tw := float(tex.get_width())
		var th := float(tex.get_height())
		var tex_scale := minf(max_w / tw, max_h / th)
		if tex_scale < 1.0:
			win_w = tw * tex_scale
			win_h = th * tex_scale
		else:
			win_w = tw
			win_h = th
	win_w = maxf(win_w, 200.0)
	win_h = maxf(win_h, 200.0)

	var preview_window := Window.new()
	preview_window.title    = str(texture_info.get("name", "Текстура"))
	preview_window.size     = Vector2(win_w, win_h)
	preview_window.min_size = Vector2i(200, 200)
	preview_window.close_requested.connect(func(): preview_window.queue_free())

	# TextureRect fills the entire window and rescales when the window is resized.
	var texture_rect := TextureRect.new()
	texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_rect.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_rect.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	if tex:
		texture_rect.texture = tex

	preview_window.add_child(texture_rect)
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
	if dimensions_label:
		dimensions_label.text = "Размеры: -"
	_current_model_path = ""
	if path_label:
		path_label.text = "Путь: -"

	_clear_container(materials_container)
	_clear_container(textures_container)
	_clear_container(animations_container)
	_clear_container(meshes_container)
	_add_empty_label(materials_container, "Нет материалов")
	_add_empty_label(textures_container, "Нет текстур")
	_add_empty_label(animations_container, "Нет анимаций")
	_add_empty_label(meshes_container, "Нет мешей")

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


func _create_dimensions_label() -> void:
	if !content_root:
		return
	dimensions_label      = Label.new()
	dimensions_label.name = "DimensionsLabel"
	dimensions_label.text = "Размеры: -"
	content_root.add_child(dimensions_label)
	# Place right after MaterialsLabel
	if materials_label and materials_label.get_parent() == content_root:
		content_root.move_child(dimensions_label, materials_label.get_index() + 1)


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


# ══════════════════════════════════════════════════════════════════════════════
#  Meshes section (created at runtime so no scene change needed)
# ══════════════════════════════════════════════════════════════════════════════
func _create_path_copy_button() -> void:
	if !path_label or !content_root:
		return

	var copy_btn := Button.new()
	copy_btn.name               = "PathCopyBtn"
	copy_btn.text               = "📋  Скопировать путь"
	copy_btn.custom_minimum_size = Vector2(0, 26)
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.clip_text          = true
	copy_btn.pressed.connect(func() -> void:
		if _current_model_path.is_empty():
			return
		DisplayServer.clipboard_set(_current_model_path)
		copy_btn.text = "✓  Скопировано!"
		get_tree().create_timer(1.5).timeout.connect(func() -> void:
			if is_instance_valid(copy_btn):
				copy_btn.text = "📋  Скопировать путь"
		, CONNECT_ONE_SHOT)
	)
	content_root.add_child(copy_btn)
	# Place directly after PathLabel
	if path_label.get_parent() == content_root:
		content_root.move_child(copy_btn, path_label.get_index() + 1)


func _create_meshes_section() -> void:
	if !content_root:
		return

	var section := VBoxContainer.new()
	section.name = "MeshesSection"
	section.add_theme_constant_override("separation", 4)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := Label.new()
	header.text = "Меши"
	header.add_theme_font_size_override("font_size", 13)
	section.add_child(header)

	var sep := HSeparator.new()
	section.add_child(sep)

	var list := VBoxContainer.new()
	list.name = "MeshesList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(list)

	meshes_container = list
	content_root.add_child(section)

	# Place right before AnimationsSection if it exists
	var anim_section := content_root.get_node_or_null("AnimationsSection")
	if anim_section:
		content_root.move_child(section, anim_section.get_index())


func update_meshes_list(meshes_data: Array) -> void:
	_clear_container(meshes_container)
	if meshes_data.is_empty():
		_add_empty_label(meshes_container, "Нет мешей")
		return

	for mesh_info in meshes_data:
		var node_name    := str(mesh_info.get("name",    "Unnamed Mesh"))
		var display_name := str(mesh_info.get("display", node_name))
		var item := Button.new()
		item.text = display_name
		item.custom_minimum_size = Vector2(0, 28)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.clip_text = true
		item.toggle_mode = true
		item.tooltip_text = display_name + "\nКлик — изолировать (повторный — показать все)"
		item.toggled.connect(func(_pressed: bool):
			_on_mesh_isolation_pressed(node_name)
		)
		meshes_container.add_child(item)


func _on_mesh_isolation_pressed(mesh_name: String) -> void:
	var viewport := get_node_or_null("../../VBoxContainer2/SubViewportContainer")
	if viewport and viewport.has_method("isolate_mesh"):
		viewport.isolate_mesh(mesh_name)
		var isolated: String = str(viewport.get("_isolated_mesh_name") if viewport.get("_isolated_mesh_name") != null else "")
		_sync_isolation_buttons(isolated)


func _sync_isolation_buttons(isolated_name: String) -> void:
	if !meshes_container:
		return
	for child in meshes_container.get_children():
		if child is Button:
			# Use set_pressed_no_signal to avoid re-triggering the toggled callback
			child.set_pressed_no_signal(isolated_name != "" and child.text == isolated_name)
