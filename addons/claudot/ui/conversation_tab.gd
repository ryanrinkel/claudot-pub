@tool
extends VBoxContainer

## ConversationTab - Dedicated conversation UI tab for Claude Code interaction
##
## Provides conversation UI with toolbar (clear button), message display,
## input field, context menu, and 100-message ring buffer.

class_name ConversationTab

# Preload utilities
const MessageFormatter = preload("res://addons/claudot/ui/message_formatter.gd")
const ConversationStorage = preload("res://addons/claudot/ui/conversation_storage.gd")

# Signals
signal message_submitted(text: String)  # Emitted when user submits a message
signal clear_confirmed()  # Emitted when user confirms clear action
signal user_input_submitted(answer: Dictionary)  # Emitted when user answers an input widget
signal ask_user_answered(text: String)  # Emitted when user answers an AskUserQuestion tool call
signal permission_answered(decision: String)  # Emitted when user allows/denies a tool permission request
signal stop_requested  # Emitted when user clicks the stop button to interrupt Claude

# State
var conversation: Array = []
var message_count: int = 0
const MAX_DISPLAY_MESSAGES = 100

# Smart auto-scroll state
var scroll_indicator_button: Button
const BOTTOM_THRESHOLD = 20

# Interactive input widget state
var _input_widget: PanelContainer = null  # nil when not showing
var _ask_user_mode: bool = false  # true when widget serves AskUserQuestion (vs MCP request_user_input)
var _permission_mode: bool = false  # true when widget serves a tool permission request

# Message history navigation (Phase 29: HIST-01 through HIST-04)
var _input_history: Array[String] = []
var _history_cursor: int = -1
var _history_draft: String = ""
const MAX_INPUT_HISTORY: int = 200

# Autocomplete scaffolding (Phases 30 and 31 depend on these)
var _suppress_autocomplete: bool = false
var _autocomplete_panel = null
var _slash_commands: Array = []
var _slash_commands_loaded: bool = false
var _autocomplete_mode: String = ""       # "" | "slash" | "at"
var _at_trigger_pos: int = -1             # Index of "@" char that opened popup; -1 when closed
var _project_files: Array = []            # Array of {path: String, name: String}
var _project_files_loaded: bool = false

# Context window usage tracking
var _context_pct: float = 0.0  # Last known context window usage percentage

# UI node references
var confirmation_dialog: ConfirmationDialog
var scroll_container: ScrollContainer
var output: RichTextLabel
var message_input: LineEdit
var send_button: Button
var stop_button: Button
var working_label: Label


func _ready() -> void:
	# Build UI tree programmatically
	_build_ui()

	# Connect UI signals
	confirmation_dialog.confirmed.connect(_on_clear_confirmed)
	message_input.text_submitted.connect(_on_input_submitted)
	send_button.pressed.connect(_on_send_pressed)
	scroll_indicator_button.pressed.connect(_on_scroll_indicator_pressed)

	# Connect scrollbar for smart auto-scroll
	var scrollbar = scroll_container.get_v_scroll_bar()
	if scrollbar:
		scrollbar.value_changed.connect(_on_scrollbar_value_changed)

	# Connect autocomplete triggers
	message_input.text_changed.connect(_on_message_input_text_changed)
	message_input.focus_exited.connect(_hide_autocomplete_panel)

	# Invalidate file cache when project files change
	var efs = EditorInterface.get_resource_filesystem()
	if efs:
		efs.filesystem_changed.connect(func(): _project_files_loaded = false)

	# Setup context menu on output
	_setup_context_menu()


func _input(event: InputEvent) -> void:
	## Intercept Up/Down/Escape/Tab/Enter for history navigation and autocomplete.
	## Must be on the parent VBoxContainer, not the LineEdit -- LineEdit consumes
	## these keys internally before gui_input fires (GitHub #95411, by-design).
	if not message_input.has_focus():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
		KEY_UP:
			get_viewport().set_input_as_handled()
			if _autocomplete_panel != null and _autocomplete_panel.visible:
				_autocomplete_select_prev()
			else:
				_history_navigate(-1)
		KEY_DOWN:
			get_viewport().set_input_as_handled()
			if _autocomplete_panel != null and _autocomplete_panel.visible:
				_autocomplete_select_next()
			else:
				_history_navigate(1)
		KEY_ESCAPE:
			if _autocomplete_panel != null and _autocomplete_panel.visible:
				get_viewport().set_input_as_handled()
				_hide_autocomplete_panel()
		KEY_TAB:
			if _autocomplete_panel != null and _autocomplete_panel.visible:
				get_viewport().set_input_as_handled()
				var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
				if item_list and item_list.get_selected_items().size() > 0:
					if _autocomplete_mode == "at":
						_accept_at_suggestion(item_list.get_selected_items()[0])
					else:
						_accept_slash_suggestion(item_list.get_selected_items()[0])
		KEY_ENTER:
			if _autocomplete_panel != null and _autocomplete_panel.visible:
				get_viewport().set_input_as_handled()
				var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
				if item_list and item_list.get_selected_items().size() > 0:
					if _autocomplete_mode == "at":
						_accept_at_suggestion(item_list.get_selected_items()[0])
					else:
						_accept_slash_suggestion(item_list.get_selected_items()[0])


