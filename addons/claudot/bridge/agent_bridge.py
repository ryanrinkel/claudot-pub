#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "claude-agent-sdk>=0.1.0",
#   "anyio>=4.0.0",
# ]
# ///

"""
Claudot Agent Bridge - Chat relay daemon for Godot plugin.

Provides persistent Claude conversation sessions for the Godot chat interface.
Uses Claude Agent SDK for chat relay and real-time streaming.

Architecture:
- TCP server on port 7777 for Godot plugin connections
- Claude API client for chat messages (Agent SDK)
- MCP tools are provided by the standalone godot_mcp_server.py (not this file)

This is the chat-only bridge. For MCP tools, see addons/claudot/bridge/godot_mcp_server.py.
"""

import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Optional


import anyio
from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    HookMatcher,
    AssistantMessage,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolUseBlock
)

logger = logging.getLogger(__name__)

# Context window sizes by model family (prefix match)
# Claude Code CLI uses 1M context for Opus/Sonnet 4.x by default
_MODEL_CONTEXT_WINDOWS = {
    "claude-opus-4":   1_000_000,
    "claude-sonnet-4": 1_000_000,
    "claude-haiku-4":    200_000,
    "claude-3-5":        200_000,
    "claude-3-opus":     200_000,
}
_DEFAULT_CONTEXT_WINDOW = 200_000


def _context_window_for_model(model_id: str) -> int:
    """Return context window token count for a model ID via prefix match."""
    for prefix, tokens in _MODEL_CONTEXT_WINDOWS.items():
        if model_id.startswith(prefix):
            return tokens
    return _DEFAULT_CONTEXT_WINDOW

_BUILTIN_COMMANDS = {"/clear", "/compact", "/cost", "/help", "/memory",
                     "/model", "/permissions", "/plan", "/review", "/status", "/vim"}

_SYSTEM_PROMPT = """You are an expert Godot 4 GDScript developer embedded in the Godot editor as an AI assistant.

## MCP Tool Use — Mandatory

Always call MCP tools proactively. Never wait for the user to ask.

- Before ANY scene work: call get_editor_context()
- Before reading/editing a node's script: call get_node_script(node_path)
- Before set_node_property or scene mutations: call get_scene_state() or get_node_property()
- To find .gd files: call search_files(extensions=[".gd"]) — never guess paths
- After writing or changing code: call run_tests(), then get_debugger_output() and get_debugger_errors()
- After visual scene changes: call capture_screenshot()

## GDScript 4.x — Required Patterns

Write Godot 4 GDScript only. Never use Godot 3 syntax.

### Always type variables and function signatures
```gdscript
var speed: float = 200.0
func move(delta: float) -> void:
    pass
```

### Use @export and @onready decorators
```gdscript
@export var speed: float = 200.0
@onready var sprite: Sprite2D = $Sprite2D
```

### Signals — prefer signal-first architecture
Signals decouple systems and make testing easy. Use them everywhere state changes.
```gdscript
signal health_changed(new_health: int)
signal player_died

# Emit:
health_changed.emit(health)

# Connect in code:
player.health_changed.connect(_on_health_changed)

# Lambda connect:
button.pressed.connect(func(): do_thing())
```
Default to signals over direct method calls between nodes. Child nodes emit; parents/managers listen.

### Async / await (not yield)
```gdscript
await get_tree().create_timer(1.0).timeout
await animation_player.animation_finished
```

### super() calls
```gdscript
func _ready() -> void:
    super()
```

### Typed arrays and dicts
```gdscript
var items: Array[String] = []
var scores: Dictionary = {}
```

### Critical Godot 3 → 4 syntax (always use the right side)
- `export var` / `onready var` → `@export var` / `@onready var`
- `yield(signal, "signal_name")` → `await signal_name`
- `connect("signal", obj, "method")` → `signal_name.connect(callable)`
"""


