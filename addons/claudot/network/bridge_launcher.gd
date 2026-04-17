@tool
extends Node

## BridgeLauncher - Manages the lifecycle of the agent_bridge.py background process.
##
## Detects available Python launcher (uv > python > python3), launches agent_bridge.py
## as a non-blocking background process using OS.create_process(), and kills it on cleanup.
## Emits launcher_error(message) when no launcher is found or the process fails to start.

signal launcher_error(message: String)
signal bridge_process_exited()

var _pid: int = -1
var _launcher: String = ""
var _launch_time: float = -1.0

## Derived port for this project's bridge instance. Set by auto_launch().
var bridge_port: int = -1

# How long the process must run before an exit is considered unexpected.
# uv exits quickly after delegating to Python — we must not treat that as a crash.
const CRASH_GRACE_PERIOD = 5.0

## Public API

func auto_launch() -> void:
	## Detect launcher and launch the bridge. Call from claudot_plugin._enter_tree().
	_launcher = detect_launcher()
	if _launcher.is_empty():
		var msg = _build_not_found_message()
		push_error("[Claudot BridgeLauncher] " + msg)
		launcher_error.emit(msg)
		return
	bridge_port = _get_project_port()
	print("[Claudot] Bridge port for this project: %d" % bridge_port)
	_launch_bridge(_launcher)


func stop() -> void:
	## Kill the bridge process. Zeroes _pid BEFORE OS.kill() so _process() does not
	## fire bridge_process_exited for an intentional shutdown.
	if _pid <= 0:
		return
	var pid_to_kill = _pid
	_pid = -1  # Zero first — _process() checks _pid; must be -1 before kill
	OS.kill(pid_to_kill)


func is_running() -> bool:
	## Returns true if the bridge process is currently running.
	if _pid <= 0:
		return false
	return OS.is_process_running(_pid)


func probe_executable(name: String) -> int:
	## Public wrapper for _probe_executable. Returns 0 if found, -1 if not.
	return _probe_executable(name)


func _process(_delta: float) -> void:
	## Poll the bridge process each frame. Emits bridge_process_exited if it dies unexpectedly.
	## Returns immediately if no process is running (_pid <= 0).
	## Grace period: uv exits by design after delegating to Python — ignore exits within
	## CRASH_GRACE_PERIOD seconds of launch so we don't report a false crash.
	if _pid <= 0:
		return
	if not OS.is_process_running(_pid):
		var runtime = Time.get_ticks_msec() / 1000.0 - _launch_time
		_pid = -1
		if runtime >= CRASH_GRACE_PERIOD:
			bridge_process_exited.emit()


func get_launcher() -> String:
	## Returns the detected launcher name ("uv", "python", "python3", or "").
	return _launcher


func _get_project_port() -> int:
	## Derive a unique TCP port for this project's bridge from the project path hash.
	## Maps into the range 7800–8800 (1000 slots) to avoid the default 7777 port.
	## Collision probability between two simultaneously-open projects is ~0.1%.
	var project_root = ProjectSettings.globalize_path("res://")
	var h = project_root.hash()
	return 7800 + (absi(h) % 1000)


## Launcher Detection

func detect_launcher() -> String:
	## Try uv, then python, then python3. Returns first working launcher or "".
	for candidate in ["uv", "python", "python3"]:
		if _probe_executable(candidate) == 0:
			return candidate
	return ""


func _probe_executable(name: String) -> int:
	## Returns 0 if executable is found and responds to --version, -1 if not found.
	## Handles the Windows GUI PATH limitation via cmd.exe /C where fallback.
	var output: Array = []
	var exit_code = OS.execute(name, PackedStringArray(["--version"]), output, true)
	if exit_code != -1:
		return 0  # Found (treat any non-(-1) as found)

	# Windows fallback: GUI apps may not inherit full shell PATH
	if OS.get_name() == "Windows":
		var where_out: Array = []
		var where_exit = OS.execute(
			"cmd.exe",
			PackedStringArray(["/C", "where", name]),
			where_out,
			false
		)
		if where_exit == 0:
			return 0  # Found via where, direct invocation should work
	return -1  # Not found


## Dependency Management

func _ensure_deps(launcher: String) -> bool:
	## When using plain python (not uv), check that required packages are installed.
	## Auto-installs them via pip if missing. Returns true if deps are ready.
	## uv handles this automatically via inline script metadata, so skip for uv.
	if launcher == "uv":
		return true

	# Quick import check — if this succeeds, deps are already installed
	var output: Array = []
	var exit_code = OS.execute(
		launcher,
		PackedStringArray(["-c", "import claude_agent_sdk; import anyio"]),
		output,
		true
	)
	if exit_code == 0:
		return true

	# Missing deps — install automatically
	print("[Claudot] Installing Python dependencies (first run)...")
	var pip_output: Array = []
	var pip_exit = OS.execute(
		launcher,
		PackedStringArray(["-m", "pip", "install", "claude-agent-sdk>=0.1.0", "anyio>=4.0.0"]),
		pip_output,
		true
	)
	if pip_exit != 0:
		var msg = "[b]Failed to install Python dependencies.[/b]\n\nTry running manually:\n  %s -m pip install claude-agent-sdk anyio\n\nOr install uv (recommended) which handles dependencies automatically." % launcher
		push_error("[Claudot BridgeLauncher] " + msg)
		launcher_error.emit(msg)
		return false

	print("[Claudot] Dependencies installed successfully.")
	return true


## Bridge Launch

func _launch_bridge(launcher: String) -> void:
	## Launch agent_bridge.py using the detected launcher.
	## Ensures dependencies are installed first (for plain python).
	## Uses OS.create_process() — non-blocking, returns PID immediately.
	if not _ensure_deps(launcher):
		return

	var script_abs = ProjectSettings.globalize_path("res://addons/claudot/bridge/agent_bridge.py")
	var project_root = ProjectSettings.globalize_path("res://")

	# Build argument list based on launcher
	var args: PackedStringArray
	if launcher == "uv":
		args = PackedStringArray(["run", script_abs, "--project-root", project_root, "--port", str(bridge_port)])
	else:
		# python or python3: run script directly (no "run" subcommand)
		args = PackedStringArray([script_abs, "--project-root", project_root, "--port", str(bridge_port)])

	_pid = OS.create_process(launcher, args, false)
	_launch_time = Time.get_ticks_msec() / 1000.0

	if _pid == -1:
		var msg = "[b]Bridge failed to start.[/b]\n\nLauncher '%s' was found but could not start the bridge.\nCheck that 'addons/claudot/bridge/agent_bridge.py' exists in your project." % launcher
		push_error("[Claudot BridgeLauncher] " + msg)
		launcher_error.emit(msg)


## Error Messages

func _build_not_found_message() -> String:
	return """[b]Python not found.[/b] The Claudot bridge requires Python or uv to run.

Install uv (recommended — handles dependencies automatically):
  Windows: winget install astral-sh.uv
  macOS:   brew install uv
  Linux:   curl -LsSf https://astral.sh/uv/install.sh | sh

Or install Python 3.10+:
  https://www.python.org/downloads/

After installing, restart Godot for PATH changes to take effect.

Note: If uv or Python is installed but not detected, it may not be on your system PATH.
On Windows, try adding the install directory to System Environment Variables."""
