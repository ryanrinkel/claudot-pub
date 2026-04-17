@tool
extends Control

## ChatPanel - Dockable editor panel for Claude Code interaction (TabContainer host)
##
## Manages a TabContainer with conversation and console tabs.
## Handles TCP connection, context injection, and message routing.

# Preload utilities and dependencies
const ConversationTabScript = preload("res://addons/claudot/ui/conversation_tab.gd")
const ConsoleTabScript = preload("res://addons/claudot/ui/console_tab.gd")
const ConversationStorage = preload("res://addons/claudot/ui/conversation_storage.gd")
const TCPClient = preload("res://addons/claudot/network/tcp_client.gd")
const ContextProvider = preload("res://addons/claudot/mcp/context_provider.gd")

const CLAUDOT_VERSION = "v2.3.0-beta"
const CLAUDOT_RELEASES_URL = "https://github.com/claudot-dev/claudot/releases"

# Reference to TCP client (set by plugin before entering tree)
var tcp_client: Node = null
var context_provider = null  # Set via setup_context method
var bridge_launcher: Node = null  # Set via setup_bridge_launcher

# UI node references (assigned in _build_ui)
var status_label: Label
var connect_button: Button
var context_scene_check: CheckBox
var context_selection_check: CheckBox
var context_docs_check: CheckBox
var tab_container: TabContainer
var conversation_tab: VBoxContainer  # ConversationTab instance
var console_tab: VBoxContainer  # ConsoleTab instance
var is_working: bool = false
var _intermediate_text_shown: bool = false
var _ask_user_via_hook: bool = false  # True when chat/ask_user_question arrived (hook path)
var _last_ctx_pct: float = 0.0  # Last known context window usage percentage
var clear_tab_button: Button  # Anchor-overlaid in tab bar


func _ready() -> void:
	# Build UI tree programmatically
	_build_ui()

	# Connect UI signals only (TCP signals wired separately via setup_tcp_signals)
	conversation_tab.message_submitted.connect(_on_input_submitted)
	conversation_tab.clear_confirmed.connect(_on_clear_confirmed)
	conversation_tab.ask_user_answered.connect(_on_ask_user_answered)
	conversation_tab.permission_answered.connect(_on_permission_answered)
	conversation_tab.stop_requested.connect(_on_stop_requested)
	connect_button.pressed.connect(_on_connect_pressed)

	# Set initial disconnected state
	if status_label:
		status_label.text = "Disconnected"
		status_label.modulate = Color("#cc241d")  # Red

	# Load conversation history from disk
	conversation_tab.load_conversation(ConversationStorage.load_conversation())

	call_deferred("_add_tab_bar_buttons")


func _build_ui() -> void:
	## Build the entire UI tree programmatically with TabContainer architecture.
	# Main container
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.anchor_left = 0
	vbox.anchor_top = 0
	vbox.anchor_right = 1
	vbox.anchor_bottom = 1
	vbox.offset_left = 0
	vbox.offset_top = 0
	vbox.offset_right = 0
	vbox.offset_bottom = 0
	add_child(vbox)

	# InfoBar: merged status + context toggles + connect button
	var info_bar = HBoxContainer.new()
	info_bar.name = "InfoBar"
	vbox.add_child(info_bar)

	var version_button = LinkButton.new()
	version_button.name = "VersionButton"
	version_button.text = CLAUDOT_VERSION
	version_button.add_theme_font_size_override("font_size", 11)
	version_button.pressed.connect(func(): OS.shell_open(CLAUDOT_RELEASES_URL))
	info_bar.add_child(version_button)

	var vsep_version = VSeparator.new()
	info_bar.add_child(vsep_version)

	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Disconnected"
	status_label.add_theme_font_size_override("font_size", 11)
	info_bar.add_child(status_label)

	var vsep = VSeparator.new()
	info_bar.add_child(vsep)

	context_scene_check = CheckBox.new()
	context_scene_check.name = "SceneCheck"
	context_scene_check.text = "Scene"
	context_scene_check.button_pressed = true
	context_scene_check.add_theme_font_size_override("font_size", 10)
	info_bar.add_child(context_scene_check)

	context_selection_check = CheckBox.new()
	context_selection_check.name = "SelectionCheck"
	context_selection_check.text = "Node"
	context_selection_check.button_pressed = true
	context_selection_check.add_theme_font_size_override("font_size", 10)
	info_bar.add_child(context_selection_check)

	context_docs_check = CheckBox.new()
	context_docs_check.name = "DocsCheck"
	context_docs_check.text = "Docs"
	context_docs_check.button_pressed = false
	context_docs_check.add_theme_font_size_override("font_size", 10)
	info_bar.add_child(context_docs_check)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_bar.add_child(spacer)

	connect_button = Button.new()
	connect_button.name = "ConnectButton"
	connect_button.text = "Connect"
	connect_button.flat = true
	connect_button.add_theme_font_size_override("font_size", 11)
	info_bar.add_child(connect_button)

	# TabContainer (main content area)
	tab_container = TabContainer.new()
	tab_container.name = "TabContainer"
	tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_container)

	# Conversation tab
	conversation_tab = ConversationTabScript.new()
	conversation_tab.name = "Claudot"
	tab_container.add_child(conversation_tab)

	# Console tab
	console_tab = ConsoleTabScript.new()
	console_tab.name = "Console"
	tab_container.add_child(console_tab)

	# Default to conversation tab
	tab_container.current_tab = 0