class GodotTCPConnection:
    """Manages TCP connection to a single Godot editor instance."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self.client_addr = writer.get_extra_info('peername')

    async def receive_message(self) -> Optional[dict]:
        """
        Receive JSON-RPC message from Godot.

        Returns:
            Parsed JSON dict or None if connection closed
        """
        try:
            # Read newline-delimited JSON
            line = await self.reader.readline()
            if not line:
                return None

            message = json.loads(line.decode('utf-8'))
            logger.debug(f"Received from Godot: {message}")
            return message

        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.error(f"Error receiving message: {e}")
            return None

    async def send_message(self, data: dict) -> bool:
        """
        Send JSON-RPC message to Godot.

        Args:
            data: Dictionary to send as JSON

        Returns:
            True if successful, False otherwise
        """
        try:
            message_json = json.dumps(data) + "\n"
            self.writer.write(message_json.encode('utf-8'))
            await self.writer.drain()
            logger.debug(f"Sent to Godot: {data}")
            return True

        except Exception as e:
            logger.error(f"Error sending message: {e}")
            return False

    def close(self):
        """Close the TCP connection."""
        self.writer.close()


class AgentBridge:
    """
    Chat relay bridge daemon using Claude Agent SDK for persistent conversations.

    Architecture:
    - Godot connects via TCP on port 7777 (one connection = one Claude session)
    - Bridge maintains persistent ClaudeSDKClient for conversation continuity
    - Responses stream back to Godot in real-time
    - MCP tools are handled separately by godot_mcp_server.py via HTTP bridge

    This is chat-only. Scene manipulation uses the standalone MCP server.
    """

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 7777,
        model: str = "claude-opus-4-6",
        log_level: str = "INFO"
    ):
        self.host = host
        self.port = port
        self.model = model
        self.log_level = log_level

        self.tcp_connection: Optional[GodotTCPConnection] = None
        self._answer_queue: asyncio.Queue = asyncio.Queue()
        self._query_queue: asyncio.Queue = asyncio.Queue()
        self._permission_queue: asyncio.Queue = asyncio.Queue()
        self._session_allowed_tools: set[str] = set()
        self._context_window_tokens: int = _context_window_for_model(model)
        self._detected_model: Optional[str] = None

        # Setup logging
        self._setup_logging()

    def _setup_logging(self):
        """Configure logging to stderr."""
        numeric_level = getattr(logging, self.log_level.upper(), logging.INFO)

        logging.basicConfig(
            level=numeric_level,
            format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S',
            stream=sys.stderr
        )

        logger.info(f"Logging configured at {self.log_level.upper()} level")



    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """
        Handle a single Godot editor connection with persistent Claude session.

        Args:
            reader: TCP stream reader
            writer: TCP stream writer
        """
        self.tcp_connection = GodotTCPConnection(reader, writer)
        client_addr = writer.get_extra_info('peername')
        logger.info(f"Godot editor connected from {client_addr}")

        try:
            await self._run_conversation_loop()
        except Exception as e:
            logger.error(f"Conversation error: {e}", exc_info=True)
        finally:
            self.tcp_connection.close()
            self.tcp_connection = None
            logger.info(f"Godot editor disconnected from {client_addr}")

    async def _ask_user_hook(self, hook_input, tool_use_id, context):
        """
        PreToolUse hook for AskUserQuestion tool calls.

        Intercepts AskUserQuestion before it executes, sends the questions to Godot
        via TCP, then blocks until Godot sends back the user's answer. The tool must
        be denied (to prevent the real CLI-based AskUserQuestion from executing), but
        additionalContext carries the user's answer so Claude treats it as a successful
        interaction rather than a rejection.
        """
        questions = hook_input["tool_input"]["questions"]
        await self.tcp_connection.send_message({
            "jsonrpc": "2.0",
            "method": "chat/ask_user_question",
            "params": {"questions": questions}
        })
        # Block until Godot sends back the user's answer via chat/ask_user_answer
        answer = await self._answer_queue.get()
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "Tool handled by Godot UI — answer provided via additionalContext.",
                "additionalContext": f"The user answered your question via the Godot chat interface. Their response: {answer}"
            }
        }

    async def _permission_hook(self, hook_input, tool_use_id, context):
        """
        PreToolUse hook for tools that require explicit user permission (e.g. WebFetch, WebSearch).

        Sends a permission request to Godot, blocks until the user allows or denies,
        then returns the appropriate permission decision to the SDK.
        """
        tool_name = hook_input.get("tool_name", "unknown")
        tool_input = hook_input.get("tool_input", {})
        summary = tool_input.get("url") or tool_input.get("query") or str(tool_input)[:120]
        if tool_name in self._session_allowed_tools:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow"
                }
            }
        await self.tcp_connection.send_message({
            "jsonrpc": "2.0",
            "method": "chat/permission_request",
            "params": {"tool_name": tool_name, "summary": summary}
        })
        decision = await self._permission_queue.get()
        if decision in ("allow", "allow_all"):
            if decision == "allow_all":
                self._session_allowed_tools.add(tool_name)
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow"
                }
            }
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "User denied permission to use this tool."
            }
        }

    async def _handle_builtin_command(self, command: str) -> None:
        """Handle a built-in slash command locally without forwarding to the SDK."""
        if command == "/clear":
            await self.tcp_connection.send_message({
                "jsonrpc": "2.0",
                "method": "chat/clear",
                "params": {}
            })
        elif command == "/plan":
            self._plan_mode = not self._plan_mode
            state_msg = (
                "Plan mode ON — I will describe changes step-by-step without executing them. "
                "Type /plan again to exit."
            ) if self._plan_mode else "Plan mode OFF — resuming normal execution."
            await self.tcp_connection.send_message({
                "jsonrpc": "2.0",
                "method": "chat/assistant_text",
                "params": {"content": state_msg, "is_partial": False}
            })
        # Send a synthetic response to reset is_working state in Godot
        await self.tcp_connection.send_message({
            "jsonrpc": "2.0",
            "method": "chat/response",
            "params": {"content": "", "cost_usd": 0.0, "duration_ms": 0, "num_turns": 0}
        })

    async def _tcp_router(self):
        """Read ALL incoming TCP messages and route by method.

        Runs concurrently with _claude_processor so that TCP messages are always
        being read — even while Claude is processing a query. This prevents the
        deadlock where _answer_queue.get() would block forever because nobody was
        reading the TCP stream.
        """
        while True:
            msg = await self.tcp_connection.receive_message()
            if not msg:
                break
            method = msg.get("method", "")
            if method == "chat/send":
                await self._query_queue.put(msg)
            elif method == "chat/ask_user_answer":
                answer = msg.get("params", {}).get("answer", "")
                await self._answer_queue.put(answer)
            elif method == "chat/permission_response":
                decision = msg.get("params", {}).get("decision", "deny")
                await self._permission_queue.put(decision)
            elif method == "chat/cancel":
                if self._client:
                    logger.info("Interrupt requested by user")
                    await self._client.interrupt()
            else:
                logger.warning(f"Unknown method from Godot: {method}")

    async def _claude_processor(self, client: ClaudeSDKClient):
        """Process chat/send messages through Claude sequentially.

        Runs concurrently with _tcp_router. Picks up messages from _query_queue
        (fed by _tcp_router) and processes them one at a time through Claude.
        """
        while True:
            msg = await self._query_queue.get()
            try:
                params = msg.get("params", {})
                content = params.get("content", "")
                context = params.get("context", {})

                prompt = self._build_prompt_with_context(content, context)
                logger.info(f"User message: {content[:100]}...")

                if content.strip() in _BUILTIN_COMMANDS:
                    await self._handle_builtin_command(content.strip())
                    continue

                await client.query(prompt)
                await self._stream_response_to_godot(client)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Message handling error: {e}", exc_info=True)
                await self.tcp_connection.send_message({
                    "jsonrpc": "2.0",
                    "method": "chat/error",
                    "params": {"error": str(e)}
                })

    async def _run_conversation_loop(self):
        """Main conversation loop with persistent Claude session."""

        # Reset queues and session state for this connection
        self._answer_queue = asyncio.Queue()
        self._query_queue = asyncio.Queue()
        self._permission_queue = asyncio.Queue()
        self._session_allowed_tools = set()
        self._client = None
        self._detected_model = None
        self._plan_mode = False

        # Configure Claude Agent SDK options with PreToolUse hook for AskUserQuestion
        options = ClaudeAgentOptions(
            model=self.model,
            system_prompt=_SYSTEM_PROMPT,
            allowed_tools=["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch"],
            permission_mode="acceptEdits",  # Auto-approve file edits
            include_partial_messages=True,  # Enable streaming
            setting_sources=["user", "project", "local"],  # Required for custom slash commands
            hooks={
                "PreToolUse": [
                    HookMatcher(matcher="AskUserQuestion", hooks=[self._ask_user_hook]),
                    HookMatcher(matcher="WebFetch", hooks=[self._permission_hook]),
                    HookMatcher(matcher="WebSearch", hooks=[self._permission_hook]),
                ]
            }
        )

        logger.info("Creating persistent Claude session...")

        async with ClaudeSDKClient(options=options) as client:
            self._client = client
            logger.info("Claude session established")

            # Log server info for diagnostics (model/context info discovery)
            try:
                server_info = await client.get_server_info()
                if server_info:
                    logger.info(f"Server info keys: {list(server_info.keys())}")
            except Exception:
                pass

            # Send initial system message
            await self.tcp_connection.send_message({
                "jsonrpc": "2.0",
                "method": "chat/system",
                "params": {"message": f"Claude AI assistant ready. Working in: {os.getcwd()}"}
            })

            # Run TCP router and Claude processor concurrently.
            # The task group exits when either task finishes (TCP disconnect or error).
            async with anyio.create_task_group() as tg:
                tg.start_soon(self._tcp_router)
                tg.start_soon(self._claude_processor, client)

    def _build_prompt_with_context(self, content: str, context: dict) -> str:
        """
        Build prompt with Godot editor context and auto-injected class API docs.

        Args:
            content: User's message
            context: Editor context (scene path, selected nodes)

        Returns:
            Enhanced prompt with context and optional Godot API reference block
        """
        # Slash commands must pass through verbatim — no context wrapping or doc injection
        if content.lstrip().startswith("/"):
            return content

        if self._plan_mode:
            plan_instruction = (
                "PLAN MODE ACTIVE: Do not call any tools or make any file changes. "
                "Instead, describe step-by-step what you would do to accomplish the "
                "following task, including which files you would modify and what changes "
                "you would make. The user will review your plan before you execute anything.\n\n"
                "User request:\n"
            )
            content = plan_instruction + content

        # Build the prompt body (context + message)
        if not context:
            prompt = content
        else:
            context_parts = []

            if "scene_path" in context:
                context_parts.append(f"Current scene: {context['scene_path']}")

            if "scene_root_name" in context:
                context_parts.append(f"Scene root: {context['scene_root_name']} ({context.get('scene_root_type', 'Node')})")

            if "selected_nodes" in context and context["selected_nodes"]:
                context_parts.append("Selected nodes:")
                for node in context["selected_nodes"]:
                    node_info = f"  - {node['path']} ({node['type']})"
                    if "script" in node:
                        node_info += f" [script: {node['script']}]"
                    context_parts.append(node_info)

            if context_parts:
                context_str = "\n".join(context_parts)
                prompt = f"**Current Godot Editor Context:**\n{context_str}\n\n**User Message:**\n{content}"
            else:
                prompt = content

        return prompt

    async def _stream_response_to_godot(self, client: ClaudeSDKClient):
        """
        Stream Claude's response back to Godot in real-time.

        Args:
            client: Claude SDK client
        """
        # Send stream start marker
        await self.tcp_connection.send_message({
            "jsonrpc": "2.0",
            "method": "chat/stream_start",
            "params": {"timestamp": time.time()}
        })

        current_text = ""

        async for message in client.receive_response():
            if isinstance(message, AssistantMessage):
                # Detect context window from first response's model name
                if not self._detected_model and message.model:
                    self._detected_model = message.model
                    self._context_window_tokens = _context_window_for_model(message.model)
                    logger.info(f"Detected model: {message.model} → context window: {self._context_window_tokens:,} tokens")
                # Complete message available
                for block in message.content:
                    if isinstance(block, TextBlock):
                        current_text = block.text
                        # Send intermediate text to Godot for real-time display
                        await self.tcp_connection.send_message({
                            "jsonrpc": "2.0",
                            "method": "chat/assistant_text",
                            "params": {
                                "content": block.text,
                                "is_partial": True
                            }
                        })
                    elif isinstance(block, ToolUseBlock):
                        # Tool is being used
                        await self.tcp_connection.send_message({
                            "jsonrpc": "2.0",
                            "method": "chat/tool_use",
                            "params": {
                                "tool_name": block.name,
                                "tool_input": block.input
                            }
                        })

            elif isinstance(message, SystemMessage):
                # System events (can log these)
                logger.debug(f"System event: {message.subtype}")

            elif isinstance(message, ResultMessage):
                # Final result - conversation turn complete
                # Use current_text if available, fall back to message.result
                final_text = current_text if current_text else (message.result or "")
                usage_data = {}
                if message.usage:
                    input_t = message.usage.get("input_tokens", 0)
                    output_t = message.usage.get("output_tokens", 0)
                    total = input_t + output_t
                    usage_data = {
                        "input_tokens": input_t,
                        "output_tokens": output_t,
                        "total_tokens": total,
                        "context_pct": round((total / self._context_window_tokens) * 100, 1)
                    }
                await self.tcp_connection.send_message({
                    "jsonrpc": "2.0",
                    "method": "chat/response",
                    "params": {
                        "content": final_text,
                        "cost_usd": message.total_cost_usd,
                        "duration_ms": message.duration_ms,
                        "num_turns": message.num_turns,
                        "usage": usage_data
                    }
                })

                pct_str = f", {usage_data.get('context_pct', '?')}% ctx" if usage_data else ""
                logger.info(f"Response complete ({message.num_turns} turns, ${message.total_cost_usd:.4f}, {message.duration_ms}ms{pct_str})")
                break

    async def run(self):
        """Start the bridge daemon TCP server."""
        server = await asyncio.start_server(
            self.handle_client,
            self.host,
            self.port
        )

        addr = server.sockets[0].getsockname()
        logger.info(f"Agent Bridge listening on {addr[0]}:{addr[1]}")
        logger.info(f"Model: {self.model}")
        logger.info(f"Ready for Godot connections...")

        async with server:
            await server.serve_forever()


async def main():
    """Entry point for the agent bridge daemon."""
    import argparse

    parser = argparse.ArgumentParser(description="Claudot Agent Bridge Daemon")
    parser.add_argument("--host", default="127.0.0.1", help="TCP server host")
    parser.add_argument("--port", type=int, default=7777, help="TCP server port")
    parser.add_argument("--model", default="claude-opus-4-6", help="Claude model to use")
    parser.add_argument("--log-level", default="INFO", help="Logging level")
    parser.add_argument("--project-root", default="", help="Godot project root directory")

    args = parser.parse_args()

    # Set working directory to the Godot project root so claude CLI finds the right CLAUDE.md.
    if args.project_root:
        project_root = Path(args.project_root)
        if project_root.is_dir():
            os.chdir(project_root)
            logger.info(f"Working directory: {project_root}")
        else:
            logger.warning(f"--project-root '{args.project_root}' is not a directory; using inherited cwd: {os.getcwd()}")
    else:
        logger.warning(f"No --project-root provided; using inherited cwd: {os.getcwd()}")

    bridge = AgentBridge(
        host=args.host,
        port=args.port,
        model=args.model,
        log_level=args.log_level
    )

    try:
        await bridge.run()
    except KeyboardInterrupt:
        logger.info("Bridge shutting down...")


if __name__ == "__main__":
    asyncio.run(main())
