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

const AUTO_SCAN_LAST_DIRECTORY_ON_START := true    # restore last project on startup
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
var file_dialog:         FileDialog
var _copy_dest_dialog:   FileDialog = null
var _pending_copy_paths: Array[String] = []
var loading_dialog: AcceptDialog
var message_dialog: AcceptDialog

# ── Light-panel drag / resize state ──────────────────────────────────────────
var _lp_drag_active:   bool = false
var _lp_resize_active: bool = false

# ── Batch operations state ───────────────────────────────────────────────────
var _settings_win:          Window = null
var _settings_win_last_tab: int    = 0
var _miss_tex_dialog:       Window = null

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

# ── Model-list right-click context menu ───────────────────────────────────────
var _list_context_menu: PopupMenu = null
var _loaded_model_path: String    = ""   # path of the model currently in viewport

# ── Favorites / tab system ────────────────────────────────────────────────────
var _active_tab:   int    = 0   # 0 = All models, 1 = Favorites
var _tab_all_btn:  Button = null
var _tab_fav_btn:  Button = null

# ── Status bar ────────────────────────────────────────────────────────────────
var _status_label:       Label  = null
var _status_busy_text:   String = ""

# ── Progress overlay (CanvasLayer panel, not a separate OS window) ────────────
const PROGRESS_THRESHOLD_MS := 250   # don't show for ops faster than this (ms)

var _prog_overlay:     Control     = null   # PanelContainer on a CanvasLayer
var _progress_bar:     ProgressBar = null   # bar inside the overlay
var _prog_stage_label: Label       = null   # current-stage text
var _prog_pct_label:   Label       = null   # "55%"
var _op_start_msec:    int         = 0      # Time.get_ticks_msec() when op began

# ── Async load state (polled in _process) ─────────────────────────────────────
var _loading_path:  String = ""   # non-empty while async load is in flight
var _loading_index: int    = -1   # filtered_model_paths index being loaded


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
	_create_list_tabs()
	_create_status_bar()
	_create_progress_window()

	# Connect loading-stage signal so the status bar shows live progress text
	if viewport_container:
		viewport_container.loading_stage.connect(_on_loading_stage)

	# Connect right-panel action buttons
	if model_info_panel:
		model_info_panel.textures_action_requested.connect(_show_missing_textures_dialog)

	call_deferred("_first_layout")
	print("3DViewModels: ready completed")


func _first_layout() -> void:
	_apply_layout(true)
	await get_tree().process_frame
	_apply_layout(false)
	print("3DViewModels: first layout completed")


## Polls the async model-load thread every frame and handles completion.
## Uses time-based fake progress (10 → 78 %) so the bar fills smoothly while
## the thread runs. Post-thread scene setup stages (85/90/96/100 %) are handled
## by _on_loading_stage() which fires from finish_async_load().
func _process(_delta: float) -> void:
	if _loading_path.is_empty():
		return

	var status := viewport_container.poll_async_load()

	if status == -1:
		# Thread still running — animate bar with a time-based curve.
		var elapsed := float(Time.get_ticks_msec() - _op_start_msec) / 1000.0
		var fake_pct := 10.0 + 70.0 * (1.0 - exp(-elapsed * 0.8))
		_show_progress(fake_pct)
		return

	# Thread finished — grab path/index, clear state BEFORE any await so that
	# subsequent _process() calls short-circuit at the top check above.
	var path  := _loading_path
	var idx   := _loading_index
	_loading_path  = ""
	_loading_index = -1

	if status == 1:   # thread returned null (load error)
		_hide_progress()
		_set_status("⚠  Ошибка загрузки", 10.0)
		return

	# status == 0: thread succeeded. Do scene setup on the main thread.
	# finish_async_load emits stage signals (Добавление/Настройка/…) which are
	# caught by _on_loading_stage and update the bar to 85/90/96/100 %.
	var result := viewport_container.finish_async_load()

	if result != "Модель загружена успешно":
		_set_status("⚠  %s" % result, 10.0)
		_show_message("Ошибка загрузки", result)
		_show_progress(100.0)
		await get_tree().create_timer(0.4).timeout
		_hide_progress()
		return

	_loaded_model_path = path
	settings.set_setting("last_model", path)
	settings.add_recent_model(path)
	show_model_info(idx)
	_set_status("✓  " + path.get_file(), 8.0)
	_update_model_header()

	var captured_path := path
	var captured_idx  := idx
	get_tree().create_timer(0.35).timeout.connect(
		func() -> void: _capture_and_store_thumb(captured_path, captured_idx), CONNECT_ONE_SHOT)

	# Keep bar at 100 % for a short moment so the user sees completion.
	if _prog_overlay and _prog_overlay.modulate.a >= 1.0:
		await get_tree().create_timer(0.35).timeout
	_hide_progress()


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
	var ca_w := int(content_area.size.x)
	if ca_w <= 0:
		return
	# Derive effective mode from actual window width to avoid stale _layout_mode
	# when this fires mid-frame during rapid resize.
	var vr := get_viewport().get_visible_rect() if get_viewport() else Rect2()
	var win_w := maxf(vr.size.x, size.x)
	var eff_compact: bool = win_w < BP_COMPACT
	if eff_compact:
		content_area.split_offset = ca_w
		return
	var eff_mode: LayoutMode = LayoutMode.NARROW if win_w < BP_NARROW else LayoutMode.NORMAL
	var target: int = _desired_info_w if _desired_info_w > 0 else INFO_W[eff_mode]
	target = clampi(target, 80, ca_w - 100)
	content_area.split_offset = ca_w - target


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
		model_list.select_mode           = ItemList.SELECT_MULTI

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
		elif not _left_panel_collapsed:
			# Clamp within current window even when mode did not change
			var max_left := int(w * 0.45)
			if root_split.split_offset > max_left:
				root_split.split_offset = max_left

	# ── Right divider (viewport ↔ info panel) ────────────────────────────────
	if content_area:
		if compact:
			content_area.split_offset = int(content_area.size.x)
		else:
			var ca_w := int(content_area.size.x)
			if ca_w == 0:
				ca_w = int(w) - left_w
			if mode_changed:
				_desired_info_w = 0  # Reset on mode change → use default
			var target := _desired_info_w if _desired_info_w > 0 else info_w
			target = clampi(target, 80, ca_w - 100)
			var new_offset := ca_w - target
			if new_offset >= 100:
				content_area.split_offset = new_offset
		_split_info_done = true


