extends Control

# ══════════════════════════════════════════════════════════════════════════════
#  Node references
# ══════════════════════════════════════════════════════════════════════════════
@onready var root_split:            HSplitContainer = $HSplitContainer
@onready var left_panel:            VBoxContainer   = $HSplitContainer/VBoxContainer
@onready var model_list:            ItemList        = $HSplitContainer/VBoxContainer/ModelContainer/ModelList
@onready var select_project_button: Button          = $HSplitContainer/VBoxContainer/ButtonContainer/SelectProjectButton
@onready var content_area:          HSplitContainer = $HSplitContainer/HBoxContainer2
@onready var preview_column:        VBoxContainer   = $HSplitContainer/HBoxContainer2/VBoxContainer2
@onready var viewport_container:    PreviewModel    = $HSplitContainer/HBoxContainer2/VBoxContainer2/SubViewportContainer
@onready var search_box:            LineEdit        = $HSplitContainer/VBoxContainer/SearchLineEdit
@onready var info_panel_wrapper:    VBoxContainer   = $HSplitContainer/HBoxContainer2/HBoxContainer
@onready var model_info_panel                       = $HSplitContainer/HBoxContainer2/HBoxContainer/ModelInfoPanel
@onready var button_container:      HBoxContainer   = $HSplitContainer/VBoxContainer/ButtonContainer

@onready var settings = preload("res://settings.gd").new()

# ══════════════════════════════════════════════════════════════════════════════
#  Layout breakpoints  (window inner width in pixels)
# ══════════════════════════════════════════════════════════════════════════════
enum LayoutMode { COMPACT, NARROW, NORMAL }

# Width thresholds
const BP_COMPACT := 680.0   # < BP_COMPACT  → COMPACT  (info panel hidden)
const BP_NARROW  := 960.0   # < BP_NARROW   → NARROW
#                            # ≥ BP_NARROW   → NORMAL

# Left-panel pixel widths per mode
const LEFT_W := { LayoutMode.COMPACT: 145, LayoutMode.NARROW: 185, LayoutMode.NORMAL: 240 }

# Info-panel pixel widths per mode  (0 = hidden)
const INFO_W := { LayoutMode.COMPACT: 0,   LayoutMode.NARROW: 160, LayoutMode.NORMAL: 240 }

# ══════════════════════════════════════════════════════════════════════════════
#  Misc constants
# ══════════════════════════════════════════════════════════════════════════════
const MIN_WINDOW_SIZE   := Vector2(520, 320)
const DEFAULT_WINDOW_SIZE := Vector2i(1100, 700)

const AUTO_SCAN_LAST_DIRECTORY_ON_START := false
const AUTO_LOAD_LAST_MODEL_ON_START     := false
const SUPPORTED_EXTENSIONS: Array[String] = ["glb", "gltf", "obj", "fbx"]

# ══════════════════════════════════════════════════════════════════════════════
#  Runtime state
# ══════════════════════════════════════════════════════════════════════════════
var _layout_mode:            LayoutMode = LayoutMode.NORMAL
var _layout_pending:         bool       = false
var _split_initialised:      bool       = false
var _left_panel_collapsed:   bool       = false
var _split_before_collapse:  int        = 0
var _split_info_done:        bool       = false
var _desired_info_w:         int        = 0
var _info_panel_collapsed:   bool       = false
var _split_before_info_collapse: int    = 0

var model_paths:          Array[String] = []
var filtered_model_paths: Array[String] = []
var file_dialog:    FileDialog
var loading_dialog: AcceptDialog
var message_dialog: AcceptDialog


# ══════════════════════════════════════════════════════════════════════════════
#  Startup
# ══════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	var v := Engine.get_version_info()
	print("3DViewModels: main scene loaded - Godot %s.%s.%s v17" % [
		v.get("major","?"), v.get("minor","?"), v.get("patch","?")])

	# Only enforce a minimum size — everything else (initial size, scaling) is
	# handled by project.godot (stretch/mode="disabled").
	var win := get_window()
	if win:
		win.min_size = Vector2i(int(MIN_WINDOW_SIZE.x), int(MIN_WINDOW_SIZE.y))

	# Root Control + HSplitContainer fill the whole viewport via anchors.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	if root_split:
		root_split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		root_split.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	add_child(settings)
	settings.load_settings()
	print("3DViewModels: settings ok")

	_connect_ui_signals()
	_create_import_export_buttons()
	_create_collapse_button()
	_create_info_collapse_button()
	_register_input_actions()
	_init_ui()
	_init_file_dialog()
	_restore_last_directory_without_loading_model()
	_connect_resize_signals()

	call_deferred("_first_layout")
	print("3DViewModels: ready completed")