func _add_tab_bar_buttons() -> void:
	## Add Clear button anchored to right side of TabContainer tab bar.
	## Must be called deferred — tab bar internal layout is not ready in _ready().
	var tab_bar = tab_container.get_tab_bar()
	clear_tab_button = Button.new()
	clear_tab_button.text = "Clear"
	clear_tab_button.flat = true
	clear_tab_button.add_theme_font_size_override("font_size", 11)
	clear_tab_button.anchor_left = 1.0
	clear_tab_button.anchor_right = 1.0
	clear_tab_button.anchor_top = 0.0
	clear_tab_button.anchor_bottom = 1.0
	clear_tab_button.offset_left = -65
	clear_tab_button.offset_right = -4
	clear_tab_button.offset_top = 2
	clear_tab_button.offset_bottom = -2
	tab_bar.add_child(clear_tab_button)
	clear_tab_button.pressed.connect(_on_clear_tab_button_pressed)


func _on_clear_tab_button_pressed() -> void:
	## Route Clear button press to the active tab's clear handler.
	if tab_container.current_tab == 0:
		conversation_tab._on_clear_pressed()
	else:
		console_tab._on_clear_pressed()


func setup_tcp_signals(client: Node) -> void:
	## Called by plugin after panel's _ready() completes.
	## Wires up TCP client signals and syncs current connection state.
	tcp_client = client

	# Connect TCP client signals
	client.connection_state_changed.connect(_on_connection_state_changed)
	client.message_received.connect(_on_message_received)
	client.connection_error.connect(_on_connection_error)

	# Sync current state to UI immediately
	_on_connection_state_changed(client.current_state)


func setup_bridge_launcher(launcher: Node) -> void:
	## Called by plugin to give chat_panel access to the bridge launcher.
	bridge_launcher = launcher


func setup_context(editor_plugin: EditorPlugin) -> void:
	## Called by plugin to initialize context provider with editor reference.
	context_provider = ContextProvider.new(editor_plugin)


func get_tab_container() -> TabContainer:
	## Public accessor for tab container (for future console tab wiring).
	return tab_container


func _on_input_submitted(text: String) -> void:
	## Handle message submission from ConversationTab.
	send_message(text)


func _on_clear_confirmed() -> void:
	## Handle clear confirmation from ConversationTab.
	## Send /clear command to attached Claude agent if connected.
	if tcp_client == null:
		return

	# Only send /clear if connected to bridge
	if tcp_client.current_state == TCPClient.ConnectionState.CONNECTED:
		# Send /clear directly to bridge without displaying in conversation UI
		# (UI was already cleared by conversation_tab's _on_clear_confirmed)
		var params = {"content": "/clear"}

		# Forward to console tab for debugging
		if console_tab:
			console_tab.append_json_message(params, "request")

		# Send directly to TCP client (bypass send_message to avoid UI display)
		tcp_client.send_message("chat/send", params)


func send_message(text: String) -> void:
	## Send user message to bridge via TCP client.
	if text.strip_edges().is_empty():
		return

	# Check connection state
	if tcp_client == null:
		conversation_tab.append_system_message("TCP client not available.")
		return

	# Check if connected
	if tcp_client.current_state != TCPClient.ConnectionState.CONNECTED:
		conversation_tab.append_system_message(
			"Not connected to bridge. Start the bridge daemon with: python addons/claudot/bridge/agent_bridge.py\nThen click the Connect button."
		)
		return

	# Reset intermediate text flag for this new query
	_intermediate_text_shown = false

	# Display user message in conversation tab
	conversation_tab.append_message("user", text)

	# Append docs instruction if checkbox is checked
	if context_docs_check.button_pressed:
		text += "\n\n[IMPORTANT: Before responding, use godot_get_class_docs to look up documentation for EVERY Godot class referenced in or needed for this request. Do not skip any class.]"

	# Gather editor context based on checkbox states
	var params = {"content": text}
	if context_provider:
		var ctx = context_provider.get_context(
			context_scene_check.button_pressed,
			context_selection_check.button_pressed
		)
		if not ctx.is_empty():
			params["context"] = ctx

	# Forward outgoing request to console tab
	if console_tab:
		console_tab.append_json_message(params, "request")

	# Activate working indicator
	is_working = true
	conversation_tab.set_working(true)

	# Send to bridge
	var msg_id = tcp_client.send_message("chat/send", params)

	if msg_id < 0:
		is_working = false
		conversation_tab.set_working(false)
		conversation_tab.append_system_message("Failed to send message.")

	# Save conversation to disk
	ConversationStorage.save_conversation(conversation_tab.conversation)


