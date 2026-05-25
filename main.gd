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

# ── Light-panel drag / resize state ──────────────────────────────────────────
var _lp_drag_active:   bool = false
var _lp_resize_active: bool = false

# ── Batch operations state ───────────────────────────────────────────────────
var _batch_win:       Window       = null
var _batch_mode:      int          = 0        # 0 = screenshots, 1 = export info
var _batch_checks:    Array        = []       # Array[CheckBox]
var _batch_out_edit:  LineEdit     = null
var _batch_fmt_opt:   OptionButton = null
var _batch_progress:  Label        = null
var _batch_run_btn:   Button       = null
var _batch_running:   bool         = false

# ── Thumbnail / hover-preview system ─────────────────────────────────────────
var _thumb_cache:      Dictionary = {}   # path  → ImageTexture (64×64 capture)
var _thumb_fmt_icons:  Dictionary = {}   # ".glb" → ImageTexture (placeholder)
var _thumb_popup:      Panel      = null
var _thumb_popup_img:  TextureRect = null
var _last_hovered_idx: int        = -1


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
	_create_batch_button()
	_create_collapse_button()
	_create_info_collapse_button()
	_register_input_actions()
	_init_ui()
	_init_file_dialog()
	_setup_thumb_system()
	_restore_last_directory_without_loading_model()
	_connect_resize_signals()
	_connect_drag_drop()
	_create_viewport_toolbar()
	_create_recent_button()

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

	if !InputMap.has_action("camera_reset"):
		InputMap.add_action("camera_reset")
		var home_ev := InputEventKey.new()
		home_ev.keycode = KEY_HOME
		InputMap.action_add_event("camera_reset", home_ev)
		var r_ev := InputEventKey.new()
		r_ev.keycode = KEY_R
		InputMap.action_add_event("camera_reset", r_ev)

	if !InputMap.has_action("toggle_wireframe"):
		InputMap.add_action("toggle_wireframe")
		var wf_ev := InputEventKey.new()
		wf_ev.keycode = KEY_W
		InputMap.action_add_event("toggle_wireframe", wf_ev)

	# Num 1=Спереди  2=Сзади  3=Справа  4=Слева  7=Сверху  8=Снизу
	var _numpad_views: Dictionary = {
		"view_front":  KEY_KP_1,
		"view_back":   KEY_KP_2,
		"view_right":  KEY_KP_3,
		"view_left":   KEY_KP_4,
		"view_top":    KEY_KP_7,
		"view_bottom": KEY_KP_8,
	}
	for _act: String in _numpad_views:
		if !InputMap.has_action(_act):
			InputMap.add_action(_act)
			var _ev := InputEventKey.new()
			_ev.keycode = _numpad_views[_act]
			InputMap.action_add_event(_act, _ev)


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
		model_list.icon_mode             = ItemList.ICON_MODE_LEFT
		model_list.fixed_icon_size       = Vector2i(32, 32)

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