func _first_layout() -> void:
	_apply_layout(true)
	await get_tree().process_frame
	_apply_layout(false)
	print("3DViewModels: first layout completed")


# ══════════════════════════════════════════════════════════════════════════════
#  Resize signal plumbing
# ══════════════════════════════════════════════════════════════════════════════
func _register_input_actions() -> void:
	if !InputMap.has_action("toggle_rotation"):
		InputMap.add_action("toggle_rotation")
		var key_event := InputEventKey.new()
		key_event.keycode = KEY_SPACE
		InputMap.action_add_event("toggle_rotation", key_event)

	if !InputMap.has_action("toggle_fullscreen"):
		InputMap.add_action("toggle_fullscreen")
		var key_event := InputEventKey.new()
		key_event.keycode = KEY_F11
		InputMap.action_add_event("toggle_fullscreen", key_event)


func _connect_resize_signals() -> void:
	if !resized.is_connected(_queue_layout):
		resized.connect(_queue_layout)
	var win := get_window()
	if win and !win.size_changed.is_connected(_queue_layout):
		win.size_changed.connect(_queue_layout)
	# Right split: when user drags the viewport↔info divider, remember their choice.
	if content_area:
		if !content_area.dragged.is_connected(_on_info_split_dragged):
			content_area.dragged.connect(_on_info_split_dragged)
		if !content_area.resized.is_connected(_update_right_split):
			content_area.resized.connect(_update_right_split)


func _on_info_split_dragged(offset: int) -> void:
	# Record how wide the user wants the info panel (right child width).
	var ca_w := int(content_area.size.x)
	if ca_w > 0:
		_desired_info_w = clampi(ca_w - offset, 80, ca_w - 120)


func _update_right_split() -> void:
	# Keep the info panel at the user-preferred (or default) width as the
	# window / left-divider changes size.
	if !content_area or !_split_info_done:
		return
	if _layout_mode == LayoutMode.COMPACT:
		return
	var ca_w := int(content_area.size.x)
	var target: int    = _desired_info_w if _desired_info_w > 0 else INFO_W[_layout_mode]
	var new_offset: int = ca_w - target
	if new_offset > 80 and new_offset < ca_w - 80:
		content_area.split_offset = new_offset


# ══════════════════════════════════════════════════════════════════════════════
#  Responsive layout
# ══════════════════════════════════════════════════════════════════════════════
func _queue_layout() -> void:
	if _layout_pending:
		return
	_layout_pending = true
	call_deferred("_deferred_layout")


func _deferred_layout() -> void:
	_layout_pending = false
	_apply_layout(false)