func _on_connection_state_changed(state: int) -> void:
	## Update UI based on TCP connection state.
	if tcp_client == null:
		return

	# Update status label text and color based on connection state
	if state == TCPClient.ConnectionState.CONNECTED:
		if _last_ctx_pct > 0.0:
			var color := Color("#fb4934") if _last_ctx_pct > 75.0 else (Color("#fabd2f") if _last_ctx_pct > 50.0 else Color("#8ec07c"))
			status_label.text = "Ready [%s%% ctx]" % str(snapped(_last_ctx_pct, 0.1))
			status_label.modulate = color
		else:
			status_label.text = "Ready"
			status_label.modulate = Color("#8ec07c")  # Green
		connect_button.text = "Connected"
		connect_button.disabled = true

	elif state == TCPClient.ConnectionState.CONNECTING:
		status_label.text = "Connecting..."
		status_label.modulate = Color("#fabd2f")  # Yellow
		connect_button.disabled = true

	elif state == TCPClient.ConnectionState.DISCONNECTED:
		_last_ctx_pct = 0.0
		status_label.text = "Disconnected"
		status_label.modulate = Color("#cc241d")  # Red
		connect_button.text = "Connect"
		connect_button.disabled = false

	elif state == TCPClient.ConnectionState.ERROR:
		status_label.text = "Error (retrying...)"
		status_label.modulate = Color("#cc241d")  # Red
		connect_button.text = "Connect"
		connect_button.disabled = false

	elif state == TCPClient.ConnectionState.CIRCUIT_OPEN:
		status_label.text = "Bridge unavailable"
		status_label.modulate = Color("#cc241d")  # Red
		connect_button.text = "Reset & Connect"
		connect_button.disabled = false

	# Clear working indicator if connection drops while working
	if state != TCPClient.ConnectionState.CONNECTED and is_working:
		is_working = false
		conversation_tab.set_working(false)


func _on_message_received(message: Dictionary) -> void:
	## Handle JSON-RPC response from bridge.
	# Forward ALL messages to console tab as raw JSON
	if console_tab:
		var msg_type = "response"
		if message.has("error"):
			msg_type = "error"
		console_tab.append_json_message(message, msg_type)

	# Check for chat/response method (bridge sends responses this way)
	if message.get("method") == "chat/response":
		# Extract context usage before clearing working state
		var ctx_pct: float = 0.0
		if message.has("params") and message.params is Dictionary and message.params.has("usage"):
			var usage = message.params.get("usage", {})
			if usage is Dictionary and usage.has("context_pct"):
				ctx_pct = usage.get("context_pct", 0.0)
		is_working = false
		conversation_tab.set_working(false)
		# Show context usage persistently in status label
		if ctx_pct > 0.0:
			_last_ctx_pct = ctx_pct
			var color := Color("#fb4934") if ctx_pct > 75.0 else (Color("#fabd2f") if ctx_pct > 50.0 else Color("#8ec07c"))
			status_label.text = "Ready [%s%% ctx]" % str(snapped(ctx_pct, 0.1))
			status_label.modulate = color
		if message.has("params") and message.params is Dictionary and message.params.has("content"):
			var content = message.params.content
			# Only display if intermediate text was NOT already shown (simple single-turn response)
			# If intermediate text was shown, it was already appended to the conversation
			if not _intermediate_text_shown and not content.is_empty():
				conversation_tab.append_message("assistant", content)
			# Reset flag for next query
			_intermediate_text_shown = false
			# Save conversation to disk
			ConversationStorage.save_conversation(conversation_tab.conversation)

	# Handle intermediate assistant text during multi-turn conversations
	elif message.get("method") == "chat/assistant_text":
		if message.has("params") and message.params is Dictionary and message.params.has("content"):
			var content = message.params.content
			if not content.is_empty():
				conversation_tab.append_message("assistant", content)
				_intermediate_text_shown = true
				ConversationStorage.save_conversation(conversation_tab.conversation)

	# Handle chat/clear from bridge (e.g. user typed /clear)
	elif message.get("method") == "chat/clear":
		conversation_tab.clear_conversation()

	# Handle tool permission request from PreToolUse hook
	elif message.get("method") == "chat/permission_request":
		if message.has("params") and message.params is Dictionary:
			var tool_name = message.params.get("tool_name", "unknown")
			var summary = message.params.get("summary", "")
			conversation_tab.show_permission_request(tool_name, summary)

	# Handle ask_user_question from PreToolUse hook (true bidirectional path)
	elif message.get("method") == "chat/ask_user_question":
		if message.has("params") and message.params is Dictionary:
			var questions = message.params.get("questions", [])
			if questions.size() > 0:
				_ask_user_via_hook = true
				conversation_tab.show_ask_user_question(questions)

	# Handle context usage updates during streaming
	elif message.get("method") == "chat/usage_update":
		if message.has("params") and message.params is Dictionary:
			var pct = message.params.get("context_pct", 0.0)
			conversation_tab.update_context_usage(pct)

	# Handle tool use notifications
	elif message.get("method") == "chat/tool_use":
		if message.has("params") and message.params is Dictionary:
			var tool_name = message.params.get("tool_name", "unknown")
			# AskUserQuestion: show interactive widget instead of a plain system message
			if tool_name == "AskUserQuestion":
				var tool_input = message.params.get("tool_input", {})
				var questions = tool_input.get("questions", [])
				if questions.size() > 0:
					conversation_tab.show_ask_user_question(questions)
					return
			conversation_tab.append_system_message("Using tool: %s" % tool_name)

	# Check for result with content (JSON-RPC result format)
	elif message.has("result") and message.result is Dictionary and message.result.has("content"):
		is_working = false
		conversation_tab.set_working(false)
		var content = message.result.content
		conversation_tab.append_message("assistant", content)

		# Save conversation to disk
		ConversationStorage.save_conversation(conversation_tab.conversation)

	# Check for error
	elif message.has("error"):
		is_working = false
		conversation_tab.set_working(false)
		var error_text = "Error: %s" % JSON.stringify(message.error)
		conversation_tab.append_system_message(error_text)