func _history_navigate(direction: int) -> void:
	## Navigate history. direction=-1 goes to older messages (Up), +1 goes newer (Down).
	## Uses explicit direction branches instead of clampi to correctly handle the
	## -1 sentinel (draft position) which is not a valid array index.
	if _input_history.is_empty():
		return

	if direction == -1:  # Up -- move toward older entries
		if _history_cursor == -1:
			# First Up from draft: save draft text, jump to newest entry
			_history_draft = message_input.text
			_suppress_autocomplete = true
			_history_cursor = _input_history.size() - 1
		elif _history_cursor > 0:
			# Already in history: move one step older
			_history_cursor -= 1
		else:
			# cursor == 0: already at oldest entry, no-op
			return
		message_input.text = _input_history[_history_cursor]
		message_input.caret_column = _input_history[_history_cursor].length()
	else:  # Down -- move toward newer entries / draft
		if _history_cursor == -1:
			return  # Already at draft position, nothing to do
		_history_cursor += 1
		if _history_cursor >= _input_history.size():
			# Past the newest entry: restore draft
			_history_cursor = -1
			_suppress_autocomplete = false
			message_input.text = _history_draft
			message_input.caret_column = _history_draft.length()
			_history_draft = ""
		else:
			message_input.text = _input_history[_history_cursor]
			message_input.caret_column = _input_history[_history_cursor].length()


func _autocomplete_select_prev() -> void:
	## Move selection one step up (toward earlier items) in the autocomplete list.
	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	if item_list == null:
		return
	var selected = item_list.get_selected_items()
	if selected.is_empty():
		item_list.select(item_list.item_count - 1)
	elif selected[0] > 0:
		item_list.select(selected[0] - 1)
	# At index 0: stay (no wrapping)
	item_list.ensure_current_is_visible()


func _autocomplete_select_next() -> void:
	## Move selection one step down (toward later items) in the autocomplete list.
	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	if item_list == null:
		return
	var selected = item_list.get_selected_items()
	if selected.is_empty():
		item_list.select(0)
	elif selected[0] < item_list.item_count - 1:
		item_list.select(selected[0] + 1)
	# At last index: stay (no wrapping)
	item_list.ensure_current_is_visible()


func _on_message_input_text_changed(new_text: String) -> void:
	## Called when the message input text changes. Triggers autocomplete evaluation
	## unless suppressed (e.g. during history navigation or suggestion acceptance).
	if _suppress_autocomplete:
		return
	_evaluate_autocomplete_trigger(new_text)


func _evaluate_autocomplete_trigger(text: String) -> void:
	## Detect slash or @ prefix and show/hide autocomplete popup accordingly.
	## Slash trigger takes priority and is checked first with early return.
	var caret: int = message_input.caret_column
	var before_caret: String = text.left(caret)

	# Slash trigger: starts with "/" and no space before caret (unchanged logic)
	if before_caret.begins_with("/") and " " not in before_caret:
		var partial: String = before_caret.substr(1)
		_autocomplete_mode = "slash"
		_at_trigger_pos = -1
		_show_slash_suggestions(partial)
		return

	# @ trigger: search backward from caret for "@" at a word boundary
	var at_pos: int = _find_at_trigger(text, caret)
	if at_pos != -1:
		var query: String = text.substr(at_pos + 1, caret - at_pos - 1)
		if " " not in query:
			_autocomplete_mode = "at"
			_at_trigger_pos = at_pos
			_show_at_suggestions(query)
			return

	_autocomplete_mode = ""
	_at_trigger_pos = -1
	_hide_autocomplete_panel()


func _load_slash_commands() -> void:
	## Lazy one-time scan: load built-in slash commands and scan ~/.claude/commands/
	## and ~/.claude/skills/ for custom commands. Results are alphabetically sorted.
	if _slash_commands_loaded:
		return
	_slash_commands_loaded = true

	_slash_commands = ["clear", "compact", "cost", "help", "memory", "model",
		"permissions", "plan", "review", "status", "vim"]

	var home: String = OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	if home.is_empty():
		return

	var custom_commands = _scan_command_dir_for_names(home.path_join(".claude/commands"))
	for cmd in custom_commands:
		_slash_commands.append(cmd)

	var skill_commands = _scan_skills_dir_for_names(home.path_join(".claude/skills"))
	for cmd in skill_commands:
		_slash_commands.append(cmd)

	_slash_commands.sort()


