#!/usr/bin/env python3
"""Unit tests for the llmos eval harness."""

from __future__ import annotations

import unittest
from types import SimpleNamespace

import demo.eval as evals


class FakeSession:
    banner = "# llmos v0.1 proto=1 primitives=29"

    def __init__(self, responses: dict[str, str]) -> None:
        self.responses = responses
        self.commands: list[str] = []

    def send(self, command: str) -> str:
        self.commands.append(command)
        return self.responses[command]


class TextBlock:
    type = "text"

    def __init__(self, text: str) -> None:
        self.text = text


class FakeMessages:
    def __init__(self, commands: list[str]) -> None:
        self.commands = commands

    def create(self, **_kwargs):
        command = self.commands.pop(0)
        return SimpleNamespace(content=[TextBlock(command)])


class FakeClient:
    model = "fake-model"

    def __init__(self, commands: list[str]) -> None:
        self.messages = FakeMessages(commands)


class EvalHarnessTests(unittest.TestCase):
    def test_validate_transcript_reports_missing_patterns(self) -> None:
        task = evals.EvalTask(
            name="sample",
            prompt="sample",
            script=(),
            must_match=(r"^< ok ready=1$",),
        )

        self.assertEqual(
            evals.validate_transcript(task, "# eval: sample\n"),
            [r"missing required pattern: ^< ok ready=1$"],
        )

    def test_scripted_task_sends_declared_commands(self) -> None:
        task = evals.EvalTask(
            name="sample",
            prompt="sample",
            script=("help", "cpu.vendor"),
            must_match=(r"^< ok primitives=help", r"^< ok vendor=GenuineIntel "),
        )
        session = FakeSession(
            {
                "help": "ok primitives=help,describe,cpu.vendor",
                "cpu.vendor": "ok vendor=GenuineIntel family=6 model=6 stepping=3",
            }
        )

        transcript, errors = evals.run_scripted_task(task, session)

        self.assertEqual(errors, [])
        self.assertEqual(session.commands, ["help", "cpu.vendor"])
        self.assertIn("> help", transcript)
        self.assertIn("< ok vendor=GenuineIntel", transcript)

    def test_ai_task_requires_done(self) -> None:
        task = evals.EvalTask(
            name="sample",
            prompt="sample",
            script=(),
            must_match=(r"^< ok primitives=help",),
        )
        session = FakeSession({"help": "ok primitives=help,describe"})

        _transcript, errors = evals.run_ai_task(
            task,
            session,
            FakeClient(["help"]),
            limit=1,
        )

        self.assertIn("model did not signal DONE before the step limit", errors)

    def test_ai_task_validates_command_trace(self) -> None:
        task = evals.EvalTask(
            name="sample",
            prompt="sample",
            script=(),
            must_match=(r"^< ok primitives=help",),
        )
        session = FakeSession({"help": "ok primitives=help,describe"})

        transcript, errors = evals.run_ai_task(
            task,
            session,
            FakeClient(["help", "DONE"]),
            limit=2,
        )

        self.assertEqual(errors, [])
        self.assertEqual(session.commands, ["help"])
        self.assertIn("< ok primitives=help,describe", transcript)


if __name__ == "__main__":
    unittest.main()