func _on_ask_user_answered(text: String) -> void:
	## Handle answer from AskUserQuestion widget.
	## Two paths depending on how the widget was triggered:
	## - Hook path (chat/ask_user_question): send chat/ask_user_answer to unblock _answer_queue
	## - Fallback path (chat/tool_use): AskUserQuestion ran headlessly, send answer as new chat/send
	if tcp_client == null or tcp_client.current_state != TCPClient.ConnectionState.CONNECTED:
		_ask_user_via_hook = false
		return

	if _ask_user_via_hook:
		# PreToolUse hook is blocking on _answer_queue — send dedicated answer method
		_ask_user_via_hook = false
		var params = {"answer": text}
		if console_tab:
			console_tab.append_json_message(params, "request")
		tcp_client.send_message("chat/ask_user_answer", params)
	else:
		# AskUserQuestion ran headlessly (not in hook scope) — answer as a new user message
		var params = {"content": text}
		if console_tab:
			console_tab.append_json_message(params, "request")
		is_working = true
		conversation_tab.set_working(true)
		tcp_client.send_message("chat/send", params)

	ConversationStorage.save_conversation(conversation_tab.conversation)


func _on_permission_answered(decision: String) -> void:
	## Handle allow/deny/allow_all from tool permission widget.
	## Sends decision back to bridge to unblock the PreToolUse hook's _permission_queue.
	if tcp_client == null or tcp_client.current_state != TCPClient.ConnectionState.CONNECTED:
		return
	var params = {"decision": decision}
	if console_tab:
		console_tab.append_json_message(params, "request")
	tcp_client.send_message("chat/permission_response", params)


func _on_stop_requested() -> void:
	## Handle stop button — send interrupt to bridge.
	if tcp_client == null or tcp_client.current_state != TCPClient.ConnectionState.CONNECTED:
		return
	if not is_working:
		return
	tcp_client.send_message("chat/cancel", {})
	conversation_tab.append_system_message("Interrupt sent.")


func _on_connection_error(error_message: String) -> void:
	## Handle connection error from TCP client.
	## Errors go to the console tab only — the status bar already shows retry state.
	## Flooding the conversation tab with retry failures creates noise.
	is_working = false
	conversation_tab.set_working(false)
	if console_tab:
		console_tab.append_json_message({"error": error_message}, "error")


func _on_connect_pressed() -> void:
	## Handle Connect button press.
	## If the bridge process is not running, start it first. The TCP retry
	## mechanism handles the startup delay — no manual timing needed.
	if tcp_client == null:
		return

	# Start bridge if it isn't running (e.g. first run, or it crashed)
	if bridge_launcher and not bridge_launcher.is_running():
		bridge_launcher.auto_launch()

	var current = tcp_client.current_state

	if current == TCPClient.ConnectionState.DISCONNECTED or current == TCPClient.ConnectionState.ERROR:
		tcp_client.attempt_connect()
	elif current == TCPClient.ConnectionState.CIRCUIT_OPEN:
		tcp_client.reset_circuit_breaker()
		tcp_client.attempt_connect()