func _scan_command_dir_for_names(dir_path: String) -> Array:
	## Scan a commands directory for .md files. Returns array of command name strings.
	## Supports nested subdirectory structure: subdir/file.md -> "subdir:file".
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return []

	var result: Array = []
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				# Recurse into subdirectory
				var sub_dir_path = dir_path.path_join(entry)
				var sub_dir = DirAccess.open(sub_dir_path)
				if sub_dir != null:
					sub_dir.list_dir_begin()
					var sub_entry = sub_dir.get_next()
					while sub_entry != "":
						if not sub_dir.current_is_dir() and sub_entry.ends_with(".md"):
							var full_path = sub_dir_path.path_join(sub_entry)
							var name_found = _extract_frontmatter_name(full_path)
							if not name_found.is_empty():
								result.append(name_found)
							else:
								var base = sub_entry.get_basename()
								result.append(entry + ":" + base)
						sub_entry = sub_dir.get_next()
					sub_dir.list_dir_end()
		elif entry.ends_with(".md"):
			# Top-level .md file: use basename as command name
			result.append(entry.get_basename())
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func _scan_skills_dir_for_names(dir_path: String) -> Array:
	## Scan a skills directory for subdirs containing SKILL.md. Returns command names.
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return []

	var result: Array = []
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry != "." and entry != "..":
			var skill_md_path = dir_path.path_join(entry).path_join("SKILL.md")
			if FileAccess.file_exists(skill_md_path):
				var name_found = _extract_frontmatter_name(skill_md_path)
				if not name_found.is_empty():
					result.append(name_found)
				else:
					result.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func _extract_frontmatter_name(file_path: String) -> String:
	## Read up to 20 lines of a markdown file looking for a frontmatter name: field.
	## Returns the name value or "" if not found.
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ""
	var in_frontmatter: bool = false
	var line_count: int = 0
	while not file.eof_reached() and line_count < 20:
		var line = file.get_line()
		line_count += 1
		if line.strip_edges() == "---":
			if not in_frontmatter:
				in_frontmatter = true
				continue
			else:
				break  # Second --- closes frontmatter
		if in_frontmatter and line.begins_with("name:"):
			var value = line.substr(5).strip_edges()
			# Strip surrounding quotes if present
			if (value.begins_with('"') and value.ends_with('"')) or \
				(value.begins_with("'") and value.ends_with("'")):
				value = value.substr(1, value.length() - 2)
			return value
	return ""


func _get_matching_commands(partial: String) -> Array:
	## Return all slash commands whose names contain 'partial' (case-insensitive substring match).
	if partial.is_empty():
		return _slash_commands.duplicate()
	var partial_lower = partial.to_lower()
	var matches: Array = []
	for entry in _slash_commands:
		if entry.to_lower().contains(partial_lower):
			matches.append(entry)
	return matches


func _build_autocomplete_panel() -> PanelContainer:
	## Create and return a styled PanelContainer with an ItemList for suggestions.
	var panel = PanelContainer.new()
	panel.name = "AutocompletePanel"

	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color("#1d2433")
	stylebox.border_color = Color("#4a5568")
	stylebox.border_width_left = 1
	stylebox.border_width_right = 1
	stylebox.border_width_top = 1
	stylebox.border_width_bottom = 1
	stylebox.corner_radius_top_left = 4
	stylebox.corner_radius_top_right = 4
	stylebox.corner_radius_bottom_left = 4
	stylebox.corner_radius_bottom_right = 4
	stylebox.content_margin_left = 4
	stylebox.content_margin_right = 4
	stylebox.content_margin_top = 4
	stylebox.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", stylebox)

	var item_list = ItemList.new()
	item_list.name = "SuggestionList"
	item_list.allow_reselect = true
	item_list.auto_height = true
	item_list.max_columns = 1
	item_list.item_activated.connect(_on_autocomplete_item_activated)
	panel.add_child(item_list)

	return panel


func _show_slash_suggestions(partial: String) -> void:
	## Show (or update) the autocomplete popup with commands matching 'partial'.
	_load_slash_commands()
	var matches = _get_matching_commands(partial)
	if matches.is_empty():
		_hide_autocomplete_panel()
		return

	if _autocomplete_panel == null:
		_autocomplete_panel = _build_autocomplete_panel()
		add_child(_autocomplete_panel)
		# Insert just before InputContainer (last child) in the VBox layout
		move_child(_autocomplete_panel, get_child_count() - 2)
		_autocomplete_panel.size_flags_vertical = 0

	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	item_list.clear()
	for match_entry in matches:
		item_list.add_item("/" + match_entry)
	item_list.select(0)
	_autocomplete_panel.visible = true

	# Cap height to ~10 items when list is long
	if matches.size() > 10:
		_autocomplete_panel.custom_minimum_size.y = 240
	else:
		_autocomplete_panel.custom_minimum_size.y = 0


func _hide_autocomplete_panel() -> void:
	## Free and nullify the autocomplete popup. Reset mode and trigger position.
	if _autocomplete_panel == null:
		return
	_autocomplete_panel.queue_free()
	_autocomplete_panel = null
	_autocomplete_mode = ""
	_at_trigger_pos = -1


func _accept_slash_suggestion(index: int) -> void:
	## Accept the suggestion at 'index': insert "/command " into the input field.
	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	var command_text: String = item_list.get_item_text(index)
	_suppress_autocomplete = true
	message_input.text = command_text + " "
	message_input.caret_column = message_input.text.length()
	_hide_autocomplete_panel()
	_suppress_autocomplete = false
	message_input.grab_focus()


