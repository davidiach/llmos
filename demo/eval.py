#!/usr/bin/env python3
"""Task-level eval harness for llmos command traces."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from demo.bridge import (  # noqa: E402
    LlmosSession,
    command_for_log,
    extract_ai_command,
    make_anthropic_client,
    preflight_ai_limit,
    preflight_image_path,
    preflight_qemu,
)


@dataclass(frozen=True)
class EvalTask:
    name: str
    prompt: str
    script: tuple[str, ...]
    must_match: tuple[str, ...]
    must_not_match: tuple[str, ...] = ()


TASKS: tuple[EvalTask, ...] = (
    EvalTask(
        name="machine-id",
        prompt="Identify the CPU, memory size, and broad machine topology.",
        script=(
            "help",
            "describe cpu.vendor",
            "cpu.vendor",
            "mem.query",
            "pci.scan",
        ),
        must_match=(
            r"^< ok primitives=help,describe",
            r"^< ok name=cpu\.vendor ",
            r"^< ok vendor=GenuineIntel ",
            r"^< ok conv_kb=[0-9]+ ext_kb=[0-9]+ ",
            r"^< ok devices=.*00\.02\.0:1234:1111:03",
        ),
    ),
    EvalTask(
        name="denied-smart",
        prompt=(
            "Explain why the OS cannot read ATA SMART status, then find one "
            "legal adjacent hardware fact."
        ),
        script=(
            "io.in port=1f0",
            "io.in port=1f7",
            "describe io.in",
            "mem.read addr=400 len=128",
        ),
        must_match=(
            r'^< err code=denied detail="port not in allowlist"$',
            r"^< ok name=io\.in .*allowlist=.*0x3f8.*0x3ff",
            r"^< ok addr=0400 len=128 data=[0-9a-f]+$",
        ),
    ),
    EvalTask(
        name="pci-topology",
        prompt=(
            "Inspect the PCI bus, decode display BARs, and read identifying "
            "config bytes from the display device."
        ),
        script=(
            "describe pci.scan",
            "pci.scan",
            "describe pci.bars",
            "pci.bars bdf=00.02.0",
            "pci.config.read bdf=00.02.0 offset=0 len=4",
            "pci.mem.read bdf=00.02.0 bar=0 offset=0 len=4",
        ),
        must_match=(
            r"^< ok name=pci\.scan ",
            r"^< ok devices=.*00\.02\.0:1234:1111:03",
            r"^< ok name=pci\.bars ",
            r"^< ok bdf=00\.02\.0 bars=0:m32:[0-9a-f]{8}:p",
            r"^< ok bdf=00\.02\.0 offset=00 len=4 data=34121111$",
            r"^< ok bdf=00\.02\.0 bar=0 kind=m32 addr=[0-9a-f]{8} "
            r"offset=0000 len=4 data=[0-9a-f]{8}$",
        ),
    ),
)


TASK_BY_NAME = {task.name: task for task in TASKS}

EVAL_SYSTEM = (
    "You are connected to llmos over a serial protocol. Send exactly one "
    "bare command per turn, with no quotes or commentary. Use help and "
    "describe to discover the interface. When the eval task is complete, "
    "send exactly DONE."
)


def task_names() -> str:
    return ", ".join(task.name for task in TASKS)


def select_tasks(names: list[str]) -> list[EvalTask]:
    if not names:
        return list(TASKS)
    unknown = [name for name in names if name not in TASK_BY_NAME]
    if unknown:
        raise SystemExit(
            f"unknown eval task(s): {', '.join(unknown)}; available: {task_names()}"
        )
    return [TASK_BY_NAME[name] for name in names]


def transcript_for(
    task: EvalTask,
    banner: str,
    events: list[tuple[str, str]],
) -> str:
    lines = [f"# eval: {task.name}", f"# task: {task.prompt}", banner]
    for command, response in events:
        lines.append(f"> {command_for_log(command)}")
        lines.append(f"< {response}")
    return "\n".join(lines) + "\n"


def validate_transcript(task: EvalTask, transcript: str) -> list[str]:
    errors: list[str] = []
    for pattern in task.must_match:
        if re.search(pattern, transcript, re.MULTILINE) is None:
            errors.append(f"missing required pattern: {pattern}")
    for pattern in task.must_not_match:
        if re.search(pattern, transcript, re.MULTILINE) is not None:
            errors.append(f"forbidden pattern matched: {pattern}")
    return errors


def run_scripted_task(task: EvalTask, session: LlmosSession) -> tuple[str, list[str]]:
    events: list[tuple[str, str]] = []
    for command in task.script:
        events.append((command, session.send(command)))
    transcript = transcript_for(task, session.banner, events)
    return transcript, validate_transcript(task, transcript)


def run_ai_task(
    task: EvalTask,
    session: LlmosSession,
    client,
    limit: int,
) -> tuple[str, list[str]]:
    prompt = (
        f"Eval task: {task.prompt}\n\n"
        f"Kernel banner on boot: {session.banner}\n\n"
        "What is your first command?"
    )
    messages = [{"role": "user", "content": prompt}]
    events: list[tuple[str, str]] = []
    done = False

    for _step in range(limit):
        response = client.messages.create(
            model=client.model,
            max_tokens=256,
            system=EVAL_SYSTEM,
            messages=messages,
        )
        text = "\n".join(
            block.text
            for block in response.content
            if getattr(block, "type", None) == "text"
        )
        command = extract_ai_command(text)
        if command == "DONE":
            done = True
            break
        kernel_response = session.send(command)
        events.append((command, kernel_response))
        messages.append({"role": "assistant", "content": command})
        messages.append({"role": "user", "content": kernel_response})

    transcript = transcript_for(task, session.banner, events)
    errors = validate_transcript(task, transcript)
    if not done:
        errors.append("model did not signal DONE before the step limit")
    return transcript, errors


class AnthropicEvalClient:
    def __init__(self, model: str):
        self.model = model
        self.messages = make_anthropic_client().messages


def report_result(transcript: str, errors: list[str]) -> bool:
    print(transcript, end="")
    if errors:
        for error in errors:
            print(f"# eval failure: {error}")
        return False
    print("# eval passed")
    return True


def run_scripted(args) -> int:
    failed = 0
    for task in select_tasks(args.tasks):
        session = LlmosSession(args.image, qemu=args.qemu, qemu_args=args.qemu_arg)
        try:
            transcript, errors = run_scripted_task(task, session)
        finally:
            session.close()
        if not report_result(transcript, errors):
            failed += 1
    return 1 if failed else 0


def run_ai(args) -> int:
    import os

    failed = 0
    client = AnthropicEvalClient(os.environ.get("ANTHROPIC_MODEL", args.model))
    for task in select_tasks(args.tasks):
        session = LlmosSession(args.image, qemu=args.qemu, qemu_args=args.qemu_arg)
        try:
            transcript, errors = run_ai_task(task, session, client, args.limit)
        finally:
            session.close()
        if not report_result(transcript, errors):
            failed += 1
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image",
        default=Path(__file__).parent.parent / "build" / "llmos.img",
        type=Path,
        help="path to llmos.img",
    )
    parser.add_argument("--qemu", default="qemu-system-i386")
    parser.add_argument("--qemu-arg", action="append", default=[])
    sub = parser.add_subparsers(dest="mode", required=True)

    scripted = sub.add_parser("scripted", help="run deterministic eval scripts")
    scripted.add_argument("tasks", nargs="*", help=f"tasks: {task_names()}")

    ai = sub.add_parser("ai", help="run model-driven evals")
    ai.add_argument("tasks", nargs="*", help=f"tasks: {task_names()}")
    ai.add_argument("-n", "--limit", type=int, default=20)
    ai.add_argument("--model", default="claude-opus-4-7")

    args = parser.parse_args()
    if args.mode == "ai":
        preflight_ai_limit(args.limit)
    preflight_image_path(args.image)
    preflight_qemu(args.qemu)

    if args.mode == "scripted":
        return run_scripted(args)
    return run_ai(args)


if __name__ == "__main__":
    raise SystemExit(main())