func _create_viewport_toolbar() -> void:
	if !preview_column:
		return

	var toolbar := HBoxContainer.new()
	toolbar.name = "ViewportToolbar"
	toolbar.add_theme_constant_override("separation", 4)

	# ── Reset camera ──────────────────────────────────────────────────────────
	var reset_btn := Button.new()
	reset_btn.text              = "↺"
	reset_btn.tooltip_text      = "Сброс камеры  [R / Home]"
	reset_btn.custom_minimum_size.x = 28
	reset_btn.pressed.connect(func():
		if viewport_container and viewport_container.current_model:
			viewport_container.reset_camera()
	)
	toolbar.add_child(reset_btn)

	# ── Fit to view ───────────────────────────────────────────────────────────
	var fit_btn := Button.new()
	fit_btn.text             = "⊡"
	fit_btn.tooltip_text     = "Вписать модель в экран  [F]"
	fit_btn.custom_minimum_size.x = 28
	fit_btn.pressed.connect(func():
		if viewport_container and viewport_container.current_model:
			viewport_container.fit_to_view()
	)
	toolbar.add_child(fit_btn)

	toolbar.add_child(VSeparator.new())

	# ── View preset dropdown ──────────────────────────────────────────────────
	var view_btn := MenuButton.new()
	view_btn.text         = "Вид"
	view_btn.tooltip_text = "Виды камеры"
	view_btn.flat         = false
	var popup := view_btn.get_popup()
	popup.add_item("Спереди    [Num 1]", 0)
	popup.add_item("Сзади      [Num 2]", 1)
	popup.add_item("Слева      [Num 4]", 2)
	popup.add_item("Справа     [Num 3]", 3)
	popup.add_item("Сверху     [Num 7]", 4)
	popup.add_item("Снизу      [Num 8]", 5)
	popup.index_pressed.connect(func(idx: int):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(idx)
	)
	toolbar.add_child(view_btn)

	toolbar.add_child(VSeparator.new())

	# ── Grid toggle ───────────────────────────────────────────────────────────
	var grid_btn := Button.new()
	grid_btn.name           = "GridToggleBtn"
	grid_btn.text           = "Сетка"
	grid_btn.tooltip_text   = "Показать/скрыть сетку пола"
	grid_btn.toggle_mode    = true
	grid_btn.button_pressed = true
	grid_btn.toggled.connect(func(_p: bool):
		if viewport_container:
			viewport_container.toggle_grid()
	)
	toolbar.add_child(grid_btn)

	# ── Gizmo toggle ──────────────────────────────────────────────────────────
	var gizmo_btn := Button.new()
	gizmo_btn.name           = "GizmoToggleBtn"
	gizmo_btn.text           = "Оси"
	gizmo_btn.tooltip_text   = "Показать/скрыть оси XYZ"
	gizmo_btn.toggle_mode    = true
	gizmo_btn.button_pressed = true
	gizmo_btn.toggled.connect(func(_p: bool):
		if viewport_container:
			viewport_container.toggle_gizmo()
	)
	toolbar.add_child(gizmo_btn)

	toolbar.add_child(VSeparator.new())

	# ── Wireframe toggle ──────────────────────────────────────────────────────
	var wf_btn := Button.new()
	wf_btn.name           = "WireframeToggleBtn"
	wf_btn.text           = "Каркас"
	wf_btn.tooltip_text   = "Wireframe  [W вне вьюпорта]"
	wf_btn.toggle_mode    = true
	wf_btn.button_pressed = false
	wf_btn.toggled.connect(func(_p: bool):
		if viewport_container:
			viewport_container.toggle_wireframe()
	)
	toolbar.add_child(wf_btn)

	# ── Zoom-to-cursor toggle ─────────────────────────────────────────────────
	var ztc_btn := Button.new()
	ztc_btn.name           = "ZoomCursorToggleBtn"
	ztc_btn.text           = "ЗумCursor"
	ztc_btn.tooltip_text   = "Зум к позиции курсора (вкл/выкл)"
	ztc_btn.toggle_mode    = true
	ztc_btn.button_pressed = true   # on by default
	ztc_btn.toggled.connect(func(_p: bool):
		if viewport_container:
			viewport_container.toggle_zoom_to_cursor()
	)
	toolbar.add_child(ztc_btn)

	toolbar.add_child(VSeparator.new())

	# ── Screenshot ────────────────────────────────────────────────────────────
	var shot_btn := Button.new()
	shot_btn.name           = "ScreenshotBtn"
	shot_btn.text           = "📷"
	shot_btn.tooltip_text   = "Сохранить скриншот вьюпорта"
	shot_btn.pressed.connect(_on_screenshot_pressed)
	toolbar.add_child(shot_btn)

	toolbar.add_child(VSeparator.new())

	# ── Environment preset ────────────────────────────────────────────────────
	var env_btn := MenuButton.new()
	env_btn.text         = "Фон"
	env_btn.tooltip_text = "Фон / освещение сцены"
	env_btn.flat         = false
	var env_pop := env_btn.get_popup()
	env_pop.add_item("Серый (по умолчанию)", 0)
	env_pop.add_item("Тёмный",              1)
	env_pop.add_item("Белый",               2)
	env_pop.add_item("Небо (процедурное)",  3)
	env_pop.add_separator()
	env_pop.add_item("Загрузить HDRI...", 10)
	env_pop.index_pressed.connect(func(idx: int) -> void:
		var item_id: int = env_pop.get_item_id(idx)
		if item_id == 10:
			_open_hdri_dialog()
		elif viewport_container:
			viewport_container.set_env_preset(item_id)
	)
	toolbar.add_child(env_btn)

	# ── Light control toggle ──────────────────────────────────────────────────
	var light_btn := Button.new()
	light_btn.name           = "LightControlBtn"
	light_btn.text           = "Свет"
	light_btn.tooltip_text   = "Управление источником света"
	light_btn.toggle_mode    = true
	light_btn.button_pressed = false
	light_btn.toggled.connect(func(pressed: bool) -> void:
		var lp: Panel = get_node_or_null("LightPanel") as Panel
		if lp:
			lp.visible = pressed
	)
	toolbar.add_child(light_btn)

	toolbar.add_child(VSeparator.new())

	# ── Texture channel viewer ────────────────────────────────────────────────
	var ch_btn := MenuButton.new()
	ch_btn.text         = "Каналы"
	ch_btn.tooltip_text = "Просмотр канала текстуры"
	ch_btn.flat         = false
	var ch_pop := ch_btn.get_popup()
	ch_pop.add_radio_check_item("Полный",    0)
	ch_pop.add_radio_check_item("Albedo",    1)
	ch_pop.add_radio_check_item("Roughness", 2)
	ch_pop.add_radio_check_item("Normal",    3)
	ch_pop.add_radio_check_item("Metallic",  4)
	ch_pop.set_item_checked(0, true)
	ch_pop.index_pressed.connect(func(idx: int) -> void:
		for i: int in range(ch_pop.item_count):
			ch_pop.set_item_checked(i, i == idx)
		if viewport_container:
			viewport_container.set_texture_channel(idx)
	)
	toolbar.add_child(ch_btn)

	toolbar.add_child(VSeparator.new())

	# ── FPS counter ───────────────────────────────────────────────────────────
	var fps_btn := Button.new()
	fps_btn.name           = "FPSToggleBtn"
	fps_btn.text           = "FPS"
	fps_btn.tooltip_text   = "Показать FPS и draw calls"
	fps_btn.toggle_mode    = true
	fps_btn.button_pressed = false
	fps_btn.toggled.connect(func(_p: bool) -> void:
		if viewport_container:
			viewport_container.toggle_fps_counter()
	)
	toolbar.add_child(fps_btn)

	preview_column.add_child(toolbar)
	_create_light_panel()