func _find_at_trigger(text: String, caret: int) -> int:
	## Search backward from caret for "@" at a word boundary (preceded by space
	## or at start of string). Returns index of "@" or -1 if not found.
	## Stops immediately when a space is hit before finding "@".
	var i: int = caret - 1
	while i >= 0:
		var ch: String = text[i]
		if ch == "@":
			# Found "@" — valid if at start or preceded by a space
			if i == 0 or text[i - 1] == " ":
				return i
			else:
				return -1  # "@" mid-word (e.g. email@example)
		elif ch == " ":
			return -1  # Space hit before "@" — no trigger
		i -= 1
	return -1


func _load_project_files() -> void:
	## Lazy one-time scan of the project via EditorFileSystem.
	## Called on first @ trigger and when filesystem_changed fires.
	if _project_files_loaded:
		return
	_project_files = []
	var efs = EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	var root_dir = efs.get_filesystem()
	if root_dir == null:
		return  # Not ready yet — do NOT set loaded=true; retry on next trigger
	_collect_files_recursive(root_dir)
	# Sort: .gd files first alphabetically, then all others alphabetically
	var gd_files: Array = []
	var other_files: Array = []
	for entry in _project_files:
		if entry.name.ends_with(".gd"):
			gd_files.append(entry)
		else:
			other_files.append(entry)
	gd_files.sort_custom(func(a, b): return a.name < b.name)
	other_files.sort_custom(func(a, b): return a.name < b.name)
	_project_files = gd_files + other_files
	_project_files_loaded = true


func _collect_files_recursive(dir: EditorFileSystemDirectory) -> void:
	## Recursively collect files from an EditorFileSystemDirectory.
	## Skips .godot/ internal directories and noise files.
	var dir_path: String = dir.get_path()
	if ".godot/" in dir_path:
		return
	for i in range(dir.get_file_count()):
		var file_name: String = dir.get_file(i)
		if _is_noise_file(file_name):
			continue
		_project_files.append({
			"path": dir.get_file_path(i),
			"name": file_name
		})
	for i in range(dir.get_subdir_count()):
		_collect_files_recursive(dir.get_subdir(i))


func _is_noise_file(file_name: String) -> bool:
	## Return true if the file should be excluded from @ autocomplete results.
	return file_name.ends_with(".import") or file_name.ends_with(".uid") or file_name.ends_with(".tmp")


func _get_matching_files(query: String) -> Array:
	## Return up to 20 project files matching query (case-insensitive substring).
	## If query is empty, returns the first 20 files (already sorted .gd-first).
	_load_project_files()
	if query.is_empty():
		return _project_files.slice(0, 20)
	var query_lower: String = query.to_lower()
	var matches: Array = []
	for entry in _project_files:
		if entry.name.to_lower().contains(query_lower):
			matches.append(entry)
			if matches.size() >= 20:
				break
	return matches


func _show_at_suggestions(query: String) -> void:
	## Show (or update) the autocomplete popup with project files matching query.
	var matches = _get_matching_files(query)
	if matches.is_empty():
		_hide_autocomplete_panel()
		return

	if _autocomplete_panel == null:
		_autocomplete_panel = _build_autocomplete_panel()
		add_child(_autocomplete_panel)
		# Insert just before InputContainer (last child) in the VBox layout
		move_child(_autocomplete_panel, get_child_count() - 2)
		_autocomplete_panel.size_flags_vertical = 0

	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	item_list.clear()
	for entry in matches:
		item_list.add_item(entry.path)
	item_list.select(0)
	_autocomplete_panel.visible = true

	# Cap height to ~10 items when list is long
	if matches.size() > 10:
		_autocomplete_panel.custom_minimum_size.y = 240
	else:
		_autocomplete_panel.custom_minimum_size.y = 0


func _accept_at_suggestion(index: int) -> void:
	## Accept the file suggestion at index: replace @<partial> with @res://path token.
	## Uses caret-aware range replacement so surrounding text is preserved.
	var item_list = _autocomplete_panel.get_node("SuggestionList") as ItemList
	var file_path: String = item_list.get_item_text(index)
	var token: String = "@" + file_path + " "
	var trigger_pos: int = _at_trigger_pos
	var caret: int = message_input.caret_column
	var text: String = message_input.text
	# Validate trigger position is still within bounds
	if trigger_pos < 0 or trigger_pos >= text.length():
		_hide_autocomplete_panel()
		return
	var new_text: String = text.left(trigger_pos) + token + text.substr(caret)
	_suppress_autocomplete = true
	message_input.text = new_text
	message_input.caret_column = trigger_pos + token.length()
	_hide_autocomplete_panel()
	_suppress_autocomplete = false
	message_input.grab_focus()


func _on_autocomplete_item_activated(index: int) -> void:
	## Handle double-click or Enter on an ItemList item. Dispatch by mode.
	if _autocomplete_mode == "at":
		_accept_at_suggestion(index)
	else:
		_accept_slash_suggestion(index)