func _apply_layout(force_split: bool) -> void:
	# get_visible_rect() is the authoritative source for the real drawable area.
	# self.size can be 0 on the first deferred call before Godot finishes layout.
	var viewport_rect := get_viewport().get_visible_rect() if get_viewport() else Rect2()
	var w := maxf(
		maxf(viewport_rect.size.x, size.x),
		float(MIN_WINDOW_SIZE.x)
	)

	# ── Resolve layout mode ──────────────────────────────────────────────────
	var new_mode: LayoutMode
	if   w < BP_COMPACT: new_mode = LayoutMode.COMPACT
	elif w < BP_NARROW:  new_mode = LayoutMode.NARROW
	else:                new_mode = LayoutMode.NORMAL

	var mode_changed := new_mode != _layout_mode
	_layout_mode = new_mode

	var left_w: int = LEFT_W[_layout_mode]
	var info_w: int = INFO_W[_layout_mode]
	var compact := _layout_mode == LayoutMode.COMPACT

	# ── Left panel ───────────────────────────────────────────────────────────
	if left_panel:
		left_panel.custom_minimum_size   = Vector2(left_w, 0)
		left_panel.size_flags_horizontal = Control.SIZE_FILL
		left_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# ── Search box ───────────────────────────────────────────────────────────
	if search_box:
		search_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ── Model list ───────────────────────────────────────────────────────────
	if model_list:
		model_list.custom_minimum_size   = Vector2.ZERO
		model_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		model_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# ── Button bar ───────────────────────────────────────────────────────────
	if button_container:
		button_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if select_project_button:
		select_project_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select_project_button.custom_minimum_size   = Vector2(80, 28)

	# ── Content area (right of splitter) ─────────────────────────────────────
	if content_area:
		content_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content_area.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		content_area.custom_minimum_size   = Vector2.ZERO

	# ── Preview column ────────────────────────────────────────────────────────
	if preview_column:
		preview_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		preview_column.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		preview_column.custom_minimum_size   = Vector2.ZERO

	# ── 3D viewport ───────────────────────────────────────────────────────────
	if viewport_container:
		viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		viewport_container.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		viewport_container.custom_minimum_size   = Vector2(120, 80)
		if viewport_container.has_method("sync_viewport_size"):
			viewport_container.call_deferred("sync_viewport_size")

	# ── Info panel (right child of HSplitContainer) ──────────────────────────
	# SIZE_EXPAND_FILL so each child fills its half of the split.
	if info_panel_wrapper:
		info_panel_wrapper.visible               = !compact
		info_panel_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_panel_wrapper.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		info_panel_wrapper.custom_minimum_size   = Vector2(info_w if !compact else 0, 0)

	if model_info_panel:
		model_info_panel.visible               = !compact
		model_info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		model_info_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		model_info_panel.custom_minimum_size   = Vector2(info_w if !compact else 0, 0)

	# ── Left divider (list ↔ viewport+info) ───────────────────────────────────
	if root_split:
		if force_split or !_split_initialised or mode_changed:
			_set_split_offset(left_w, w, mode_changed)
			_split_initialised = true

	# ── Right divider (viewport ↔ info panel) ────────────────────────────────
	if content_area and (!_split_info_done or mode_changed):
		if compact:
			content_area.split_offset = int(content_area.size.x)
		else:
			var ca_w := int(content_area.size.x)
			if ca_w == 0:
				ca_w = int(w) - left_w
			if mode_changed:
				_desired_info_w = 0  # Reset on mode change → use default
			var target := _desired_info_w if _desired_info_w > 0 else info_w
			var new_offset := ca_w - target
			if new_offset > 80:
				content_area.split_offset = new_offset
		_split_info_done = true


func _set_split_offset(ideal: int, window_w: float, clamp_existing: bool) -> void:
	if !root_split:
		return

	if !_split_initialised:
		# First time: use the ideal width exactly.
		root_split.split_offset = ideal
		return

	if clamp_existing:
		# Mode changed: pull the divider into a sensible range for the new mode,
		# but honour whatever position the user had if it already fits.
		var lo := ideal
		var hi := int(minf(float(ideal) * 2.5, window_w * 0.5))
		root_split.split_offset = clampi(root_split.split_offset, lo, hi)


# ══════════════════════════════════════════════════════════════════════════════
#  Notification (resize from OS)
# ══════════════════════════════════════════════════════════════════════════════
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_queue_layout()


func _exit_tree() -> void:
	if settings:
		_save_current_session()


# ══════════════════════════════════════════════════════════════════════════════
#  UI wiring
# ══════════════════════════════════════════════════════════════════════════════
func _connect_ui_signals() -> void:
	if model_list:
		model_list.clear()
		if !model_list.item_selected.is_connected(_on_model_selected):
			model_list.item_selected.connect(_on_model_selected)

	if select_project_button and !select_project_button.pressed.is_connected(_on_select_project_pressed):
		select_project_button.pressed.connect(_on_select_project_pressed)

	if search_box and !search_box.text_changed.is_connected(_on_search_text_changed):
		search_box.text_changed.connect(_on_search_text_changed)