func _set_split_offset(ideal: int, window_w: float, clamp_existing: bool) -> void:
	if !root_split:
		return

	if _left_panel_collapsed:
		root_split.split_offset = 28
		return

	# Upper bound: at most 45 % of window width, and at most 2.5× the ideal
	var hi := int(minf(float(ideal) * 2.5, window_w * 0.45))
	hi = maxi(hi, ideal)   # never let hi < lo

	if !_split_initialised:
		root_split.split_offset = ideal
		return

	if clamp_existing:
		# Mode changed: pull the divider into a sensible range for the new mode,
		# but honour whatever position the user had if it already fits.
		root_split.split_offset = clampi(root_split.split_offset, ideal, hi)


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
		# item_selected is intentionally NOT connected in SELECT_MULTI mode:
		# clicking an already-selected item deselects it (toggle) and never
		# fires item_selected, so model loading is driven by item_clicked instead.
		if model_list.item_selected.is_connected(_on_model_selected):
			model_list.item_selected.disconnect(_on_model_selected)
		if !model_list.item_clicked.is_connected(_on_model_list_item_clicked):
			model_list.item_clicked.connect(_on_model_list_item_clicked)

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

	# ── Wireframe cycle button  (Off → Overlay → Only → Off …) ───────────────
	var wf_btn := Button.new()
	wf_btn.name         = "WireframeToggleBtn"
	wf_btn.text         = "Каркас"
	wf_btn.tooltip_text = "Режим каркаса [W вне вьюпорта]\nВыкл → Поверх (solid+wire) → Только каркас"
	wf_btn.toggle_mode  = false
	wf_btn.pressed.connect(func():
		if viewport_container:
			viewport_container.toggle_wireframe()
			_update_wireframe_btn_text()
	)
	toolbar.add_child(wf_btn)

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

	# ── Settings ──────────────────────────────────────────────────────────────
	var sett_btn := Button.new()
	sett_btn.name         = "SettingsBtn"
	sett_btn.text         = "⚙"
	sett_btn.tooltip_text = "Настройки программы"
	sett_btn.pressed.connect(func() -> void: _open_settings_window())
	toolbar.add_child(sett_btn)

	# Wrap in scroll so buttons don't overflow onto the 3D viewport at small sizes
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.name                    = "ToolbarScroll"
	toolbar_scroll.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	toolbar_scroll.size_flags_vertical     = Control.SIZE_SHRINK_BEGIN
	toolbar_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	toolbar_scroll.custom_minimum_size    = Vector2(0, 34)
	toolbar_scroll.clip_contents          = true
	toolbar.size_flags_horizontal         = Control.SIZE_SHRINK_BEGIN
	toolbar_scroll.add_child(toolbar)
	preview_column.add_child(toolbar_scroll)
	_apply_startup_display_settings()
	_create_light_panel()


# ══════════════════════════════════════════════════════════════════════════════
#  Startup display settings (grid / gizmo / fps defaults from config)
# ══════════════════════════════════════════════════════════════════════════════
func _apply_startup_display_settings() -> void:
	var pairs := [
		["GridToggleBtn",  "show_grid",  func(): viewport_container.toggle_grid()],
		["GizmoToggleBtn", "show_gizmo", func(): viewport_container.toggle_gizmo()],
	]
	for pair in pairs:
		var btn := preview_column.find_child(pair[0] as String, true, false) as Button
		if btn == null or viewport_container == null:
			continue
		var want: bool = bool(settings.get_setting(pair[1] as String))
		if btn.button_pressed != want:
			btn.set_pressed_no_signal(want)
			(pair[2] as Callable).call()
	if viewport_container:
		viewport_container.apply_viewer_settings(settings)
		# Apply show_fps directly — no toolbar button
		if bool(settings.get_setting("show_fps")):
			viewport_container.toggle_fps_counter()


# ══════════════════════════════════════════════════════════════════════════════
#  Settings window
# ══════════════════════════════════════════════════════════════════════════════
func _open_settings_window() -> void:
	if _settings_win and is_instance_valid(_settings_win):
		_settings_win.show()
		_settings_win.grab_focus()
		return
	_settings_win = _build_settings_window()
	add_child(_settings_win)
	var sx: int = int(settings.get_setting("settings_win_x"))
	var sy: int = int(settings.get_setting("settings_win_y"))
	var sw: int = int(settings.get_setting("settings_win_w"))
	var sh: int = int(settings.get_setting("settings_win_h"))
	if sx >= 0 and sy >= 0:
		_settings_win.size     = Vector2i(sw, sh)
		_settings_win.position = Vector2i(sx, sy)
		_settings_win.show()
	else:
		_settings_win.popup_centered()