func _build_ui() -> void:
	## Build the entire conversation tab UI tree.

	# Toolbar at top
	var toolbar = HBoxContainer.new()
	toolbar.name = "Toolbar"
	add_child(toolbar)

	working_label = Label.new()
	working_label.name = "WorkingLabel"
	working_label.text = "Working..."
	working_label.add_theme_color_override("font_color", Color("#fabd2f"))
	working_label.add_theme_font_size_override("font_size", 11)
	working_label.visible = false
	toolbar.add_child(working_label)

	# Confirmation dialog for clear action
	confirmation_dialog = ConfirmationDialog.new()
	confirmation_dialog.name = "ConfirmationDialog"
	confirmation_dialog.dialog_text = "Clear conversation history? This cannot be undone."
	confirmation_dialog.title = "Confirm Clear"
	add_child(confirmation_dialog)

	# Scroll container with output
	scroll_container = ScrollContainer.new()
	scroll_container.name = "ScrollContainer"
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll_container)

	output = RichTextLabel.new()
	output.name = "Output"
	output.bbcode_enabled = true
	output.fit_content = true
	output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output.selection_enabled = true
	output.scroll_active = false  # Let ScrollContainer handle scrolling

	# Compact font sizes
	output.add_theme_font_size_override("normal_font_size", 12)
	output.add_theme_font_size_override("bold_font_size", 13)

	scroll_container.add_child(output)

	# Create "New messages" indicator button
	scroll_indicator_button = Button.new()
	scroll_indicator_button.name = "ScrollIndicator"
	scroll_indicator_button.text = "New messages"
	scroll_indicator_button.visible = false
	scroll_indicator_button.anchor_left = 1.0
	scroll_indicator_button.anchor_right = 1.0
	scroll_indicator_button.anchor_top = 1.0
	scroll_indicator_button.anchor_bottom = 1.0
	scroll_indicator_button.offset_left = -130
	scroll_indicator_button.offset_right = -10
	scroll_indicator_button.offset_top = -35
	scroll_indicator_button.offset_bottom = -5
	scroll_container.add_child(scroll_indicator_button)

	# Input container at bottom
	var input_container = HBoxContainer.new()
	input_container.name = "InputContainer"
	add_child(input_container)

	message_input = LineEdit.new()
	message_input.name = "MessageInput"
	message_input.placeholder_text = "Type a message..."
	message_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_container.add_child(message_input)

	send_button = Button.new()
	send_button.name = "SendButton"
	send_button.text = "Send"
	input_container.add_child(send_button)

	stop_button = Button.new()
	stop_button.name = "StopButton"
	stop_button.text = "\u{1F6D1}"
	stop_button.tooltip_text = "Stop Claude (interrupt)"
	stop_button.visible = false
	stop_button.pressed.connect(_on_stop_pressed)
	input_container.add_child(stop_button)


func _setup_context_menu() -> void:
	## Setup right-click context menu on output RichTextLabel.
	output.context_menu_enabled = true
	var menu = output.get_menu()

	if menu:
		menu.add_separator()
		menu.add_item("Copy Message", 100)
		menu.id_pressed.connect(_on_context_menu_id_pressed)


func _on_context_menu_id_pressed(id: int) -> void:
	## Handle context menu item selection.
	if id == 100:  # Copy Message
		var selected = output.get_selected_text()
		if selected.is_empty():
			# No selection, copy all text
			DisplayServer.clipboard_set(output.text)
		else:
			DisplayServer.clipboard_set(selected)


func _on_clear_pressed() -> void:
	## Handle Clear button - show confirmation dialog.
	confirmation_dialog.popup_centered()


func _on_clear_confirmed() -> void:
	## Handle confirmed clear action.
	# Clear storage
	ConversationStorage.clear_conversation()

	# Clear local state
	conversation.clear()
	message_count = 0

	# Clear UI
	output.clear()
	output.text = ""

	# Emit signal so chat_panel can send /clear to bridge
	clear_confirmed.emit()


func clear_conversation() -> void:
	## Clear conversation display and storage without emitting clear_confirmed.
	## Called by chat_panel when bridge sends chat/clear (e.g. responding to /clear).
	ConversationStorage.clear_conversation()
	conversation.clear()
	message_count = 0
	output.clear()
	output.text = ""


func _on_input_submitted(text: String) -> void:
	## Handle Enter key in message input.
	var stripped: String = text.strip_edges()
	if not stripped.is_empty():
		_hide_autocomplete_panel()
		# Append to history (deduplicate consecutive identical entries)
		if _input_history.is_empty() or _input_history.back() != stripped:
			_input_history.append(stripped)
			if _input_history.size() > MAX_INPUT_HISTORY:
				_input_history.pop_front()
		# Reset history navigation state
		_history_cursor = -1
		_history_draft = ""
		_suppress_autocomplete = false
		# Clear input and emit (existing behavior preserved)
		message_input.text = ""
		message_submitted.emit(stripped)
		message_input.grab_focus()  # Fix Godot focus loss bug
		# Re-lock auto-scroll: sending a message is an explicit "I'm back at bottom" gesture.
		# This ensures the user's own message and subsequent assistant replies are visible.
		scroll_indicator_button.visible = false
		_force_scroll_to_bottom()