func _create_import_export_buttons() -> void:
	if !button_container:
		return

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	button_container.add_child(row)

	var export_btn := Button.new()
	export_btn.text = "Export"
	export_btn.custom_minimum_size.x = 80
	export_btn.pressed.connect(_on_export_pressed)
	row.add_child(export_btn)

	var import_btn := Button.new()
	import_btn.text = "Import"
	import_btn.custom_minimum_size.x = 80
	import_btn.pressed.connect(_on_import_pressed)
	row.add_child(import_btn)


func _create_collapse_button() -> void:
	# Inserts a "◀ / ▶" toggle above the search box to collapse/expand left panel.
	if !left_panel or !search_box:
		return

	var collapse_btn := Button.new()
	collapse_btn.name              = "CollapseButton"
	collapse_btn.text              = "◀"
	collapse_btn.tooltip_text      = "Свернуть / развернуть панель списка"
	collapse_btn.flat              = true
	collapse_btn.custom_minimum_size = Vector2(0, 22)
	collapse_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse_btn.pressed.connect(_toggle_left_panel)
	# Insert before the SearchLineEdit (index 0)
	left_panel.add_child(collapse_btn)
	left_panel.move_child(collapse_btn, 0)


func _toggle_left_panel() -> void:
	if !root_split or !left_panel:
		return

	var collapse_btn := left_panel.get_node_or_null("CollapseButton") as Button

	if _left_panel_collapsed:
		# ── Expand ──────────────────────────────────────────────────────────
		_left_panel_collapsed = false
		for child in left_panel.get_children():
			if child != collapse_btn:
				child.visible = true
		var restore: int = _split_before_collapse if _split_before_collapse > 0 \
					   else LEFT_W[_layout_mode]
		root_split.split_offset = restore
		left_panel.custom_minimum_size.x = LEFT_W[_layout_mode]
		if collapse_btn:
			collapse_btn.text = "◀"
	else:
		# ── Collapse ─────────────────────────────────────────────────────────
		_left_panel_collapsed = true
		_split_before_collapse = root_split.split_offset
		for child in left_panel.get_children():
			if child != collapse_btn:
				child.visible = false
		root_split.split_offset = 28
		left_panel.custom_minimum_size.x = 28
		if collapse_btn:
			collapse_btn.text = "▶"


func _create_info_collapse_button() -> void:
	# Adds a "◀ / ▶" toggle at the TOP of the info panel wrapper,
	# mirroring the left panel's collapse button position.
	if !info_panel_wrapper or !content_area:
		return

	var btn := Button.new()
	btn.name                    = "InfoCollapseButton"
	btn.text                    = "▶"
	btn.tooltip_text            = "Свернуть / развернуть панель информации"
	btn.flat                    = true
	btn.custom_minimum_size     = Vector2(0, 22)
	btn.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical     = Control.SIZE_SHRINK_BEGIN
	btn.pressed.connect(_toggle_info_panel)
	info_panel_wrapper.add_child(btn)
	info_panel_wrapper.move_child(btn, 0)   # pin to top


func _toggle_info_panel() -> void:
	if !content_area or !info_panel_wrapper:
		return

	var btn := info_panel_wrapper.get_node_or_null("InfoCollapseButton") as Button

	if _info_panel_collapsed:
		# ── Expand ──────────────────────────────────────────────────────────
		_info_panel_collapsed = false
		for child in info_panel_wrapper.get_children():
			if child != btn:
				child.visible = true
		var ca_w := int(content_area.size.x)
		var restore: int = _split_before_info_collapse if _split_before_info_collapse > 0 \
						   else ca_w - INFO_W[_layout_mode]
		content_area.split_offset = restore
		info_panel_wrapper.custom_minimum_size.x = INFO_W[_layout_mode]
		_desired_info_w = INFO_W[_layout_mode]
		if btn:
			btn.text = "▶"
	else:
		# ── Collapse ─────────────────────────────────────────────────────────
		_info_panel_collapsed = true
		_split_before_info_collapse = content_area.split_offset
		for child in info_panel_wrapper.get_children():
			if child != btn:
				child.visible = false
		var ca_w := int(content_area.size.x)
		content_area.split_offset = ca_w - 28   # leave 28 px for the "◀" button
		info_panel_wrapper.custom_minimum_size.x = 28
		_desired_info_w = 28
		if btn:
			btn.text = "◀"