# ══════════════════════════════════════════════════════════════════════════════
#  Light control panel
# ══════════════════════════════════════════════════════════════════════════════
func _create_light_panel() -> void:
	var panel := Panel.new()
	panel.name                = "LightPanel"
	panel.visible             = false
	panel.custom_minimum_size = Vector2(300, 500)
	panel.size                = Vector2(300, 500)
	# Float the panel over the viewport, just below the toolbar row.
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(170, 60)
	panel.z_index  = 10

	# Scrollable inner content — cap height so it never overflows the screen
	var scroll := ScrollContainer.new()
	scroll.name = "LightPanelScroll"
	scroll.custom_minimum_size         = Vector2(300, 200)
	scroll.size_flags_horizontal       = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical         = Control.SIZE_EXPAND_FILL
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT,
			Control.PRESET_MODE_MINSIZE, 6)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	panel.add_child(scroll)

	# ── Title + close ──────────────────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	var title := Label.new()
	title.text = "Управление светом"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.custom_minimum_size = Vector2(24, 24)
	close_btn.pressed.connect(func() -> void:
		panel.visible = false
		var lbtn := get_node_or_null("HSplitContainer/HBoxContainer2/VBoxContainer2/ViewportToolbar/LightControlBtn")
		if lbtn is Button:
			(lbtn as Button).button_pressed = false
	)
	title_row.add_child(title)
	title_row.add_child(close_btn)
	vbox.add_child(title_row)
	vbox.add_child(HSeparator.new())

	# ── Drag: press on title bar → _input() moves the panel ──────────────────
	title_row.mouse_filter               = Control.MOUSE_FILTER_STOP
	title_row.mouse_default_cursor_shape = Control.CURSOR_DRAG
	title_row.custom_minimum_size.y      = 28
	title_row.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				_lp_drag_active = mb.pressed
	)

	# ── Light presets ──────────────────────────────────────────────────────────
	var preset_lbl := Label.new()
	preset_lbl.text = "Пресеты:"
	preset_lbl.modulate.a = 0.75
	vbox.add_child(preset_lbl)

	var presets_row := HBoxContainer.new()
	presets_row.add_theme_constant_override("separation", 4)
	var _preset_defs: Array = [
		["Студия", 0], ["Улица", 1], ["Ночь", 2], ["Контур", 3]]
	for preset_data in _preset_defs:
		var pb := Button.new()
		pb.text = str(preset_data[0])
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.custom_minimum_size.y = 26
		var pid: int = int(preset_data[1])
		pb.pressed.connect(func() -> void:
			if viewport_container:
				viewport_container.apply_light_preset(pid)
		)
		presets_row.add_child(pb)
	vbox.add_child(presets_row)
	vbox.add_child(HSeparator.new())

	# ── Main (key) light ───────────────────────────────────────────────────────
	var key_lbl := Label.new()
	key_lbl.text = "Основной свет"
	key_lbl.modulate.a = 0.75
	vbox.add_child(key_lbl)

	vbox.add_child(_make_slider_row("Горизонталь", -180.0, 180.0, -30.0,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_light_azimuth(v)))

	vbox.add_child(_make_slider_row("Вертикаль", -180.0, 180.0, -60.0,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_light_elevation(v)))

	vbox.add_child(_make_slider_row("Яркость", 0.0, 5.0, 2.0,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_light_energy(v),
		true))

	var color_row := HBoxContainer.new()
	var color_lbl := Label.new()
	color_lbl.text = "Цвет"
	color_lbl.custom_minimum_size.x = 90
	var color_picker := ColorPickerButton.new()
	color_picker.color = Color(1.0, 0.98, 0.95)
	color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_picker.custom_minimum_size.y = 28
	color_picker.color_changed.connect(func(c: Color) -> void:
		if viewport_container: viewport_container.set_light_color(c))
	color_row.add_child(color_lbl)
	color_row.add_child(color_picker)
	vbox.add_child(color_row)

	var shadow_row := HBoxContainer.new()
	var shadow_lbl := Label.new()
	shadow_lbl.text = "Тени"
	shadow_lbl.custom_minimum_size.x = 90
	var shadow_check := CheckBox.new()
	shadow_check.text           = "Включить"
	shadow_check.button_pressed = true
	shadow_check.toggled.connect(func(on: bool) -> void:
		if viewport_container: viewport_container.set_shadow_enabled(on))
	shadow_row.add_child(shadow_lbl)
	shadow_row.add_child(shadow_check)
	vbox.add_child(shadow_row)
	vbox.add_child(HSeparator.new())

	# ── Fill light ─────────────────────────────────────────────────────────────
	var fill_lbl := Label.new()
	fill_lbl.text = "Заполняющий свет"
	fill_lbl.modulate.a = 0.75
	vbox.add_child(fill_lbl)

	var fill_on_row := HBoxContainer.new()
	var fill_on_lbl := Label.new()
	fill_on_lbl.text = "Включён"
	fill_on_lbl.custom_minimum_size.x = 90
	var fill_check := CheckBox.new()
	fill_check.button_pressed = true
	fill_check.toggled.connect(func(on: bool) -> void:
		if viewport_container: viewport_container.set_fill_light_enabled(on))
	fill_on_row.add_child(fill_on_lbl)
	fill_on_row.add_child(fill_check)
	vbox.add_child(fill_on_row)

	vbox.add_child(_make_slider_row("Яркость", 0.0, 3.0, 1.0,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_fill_light_energy(v),
		true))
	vbox.add_child(HSeparator.new())

	# ── Rim light ──────────────────────────────────────────────────────────────
	var rim_lbl := Label.new()
	rim_lbl.text = "Контурный свет (rim)"
	rim_lbl.modulate.a = 0.75
	vbox.add_child(rim_lbl)

	var rim_on_row := HBoxContainer.new()
	var rim_on_lbl := Label.new()
	rim_on_lbl.text = "Включён"
	rim_on_lbl.custom_minimum_size.x = 90
	var rim_check := CheckBox.new()
	rim_check.button_pressed = true
	rim_check.toggled.connect(func(on: bool) -> void:
		if viewport_container: viewport_container.set_rim_light_enabled(on))
	rim_on_row.add_child(rim_on_lbl)
	rim_on_row.add_child(rim_check)
	vbox.add_child(rim_on_row)

	vbox.add_child(_make_slider_row("Яркость", 0.0, 3.0, 0.4,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_rim_light_energy(v),
		true))
	vbox.add_child(HSeparator.new())

	# ── Ambient / environment light ────────────────────────────────────────────
	var amb_lbl := Label.new()
	amb_lbl.text = "Окружающий свет"
	amb_lbl.modulate.a = 0.75
	vbox.add_child(amb_lbl)

	vbox.add_child(_make_slider_row("Яркость", 0.0, 3.0, 1.5,
		func(v: float) -> void:
			if viewport_container: viewport_container.set_ambient_energy(v),
		true))

	# ── Resize grip ────────────────────────────────────────────────────────────
	var grip := Label.new()
	grip.text = "⇲"
	grip.horizontal_alignment            = HORIZONTAL_ALIGNMENT_RIGHT
	grip.mouse_filter                    = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape      = Control.CURSOR_FDIAGSIZE
	grip.size_flags_horizontal           = Control.SIZE_EXPAND_FILL
	grip.custom_minimum_size             = Vector2(0, 20)
	grip.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				_lp_resize_active = mb.pressed
	)
	vbox.add_child(grip)

	add_child(panel)


