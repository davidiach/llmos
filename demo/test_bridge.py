#!/usr/bin/env python3
"""Unit tests for the llmos bridge helpers.

These tests stay stdlib-only so they can run anywhere the bridge itself runs.
QEMU-backed protocol tests live in the transcript smoke target.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import demo.bridge as bridge


KERNEL_ASM = Path(__file__).resolve().parents[1] / "src" / "kernel.asm"


class BridgeHelperTests(unittest.TestCase):
    def test_is_ready_banner_accepts_llmos_protocol_banner(self) -> None:
        self.assertTrue(bridge.is_ready_banner("# llmos v0.1 proto=1 primitives=29"))

    def test_is_ready_banner_rejects_other_system_lines(self) -> None:
        self.assertFalse(bridge.is_ready_banner("# warming up serial"))
        self.assertFalse(bridge.is_ready_banner("# llmos v0.1 proto=2 primitives=29"))
        self.assertFalse(bridge.is_ready_banner("llmos v0.1 proto=1 primitives=29"))

    def test_command_for_log_keeps_printable_ascii(self) -> None:
        self.assertEqual(bridge.command_for_log("help x=1"), "help x=1")

    def test_command_for_log_escapes_non_printable_bytes(self) -> None:
        self.assertEqual(bridge.command_for_log("help\x00"), "'help\\x00'")

    def test_extract_ai_command_accepts_single_plain_command(self) -> None:
        self.assertEqual(bridge.extract_ai_command("help"), "help")
        self.assertEqual(
            bridge.extract_ai_command("describe cpu.vendor"),
            "describe cpu.vendor",
        )
        self.assertEqual(bridge.extract_ai_command("DONE"), "DONE")

    def test_extract_ai_command_rejects_inline_code(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("`help`")

    def test_extract_ai_command_rejects_fenced_command(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("```llmos\nmem.query\n```")

    def test_extract_ai_command_rejects_plain_commentary(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("I will inspect it.\n`help`")

    def test_extract_ai_command_rejects_fenced_commentary(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("```llmos\nhelp\n```\nDone.")

    def test_extract_ai_command_rejects_multi_line_fence(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("```llmos\nhelp\nmem.query\n```")

    def test_extract_ai_command_rejects_multiple_fences(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("```llmos\nhelp\n```\n```llmos\nmem.query\n```")

    def test_extract_ai_command_rejects_unterminated_fence(self) -> None:
        with self.assertRaisesRegex(ValueError, "bare command line"):
            bridge.extract_ai_command("```llmos\nhelp")

    def test_extract_ai_command_returns_empty_for_empty_text(self) -> None:
        self.assertEqual(bridge.extract_ai_command(" \n\t "), "")


class BridgePreflightTests(unittest.TestCase):
    def assert_exits_2_with_stderr(self, func, message: str, *args) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                func(*args)
        self.assertEqual(raised.exception.code, 2)
        self.assertIn(message, stderr.getvalue())

    def test_ai_limit_preflight_rejects_non_positive_values(self) -> None:
        self.assert_exits_2_with_stderr(
            bridge.preflight_ai_limit,
            "AI step limit must be at least 1",
            0,
        )

    def test_ai_task_preflight_rejects_blank_task(self) -> None:
        self.assert_exits_2_with_stderr(
            bridge.preflight_ai_task,
            "AI task must not be empty",
            " \t ",
        )

    def test_missing_image_preflight_exits_before_session_start(self) -> None:
        self.assert_exits_2_with_stderr(
            bridge.preflight_image_path,
            "image file not found",
            Path(tempfile.gettempdir()) / "llmos-definitely-missing.img",
        )

    def test_missing_qemu_preflight_is_reported(self) -> None:
        self.assert_exits_2_with_stderr(
            bridge.preflight_qemu,
            "qemu executable not found",
            "llmos-definitely-missing-qemu",
        )

    def test_script_loader_rejects_missing_file(self) -> None:
        self.assert_exits_2_with_stderr(
            bridge.load_script_lines,
            "script file not found",
            Path(tempfile.gettempdir()) / "llmos-definitely-missing.llmos",
        )

    def test_script_loader_rejects_invalid_utf8(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "bad.llmos"
            script.write_bytes(b"\xff\n")
            self.assert_exits_2_with_stderr(
                bridge.load_script_lines,
                "cannot read script file",
                script,
            )

    def test_make_anthropic_client_requires_api_key_before_import(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assert_exits_2_with_stderr(
                bridge.make_anthropic_client,
                "set ANTHROPIC_API_KEY",
            )


class FakeSession:
    banner = "# llmos test proto=1"

    def __init__(self, response: str = "ok primitives=help") -> None:
        self.commands: list[str] = []
        self.response = response

    def send(self, cmd: str) -> str:
        self.commands.append(cmd)
        return self.response


class TextBlock:
    type = "text"

    def __init__(self, text: str) -> None:
        self.text = text


class ClientReturning:
    def __init__(self, *texts: str) -> None:
        self.calls: list[dict] = []
        self._texts = texts
        self.messages = self

    def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(content=[TextBlock(text) for text in self._texts])


class ClientRaising:
    messages = None

    def __init__(self, exc: Exception) -> None:
        self._exc = exc
        self.messages = self

    def create(self, **kwargs):
        raise self._exc


class ClosablePipe:
    def __init__(self, name: str = "pipe", events: list[str] | None = None) -> None:
        self.name = name
        self.events = events
        self.closed = False

    def read(self, size: int) -> bytes:
        return b""

    def close(self) -> None:
        self.closed = True
        if self.events is not None:
            self.events.append(f"close:{self.name}")


class FakeProcess:
    def __init__(self, stdin=..., events: list[str] | None = None):
        self.events = events
        self.stdin = ClosablePipe("stdin", events) if stdin is ... else stdin
        self.stdout = ClosablePipe("stdout", events)
        self.stderr = ClosablePipe("stderr", events)
        self.terminated = False
        self.killed = False
        self.wait_calls = 0
        self.returncode = None

    def poll(self):
        return self.returncode

    def terminate(self) -> None:
        self.terminated = True
        if self.events is not None:
            self.events.append("terminate")

    def kill(self) -> None:
        self.killed = True
        if self.events is not None:
            self.events.append("kill")

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self.events is not None:
            self.events.append("wait")
        self.returncode = 0
        return self.returncode


class FakeThread:
    def __init__(self, name: str, events: list[str]) -> None:
        self.name = name
        self.events = events

    def is_alive(self) -> bool:
        return True

    def join(self, timeout=None) -> None:
        self.events.append(f"join:{self.name}")


class BridgeSessionTests(unittest.TestCase):
    def image_path(self, tmp: str) -> Path:
        image = Path(tmp) / "llmos.img"
        image.write_bytes(b"fake")
        return image

    def test_init_closes_process_when_stdio_pipe_validation_fails(self) -> None:
        proc = FakeProcess(stdin=None)
        with tempfile.TemporaryDirectory() as tmp:
            with patch("demo.bridge.subprocess.Popen", return_value=proc):
                with self.assertRaisesRegex(RuntimeError, "stdio pipes"):
                    bridge.LlmosSession(self.image_path(tmp))

        self.assertTrue(proc.terminated)
        self.assertEqual(proc.wait_calls, 1)
        self.assertTrue(proc.stdout.closed)
        self.assertTrue(proc.stderr.closed)

    def test_init_closes_process_when_banner_wait_fails(self) -> None:
        proc = FakeProcess()
        with tempfile.TemporaryDirectory() as tmp:
            with patch("demo.bridge.subprocess.Popen", return_value=proc):
                with patch.object(
                    bridge.LlmosSession,
                    "_await_banner",
                    side_effect=TimeoutError("synthetic banner timeout"),
                ):
                    with self.assertRaisesRegex(TimeoutError, "synthetic banner"):
                        bridge.LlmosSession(self.image_path(tmp))

        self.assertTrue(proc.terminated)
        self.assertEqual(proc.wait_calls, 1)
        self.assertTrue(proc.stdin.closed)
        self.assertTrue(proc.stdout.closed)
        self.assertTrue(proc.stderr.closed)

    def test_close_joins_pumps_before_closing_reader_pipes(self) -> None:
        events: list[str] = []
        session = object.__new__(bridge.LlmosSession)
        session.proc = FakeProcess(events=events)
        session._stdout_thread = FakeThread("stdout", events)
        session._stderr_thread = FakeThread("stderr", events)

        session.close()

        self.assertLess(events.index("join:stdout"), events.index("close:stdout"))
        self.assertLess(events.index("join:stderr"), events.index("close:stderr"))

    def test_await_banner_ignores_non_ready_system_lines(self) -> None:
        session = object.__new__(bridge.LlmosSession)
        lines = iter(
            [
                "# serial diagnostics",
                "boot chatter",
                "# llmos v0.1 proto=1 primitives=29",
            ]
        )
        session._readline = lambda timeout: next(lines)

        self.assertEqual(
            session._await_banner(1.0),
            "# llmos v0.1 proto=1 primitives=29",
        )

    def test_await_banner_times_out_on_invalid_banner(self) -> None:
        session = object.__new__(bridge.LlmosSession)
        session._readline = lambda timeout: "# llmos v0.1 proto=2 primitives=29"
        times = iter([0.0, 0.0, 0.0])

        with patch("demo.bridge.time.monotonic", side_effect=lambda: next(times, 10.0)):
            with self.assertRaisesRegex(TimeoutError, "proto=2"):
                session._await_banner(1.0)


class KernelMetadataTests(unittest.TestCase):
    def test_command_tables_match_protocol_metadata(self) -> None:
        text = KERNEL_ASM.read_text(encoding="utf-8")

        cmd_table = re.search(
            r"^cmd_table:\n(?P<body>.*?)^\s*dw\s+0\b",
            text,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(cmd_table)
        cmd_labels = re.findall(
            r"^\s*dw\s+(cmd_[A-Za-z0-9_]+),\s+h_[A-Za-z0-9_]+",
            cmd_table.group("body"),
            re.MULTILINE,
        )

        command_defs = dict(
            re.findall(
                r"^(cmd_[A-Za-z0-9_]+):\s+db\s+'([^']+)',\s*0",
                text,
                re.MULTILINE,
            )
        )
        missing_commands = [label for label in cmd_labels if label not in command_defs]
        self.assertEqual(missing_commands, [])
        commands = [command_defs[label] for label in cmd_labels]

        schema_table = re.search(
            r"^schema_table:\n(?P<body>.*?)^\s*dw\s+0\b",
            text,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(schema_table)
        schema_labels = re.findall(
            r"^\s*dw\s+(cmd_[A-Za-z0-9_]+),\s+sch_[A-Za-z0-9_]+",
            schema_table.group("body"),
            re.MULTILINE,
        )
        self.assertEqual(schema_labels, cmd_labels)

        ready_msg = re.search(
            r"^ready_msg:\s+db '# llmos [^']* primitives=([0-9]+)'",
            text,
            re.MULTILINE,
        )
        self.assertIsNotNone(ready_msg)
        self.assertEqual(int(ready_msg.group(1)), len(commands))

        help_response = re.search(
            r"^help_response:\n\s+db 'ok primitives=([^']+)', 0",
            text,
            re.MULTILINE,
        )
        self.assertIsNotNone(help_response)
        self.assertEqual(help_response.group(1).split(","), commands)


class BridgeModeTests(unittest.TestCase):
    def test_mode_script_preserves_exact_non_comment_lines(self) -> None:
        session = FakeSession()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_script(
                session,
                Path("unused.llmos"),
                lines=["# comment", "", " help", "mem.query"],
            )
        self.assertEqual(rc, 0)
        self.assertEqual(session.commands, [" help", "mem.query"])
        self.assertIn(">  help", out.getvalue())

    def test_mode_script_reports_invalid_command(self) -> None:
        class BadSession(FakeSession):
            def send(self, cmd: str) -> str:
                raise ValueError("bad script command")

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_script(BadSession(), Path("unused.llmos"), lines=["bad"])
        self.assertEqual(rc, 1)
        self.assertIn("# invalid command: bad script command", out.getvalue())

    def test_mode_ai_reports_client_failure(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                FakeSession(),
                "task",
                client=ClientRaising(RuntimeError("anthropic unavailable")),
            )
        self.assertEqual(rc, 1)
        self.assertIn("# ai error: anthropic unavailable", out.getvalue())

    def test_mode_ai_reports_empty_command(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(FakeSession(), "task", client=ClientReturning(" \n\t "))
        self.assertEqual(rc, 1)
        self.assertIn("# ai error: empty command", out.getvalue())

    def test_mode_ai_reports_wrapped_command(self) -> None:
        session = FakeSession()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                session,
                "task",
                step_limit=1,
                client=ClientReturning("```llmos\nhelp\n```"),
            )
        self.assertEqual(rc, 1)
        self.assertEqual(session.commands, [])
        self.assertIn(
            "# ai error: AI response must be exactly one bare command line",
            out.getvalue(),
        )

    def test_mode_ai_reports_split_text_commentary(self) -> None:
        session = FakeSession()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                session,
                "task",
                step_limit=1,
                client=ClientReturning("Here is the command:", "`help`"),
            )
        self.assertEqual(rc, 1)
        self.assertEqual(session.commands, [])
        self.assertIn(
            "# ai error: AI response must be exactly one bare command line",
            out.getvalue(),
        )

    def test_mode_ai_requires_exact_done_case(self) -> None:
        session = FakeSession()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                session,
                "task",
                step_limit=1,
                client=ClientReturning("done"),
            )
        self.assertEqual(rc, 1)
        self.assertEqual(session.commands, ["done"])
        self.assertIn("# step limit reached", out.getvalue())

    def test_mode_ai_reports_ambiguous_command_block(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                FakeSession(),
                "task",
                step_limit=1,
                client=ClientReturning("```llmos\nhelp\nmem.query\n```"),
            )
        self.assertEqual(rc, 1)
        self.assertIn(
            "# ai error: AI response must be exactly one bare command line",
            out.getvalue(),
        )

    def test_mode_ai_uses_model_from_environment(self) -> None:
        client = ClientReturning("DONE")
        out = io.StringIO()
        with patch.dict(os.environ, {"ANTHROPIC_MODEL": "test-model"}):
            with contextlib.redirect_stdout(out):
                rc = bridge.mode_ai(FakeSession(), "task", client=client)
        self.assertEqual(rc, 0)
        self.assertEqual(client.calls[0]["model"], "test-model")
        self.assertIn("# claude signalled task complete", out.getvalue())


if __name__ == "__main__":
    unittest.main()