func _init_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access    = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title     = "Выберите папку с моделями"
	file_dialog.size      = Vector2(800, 600)
	file_dialog.min_size  = Vector2(400, 300)
	file_dialog.dir_selected.connect(_on_project_dir_selected)
	file_dialog.canceled.connect(func(): file_dialog.hide())
	add_child(file_dialog)


func _init_ui() -> void:
	var required := {
		"model_list":            model_list,
		"viewport_container":    viewport_container,
		"select_project_button": select_project_button,
		"search_box":            search_box,
		"model_info_panel":      model_info_panel
	}
	for node_name in required:
		if required[node_name] == null:
			push_error("Required node '%s' not found!" % node_name)
			return

	if viewport_container.preview_viewport == null:
		push_error("Required node 'preview_viewport' not found!")
		return
	if viewport_container.preview_camera == null:
		push_error("Required node 'preview_camera' not found!")
		return

	loading_dialog = AcceptDialog.new()
	loading_dialog.title       = "Загрузка"
	loading_dialog.dialog_text = "Загрузка модели..."
	loading_dialog.size        = Vector2(240, 110)
	loading_dialog.exclusive   = false
	loading_dialog.always_on_top = true
	add_child(loading_dialog)

	message_dialog = AcceptDialog.new()
	message_dialog.title = "Сообщение"
	message_dialog.size  = Vector2(420, 160)
	message_dialog.always_on_top = true
	add_child(message_dialog)

	viewport_container.preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.preview_viewport.transparent_bg = false


# ══════════════════════════════════════════════════════════════════════════════
#  Session persistence
# ══════════════════════════════════════════════════════════════════════════════
func _save_current_session() -> void:
	if viewport_container:
		viewport_container.save_camera_settings()
	if file_dialog and file_dialog.current_dir:
		settings.set_setting("last_directory", file_dialog.current_dir)
	var current_model_path := _get_selected_model_path()
	if current_model_path != "":
		settings.set_setting("last_model", current_model_path)
	settings.save_settings()


func _restore_last_directory_without_loading_model() -> void:
	var last_dir: String = settings.get_setting("last_directory")
	if last_dir == "" or !DirAccess.dir_exists_absolute(last_dir):
		return
	if file_dialog:
		file_dialog.current_dir = last_dir
	if AUTO_SCAN_LAST_DIRECTORY_ON_START:
		scan_project_models(last_dir)
	if AUTO_LOAD_LAST_MODEL_ON_START:
		_load_saved_settings()


func _load_saved_settings() -> void:
	var last_dir: String = settings.get_setting("last_directory")
	if last_dir == "" or !DirAccess.dir_exists_absolute(last_dir):
		return
	file_dialog.current_dir = last_dir
	scan_project_models(last_dir)

	if !AUTO_LOAD_LAST_MODEL_ON_START:
		return

	var last_model: String = settings.get_setting("last_model")
	if last_model == "" or !FileAccess.file_exists(last_model):
		return

	update_model_list()
	var model_index := filtered_model_paths.find(last_model)
	if model_index == -1 or model_index >= model_list.item_count:
		return

	model_list.select(model_index)
	await get_tree().create_timer(0.1).timeout
	_on_model_selected(model_index)