func _sett_slider_row(parent: Control, label_text: String, key: String,
		min_val: float, max_val: float, step: float, fmt: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(52, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.custom_minimum_size = Vector2(150, 0)
	var cur: float = float(settings.get_setting(key))
	slider.value = cur
	val_lbl.text = fmt % cur
	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = fmt % v
		settings.set_setting(key, v)
		if viewport_container:
			viewport_container.apply_viewer_settings(settings)
	)
	row.add_child(slider)


func _sett_check_row(parent: Control, label_text: String, key: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var chk := CheckBox.new()
	chk.button_pressed = bool(settings.get_setting(key))
	chk.toggled.connect(func(v: bool) -> void:
		settings.set_setting(key, v)
		if viewport_container:
			viewport_container.apply_viewer_settings(settings)
			if key == "show_fps" and viewport_container._fps_visible != v:
				viewport_container.toggle_fps_counter()
	)
	row.add_child(chk)


func _sett_spinbox_row(parent: Control, label_text: String, key: String,
		min_val: int, max_val: int, step_val: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var spin := SpinBox.new()
	spin.min_value = min_val
	spin.max_value = max_val
	spin.step = step_val
	spin.value = int(settings.get_setting(key))
	spin.custom_minimum_size = Vector2(80, 0)
	spin.value_changed.connect(func(v: float) -> void:
		settings.set_setting(key, int(v))
		if viewport_container:
			viewport_container.apply_viewer_settings(settings)
	)
	row.add_child(spin)


func _build_settings_window() -> Window:
	var win := Window.new()
	win.title        = "Настройки"
	win.exclusive    = false
	win.unresizable  = false
	win.min_size     = Vector2i(500, 400)
	win.size         = Vector2i(520, 480)
	win.close_requested.connect(func() -> void:
		settings.set_setting("settings_win_x", win.position.x)
		settings.set_setting("settings_win_y", win.position.y)
		settings.set_setting("settings_win_w", win.size.x)
		settings.set_setting("settings_win_h", win.size.y)
		win.hide()
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",     8)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var tabs := TabContainer.new()
	tabs.name = "SettingsTabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tabs)

	# ── Tab 1: Управление ─────────────────────────────────────────────────
	var cam_tab := VBoxContainer.new()
	cam_tab.name = "Управление"
	cam_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(cam_tab)
	cam_tab.add_child(HSeparator.new())
	_sett_slider_row(cam_tab, "Чувствительность орбиты:",   "orbit_sensitivity",
			0.0001, 0.030, 0.0001, "%.4f")
	_sett_slider_row(cam_tab, "Чувствительность вращения:", "free_rotation_sensitivity",
			0.0001, 0.030, 0.0001, "%.4f")
	_sett_slider_row(cam_tab, "Скорость зума:",             "zoom_speed",
			1.05, 2.0, 0.05, "%.2f")
	_sett_slider_row(cam_tab, "Скорость панорамы:",         "pan_speed",
			0.2, 10.0, 0.2, "%.1f")
	_sett_check_row(cam_tab, "Инерция движения (плавное замедление):", "inertia_enabled")
	_sett_check_row(cam_tab, "Зум к курсору:", "zoom_to_cursor")

	# ── Tab 2: Анимация ───────────────────────────────────────────────────
	var anim_tab := VBoxContainer.new()
	anim_tab.name = "Анимация"
	anim_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(anim_tab)
	anim_tab.add_child(HSeparator.new())
	_sett_slider_row(anim_tab, "Задержка сброса позы (сек):", "pose_reset_delay",
			0.0, 10.0, 0.5, "%.1f")
	var anim_note := Label.new()
	anim_note.text = "После окончания анимации модель возвращается\nв стандартную позу через указанное время.\n0 = сброс немедленно."
	anim_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	anim_note.modulate.a = 0.65
	anim_tab.add_child(anim_note)

	# ── Tab 3: Прочее ─────────────────────────────────────────────────────
	var misc_tab := VBoxContainer.new()
	misc_tab.name = "Прочее"
	misc_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(misc_tab)
	misc_tab.add_child(HSeparator.new())
	_sett_check_row(misc_tab, "Показывать сетку при запуске:",   "show_grid")
	_sett_check_row(misc_tab, "Показывать оси при запуске:",     "show_gizmo")
	_sett_check_row(misc_tab, "Показывать FPS:",                 "show_fps")
	_sett_spinbox_row(misc_tab, "Кэш моделей в памяти (шт.):",   "model_cache_limit",
			1, 32, 1)
	var misc_note := Label.new()
	misc_note.text = "Сетка и оси вступают в силу при следующем запуске. FPS включается сразу."
	misc_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	misc_note.modulate.a = 0.65
	misc_tab.add_child(misc_note)

	# ── Bottom buttons ────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var reset_btn := Button.new()
	reset_btn.text = "Сбросить все настройки"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(func() -> void:
		if is_instance_valid(win):
			settings.set_setting("settings_win_x", win.position.x)
			settings.set_setting("settings_win_y", win.position.y)
			settings.set_setting("settings_win_w", win.size.x)
			settings.set_setting("settings_win_h", win.size.y)
			var tc := win.find_child("SettingsTabs", true, false) as TabContainer
			if tc:
				_settings_win_last_tab = tc.current_tab
		_reset_viewer_settings_to_defaults()
		if is_instance_valid(win):
			win.queue_free()
		_settings_win = null
		_open_settings_window()
	)
	btn_row.add_child(reset_btn)

	var close_btn := Button.new()
	close_btn.text = "Закрыть"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(func() -> void:
		settings.set_setting("settings_win_x", win.position.x)
		settings.set_setting("settings_win_y", win.position.y)
		settings.set_setting("settings_win_w", win.size.x)
		settings.set_setting("settings_win_h", win.size.y)
		win.hide()
	)
	btn_row.add_child(close_btn)

	# Restore the tab that was active before (e.g. after reset)
	tabs.current_tab = clampi(_settings_win_last_tab, 0, tabs.get_tab_count() - 1)

	return win


func _reset_viewer_settings_to_defaults() -> void:
	for key: String in ["orbit_sensitivity", "free_rotation_sensitivity",
			"zoom_speed", "pan_speed", "inertia_enabled", "zoom_to_cursor",
			"pose_reset_delay", "model_cache_limit",
			"show_grid", "show_gizmo", "show_fps"]:
		settings.set_setting(key, settings.DEFAULT_SETTINGS[key])
	if viewport_container:
		viewport_container.apply_viewer_settings(settings)


# ══════════════════════════════════════════════════════════════════════════════
#  Missing textures indicator and dialog
# ══════════════════════════════════════════════════════════════════════════════
func _update_model_header() -> void:
	# Close stale texture dialog from the previous model
	if _miss_tex_dialog and is_instance_valid(_miss_tex_dialog):
		_miss_tex_dialog.queue_free()
	_miss_tex_dialog = null

	if not viewport_container or not model_info_panel:
		return
	var missing_count := viewport_container.get_missing_textures().size()
	model_info_panel.update_textures_warning(missing_count)


func _show_missing_textures_dialog() -> void:
	if _miss_tex_dialog and is_instance_valid(_miss_tex_dialog):
		_miss_tex_dialog.show()
		_miss_tex_dialog.grab_focus()
		return

	var missing: Array[String] = []
	if viewport_container:
		missing = viewport_container.get_missing_textures()

	# Gather embedded/found textures from materials for display
	var found_textures: Array = []
	if viewport_container:
		var details := viewport_container.get_model_details()
		found_textures = details.get("textures_data", [])

	var win := Window.new()
	win.title       = "Текстуры модели"
	win.exclusive   = false
	win.unresizable = false
	win.min_size    = Vector2i(420, 300)
	win.size        = Vector2i(480, 400)
	win.close_requested.connect(func() -> void: win.hide())
	_miss_tex_dialog = win
	add_child(win)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   12)
	margin.add_theme_constant_override("margin_right",  12)
	margin.add_theme_constant_override("margin_top",    10)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# ── Found / embedded textures ─────────────────────────────────────────────
	if not found_textures.is_empty():
		var found_hdr := Label.new()
		found_hdr.text = "Текстуры в модели:"
		found_hdr.add_theme_font_size_override("font_size", 12)
		vbox.add_child(found_hdr)

		var found_scroll := ScrollContainer.new()
		found_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		found_scroll.custom_minimum_size = Vector2(0, 60)
		vbox.add_child(found_scroll)

		var found_vbox := VBoxContainer.new()
		found_vbox.add_theme_constant_override("separation", 2)
		found_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		found_scroll.add_child(found_vbox)

		for tex_info: Dictionary in found_textures:
			var lbl := Label.new()
			lbl.text = "✓  " + str(tex_info.get("name", "—"))
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.modulate = Color(0.6, 1.0, 0.6)
			found_vbox.add_child(lbl)

		vbox.add_child(HSeparator.new())

	# ── Missing textures ──────────────────────────────────────────────────────
	var miss_hdr := Label.new()
	if missing.is_empty():
		miss_hdr.text = "Пропущенных текстур нет."
		miss_hdr.modulate.a = 0.65
	else:
		miss_hdr.text = "Не найдено текстур (%d):" % missing.size()
		miss_hdr.modulate = Color(1.6, 0.75, 0.2)
	miss_hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(miss_hdr)

	if not missing.is_empty():
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.custom_minimum_size = Vector2(0, 60)
		vbox.add_child(scroll)

		var list_vbox := VBoxContainer.new()
		list_vbox.add_theme_constant_override("separation", 2)
		list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list_vbox)

		for tex_name: String in missing:
			var lbl := Label.new()
			lbl.text = "✗  " + tex_name
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.modulate = Color(1.0, 0.5, 0.4)
			list_vbox.add_child(lbl)

	vbox.add_child(HSeparator.new())

	# Current folder display
	var folder_row := HBoxContainer.new()
	folder_row.add_theme_constant_override("separation", 6)
	vbox.add_child(folder_row)

	var folder_lbl := Label.new()
	folder_lbl.text = "Папка текстур:"
	folder_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	folder_row.add_child(folder_lbl)

	var cur_folder := settings.get_texture_folder(_loaded_model_path)
	var folder_val := Label.new()
	folder_val.name = "FolderValueLabel"
	folder_val.text = cur_folder if not cur_folder.is_empty() else "(не задана)"
	folder_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder_val.clip_text = true
	folder_val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	folder_val.modulate.a = 0.75 if cur_folder.is_empty() else 1.0
	folder_row.add_child(folder_val)

	# Buttons row
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var pick_btn := Button.new()
	pick_btn.text = "Указать папку..."
	pick_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick_btn.pressed.connect(func() -> void:
		_pick_texture_folder(win)
	)
	btn_row.add_child(pick_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Очистить папку"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(func() -> void:
		if _loaded_model_path.is_empty():
			return
		settings.set_texture_folder(_loaded_model_path, "")
		if viewport_container:
			viewport_container.set_extra_texture_dirs([])
		var val_l := win.find_child("FolderValueLabel", true, false) as Label
		if val_l:
			val_l.text      = "(не задана)"
			val_l.modulate.a = 0.75
	)
	btn_row.add_child(clear_btn)

	var close_btn := Button.new()
	close_btn.text = "Закрыть"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(func() -> void: win.hide())
	btn_row.add_child(close_btn)

	win.popup_centered()


func _pick_texture_folder(owner_win: Window) -> void:
	var fd := FileDialog.new()
	fd.file_mode      = FileDialog.FILE_MODE_OPEN_DIR
	fd.access         = FileDialog.ACCESS_FILESYSTEM
	fd.title          = "Выберите папку с текстурами"
	if not _loaded_model_path.is_empty():
		fd.current_dir = _loaded_model_path.get_base_dir()
	add_child(fd)
	fd.dir_selected.connect(func(dir: String) -> void:
		if _loaded_model_path.is_empty():
			fd.queue_free()
			return
		settings.set_texture_folder(_loaded_model_path, dir)
		# Reload the model so textures are resolved with the new folder
		var path := _loaded_model_path
		_loaded_model_path = ""
		if viewport_container:
			viewport_container.remove_from_cache(path)
		# Update folder label in the dialog if it's still open
		if is_instance_valid(owner_win):
			var val_l := owner_win.find_child("FolderValueLabel", true, false) as Label
			if val_l:
				val_l.text       = dir
				val_l.modulate.a = 1.0
		# Trigger reload
		var midx := filtered_model_paths.find(path)
		if midx != -1:
			_on_model_selected(midx)
		fd.queue_free()
	)
	fd.canceled.connect(func() -> void: fd.queue_free())
	fd.popup_centered(Vector2i(800, 550))


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
	model_list.call_deferred("scroll_to_item", model_index)
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
			model_list.call_deferred("scroll_to_item", model_index)
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

	# W cycles wireframe mode only when mouse is OUTSIDE the viewport (inside = WASD movement)
	elif event.is_action_pressed("toggle_wireframe"):
		if viewport_container and viewport_container.current_model \
				and not viewport_container.mouse_in_viewport:
			viewport_container.toggle_wireframe()
			_update_wireframe_btn_text()
		get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════════════════
#  Model selection / display
# ══════════════════════════════════════════════════════════════════════════════
func _on_model_selected(index: int) -> void:
	print("3DViewModels: model selected index=", index)
	if index < 0 or index >= filtered_model_paths.size():
		return

	# If another async load is already in flight, ignore the new click.
	if not _loading_path.is_empty():
		return

	var model_path := filtered_model_paths[index]
	var file_name  := model_path.get_file()

	# Already showing this exact model — nothing to do.
	if model_path == _loaded_model_path:
		return

	# Apply per-model extra texture search dirs before any load path
	var _tex_folder := settings.get_texture_folder(model_path)
	var _tex_dirs: Array[String] = []
	if not _tex_folder.is_empty():
		_tex_dirs.append(_tex_folder)
	viewport_container.set_extra_texture_dirs(_tex_dirs)

	# ── Cache hit: instant restore, no thread needed ──────────────────────────
	if viewport_container.has_cached(model_path):
		_op_start_msec = Time.get_ticks_msec()   # keep threshold clock fresh so bar stays hidden
		var result := viewport_container.load_from_cache(model_path)
		if result != "Модель загружена успешно":
			_set_status("⚠  %s" % result, 10.0)
			_show_message("Ошибка загрузки", result)
		else:
			_loaded_model_path = model_path
			settings.set_setting("last_model", model_path)
			settings.add_recent_model(model_path)
			show_model_info(index)
			_set_status("✓  " + file_name, 8.0)
			_update_model_header()
			var cp := model_path; var ci := index
			get_tree().create_timer(0.1).timeout.connect(
				func() -> void: _capture_and_store_thumb(cp, ci), CONNECT_ONE_SHOT)
		return

	# ── Cache miss: start threaded async load ─────────────────────────────────
	_set_status("⏳ Загрузка %s..." % file_name)
	_op_start_msec = Time.get_ticks_msec()
	_loading_path  = model_path
	_loading_index = index

	# start_load_async emits "Очистка" and "Чтение" stage signals synchronously,
	# then spawns a Thread for the slow file I/O and returns immediately.
	viewport_container.start_load_async(model_path)


func _on_model_list_item_clicked(index: int, _at_pos: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT:
		var ctrl  := Input.is_key_pressed(KEY_CTRL)
		var shift := Input.is_key_pressed(KEY_SHIFT)
		if not ctrl and not shift:
			# Plain left-click: select only this item and load the model.
			# Calling directly because SELECT_MULTI toggles on re-click and
			# item_selected never fires when the item was already selected.
			model_list.select(index)   # single=true (default): deselects others
			_on_model_selected(index)
		# Ctrl/Shift: ItemList handles multi-selection naturally; don't load model.
		return

	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	if index < 0 or index >= filtered_model_paths.size():
		return

	# If right-clicked item is not in the current selection → select only it
	var sel := model_list.get_selected_items()
	if index not in sel:
		model_list.deselect_all()
		model_list.select(index)

	# Lazy-create the popup once
	if !_list_context_menu:
		_list_context_menu = PopupMenu.new()
		_list_context_menu.name = "ModelListContextMenu"
		add_child(_list_context_menu)
		_list_context_menu.id_pressed.connect(_on_list_context_menu_id_pressed)

	var sel_now    := model_list.get_selected_items()
	var n          := sel_now.size()
	var lbl        := "(%d)" % n if n > 1 else ""

	# Determine star state for selected items to show the right primary action
	var favs: Array    = settings.get_favorites()
	var all_fav := true
	var any_fav := false
	for si in sel_now:
		if si < filtered_model_paths.size():
			if filtered_model_paths[si] in favs:
				any_fav = true
			else:
				all_fav = false

	_list_context_menu.clear()
	_list_context_menu.add_item("📋  Копировать путь %s"              % lbl, 0)
	_list_context_menu.add_item("📋  Копировать путь + текстуры %s"   % lbl, 1)
	_list_context_menu.add_item("📂  Показать в проводнике %s"        % lbl, 2)
	_list_context_menu.add_item("📁  Копировать файлы в папку... %s"  % lbl, 5)
	_list_context_menu.add_separator()
	if all_fav:
		# All selected are already favourites → offer only removal
		_list_context_menu.add_item("★  Убрать из избранного %s"      % lbl, 4)
	elif any_fav:
		# Mixed: some in, some out — offer both
		_list_context_menu.add_item("☆  В избранное %s"               % lbl, 3)
		_list_context_menu.add_item("★  Убрать из избранного %s"      % lbl, 4)
	else:
		# None are favourites → offer only adding
		_list_context_menu.add_item("☆  В избранное %s"               % lbl, 3)
	_list_context_menu.position = DisplayServer.mouse_get_position()
	_list_context_menu.reset_size()
	_list_context_menu.popup()


# Returns model path  +  any associated material/texture file paths.
func _get_associated_files(model_path: String) -> Array[String]:
	var result: Array[String] = [model_path]
	var ext := model_path.get_extension().to_lower()

	# OBJ → companion .mtl file
	if ext == "obj":
		var mtl := model_path.get_basename() + ".mtl"
		if FileAccess.file_exists(mtl) and mtl not in result:
			result.append(mtl)

	# Currently loaded model → add real texture file paths via the viewport
	if model_path == _loaded_model_path and viewport_container \
			and viewport_container.has_method("get_texture_file_paths"):
		for p: String in viewport_container.get_texture_file_paths():
			if p not in result:
				result.append(p)

	return result


# ══════════════════════════════════════════════════════════════════════════════
#  Copy models + dependencies to a folder
# ══════════════════════════════════════════════════════════════════════════════

func _show_copy_dest_dialog(sel_paths: Array[String]) -> void:
	if !_copy_dest_dialog:
		_copy_dest_dialog = FileDialog.new()
		_copy_dest_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_copy_dest_dialog.access    = FileDialog.ACCESS_FILESYSTEM
		_copy_dest_dialog.title     = "Выберите папку назначения"
		_copy_dest_dialog.size      = Vector2(800, 600)
		_copy_dest_dialog.min_size  = Vector2(400, 300)
		_copy_dest_dialog.canceled.connect(func(): _copy_dest_dialog.hide())
		_copy_dest_dialog.dir_selected.connect(_on_copy_dest_dir_selected)
		add_child(_copy_dest_dialog)
	_pending_copy_paths = sel_paths.duplicate()
	_copy_dest_dialog.popup_centered()


func _on_copy_dest_dir_selected(target_dir: String) -> void:
	_copy_models_to_dir(_pending_copy_paths, target_dir)
	_pending_copy_paths.clear()


## Resolve a relative or absolute reference path against base_dir and add to deps if the file exists.
func _resolve_dep(ref_path: String, base_dir: String, deps: Array[String]) -> void:
	if ref_path.is_empty() or ref_path.begins_with("data:") or ref_path.begins_with("#"):
		return
	var abs_path: String
	if ref_path.is_absolute_path():
		abs_path = ref_path.simplify_path()
	else:
		abs_path = (base_dir + "/" + ref_path).simplify_path()
	if FileAccess.file_exists(abs_path) and abs_path not in deps:
		deps.append(abs_path)


## Parse OBJ file for referenced MTL files, then parse each MTL for texture maps.
func _parse_obj_deps(obj_path: String, dir: String, deps: Array[String]) -> void:
	var fa := FileAccess.open(obj_path, FileAccess.READ)
	if !fa:
		return
	var mtl_abs_list: Array[String] = []
	while !fa.eof_reached():
		var line := fa.get_line().strip_edges()
		if line.begins_with("mtllib "):
			var name := line.substr(7).strip_edges()
			_resolve_dep(name, dir, deps)
			var abs_mtl := (dir + "/" + name).simplify_path()
			if FileAccess.file_exists(abs_mtl) and abs_mtl not in mtl_abs_list:
				mtl_abs_list.append(abs_mtl)
	fa.close()
	for mtl_path in mtl_abs_list:
		_parse_mtl_deps(mtl_path, mtl_path.get_base_dir(), deps)


## Parse MTL file for texture map paths.
func _parse_mtl_deps(mtl_path: String, dir: String, deps: Array[String]) -> void:
	var fa := FileAccess.open(mtl_path, FileAccess.READ)
	if !fa:
		return
	while !fa.eof_reached():
		var line := fa.get_line().strip_edges()
		var low := line.to_lower()
		# Match any map_ directive or bump/disp/norm/refl shorthand
		var is_map := low.begins_with("map_") or low.begins_with("bump ") \
				or low.begins_with("disp ") or low.begins_with("norm ") \
				or low.begins_with("refl ")
		if not is_map:
			continue
		# The texture filename is the last token that doesn't start with '-'
		# (earlier tokens may be -option value pairs like "-s 1 1 1 filename")
		var parts := line.split(" ", false)
		var tex_name := ""
		var i := parts.size() - 1
		while i >= 1:
			if parts[i].begins_with("-"):
				i -= 2
			else:
				tex_name = parts[i]
				break
			i -= 1
		if tex_name != "":
			_resolve_dep(tex_name, dir, deps)
	fa.close()


## Parse GLTF JSON for external buffer (.bin) and image URIs.
func _parse_gltf_deps(gltf_path: String, dir: String, deps: Array[String]) -> void:
	var fa := FileAccess.open(gltf_path, FileAccess.READ)
	if !fa:
		return
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var gltf := parsed as Dictionary
	for section in ["buffers", "images"]:
		if not gltf.has(section):
			continue
		for entry: Variant in (gltf[section] as Array):
			if typeof(entry) == TYPE_DICTIONARY and (entry as Dictionary).has("uri"):
				_resolve_dep(str(entry["uri"]), dir, deps)


## Parse Collada (.dae) XML for <init_from> image references.
func _parse_dae_deps(dae_path: String, dir: String, deps: Array[String]) -> void:
	var parser := XMLParser.new()
	if parser.open(dae_path) != OK:
		return
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		if parser.get_node_name() != "init_from":
			continue
		if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
			var ref_path := parser.get_node_data().strip_edges()
			# Strip file:// prefix that some exporters add
			if ref_path.begins_with("file://"):
				ref_path = ref_path.substr(7)
			_resolve_dep(ref_path, dir, deps)


## Return all external file paths referenced by model_path (does not include model_path itself).
func _gather_model_deps(model_path: String) -> Array[String]:
	var deps: Array[String] = []
	var dir := model_path.get_base_dir()
	match model_path.get_extension().to_lower():
		"obj":  _parse_obj_deps(model_path, dir, deps)
		"gltf": _parse_gltf_deps(model_path, dir, deps)
		"dae":  _parse_dae_deps(model_path, dir, deps)
		# glb / fbx / blend — self-contained or binary; no text parsing needed
	return deps


## Find the deepest directory that is an ancestor of every path in the array.
func _common_base_dir(paths: Array[String]) -> String:
	if paths.is_empty():
		return ""
	var base := paths[0].get_base_dir()
	for i in range(1, paths.size()):
		var d := paths[i].get_base_dir()
		while d != base and not d.begins_with(base + "/"):
			var parent := base.get_base_dir()
			if parent == base:   # reached filesystem root
				break
			base = parent
	return base


func _plural_files(n: int) -> String:
	if n % 100 in range(11, 20):
		return "ов"
	match n % 10:
		1: return ""
		2, 3, 4: return "а"
		_: return "ов"


## Copy sel_paths and all their external dependencies into target_dir,
## preserving relative directory structure from the common ancestor.
func _copy_models_to_dir(sel_paths: Array[String], target_dir: String) -> void:
	_set_status("📋 Сбор зависимостей...")

	var all_files: Array[String] = []
	for model_path in sel_paths:
		if model_path not in all_files:
			all_files.append(model_path)
		for dep in _gather_model_deps(model_path):
			if dep not in all_files:
				all_files.append(dep)

	if all_files.is_empty():
		_set_status("⚠ Нет файлов для копирования", 5.0)
		return

	var base := _common_base_dir(all_files)
	var base_prefix := base + "/"    # used for prefix stripping

	_set_status("📋 Копирование %d файл%s..." % [all_files.size(), _plural_files(all_files.size())])

	var copied := 0
	var errors := 0

	for src_path in all_files:
		# Compute relative path from common base; fall back to filename-only
		var rel: String
		if src_path.begins_with(base_prefix):
			rel = src_path.substr(base_prefix.length())
		else:
			rel = src_path.get_file()

		var dst_path := (target_dir + "/" + rel).simplify_path()
		var dst_dir  := dst_path.get_base_dir()

		if not DirAccess.dir_exists_absolute(dst_dir):
			var mk_err := DirAccess.make_dir_recursive_absolute(dst_dir)
			if mk_err != OK:
				push_error("Cannot create dir: %s (%s)" % [dst_dir, mk_err])
				errors += 1
				continue

		var cp_err := DirAccess.copy_absolute(src_path, dst_path)
		if cp_err == OK:
			copied += 1
		else:
			push_error("Copy failed: %s → %s (%s)" % [src_path, dst_path, cp_err])
			errors += 1

	var msg := "✓ Скопировано %d файл%s в %s" % [
		copied, _plural_files(copied), target_dir.get_file()
	]
	if errors > 0:
		msg += " (ошибок: %d)" % errors
	_set_status(msg, 10.0)


func _on_list_context_menu_id_pressed(id: int) -> void:
	var sel_indices := model_list.get_selected_items()
	if sel_indices.is_empty():
		return

	# Build list of selected model paths
	var sel_paths: Array[String] = []
	for i in sel_indices:
		if i < filtered_model_paths.size():
			sel_paths.append(filtered_model_paths[i])
	if sel_paths.is_empty():
		return

	match id:
		0:  # ── Copy model paths only ────────────────────────────────────────
			DisplayServer.clipboard_set("\n".join(sel_paths))

		1:  # ── Copy paths + textures / materials ───────────────────────────
			var all_files: Array[String] = []
			for p in sel_paths:
				for f in _get_associated_files(p):
					if f not in all_files:
						all_files.append(f)
			DisplayServer.clipboard_set("\n".join(all_files))

		2:  # ── Show in file manager (multi-select aware) ──────────────────
			_reveal_in_explorer(sel_paths)

		3:  # ── Add to favourites ──────────────────────────────────────────────
			_modify_favorites(sel_paths, true)

		4:  # ── Remove from favourites ────────────────────────────────────────
			_modify_favorites(sel_paths, false)

		5:  # ── Copy files (model + deps) to a folder ────────────────────────
			_show_copy_dest_dialog(sel_paths)


# ── Reveal in file manager (single or multi-file) ───────────────────────────
func _reveal_in_explorer(paths: Array[String]) -> void:
	if paths.is_empty():
		return

	# Group paths by their parent directory
	var by_dir: Dictionary = {}
	for p in paths:
		var d := p.get_base_dir()
		if not by_dir.has(d):
			by_dir[d] = []
		by_dir[d].append(p)

	for dir_key in by_dir.keys():
		var dir_files: Array = by_dir[dir_key]
		if OS.get_name() == "Windows":
			# On Windows use explorer /select for both single and multi-file:
			# it scrolls the view to the selected file (more reliable than
			# SHOpenFolderAndSelectItems which can leave the selection off-screen).
			_windows_select_multiple(dir_key, dir_files)
		else:
			OS.shell_show_in_file_manager(dir_files[0])


func _windows_select_multiple(folder: String, files: Array) -> void:
	var win_folder := folder.replace("/", "\\")
	var esc_folder := win_folder.replace("'", "''")   # PS single-quote escape

	var parts: PackedStringArray = []

	# Step 1: open Explorer and scroll to the first file.
	# "explorer /select,path" is the most reliable way to both select AND scroll.
	# We build the /select argument inside PowerShell using [char]34 (double-quote)
	# to sidestep OS.create_process quoting issues with paths that have spaces.
	var f0_win := (files[0] as String).replace("/", "\\").replace("'", "''")
	parts.append(
		"explorer.exe ('/select,' + [char]34 + '" + f0_win + "' + [char]34)"
	)

	if files.size() > 1:
		# Step 2: wait for the Explorer window, then extend the selection.
		parts.append("Start-Sleep -Milliseconds 1200")
		parts.append("$sh=New-Object -ComObject Shell.Application")
		parts.append("$fd=$sh.NameSpace('" + esc_folder + "')")
		parts.append("if($null -eq $fd){exit}")
		# Case-insensitive, trailing-backslash-tolerant comparison
		parts.append("$tgt='" + esc_folder + "'.TrimEnd('\\')")
		parts.append(
			"$wnd=$sh.Windows()" +
			"|Where-Object{try{$_.Document.Folder.Self.Path.TrimEnd('\\') -ieq $tgt}catch{$false}}" +
			"|Select-Object -First 1"
		)
		parts.append("if($null -eq $wnd){exit}")
		# Re-select first file (flag 1 = select-only, syncs with explorer's own state)
		var fname0 := (files[0] as String).get_file().replace("'", "''")
		parts.append(
			"$it=$fd.ParseName('" + fname0 + "');if($null -ne $it){$wnd.Document.SelectItem($it,1)}"
		)
		# Add remaining files (flag 3 = add to existing selection)
		for i in range(1, files.size()):
			var fname := (files[i] as String).get_file().replace("'", "''")
			parts.append(
				"$it=$fd.ParseName('" + fname + "');if($null -ne $it){$wnd.Document.SelectItem($it,3)}"
			)

	var cmd := ";".join(parts)
	OS.create_process("powershell.exe",
		["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", cmd])


func _on_select_project_pressed() -> void:
	if file_dialog:
		file_dialog.popup_centered()


func _on_project_dir_selected(dir: String) -> void:
	settings.set_setting("last_directory", dir)
	settings.add_recent_folder(dir)          # ← remember folder in recent list
	settings.save_settings()
	file_dialog.current_dir = dir

	model_paths.clear()
	filtered_model_paths.clear()
	model_list.clear()
	viewport_container.clear_model()
	if model_info_panel and model_info_panel.has_method("clear_info"):
		model_info_panel.clear_info()

	scan_project_models(dir)


# Track whether this is a top-level scan call (not a recursive sub-dir call).
var _scan_depth: int = 0

func scan_project_models(path: String) -> void:
	_scan_depth += 1
	if _scan_depth == 1:
		_set_status("🔍 Сканирование %s..." % path.get_file())
		if _prog_stage_label:
			_prog_stage_label.text = "🔍 Сканирование %s..." % path.get_file()
		_op_start_msec = Time.get_ticks_msec()
		_show_progress(5.0)   # threshold not yet reached — window stays hidden for fast scans
		print("3DViewModels: scanning models in ", path)

	var dir := DirAccess.open(path)
	if !dir:
		push_error("Failed to open directory: " + path)
		_scan_depth -= 1
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

	_scan_depth -= 1
	if _scan_depth == 0:
		# Deferred so model_paths is fully populated before we read the count.
		call_deferred("_finish_scan")


func _finish_scan() -> void:
	update_model_list(search_box.text if search_box else "")
	_set_status("📂 Найдено: %d %s" % [
		model_paths.size(),
		_plural_models(model_paths.size())
	], 6.0)
	if _prog_overlay and _prog_overlay.modulate.a >= 1.0:
		_show_progress(100.0)
		await get_tree().create_timer(0.4).timeout
	_hide_progress()


func _plural_models(n: int) -> String:
	if n % 100 in range(11, 20):
		return "моделей"
	match n % 10:
		1: return "модель"
		2, 3, 4: return "модели"
		_: return "моделей"


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
#  List tabs (All / Favorites)
# ══════════════════════════════════════════════════════════════════════════════
func _create_list_tabs() -> void:
	if not model_list:
		return
	# ModelContainer is an HBoxContainer — we must go one level up to the
	# VBoxContainer (left_panel) so the tabs row sits ABOVE the list, not beside it.
	var model_container := model_list.get_parent()          # HBoxContainer
	var left_vbox       := model_container.get_parent()     # VBoxContainer

	var tabs_bar := HBoxContainer.new()
	tabs_bar.name = "ListTabsBar"
	tabs_bar.add_theme_constant_override("separation", 0)
	tabs_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var btn_group := ButtonGroup.new()
	btn_group.pressed.connect(_on_tab_btn_pressed)

	_tab_all_btn = Button.new()
	_tab_all_btn.name                    = "TabAllBtn"
	_tab_all_btn.text                    = "Все"
	_tab_all_btn.toggle_mode             = true
	_tab_all_btn.button_pressed          = true
	_tab_all_btn.button_group            = btn_group
	_tab_all_btn.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	_tab_all_btn.custom_minimum_size     = Vector2(0, 28)
	_tab_all_btn.clip_text               = true

	_tab_fav_btn = Button.new()
	_tab_fav_btn.name                    = "TabFavBtn"
	_tab_fav_btn.text                    = "★ Избранное"
	_tab_fav_btn.toggle_mode             = true
	_tab_fav_btn.button_pressed          = false
	_tab_fav_btn.button_group            = btn_group
	_tab_fav_btn.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	_tab_fav_btn.custom_minimum_size     = Vector2(0, 28)
	_tab_fav_btn.clip_text               = true

	tabs_bar.add_child(_tab_all_btn)
	tabs_bar.add_child(_tab_fav_btn)

	# Insert tabs_bar directly above ModelContainer in the VBoxContainer
	left_vbox.add_child(tabs_bar)
	left_vbox.move_child(tabs_bar, model_container.get_index())


func _on_tab_btn_pressed(btn: BaseButton) -> void:
	_active_tab = 0 if btn == _tab_all_btn else 1
	update_model_list(search_box.text if search_box else "")


# ══════════════════════════════════════════════════════════════════════════════
#  Status bar
# ══════════════════════════════════════════════════════════════════════════════
func _create_status_bar() -> void:
	if not left_panel:
		return

	var bg := PanelContainer.new()
	bg.name = "StatusBarBg"
	bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color              = Color(0.10, 0.10, 0.10, 0.85)
	panel_style.content_margin_left   = 5
	panel_style.content_margin_right  = 5
	panel_style.content_margin_top    = 2
	panel_style.content_margin_bottom = 2
	bg.add_theme_stylebox_override("panel", panel_style)

	_status_label = Label.new()
	_status_label.name                  = "StatusLabel"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.clip_text             = true
	_status_label.custom_minimum_size   = Vector2(0, 18)
	_status_label.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 11)
	bg.add_child(_status_label)

	left_panel.add_child(bg)   # last → very bottom of left panel


# ══════════════════════════════════════════════════════════════════════════════
#  Progress overlay  (CanvasLayer panel — same OS window, no jerk)
# ══════════════════════════════════════════════════════════════════════════════
func _create_progress_window() -> void:
	# A CanvasLayer keeps the overlay inside the same OS window so that
	# RenderingServer.force_draw() can paint it immediately during a blocking
	# GDScript call, without needing the OS event loop to pump a new window.
	var canvas := CanvasLayer.new()
	canvas.layer = 128
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.name              = "ProgressOverlay"
	panel.mouse_filter      = Control.MOUSE_FILTER_IGNORE
	# Anchor to the exact centre of the viewport
	panel.anchor_left       = 0.5
	panel.anchor_right      = 0.5
	panel.anchor_top        = 0.5
	panel.anchor_bottom     = 0.5
	panel.offset_left       = -190.0
	panel.offset_right      =  190.0
	panel.offset_top        = -48.0
	panel.offset_bottom     =  48.0
	panel.modulate          = Color(1, 1, 1, 0)   # invisible until needed

	var ps := StyleBoxFlat.new()
	ps.bg_color           = Color(0.11, 0.11, 0.14, 0.96)
	ps.border_color       = Color(0.30, 0.30, 0.36)
	ps.border_width_left  = 1
	ps.border_width_right = 1
	ps.border_width_top   = 1
	ps.border_width_bottom= 1
	ps.set_corner_radius_all(6)
	ps.shadow_color       = Color(0, 0, 0, 0.45)
	ps.shadow_size        = 6
	ps.content_margin_left   = 12
	ps.content_margin_right  = 12
	ps.content_margin_top    = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	canvas.add_child(panel)
	_prog_overlay = panel

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_prog_stage_label = Label.new()
	_prog_stage_label.clip_text             = true
	_prog_stage_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prog_stage_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_prog_stage_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	_progress_bar = ProgressBar.new()
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_bar.custom_minimum_size   = Vector2(0, 20)
	_progress_bar.show_percentage       = false
	_progress_bar.min_value             = 0.0
	_progress_bar.max_value             = 100.0
	_progress_bar.value                 = 0.0

	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = Color(0.15, 0.60, 1.00)   # vivid blue fill
	_progress_bar.add_theme_stylebox_override("fill", fill_sb)

	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = Color(0.06, 0.06, 0.09)     # near-black trough
	_progress_bar.add_theme_stylebox_override("background", bg_sb)

	row.add_child(_progress_bar)

	_prog_pct_label = Label.new()
	_prog_pct_label.text                  = "0%"
	_prog_pct_label.custom_minimum_size.x = 38
	_prog_pct_label.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	_prog_pct_label.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	_prog_pct_label.add_theme_font_size_override("font_size", 12)
	row.add_child(_prog_pct_label)


## Make the overlay visible at `value` percent (0–100).
## Only becomes visible once PROGRESS_THRESHOLD_MS has elapsed since
## _op_start_msec was set — fast operations never trigger it.
func _show_progress(value: float) -> void:
	if not _prog_overlay or not _progress_bar:
		return
	var clamped := clampf(value, 0.0, 100.0)
	_progress_bar.value = clamped
	if _prog_pct_label:
		_prog_pct_label.text = "%d%%" % int(clamped)
	if _prog_overlay.modulate.a < 1.0:
		if Time.get_ticks_msec() - _op_start_msec < PROGRESS_THRESHOLD_MS:
			return   # too fast — keep hidden, just track value
		_prog_overlay.modulate = Color.WHITE


## Hide the overlay and reset the bar.
func _hide_progress() -> void:
	if _prog_overlay:
		_prog_overlay.modulate = Color(1, 1, 1, 0)
	if _progress_bar:
		_progress_bar.value = 0.0
	if _prog_pct_label:
		_prog_pct_label.text = "0%"
	if _prog_stage_label:
		_prog_stage_label.text = ""


## Show `text` in the status bar.
## Pass auto_clear_sec > 0 to auto-erase the message after that many seconds.
## Pass 0 to keep the message until the next _set_status call.
func _set_status(text: String, auto_clear_sec: float = 0.0) -> void:
	if not _status_label:
		return
	_status_label.text = text
	if auto_clear_sec > 0.0:
		var snap := text   # capture for closure
		get_tree().create_timer(auto_clear_sec).timeout.connect(
			func() -> void:
				if _status_label and _status_label.text == snap:
					_status_label.text = ""
		, CONNECT_ONE_SHOT)


## Receives stage text emitted by view_model during loading.
## Pre-thread stages (Очистка/Чтение) get low %s so the time-based fake
## progress in _process() takes over. Post-thread stages (Добавление/Настройка/
## Построение) are always above the fake-progress ceiling (~78%) so the bar
## never goes backward.
func _on_loading_stage(text: String) -> void:
	if not _status_label:
		return

	if text.is_empty():
		_show_progress(100.0)
		return

	_status_label.text = text
	if _prog_stage_label:
		_prog_stage_label.text = text

	var pct: float
	if   text.begins_with("Очистка"):    pct =  5.0
	elif text.begins_with("Чтение"):     pct = 10.0
	elif text.begins_with("Добавление"): pct = 85.0
	elif text.begins_with("Настройка"):  pct = 90.0
	elif text.begins_with("Построение"): pct = 96.0
	elif text.begins_with("Ошибка"):     pct = 100.0
	else:                                pct = 50.0

	_show_progress(pct)


# ── Favorites helpers ─────────────────────────────────────────────────────────
func _modify_favorites(paths: Array[String], add: bool) -> void:
	var favs: Array = settings.get_favorites()
	for p in paths:
		if add:
			if p not in favs:
				favs.append(p)
		else:
			favs.erase(p)
	settings.set_favorites(favs)
	update_model_list(search_box.text if search_box else "")


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

	var filter  := search_text.to_lower()
	var favs: Array = settings.get_favorites()

	# Build source list depending on active tab.
	# Favorites tab shows ALL saved favorites that still exist on disk —
	# independent of the currently scanned directory.
	var source: Array = model_paths
	if _active_tab == 1:
		source = []
		for p: String in favs:
			if FileAccess.file_exists(p):
				source.append(p)

	for path: String in source:
		var file_name := path.get_file().to_lower()
		if not filter.is_empty() and not file_name.contains(filter):
			continue
		filtered_model_paths.append(path)

		# In "All" tab mark favourite items with a star prefix.
		var display_name := path.get_file()
		if _active_tab == 0 and path in favs:
			display_name = "★ " + display_name

		var item_index := model_list.add_item(display_name)
		model_list.set_item_tooltip(item_index, path)
		var icon: ImageTexture = _thumb_cache.get(path, null) as ImageTexture
		if not icon:
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
	# Capture whatever is currently rendered — no camera movement needed
	# (the viewport has already rendered the model by the time this runs).
	var tex: ImageTexture = viewport_container.capture_thumbnail(Vector2i(128, 128))
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

	# Rebuild popup every time it opens so it always shows current data.
	# IDs: folders use IDs 0..99, models use IDs 100..199.
	recent_btn.about_to_popup.connect(func():
		var popup   := recent_btn.get_popup()
		popup.clear()

		var folders: Array = settings.get_recent_folders()
		var models:  Array = settings.get_recent_models()

		# ── Folders ──
		if not folders.is_empty():
			for i: int in folders.size():
				var label := "📁 " + str(folders[i]).rstrip("/\\").get_file()
				popup.add_item(label, i)          # ID = i  (0-based)
				popup.set_item_tooltip(popup.item_count - 1, str(folders[i]))

		# ── Separator ──
		if not folders.is_empty() and not models.is_empty():
			popup.add_separator("Модели")

		# ── Models ──
		if not models.is_empty():
			for i: int in models.size():
				popup.add_item(str(models[i]).get_file(), 100 + i)  # ID = 100+i
				popup.set_item_tooltip(popup.item_count - 1, str(models[i]))

		# ── Nothing at all ──
		if folders.is_empty() and models.is_empty():
			popup.add_item("Нет недавних", 0)
			popup.set_item_disabled(0, true)
	)

	# Use IDs (not indices) so the separator row doesn't throw off the lookup.
	recent_btn.get_popup().id_pressed.connect(func(id: int):
		if id < 100:
			# ── Folder item ──
			var folders: Array = settings.get_recent_folders()
			if id < folders.size():
				_on_project_dir_selected(str(folders[id]))
		else:
			# ── Model item ──
			var models: Array = settings.get_recent_models()
			var m_idx  := id - 100
			if m_idx < models.size():
				var path := str(models[m_idx])
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
		model_list.call_deferred("scroll_to_item", idx)
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


func _update_wireframe_btn_text() -> void:
	var btn := _get_toolbar_btn("WireframeToggleBtn")
	if !btn or !viewport_container:
		return
	var labels := ["Каркас", "Поверх▪", "Каркас■"]
	btn.text = labels[viewport_container.wireframe_mode]


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
			model_list.call_deferred("scroll_to_item", first_index)
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