func _on_send_pressed() -> void:
	## Handle Send button click.
	var text: String = message_input.text.strip_edges()
	if not text.is_empty():
		_hide_autocomplete_panel()
		# Append to history (deduplicate consecutive identical entries)
		if _input_history.is_empty() or _input_history.back() != text:
			_input_history.append(text)
			if _input_history.size() > MAX_INPUT_HISTORY:
				_input_history.pop_front()
		# Reset history navigation state
		_history_cursor = -1
		_history_draft = ""
		_suppress_autocomplete = false
		# Clear input and emit (existing behavior preserved)
		message_input.text = ""
		message_submitted.emit(text)
		message_input.grab_focus()
		# Re-lock auto-scroll: sending a message is an explicit "I'm back at bottom" gesture.
		# This ensures the user's own message and subsequent assistant replies are visible.
		scroll_indicator_button.visible = false
		_force_scroll_to_bottom()


func _on_stop_pressed() -> void:
	## Handle Stop button click — interrupt Claude's processing.
	stop_requested.emit()


func append_message(sender: String, content: String) -> void:
	## Append a message to the conversation display.
	# Check if user was at bottom before adding message
	var was_at_bottom = _is_at_bottom()

	# Format the message
	var formatted: String
	match sender:
		"user":
			formatted = MessageFormatter.format_user_message(content)
		"assistant":
			formatted = MessageFormatter.format_assistant_message(content)
		"system":
			formatted = MessageFormatter.format_system_message(content)
		_:
			formatted = MessageFormatter.format_system_message(content)

	# Append to output
	output.append_text(formatted)

	# Track message count and manage ring buffer
	message_count += 1
	if message_count > MAX_DISPLAY_MESSAGES:
		_prune_oldest_message()

	# Smart scroll: only auto-scroll if user was at bottom
	if was_at_bottom:
		_smart_scroll_to_bottom()
	else:
		scroll_indicator_button.visible = true

	# Add to conversation history
	conversation.append({"sender": sender, "content": content})


func append_system_message(content: String) -> void:
	## Shorthand for appending a system message.
	append_message("system", content)


func load_conversation(messages: Array) -> void:
	## Load conversation history from storage and restore to UI.
	for msg in messages:
		var formatted: String
		match msg.sender:
			"user":
				formatted = MessageFormatter.format_user_message(msg.content)
			"assistant":
				formatted = MessageFormatter.format_assistant_message(msg.content)
			"system":
				formatted = MessageFormatter.format_system_message(msg.content)
			_:
				formatted = MessageFormatter.format_system_message(msg.content)

		output.append_text(formatted)
		message_count += 1

	# Update conversation array to match loaded data
	conversation = messages

	# Always scroll to bottom on load
	_force_scroll_to_bottom()


func _prune_oldest_message() -> void:
	## Remove the oldest message from the display (ring buffer).
	# Strategy: Remove text up to the second \n\n delimiter
	var text = output.text
	var first_delim = text.find("\n\n")

	if first_delim == -1:
		# No delimiter found, something went wrong - don't prune
		return

	var second_delim = text.find("\n\n", first_delim + 2)

	if second_delim == -1:
		# Only one message, don't prune (need at least 2)
		return

	# Remove everything up to and including the second delimiter
	output.text = text.substr(second_delim + 2)
	message_count -= 1


func _force_scroll_to_bottom() -> void:
	## Force scroll to bottom of output area (with process_frame delay).
	await get_tree().process_frame

	var scrollbar = scroll_container.get_v_scroll_bar()
	if scrollbar:
		scrollbar.value = scrollbar.max_value


func _smart_scroll_to_bottom() -> void:
	## Smart scroll to bottom when user is already at bottom.
	await get_tree().process_frame

	var scrollbar = scroll_container.get_v_scroll_bar()
	if scrollbar:
		scrollbar.value = scrollbar.max_value
		scroll_indicator_button.visible = false


func _is_at_bottom() -> bool:
	## Check if user is currently scrolled to bottom.
	var scrollbar = scroll_container.get_v_scroll_bar()
	if not scrollbar:
		return true  # Safe default if no scrollbar

	var distance_from_bottom = (scrollbar.max_value - scroll_container.size.y) - scrollbar.value
	return distance_from_bottom <= BOTTOM_THRESHOLD


func _on_scrollbar_value_changed(value: float) -> void:
	## Handle scrollbar changes to hide indicator when user scrolls to bottom.
	if _is_at_bottom():
		scroll_indicator_button.visible = false


func _on_scroll_indicator_pressed() -> void:
	## Handle "New messages" indicator button click.
	_force_scroll_to_bottom()


func set_working(working: bool) -> void:
	## Show or hide the working indicator and toggle input availability.
	if working_label:
		working_label.visible = working
		if working:
			_context_pct = 0.0
			_update_working_text()
		else:
			_context_pct = 0.0
	if message_input:
		message_input.editable = not working
	if send_button:
		send_button.disabled = working
	if stop_button:
		stop_button.visible = working


func update_context_usage(pct: float) -> void:
	## Update context window usage percentage and refresh working label text.
	_context_pct = pct
	if working_label and working_label.visible:
		_update_working_text()


