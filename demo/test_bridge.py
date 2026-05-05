#!/usr/bin/env python3
"""Unit tests for the llmos bridge helpers.

These tests stay stdlib-only so they can run anywhere the bridge itself runs.
QEMU-backed protocol tests live in the transcript smoke target.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import demo.bridge as bridge


class BridgeHelperTests(unittest.TestCase):
    def test_command_for_log_keeps_printable_ascii(self) -> None:
        self.assertEqual(bridge.command_for_log("help x=1"), "help x=1")

    def test_command_for_log_escapes_non_printable_bytes(self) -> None:
        self.assertEqual(bridge.command_for_log("help\x00"), "'help\\x00'")

    def test_extract_ai_command_uses_last_plain_line(self) -> None:
        self.assertEqual(
            bridge.extract_ai_command("I will inspect it.\n`help`"),
            "help",
        )

    def test_extract_ai_command_accepts_single_fenced_command(self) -> None:
        self.assertEqual(
            bridge.extract_ai_command("```llmos\nmem.query\n```\nDone."),
            "mem.query",
        )

    def test_extract_ai_command_rejects_multi_line_fence(self) -> None:
        with self.assertRaisesRegex(ValueError, "ambiguous command block"):
            bridge.extract_ai_command("```llmos\nhelp\nmem.query\n```")

    def test_extract_ai_command_rejects_multiple_fences(self) -> None:
        with self.assertRaisesRegex(ValueError, "ambiguous command blocks"):
            bridge.extract_ai_command("```llmos\nhelp\n```\n```llmos\nmem.query\n```")

    def test_extract_ai_command_rejects_unterminated_fence(self) -> None:
        with self.assertRaisesRegex(ValueError, "unterminated command block"):
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

    def test_mode_ai_extracts_wrapped_command(self) -> None:
        session = FakeSession()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bridge.mode_ai(
                session,
                "task",
                step_limit=1,
                client=ClientReturning("```llmos\nhelp\n```\nThat should list commands."),
            )
        self.assertEqual(rc, 1)
        self.assertEqual(session.commands, ["help"])
        self.assertIn("> help", out.getvalue())
        self.assertNotIn("```", out.getvalue())

    def test_mode_ai_keeps_split_text_blocks_distinct(self) -> None:
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
        self.assertEqual(session.commands, ["help"])
        self.assertIn("> help", out.getvalue())

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
        self.assertIn("# ai error: ambiguous command block", out.getvalue())

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