# ══════════════════════════════════════════════════════════════════════════════
#  Export / Import
# ══════════════════════════════════════════════════════════════════════════════
func _on_export_pressed() -> void:
	var export_dialog := FileDialog.new()
	export_dialog.file_mode   = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access      = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title       = "Сохранить настройки"
	export_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	export_dialog.current_file = "viewer_settings.json"
	export_dialog.add_filter("*.json", "JSON files")
	export_dialog.close_requested.connect(export_dialog.queue_free)
	export_dialog.canceled.connect(export_dialog.queue_free)

	export_dialog.file_selected.connect(func(path: String):
		_save_current_session()
		var data := {
			"camera_settings": {
				"distance":         viewport_container.camera_distance,
				"horizontal_angle": viewport_container.camera_horizontal_angle,
				"vertical_angle":   viewport_container.camera_vertical_angle,
				"orbit_center": {
					"x": viewport_container.orbit_center.x,
					"y": viewport_container.orbit_center.y,
					"z": viewport_container.orbit_center.z
				}
			},
			"rotation_settings": {
				"enabled": viewport_container.is_rotating,
				"speed":   viewport_container.initial_auto_rotation_speed
			},
			"directory":           file_dialog.current_dir if file_dialog else "",
			"current_model_path":  _get_selected_model_path()
		}
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(data, "  "))
			f.close()
			_show_message("Экспорт", "Настройки сохранены.\n" + path)
		else:
			_show_message("Ошибка", "Не удалось сохранить настройки.\n" + path)
		export_dialog.queue_free()
	)

	add_child(export_dialog)
	export_dialog.popup_centered(Vector2(800, 600))


func _on_import_pressed() -> void:
	var import_dialog := FileDialog.new()
	import_dialog.file_mode   = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.access      = FileDialog.ACCESS_FILESYSTEM
	import_dialog.title       = "Загрузить настройки"
	import_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	import_dialog.add_filter("*.json", "JSON files")
	import_dialog.close_requested.connect(import_dialog.queue_free)
	import_dialog.canceled.connect(import_dialog.queue_free)

	import_dialog.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.READ)
		if !f:
			_show_message("Ошибка", "Не удалось открыть файл настроек.\n" + path)
			import_dialog.queue_free()
			return
		var json_string := f.get_as_text()
		f.close()
		var data: Variant = JSON.parse_string(json_string)
		if typeof(data) != TYPE_DICTIONARY:
			_show_message("Ошибка", "Файл настроек повреждён или имеет неверный формат.")
			import_dialog.queue_free()
			return
		_apply_imported_settings(data)
		_save_current_session()
		_show_message("Импорт", "Настройки загружены.")
		import_dialog.queue_free()
	)

	add_child(import_dialog)
	import_dialog.popup_centered(Vector2(800, 600))


func _apply_imported_settings(data: Dictionary) -> void:
	if data.has("camera_settings"):
		var cs: Dictionary = data["camera_settings"]
		viewport_container.camera_distance         = float(cs.get("distance",         viewport_container.camera_distance))
		viewport_container.camera_horizontal_angle = float(cs.get("horizontal_angle", viewport_container.camera_horizontal_angle))
		viewport_container.camera_vertical_angle   = float(cs.get("vertical_angle",   viewport_container.camera_vertical_angle))
		var oc: Dictionary = cs.get("orbit_center", {})
		viewport_container.orbit_center = Vector3(
			float(oc.get("x", viewport_container.orbit_center.x)),
			float(oc.get("y", viewport_container.orbit_center.y)),
			float(oc.get("z", viewport_container.orbit_center.z))
		)

	if data.has("rotation_settings"):
		var rs: Dictionary = data["rotation_settings"]
		viewport_container.is_rotating               = bool(rs.get("enabled", viewport_container.is_rotating))
		viewport_container.initial_auto_rotation_speed = float(rs.get("speed", viewport_container.initial_auto_rotation_speed))
		viewport_container.auto_rotation_speed        = viewport_container.initial_auto_rotation_speed if viewport_container.is_rotating else 0.0

	if data.has("directory") and String(data["directory"]) != "":
		var dir_path := String(data["directory"])
		if DirAccess.dir_exists_absolute(dir_path):
			file_dialog.current_dir = dir_path
			scan_project_models(dir_path)

	var imported_model_path := String(data.get("current_model_path", ""))
	if imported_model_path != "" and FileAccess.file_exists(imported_model_path):
		update_model_list(search_box.text if search_box else "")
		var model_index := filtered_model_paths.find(imported_model_path)
		if model_index != -1:
			model_list.select(model_index)
			_on_model_selected(model_index)

	viewport_container.update_camera_position()