func _update_working_text() -> void:
	## Set working label text with optional context usage percentage.
	if _context_pct > 0.0:
		working_label.text = "Working... [%s%% ctx]" % str(snapped(_context_pct, 0.1))
		# Color-code: green < 50%, yellow 50-75%, red > 75%
		if _context_pct > 75.0:
			working_label.add_theme_color_override("font_color", Color("#fb4934"))  # Red
		elif _context_pct > 50.0:
			working_label.add_theme_color_override("font_color", Color("#fabd2f"))  # Yellow
		else:
			working_label.add_theme_color_override("font_color", Color("#8ec07c"))  # Green
	else:
		working_label.text = "Working..."
		working_label.add_theme_color_override("font_color", Color("#fabd2f"))  # Default yellow


# ─── Interactive Input Widget (Phase 25) ─────────────────────────────────────

func _show_input_widget(prompt: String, input_type: String, options: Array, labels: Array, allow_custom: bool = false) -> void:
	## Show an overlay input widget above the message input area.
	## Called by scene_tools via user_input_requested signal.
	if not is_inside_tree():
		return
	if _input_widget != null:
		return  # Already showing a widget

	_input_widget = _build_input_widget(prompt, input_type, options, labels, allow_custom)
	add_child(_input_widget)
	move_child(_input_widget, scroll_container.get_index() + 1)


func _hide_input_widget() -> void:
	## Remove and free the active input widget.
	if _input_widget != null:
		_input_widget.queue_free()
		_input_widget = null


func show_ask_user_question(questions: Array) -> void:
	## Show an interactive input widget for an AskUserQuestion tool call from Claude.
	## Maps the AskUserQuestion questions format to the existing input widget types.
	## On submit, emits ask_user_answered(text) which chat_panel routes back to the bridge.
	if questions.is_empty() or not is_inside_tree():
		return
	if _input_widget != null:
		return  # Already showing a widget

	var q: Dictionary = questions[0]
	var question_text: String = q.get("question", "Claude is asking...")
	var multi: bool = q.get("multiSelect", false)
	var raw_options: Array = q.get("options", [])

	var option_labels: Array = []
	for opt in raw_options:
		option_labels.append(opt.get("label", str(opt)))

	var input_type: String
	if raw_options.is_empty():
		input_type = "text"
	elif multi:
		input_type = "checkbox"
	else:
		input_type = "radio"

	_ask_user_mode = true
	_show_input_widget(question_text, input_type, option_labels, [], true)


func show_permission_request(tool_name: String, summary: String) -> void:
	## Show a confirm widget asking the user to allow or deny a tool permission request.
	## On submit, emits permission_answered(bool) which chat_panel routes back to the bridge.
	if not is_inside_tree():
		return
	if _input_widget != null:
		return  # Already showing a widget
	_permission_mode = true
	_ask_user_mode = false
	var prompt = "Claude wants to use %s:\n%s" % [tool_name, summary]
	_show_input_widget(prompt, "confirm", [], ["Allow", "Allow all %s" % tool_name, "Deny"], false)


func _build_input_widget(prompt: String, input_type: String, options: Array, labels: Array, allow_custom: bool = false) -> PanelContainer:
	## Build and return a styled PanelContainer for the interactive input widget.

	# Outer PanelContainer with styled background
	var panel = PanelContainer.new()
	panel.name = "InputWidget"

	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color("#1d3557")
	stylebox.border_color = Color("#457b9d")
	stylebox.border_width_left = 2
	stylebox.border_width_right = 2
	stylebox.border_width_top = 2
	stylebox.border_width_bottom = 2
	stylebox.corner_radius_top_left = 4
	stylebox.corner_radius_top_right = 4
	stylebox.corner_radius_bottom_left = 4
	stylebox.corner_radius_bottom_right = 4
	stylebox.content_margin_left = 12
	stylebox.content_margin_right = 12
	stylebox.content_margin_top = 12
	stylebox.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", stylebox)

	# Inner VBoxContainer
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Prompt label
	var prompt_label = Label.new()
	prompt_label.text = prompt
	prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(prompt_label)

	# Controls area — depends on input_type
	panel.set_meta("input_type", input_type)

	match input_type:
		"radio":
			var radio_vbox = VBoxContainer.new()
			var button_group = ButtonGroup.new()
			var first = true
			for option in options:
				var rb = CheckBox.new()
				rb.text = option
				rb.button_group = button_group
				if first:
					rb.button_pressed = true
					first = false
				radio_vbox.add_child(rb)
			vbox.add_child(radio_vbox)
			panel.set_meta("button_group", button_group)
			panel.set_meta("options", options)
			if allow_custom:
				vbox.add_child(HSeparator.new())
				var other_edit = LineEdit.new()
				other_edit.placeholder_text = "Or type a custom answer..."
				other_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				other_edit.text_submitted.connect(_on_widget_text_submitted)
				vbox.add_child(other_edit)
				panel.set_meta("other_edit", other_edit)

		"checkbox":
			var checkbox_array: Array = []
			var checkbox_vbox = VBoxContainer.new()
			for option in options:
				var cb = CheckBox.new()
				cb.text = option
				checkbox_vbox.add_child(cb)
				checkbox_array.append(cb)
			if options.size() > 6:
				var scroll = ScrollContainer.new()
				scroll.custom_minimum_size.y = 120
				scroll.add_child(checkbox_vbox)
				vbox.add_child(scroll)
			else:
				vbox.add_child(checkbox_vbox)
			panel.set_meta("checkboxes", checkbox_array)
			if allow_custom:
				vbox.add_child(HSeparator.new())
				var other_edit = LineEdit.new()
				other_edit.placeholder_text = "Or type a custom answer..."
				other_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				other_edit.text_submitted.connect(_on_widget_text_submitted)
				vbox.add_child(other_edit)
				panel.set_meta("other_edit", other_edit)

		"confirm":
			var confirm_hbox = HBoxContainer.new()
			if labels.is_empty():
				labels = ["Yes", "No"]
			for label_text in labels:
				var btn = Button.new()
				btn.text = label_text
				btn.pressed.connect(_on_widget_confirm.bind(label_text))
				confirm_hbox.add_child(btn)
			vbox.add_child(confirm_hbox)
			panel.set_meta("is_confirm", true)

		"text":
			var line_edit = LineEdit.new()
			line_edit.placeholder_text = "Type your answer..."
			line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line_edit.text_submitted.connect(_on_widget_text_submitted)
			vbox.add_child(line_edit)
			panel.set_meta("line_edit", line_edit)

	# Button row
	var button_row = HBoxContainer.new()
	if input_type != "confirm":
		var submit_btn = Button.new()
		submit_btn.text = "Submit"
		submit_btn.pressed.connect(_on_widget_submitted)
		button_row.add_child(submit_btn)
		var spacer = Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button_row.add_child(spacer)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_widget_cancelled)
	button_row.add_child(cancel_btn)
	vbox.add_child(button_row)

	return panel