func _make_slider_row(label_text: String, min_v: float, max_v: float,
		default_v: float, callback: Callable, is_float: bool = false) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	var lbl  := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 90

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.value     = default_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 38
	val_lbl.text = ("%.1f" if is_float else "%d") % default_v

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = ("%.1f" if is_float else "%d") % v
		callback.call(v))

	hbox.add_child(lbl)
	hbox.add_child(slider)
	hbox.add_child(val_lbl)
	return hbox


# ══════════════════════════════════════════════════════════════════════════════
#  HDRI file loader
# ══════════════════════════════════════════════════════════════════════════════
func _open_hdri_dialog() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	dlg.title     = "Загрузить HDRI / панорамное изображение"
	dlg.size      = Vector2i(800, 500)
	dlg.add_filter("*.hdr,*.exr,*.png,*.jpg,*.jpeg", "HDRI / Images")
	dlg.file_selected.connect(func(path: String) -> void:
		if viewport_container:
			viewport_container.load_env_hdri(path)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


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
func _input(event: InputEvent) -> void:
	if !_lp_drag_active and !_lp_resize_active:
		return
	var lp: Panel = get_node_or_null("LightPanel") as Panel
	if !lp or !lp.visible:
		_lp_drag_active   = false
		_lp_resize_active = false
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and !mb.pressed:
			_lp_drag_active   = false
			_lp_resize_active = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _lp_drag_active:
			lp.position += mm.relative
			get_viewport().set_input_as_handled()
		elif _lp_resize_active:
			var new_w := maxf(lp.size.x + mm.relative.x, 240.0)
			var new_h := maxf(lp.size.y + mm.relative.y, 280.0)
			lp.custom_minimum_size = Vector2(new_w, new_h)
			lp.size                = Vector2(new_w, new_h)
			get_viewport().set_input_as_handled()


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

	elif event.is_action_pressed("camera_reset"):
		if viewport_container and viewport_container.current_model:
			viewport_container.reset_camera()
		get_viewport().set_input_as_handled()

	elif event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_F \
			and not (event as InputEventKey).is_echo():
		if viewport_container and viewport_container.current_model:
			viewport_container.fit_to_view()
		get_viewport().set_input_as_handled()

	elif event.is_action_pressed("view_front"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("view_back"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("view_left"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(2)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("view_right"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(3)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("view_top"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(4)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("view_bottom"):
		if viewport_container and viewport_container.current_model:
			viewport_container.set_view_preset(5)
		get_viewport().set_input_as_handled()

	# W toggles wireframe only when mouse is OUTSIDE the viewport (inside = WASD movement)
	elif event.is_action_pressed("toggle_wireframe"):
		if viewport_container and viewport_container.current_model \
				and not viewport_container.mouse_in_viewport:
			viewport_container.toggle_wireframe()
			var wf_btn := _get_toolbar_btn("WireframeToggleBtn")
			if wf_btn:
				wf_btn.button_pressed = viewport_container.wireframe_enabled
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
		settings.add_recent_model(model_path)
		show_model_info(index)
		# Capture thumbnail after a short delay so the viewport has rendered
		var captured_path: String = model_path
		var captured_idx:  int    = index
		get_tree().create_timer(0.35).timeout.connect(
			func() -> void: _capture_and_store_thumb(captured_path, captured_idx), CONNECT_ONE_SHOT)

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
			# Show cached thumbnail or a colored format-placeholder icon
			var icon: ImageTexture = _thumb_cache.get(path, null) as ImageTexture
			if !icon:
				icon = _get_format_icon(path.get_extension())
			if icon:
				model_list.set_item_icon(item_index, icon)


# ══════════════════════════════════════════════════════════════════════════════
#  Thumbnail system
# ══════════════════════════════════════════════════════════════════════════════
func _setup_thumb_system() -> void:
	# Create the hover-popup panel (floats over everything, ignores mouse)
	_thumb_popup = Panel.new()
	_thumb_popup.name         = "ThumbHoverPopup"
	_thumb_popup.visible      = false
	_thumb_popup.z_index      = 200
	_thumb_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb_popup.custom_minimum_size = Vector2(160, 160)
	_thumb_popup.size                = Vector2(160, 160)

	_thumb_popup_img = TextureRect.new()
	_thumb_popup_img.set_anchors_and_offsets_preset(
			Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
	_thumb_popup_img.stretch_mode         = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumb_popup_img.expand_mode          = TextureRect.EXPAND_IGNORE_SIZE
	_thumb_popup_img.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thumb_popup_img.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_thumb_popup_img.mouse_filter          = Control.MOUSE_FILTER_IGNORE
	_thumb_popup.add_child(_thumb_popup_img)
	add_child(_thumb_popup)

	# Hook into the model list for hover detection
	if model_list:
		model_list.mouse_exited.connect(func() -> void:
			_last_hovered_idx = -1
			if _thumb_popup: _thumb_popup.visible = false
		)
		model_list.gui_input.connect(_on_model_list_gui_input)


func _on_model_list_gui_input(ev: InputEvent) -> void:
	if not ev is InputEventMouseMotion:
		return
	var mm       := ev as InputEventMouseMotion
	var hovered  := model_list.get_item_at_position(mm.position, true)

	if hovered == _last_hovered_idx:
		# Just update popup position while staying on same item
		if _thumb_popup.visible:
			_place_thumb_popup()
		return

	_last_hovered_idx = hovered

	if hovered < 0 or hovered >= filtered_model_paths.size():
		_thumb_popup.visible = false
		return

	var path: String = filtered_model_paths[hovered]
	var tex: ImageTexture = _thumb_cache.get(path, null) as ImageTexture
	if !tex:
		_thumb_popup.visible = false
		return

	_thumb_popup_img.texture = tex
	_place_thumb_popup()
	_thumb_popup.visible = true


func _place_thumb_popup() -> void:
	if !model_list or !_thumb_popup:
		return
	var win_size   := get_viewport().get_visible_rect().size
	var popup_size := _thumb_popup.size
	# Position to the right of the list; if not enough space, flip to the left
	var list_right := model_list.global_position.x + model_list.size.x + 6.0
	var x := list_right if list_right + popup_size.x < win_size.x \
			else model_list.global_position.x - popup_size.x - 6.0
	var mouse_y := model_list.get_global_mouse_position().y
	var y := clampf(mouse_y - popup_size.y * 0.5, 0.0, win_size.y - popup_size.y)
	_thumb_popup.position = Vector2(x, y)


func _capture_and_store_thumb(path: String, list_idx: int) -> void:
	if !viewport_container or !viewport_container.current_model:
		return

	# Save current camera state so we can restore it after the snapshot
	var saved_dist:   float   = viewport_container.camera_distance
	var saved_horiz:  float   = viewport_container.camera_horizontal_angle
	var saved_vert:   float   = viewport_container.camera_vertical_angle
	var saved_center: Vector3 = viewport_container.orbit_center

	# Frame the model properly regardless of where the camera currently is
	viewport_container.fit_to_view()

	# Wait 2 frames so the GPU renders the updated camera position
	await get_tree().process_frame
	await get_tree().process_frame

	# Capture only if the same model is still loaded
	if !viewport_container.current_model:
		return

	var tex: ImageTexture = viewport_container.capture_thumbnail(Vector2i(128, 128))

	# Restore camera silently so the user doesn't see it jump
	viewport_container.camera_distance          = saved_dist
	viewport_container.camera_horizontal_angle  = saved_horiz
	viewport_container.camera_vertical_angle    = saved_vert
	viewport_container.orbit_center             = saved_center
	viewport_container.update_camera_position()

	if !tex:
		return
	_thumb_cache[path] = tex
	if model_list and list_idx < model_list.item_count:
		model_list.set_item_icon(list_idx, tex)


## Returns a small colored square icon for a given file extension (placeholder).
func _get_format_icon(ext: String) -> ImageTexture:
	var key := ext.to_lower()
	if _thumb_fmt_icons.has(key):
		return _thumb_fmt_icons[key] as ImageTexture
	var colors := {
		"glb":  Color(0.15, 0.65, 0.30),
		"gltf": Color(0.10, 0.55, 0.75),
		"fbx":  Color(0.85, 0.45, 0.10),
		"obj":  Color(0.60, 0.20, 0.65)
	}
	var bg: Color = colors.get(key, Color(0.45, 0.45, 0.45))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	# Subtle 1 px border
	var border: Color = bg.darkened(0.35)
	for i in range(32):
		img.set_pixel(i, 0,  border)
		img.set_pixel(i, 31, border)
		img.set_pixel(0,  i, border)
		img.set_pixel(31, i, border)
	var tex := ImageTexture.create_from_image(img)
	_thumb_fmt_icons[key] = tex
	return tex


# ══════════════════════════════════════════════════════════════════════════════
#  Utilities
# ══════════════════════════════════════════════════════════════════════════════
func _format_size(byte_count: int) -> String:
	if byte_count < 1024:
		return "%d B" % byte_count
	elif byte_count < 1024 * 1024:
		return "%.2f KB" % (byte_count / 1024.0)
	return "%.2f MB" % (byte_count / (1024.0 * 1024.0))


# ══════════════════════════════════════════════════════════════════════════════
#  Recent models
# ══════════════════════════════════════════════════════════════════════════════
func _create_recent_button() -> void:
	if !left_panel or !button_container:
		return

	var recent_btn := MenuButton.new()
	recent_btn.name                    = "RecentButton"
	recent_btn.text                    = "Недавние ▾"
	recent_btn.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	recent_btn.custom_minimum_size.y   = 28
	recent_btn.flat                    = false

	recent_btn.about_to_popup.connect(func():
		var popup := recent_btn.get_popup()
		popup.clear()
		var recent: Array = settings.get_recent_models()
		if recent.is_empty():
			popup.add_item("Нет недавних моделей", 0)
			popup.set_item_disabled(0, true)
		else:
			for i: int in recent.size():
				popup.add_item(str(recent[i]).get_file(), i)
				popup.set_item_tooltip(i, str(recent[i]))
	)

	recent_btn.get_popup().index_pressed.connect(func(idx: int):
		var recent: Array = settings.get_recent_models()
		if idx >= recent.size():
			return
		var path := str(recent[idx])
		if FileAccess.file_exists(path):
			_load_model_directly(path)
		else:
			_show_message("Ошибка", "Файл не найден:\n" + path)
	)

	left_panel.add_child(recent_btn)
	left_panel.move_child(recent_btn, button_container.get_index())


func _load_model_directly(path: String) -> void:
	if !model_paths.has(path):
		model_paths.append(path)
	update_model_list(search_box.text if search_box else "")
	var idx := filtered_model_paths.find(path)
	if idx != -1:
		model_list.select(idx)
		_on_model_selected(idx)


# ══════════════════════════════════════════════════════════════════════════════
#  Screenshot
# ══════════════════════════════════════════════════════════════════════════════
func _on_screenshot_pressed() -> void:
	if !viewport_container:
		return
	var img := viewport_container.take_screenshot()
	if !img:
		_show_message("Ошибка", "Не удалось захватить изображение вьюпорта.")
		return

	var save_dialog := FileDialog.new()
	save_dialog.file_mode   = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access      = FileDialog.ACCESS_FILESYSTEM
	save_dialog.title       = "Сохранить скриншот"
	save_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	var ts := Time.get_datetime_dict_from_system()
	save_dialog.current_file = "screenshot_%04d%02d%02d_%02d%02d%02d.png" % [
		ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second
	]
	save_dialog.add_filter("*.png", "PNG Image")
	save_dialog.close_requested.connect(save_dialog.queue_free)
	save_dialog.canceled.connect(save_dialog.queue_free)
	save_dialog.file_selected.connect(func(save_path: String):
		var err := img.save_png(save_path)
		if err == OK:
			_show_message("Скриншот", "Сохранено:\n" + save_path)
		else:
			_show_message("Ошибка", "Не удалось сохранить файл.")
		save_dialog.queue_free()
	)
	add_child(save_dialog)
	save_dialog.popup_centered(Vector2(800, 600))


# ══════════════════════════════════════════════════════════════════════════════
#  Toolbar helpers
# ══════════════════════════════════════════════════════════════════════════════
func _get_toolbar_btn(btn_name: String) -> Button:
	if !preview_column:
		return null
	var toolbar := preview_column.get_node_or_null("ViewportToolbar")
	if !toolbar:
		return null
	return toolbar.get_node_or_null(btn_name) as Button


# ══════════════════════════════════════════════════════════════════════════════
#  Drag & Drop (OS file drop)
# ══════════════════════════════════════════════════════════════════════════════
func _connect_drag_drop() -> void:
	var win := get_window()
	if win and !win.files_dropped.is_connected(_on_files_dropped):
		win.files_dropped.connect(_on_files_dropped)


func _on_files_dropped(files: PackedStringArray) -> void:
	var dirs:   Array[String] = []
	var models: Array[String] = []

	for path in files:
		if DirAccess.dir_exists_absolute(path):
			dirs.append(path)
		elif FileAccess.file_exists(path):
			var ext := path.get_extension().to_lower()
			if ext in SUPPORTED_EXTENSIONS:
				models.append(path)

	# Папка имеет приоритет — сканируем её как через кнопку выбора
	if dirs.size() > 0:
		var dir := dirs[0]
		if file_dialog:
			file_dialog.current_dir = dir
		_on_project_dir_selected(dir)
		return

	# Только файлы моделей — добавляем в список и загружаем первый
	if models.size() > 0:
		for path in models:
			if !model_paths.has(path):
				model_paths.append(path)
		update_model_list(search_box.text if search_box else "")

		var first_index := filtered_model_paths.find(models[0])
		if first_index != -1:
			model_list.select(first_index)
			_on_model_selected(first_index)
		return

	# Ничего подходящего не нашли
	_show_message("Drag & Drop", "Неподдерживаемый формат файла.\nПоддерживаются: " + ", ".join(SUPPORTED_EXTENSIONS))


func _show_message(title: String, text: String) -> void:
	if !message_dialog:
		print("%s: %s" % [title, text])
		return
	message_dialog.title       = title
	message_dialog.dialog_text = text
	message_dialog.popup_centered()


# ══════════════════════════════════════════════════════════════════════════════
#  Batch operations — button, dialog, runners
# ══════════════════════════════════════════════════════════════════════════════
func _create_batch_button() -> void:
	if !button_container:
		return
	var btn := MenuButton.new()
	btn.text                   = "Пакетно"
	btn.flat                   = false
	btn.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.y  = 28
	btn.tooltip_text           = "Пакетные операции со всеми моделями"
	var pop := btn.get_popup()
	pop.add_item("Скриншоты моделей...",       0)
	pop.add_item("Экспорт информации (.json / .txt)...", 1)
	pop.index_pressed.connect(func(idx: int) -> void:
		_show_batch_dialog(idx)
	)
	button_container.add_child(btn)


func _show_batch_dialog(mode: int) -> void:
	_batch_mode = mode
	if is_instance_valid(_batch_win):
		_batch_win.queue_free()

	_batch_win = Window.new()
	_batch_win.title    = "Пакетные скриншоты" if mode == 0 else "Экспорт информации о моделях"
	_batch_win.size     = Vector2i(500, 580)
	_batch_win.min_size = Vector2i(380, 400)
	_batch_win.close_requested.connect(func() -> void:
		_batch_running = false
		if is_instance_valid(_batch_win):
			_batch_win.queue_free()
			_batch_win = null
	)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	vbox.add_theme_constant_override("separation", 8)
	_batch_win.add_child(vbox)

	# ── Select all / none row ─────────────────────────────────────────────────
	var sel_row := HBoxContainer.new()
	var sel_all := Button.new()
	sel_all.text = "Выбрать все"
	var sel_none := Button.new()
	sel_none.text = "Снять всё"
	var cnt_lbl := Label.new()
	cnt_lbl.text = "Моделей: %d" % model_paths.size()
	cnt_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cnt_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	sel_row.add_child(sel_all)
	sel_row.add_child(sel_none)
	sel_row.add_child(cnt_lbl)
	vbox.add_child(sel_row)

	# ── Scrollable checklist ──────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 220
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var cv := VBoxContainer.new()
	cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_batch_checks.clear()
	for path in model_paths:
		var cb := CheckBox.new()
		cb.text              = path.get_file()
		cb.tooltip_text      = path
		cb.button_pressed    = true
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cv.add_child(cb)
		_batch_checks.append(cb)
	scroll.add_child(cv)
	vbox.add_child(scroll)

	# Wire select-all / none after _batch_checks is populated
	sel_all.pressed.connect(func() -> void:
		for c in _batch_checks:
			if c is CheckBox: (c as CheckBox).button_pressed = true)
	sel_none.pressed.connect(func() -> void:
		for c in _batch_checks:
			if c is CheckBox: (c as CheckBox).button_pressed = false)

	vbox.add_child(HSeparator.new())

	# ── Options ───────────────────────────────────────────────────────────────
	var opts := VBoxContainer.new()
	opts.add_theme_constant_override("separation", 6)

	if mode == 0:
		# Screenshot — choose output folder
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "Папка:"
		lbl.custom_minimum_size.x = 90
		_batch_out_edit = LineEdit.new()
		_batch_out_edit.placeholder_text  = "Выберите папку для сохранения..."
		_batch_out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var browse := Button.new()
		browse.text = "…"
		browse.pressed.connect(_open_batch_dir_dialog)
		row.add_child(lbl); row.add_child(_batch_out_edit); row.add_child(browse)
		opts.add_child(row)
	else:
		# Export info — format + output file
		var fmt_row := HBoxContainer.new()
		var fmt_lbl := Label.new()
		fmt_lbl.text = "Формат:"
		fmt_lbl.custom_minimum_size.x = 90
		_batch_fmt_opt = OptionButton.new()
		_batch_fmt_opt.add_item("JSON  (.json)", 0)
		_batch_fmt_opt.add_item("Текст (.txt)",  1)
		_batch_fmt_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fmt_row.add_child(fmt_lbl); fmt_row.add_child(_batch_fmt_opt)
		opts.add_child(fmt_row)

		var file_row := HBoxContainer.new()
		var file_lbl := Label.new()
		file_lbl.text = "Файл:"
		file_lbl.custom_minimum_size.x = 90
		_batch_out_edit = LineEdit.new()
		_batch_out_edit.placeholder_text  = "Выберите файл сохранения..."
		_batch_out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var browse2 := Button.new()
		browse2.text = "…"
		browse2.pressed.connect(_open_batch_file_dialog)
		file_row.add_child(file_lbl); file_row.add_child(_batch_out_edit); file_row.add_child(browse2)
		opts.add_child(file_row)

		# Update default file extension when format changes
		_batch_fmt_opt.item_selected.connect(func(_i: int) -> void:
			if _batch_out_edit and _batch_out_edit.text.strip_edges() != "":
				var base := _batch_out_edit.text.get_basename()
				_batch_out_edit.text = base + (".json" if _batch_fmt_opt.selected == 0 else ".txt")
		)

	vbox.add_child(opts)
	vbox.add_child(HSeparator.new())

	# ── Progress + buttons ────────────────────────────────────────────────────
	_batch_progress = Label.new()
	_batch_progress.text         = ""
	_batch_progress.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_batch_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_batch_progress)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	var close_btn := Button.new()
	close_btn.text = "Закрыть"
	close_btn.pressed.connect(func() -> void:
		_batch_running = false
		if is_instance_valid(_batch_win):
			_batch_win.queue_free()
			_batch_win = null
	)
	_batch_run_btn = Button.new()
	_batch_run_btn.text = "▶  Запустить"
	_batch_run_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_batch_run_btn.pressed.connect(_on_batch_run_pressed)
	btn_row.add_child(close_btn)
	btn_row.add_child(_batch_run_btn)
	vbox.add_child(btn_row)

	add_child(_batch_win)
	_batch_win.popup_centered()


func _on_batch_run_pressed() -> void:
	if _batch_running:
		return
	var selected: Array[String] = []
	for i in _batch_checks.size():
		var cb := _batch_checks[i] as CheckBox
		if cb and cb.button_pressed and i < model_paths.size():
			selected.append(model_paths[i])
	if selected.is_empty():
		_batch_progress.text = "⚠ Не выбрана ни одна модель."
		return
	var out_path := (_batch_out_edit.text.strip_edges() if _batch_out_edit else "")
	if out_path.is_empty():
		_batch_progress.text = "⚠ Укажите папку / файл вывода."
		return
	_batch_running = true
	_batch_run_btn.disabled = true
	_batch_run_btn.text = "⏳ Обработка..."
	if _batch_mode == 0:
		_run_batch_screenshots(selected, out_path)
	else:
		var use_json: bool = !_batch_fmt_opt or _batch_fmt_opt.selected == 0
		_run_batch_export_info(selected, out_path, use_json)


func _run_batch_screenshots(paths: Array[String], output_dir: String) -> void:
	if !DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	var saved := 0
	var failed := 0
	for i in paths.size():
		var path: String = paths[i]
		if !is_instance_valid(_batch_win):
			break   # dialog closed — abort
		if _batch_progress and is_instance_valid(_batch_progress):
			_batch_progress.text = "⏳ %d / %d  —  %s" % [i + 1, paths.size(), path.get_file()]
		var result := viewport_container.load_in_preview_portal(path)
		if result != "Модель загружена успешно":
			failed += 1
			continue
		# Fit the model into frame so the screenshot isn't empty
		viewport_container.fit_to_view()
		# Wait several frames so the renderer draws the updated camera
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var img: Image = viewport_container.get_screenshot_image()
		if !img:
			failed += 1
			continue
		var file_name := path.get_file().get_basename() + ".png"
		var save_path := output_dir.path_join(file_name)
		if img.save_png(save_path) == OK:
			saved += 1
		else:
			failed += 1
	# Restore the previously selected model
	var sel := model_list.get_selected_items()
	if sel.size() > 0 and sel[0] < filtered_model_paths.size():
		viewport_container.load_in_preview_portal(filtered_model_paths[int(sel[0])])
	_batch_running = false
	if _batch_run_btn and is_instance_valid(_batch_run_btn):
		_batch_run_btn.disabled = false
		_batch_run_btn.text = "▶  Запустить"
	if _batch_progress and is_instance_valid(_batch_progress):
		_batch_progress.text = "✓ Готово: %d сохранено, %d ошибок.\nПапка: %s" \
				% [saved, failed, output_dir]


func _run_batch_export_info(paths: Array[String], output_path: String,
		use_json: bool) -> void:
	var parent_dir := output_path.get_base_dir()
	if !DirAccess.dir_exists_absolute(parent_dir):
		DirAccess.make_dir_recursive_absolute(parent_dir)
	var ok := false
	if use_json:
		ok = _export_info_json(paths, output_path)
	else:
		ok = _export_info_txt(paths, output_path)
	_batch_running = false
	if _batch_run_btn and is_instance_valid(_batch_run_btn):
		_batch_run_btn.disabled = false
		_batch_run_btn.text = "▶  Запустить"
	if _batch_progress and is_instance_valid(_batch_progress):
		if ok:
			_batch_progress.text = "✓ Сохранено %d записей:\n%s" \
					% [paths.size(), output_path]
		else:
			_batch_progress.text = "✗ Ошибка: не удалось записать файл."


func _export_info_json(paths: Array[String], output_path: String) -> bool:
	var arr: Array = []
	for path in paths:
		var inf := get_model_info(path)
		arr.append({
			"filename":      inf.get("filename", ""),
			"path":          inf.get("path", ""),
			"type":          inf.get("type", ""),
			"size":          inf.get("size", ""),
			"date_modified": inf.get("date_modified", "")
		})
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if !file:
		return false
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	return true


func _export_info_txt(paths: Array[String], output_path: String) -> bool:
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if !file:
		return false
	file.store_line("Экспорт информации о моделях")
	file.store_line("Дата: " + Time.get_datetime_string_from_system())
	file.store_line("Количество: %d" % paths.size())
	file.store_line("")
	for path in paths:
		var inf := get_model_info(path)
		file.store_line("=".repeat(48))
		file.store_line("Файл:    " + str(inf.get("filename", "")))
		file.store_line("Путь:    " + str(inf.get("path", "")))
		file.store_line("Тип:     " + str(inf.get("type", "")))
		file.store_line("Размер:  " + str(inf.get("size", "")))
		file.store_line("Изменён: " + str(inf.get("date_modified", "")))
		file.store_line("")
	file.close()
	return true


func _open_batch_dir_dialog() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	dlg.title     = "Папка для сохранения скриншотов"
	dlg.size      = Vector2i(800, 500)
	dlg.dir_selected.connect(func(dir: String) -> void:
		if _batch_out_edit and is_instance_valid(_batch_out_edit):
			_batch_out_edit.text = dir
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _open_batch_file_dialog() -> void:
	var use_json := !_batch_fmt_opt or _batch_fmt_opt.selected == 0
	var dlg := FileDialog.new()
	dlg.file_mode    = FileDialog.FILE_MODE_SAVE_FILE
	dlg.access       = FileDialog.ACCESS_FILESYSTEM
	dlg.title        = "Сохранить файл экспорта"
	dlg.size         = Vector2i(800, 500)
	dlg.current_file = "models_info.json" if use_json else "models_info.txt"
	if use_json:
		dlg.add_filter("*.json", "JSON")
	else:
		dlg.add_filter("*.txt",  "Текст")
	dlg.file_selected.connect(func(path: String) -> void:
		if _batch_out_edit and is_instance_valid(_batch_out_edit):
			_batch_out_edit.text = path
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()