# ══════════════════════════════════════════════════════════════════════════════
#  Input
# ══════════════════════════════════════════════════════════════════════════════
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_rotation"):
		if viewport_container and viewport_container.current_model:
			viewport_container.toggle_rotation()
			get_viewport().set_input_as_handled()

	if event.is_action_pressed("toggle_fullscreen"):
		var win := get_window()
		if win:
			if win.mode == Window.MODE_FULLSCREEN or win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
				win.mode = Window.MODE_WINDOWED
			else:
				win.mode = Window.MODE_FULLSCREEN
		get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════════════════
#  Model selection / display
# ══════════════════════════════════════════════════════════════════════════════
func _on_model_selected(index: int) -> void:
	print("3DViewModels: model selected index=", index)
	if index < 0 or index >= filtered_model_paths.size():
		return

	if loading_dialog:
		loading_dialog.popup_centered()

	var model_path := filtered_model_paths[index]
	var result := viewport_container.load_in_preview_portal(model_path)
	if result != "Модель загружена успешно":
		_show_message("Ошибка загрузки", result)
	else:
		settings.set_setting("last_model", model_path)
		show_model_info(index)

	if loading_dialog:
		loading_dialog.hide()


func _on_select_project_pressed() -> void:
	if file_dialog:
		file_dialog.popup_centered()


func _on_project_dir_selected(dir: String) -> void:
	settings.set_setting("last_directory", dir)
	settings.save_settings()
	file_dialog.current_dir = dir

	model_paths.clear()
	filtered_model_paths.clear()
	model_list.clear()
	viewport_container.clear_model()
	if model_info_panel and model_info_panel.has_method("clear_info"):
		model_info_panel.clear_info()

	scan_project_models(dir)


func scan_project_models(path: String) -> void:
	print("3DViewModels: scanning models in ", path)
	var dir := DirAccess.open(path)
	if !dir:
		push_error("Failed to open directory: " + path)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				scan_project_models(full_path)
			else:
				var ext := file_name.get_extension().to_lower()
				if ext in SUPPORTED_EXTENSIONS and !model_paths.has(full_path):
					model_paths.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	call_deferred("update_model_list", search_box.text if search_box else "")


func _get_selected_model_path() -> String:
	if !model_list:
		return ""
	var selected_items := model_list.get_selected_items()
	if selected_items.size() == 0:
		return ""
	var selected_index := int(selected_items[0])
	if selected_index < 0 or selected_index >= filtered_model_paths.size():
		return ""
	return filtered_model_paths[selected_index]


# ══════════════════════════════════════════════════════════════════════════════
#  Model info
# ══════════════════════════════════════════════════════════════════════════════
func show_model_info(index: int) -> void:
	if index < 0 or index >= filtered_model_paths.size():
		return
	var model_path := filtered_model_paths[index]
	var info := get_model_info(model_path)
	var details := viewport_container.get_model_details()
	info.merge(details, true)
	model_info_panel.update_info(info)


func get_model_info(path: String) -> Dictionary:
	var info := {
		"filename":      path.get_file(),
		"path":          path,
		"size":          "0 B",
		"date_modified": "",
		"type":          path.get_extension().to_upper(),
		"vertices":      "0",
		"faces":         "0",
		"materials":     "0"
	}

	if !FileAccess.file_exists(path):
		return info

	var model_file := FileAccess.open(path, FileAccess.READ)
	if !model_file:
		return info

	info["size"] = _format_size(model_file.get_length())
	model_file.close()

	var file_modified := FileAccess.get_modified_time(path)
	var dt := Time.get_datetime_dict_from_unix_time(file_modified)
	info["date_modified"] = "%d-%02d-%02d %02d:%02d:%02d" % [
		dt["year"], dt["month"], dt["day"], dt["hour"], dt["minute"], dt["second"]
	]

	match path.get_extension().to_lower():
		"obj":
			info.merge(_collect_obj_statistics(path), true)
		"gltf", "glb":
			var gltf_json: Variant = _read_gltf_json(path)
			if typeof(gltf_json) == TYPE_DICTIONARY:
				info.merge(_collect_gltf_statistics(gltf_json), true)

	return info