func _on_widget_submitted() -> void:
	## Handle Submit button press for radio, checkbox, and text types.
	if _input_widget == null:
		return

	# Custom "other" field takes priority over any radio/checkbox selection
	if _input_widget.has_meta("other_edit"):
		var other_text = _input_widget.get_meta("other_edit").text.strip_edges()
		if not other_text.is_empty():
			_finalize_submission({"value": other_text})
			return

	var input_type = _input_widget.get_meta("input_type")
	var answer: Dictionary = {}

	match input_type:
		"radio":
			var selected = _input_widget.get_meta("button_group").get_pressed_button()
			if selected == null:
				return
			answer = {"value": selected.text}
		"checkbox":
			var checkboxes = _input_widget.get_meta("checkboxes")
			var selected_array: Array = []
			for cb in checkboxes:
				if cb.button_pressed:
					selected_array.append(cb.text)
			answer = {"values": selected_array}
		"text":
			var text = _input_widget.get_meta("line_edit").text.strip_edges()
			if text.is_empty():
				return
			answer = {"value": text}
		_:
			return

	_finalize_submission(answer)


func _on_widget_confirm(label: String) -> void:
	## Handle confirm button press.
	var answer = {"value": label}
	_finalize_submission(answer)


func _on_widget_text_submitted(text: String) -> void:
	## Handle Enter key in text input field.
	if text.strip_edges().is_empty():
		return
	var answer = {"value": text.strip_edges()}
	_finalize_submission(answer)


func _finalize_submission(answer: Dictionary) -> void:
	## Echo answer, save conversation, emit signal, and hide widget.
	## Routes via ask_user_answered (back to bridge) or user_input_submitted (MCP path)
	## depending on whether the widget was opened by AskUserQuestion or request_user_input.
	var display_text: String
	if answer.has("values"):
		display_text = ", ".join(answer.get("values", []))
	else:
		display_text = answer.get("value", "")

	append_message("user", "Selected: %s" % display_text)
	ConversationStorage.save_conversation(conversation)

	if _ask_user_mode:
		_ask_user_mode = false
		_hide_input_widget()
		_force_scroll_to_bottom()
		ask_user_answered.emit(display_text)
	elif _permission_mode:
		_permission_mode = false
		_hide_input_widget()
		_force_scroll_to_bottom()
		var perm_decision: String
		if display_text == "Allow":
			perm_decision = "allow"
		elif display_text.begins_with("Allow all"):
			perm_decision = "allow_all"
		else:
			perm_decision = "deny"
		permission_answered.emit(perm_decision)
	else:
		user_input_submitted.emit(answer)
		_hide_input_widget()
		# Widget removal changes scroll_container size, invalidating the scroll from
		# append_message. Force scroll to bottom after layout settles.
		_force_scroll_to_bottom()


func _on_widget_cancelled() -> void:
	## Handle Cancel button press.
	append_message("user", "(Input cancelled)")
	ConversationStorage.save_conversation(conversation)
	if _ask_user_mode:
		_ask_user_mode = false
		_hide_input_widget()
		_force_scroll_to_bottom()
		# Must send answer back to unblock the PreToolUse hook in the bridge.
		# If we don't emit, _answer_queue.get() hangs forever and Claude freezes.
		ask_user_answered.emit("(cancelled by user)")
	elif _permission_mode:
		_permission_mode = false
		_hide_input_widget()
		_force_scroll_to_bottom()
		# Must emit to unblock _permission_queue.get() in the bridge hook.
		permission_answered.emit("deny")
	else:
		user_input_submitted.emit({"cancelled": true})
		_hide_input_widget()
		_force_scroll_to_bottom()