func _collect_obj_statistics(path: String) -> Dictionary:
	var vertex_count := 0
	var face_count   := 0
	var materials    := {}

	var obj_file := FileAccess.open(path, FileAccess.READ)
	if !obj_file:
		return {"vertices": "0", "faces": "0", "materials": "0"}

	while !obj_file.eof_reached():
		var line := obj_file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("v "):
			vertex_count += 1
		elif line.begins_with("f "):
			face_count += 1
		elif line.begins_with("usemtl "):
			var parts := line.split(" ", false)
			if parts.size() >= 2:
				materials[parts[1]] = true
	obj_file.close()

	return {"vertices": str(vertex_count), "faces": str(face_count), "materials": str(materials.size())}


func _read_gltf_json(path: String):
	var ext := path.get_extension().to_lower()
	if ext == "gltf":
		return JSON.parse_string(FileAccess.get_file_as_string(path))

	var glb_file := FileAccess.open(path, FileAccess.READ)
	if !glb_file:
		return null
	var bytes := glb_file.get_buffer(glb_file.get_length())
	glb_file.close()

	if bytes.size() < 20:
		return null
	var json_length := bytes.decode_u32(12)
	var json_start  := 20
	var json_end    := json_start + json_length
	if json_end > bytes.size():
		return null
	return JSON.parse_string(bytes.slice(json_start, json_end).get_string_from_utf8())


func _collect_gltf_statistics(gltf_json: Dictionary) -> Dictionary:
	var vertex_count   := 0
	var face_count     := 0
	var accessors: Array = gltf_json.get("accessors", [])
	var meshes:    Array = gltf_json.get("meshes",    [])
	var material_count := (gltf_json.get("materials", []) as Array).size()

	for mesh_data in meshes:
		if typeof(mesh_data) != TYPE_DICTIONARY:
			continue
		for primitive_data in (mesh_data.get("primitives", []) as Array):
			if typeof(primitive_data) != TYPE_DICTIONARY:
				continue
			var attrs: Dictionary = primitive_data.get("attributes", {})
			if attrs.has("POSITION"):
				var ai := int(attrs["POSITION"])
				if ai >= 0 and ai < accessors.size() and typeof(accessors[ai]) == TYPE_DICTIONARY:
					vertex_count += int(accessors[ai].get("count", 0))
			if primitive_data.has("indices"):
				var ii := int(primitive_data["indices"])
				if ii >= 0 and ii < accessors.size() and typeof(accessors[ii]) == TYPE_DICTIONARY:
					face_count += int(float(accessors[ii].get("count", 0)) / 3.0)
			elif attrs.has("POSITION"):
				var pi := int(attrs["POSITION"])
				if pi >= 0 and pi < accessors.size() and typeof(accessors[pi]) == TYPE_DICTIONARY:
					face_count += int(float(accessors[pi].get("count", 0)) / 3.0)

	return {"vertices": str(vertex_count), "faces": str(face_count), "materials": str(material_count)}


# ══════════════════════════════════════════════════════════════════════════════
#  Model list
# ══════════════════════════════════════════════════════════════════════════════
func _on_search_text_changed(new_text: String) -> void:
	update_model_list(new_text)


func update_model_list(search_text: String = "") -> void:
	if !model_list:
		return
	model_list.clear()
	filtered_model_paths.clear()

	var filter := search_text.to_lower()
	for path in model_paths:
		var file_name := path.get_file().to_lower()
		if filter.is_empty() or file_name.contains(filter):
			filtered_model_paths.append(path)
			var item_index := model_list.add_item(path.get_file())
			model_list.set_item_tooltip(item_index, path)


# ══════════════════════════════════════════════════════════════════════════════
#  Utilities
# ══════════════════════════════════════════════════════════════════════════════
func _format_size(byte_count: int) -> String:
	if byte_count < 1024:
		return "%d B" % byte_count
	elif byte_count < 1024 * 1024:
		return "%.2f KB" % (byte_count / 1024.0)
	return "%.2f MB" % (byte_count / (1024.0 * 1024.0))


func _show_message(title: String, text: String) -> void:
	if !message_dialog:
		print("%s: %s" % [title, text])
		return
	message_dialog.title       = title
	message_dialog.dialog_text = text
	message_dialog.popup_centered()
