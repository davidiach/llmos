#!/usr/bin/env python3
"""
llmos bridge — serial glue between the llmos kernel running under QEMU and
its user (a human at the terminal, a scripted transcript, or the Claude API).

The three modes:

  bridge.py repl                    interactive: you type, llmos responds
  bridge.py script FILE             send each non-comment line from FILE
  bridge.py ai "TASK" [-n LIMIT]    Claude drives llmos to accomplish TASK
                                    (requires ANTHROPIC_API_KEY)

All modes share the same underlying LlmosSession, which launches QEMU with
COM1 on stdio and waits for the `# llmos … proto=1` ready banner before
returning control.
"""

import argparse
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path


DEFAULT_ANTHROPIC_MODEL = "claude-opus-4-7"
READY_BANNER_RE = re.compile(
    r"^# llmos v[0-9][A-Za-z0-9._-]* proto=1 primitives=[0-9]+$"
)


def is_ready_banner(line: str) -> bool:
    """Return true only for the llmos protocol-ready boot banner."""
    return READY_BANNER_RE.fullmatch(line) is not None


class LlmosSession:
    """A running llmos instance. Send commands, get back response lines."""

    def __init__(
        self,
        image: Path,
        qemu: str = "qemu-system-i386",
        qemu_args: list[str] | None = None,
        boot_timeout: float = 5.0,
    ):
        self.image = Path(image)
        if not self.image.exists():
            raise FileNotFoundError(f"image not found: {self.image}")
        launch = [
            qemu,
            "-drive", f"format=raw,if=floppy,file={self.image}",
            "-serial", "stdio",
            "-display", "none",
            "-no-reboot",
        ]
        if qemu_args:
            launch.extend(qemu_args)
        self._stderr_limit = 4096
        self._stderr_buf = bytearray()
        self._stderr_lock = threading.Lock()
        self.proc = subprocess.Popen(
            launch,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        if self.proc.stdin is None or self.proc.stdout is None or self.proc.stderr is None:
            raise RuntimeError("failed to open llmos stdio pipes")
        self._stdout_queue: queue.Queue[bytes | None] = queue.Queue()
        self._stdout_thread = threading.Thread(
            target=self._pump_stdout,
            name="llmos-stdout",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._pump_stderr,
            name="llmos-stderr",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()
        self._sync_lost = False
        try:
            self.banner = self._await_banner(boot_timeout)
        except BaseException as exc:
            qemu_exited = self.proc.poll() is not None
            stderr = self._stderr_text()
            self.close()
            if qemu_exited and not stderr:
                stderr = self._stderr_text()
            if qemu_exited and stderr:
                raise RuntimeError(f"{exc}; qemu stderr: {stderr}") from exc
            raise
        self.log: list[tuple[str, str]] = []   # (request, response) history

    # ----- low-level I/O ----------------------------------------------------

    def _pump_stdout(self) -> None:
        """Read bytes from QEMU on a worker thread so timeouts stay enforceable."""
        assert self.proc.stdout is not None
        try:
            while True:
                ch = self.proc.stdout.read(1)
                if not ch:
                    break
                self._stdout_queue.put(ch)
        except OSError:
            pass
        finally:
            self._stdout_queue.put(None)

    def _pump_stderr(self) -> None:
        """Capture bounded QEMU stderr so startup failures stay diagnosable."""
        assert self.proc.stderr is not None
        try:
            while True:
                chunk = self.proc.stderr.read(1024)
                if not chunk:
                    break
                with self._stderr_lock:
                    self._stderr_buf.extend(chunk)
                    if len(self._stderr_buf) > self._stderr_limit:
                        del self._stderr_buf[: len(self._stderr_buf) - self._stderr_limit]
        except OSError:
            pass

    def _stderr_text(self) -> str:
        with self._stderr_lock:
            data = bytes(self._stderr_buf)
        return data.decode("utf-8", errors="replace").strip()

    def _readline(self, timeout: float = 2.0) -> str:
        """Read one \\r\\n-terminated line from the kernel, with a deadline."""
        deadline = time.monotonic() + timeout
        buf = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response within {timeout}s (partial: {buf!r})")
            try:
                ch = self._stdout_queue.get(timeout=remaining)
            except queue.Empty as exc:
                raise TimeoutError(f"no response within {timeout}s (partial: {buf!r})") from exc
            if ch is None:
                raise EOFError(
                    f"llmos exited before completing a line (partial: {buf!r})"
                )
            if ch == b"\r":
                continue
            if ch == b"\n":
                return buf.decode("ascii", errors="replace")
            buf += ch

    def _await_banner(self, timeout: float) -> str:
        """Read lines until we see the protocol-ready llmos boot banner."""
        deadline = time.monotonic() + timeout
        last_line: str | None = None
        while time.monotonic() < deadline:
            line = self._readline(timeout=deadline - time.monotonic())
            if is_ready_banner(line):
                return line
            last_line = line
        message = "llmos never produced a ready banner"
        if last_line is not None:
            message += f" (last line: {last_line!r})"
        raise TimeoutError(message)

    def send(self, cmd: str, timeout: float = 2.0) -> str:
        """Send one command, return its single-line response."""
        if self._sync_lost:
            raise RuntimeError("session is desynchronized; restart llmos")
        if "\r" in cmd or "\n" in cmd:
            raise ValueError("llmos commands must be a single line")
        if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in cmd):
            raise ValueError("llmos commands must be printable ASCII")
        try:
            payload = (cmd + "\r\n").encode("ascii")
        except UnicodeEncodeError as exc:
            raise ValueError("llmos commands must be ASCII") from exc
        assert self.proc.stdin is not None
        try:
            self.proc.stdin.write(payload)
            self.proc.stdin.flush()
        except OSError as exc:
            self._sync_lost = True
            raise EOFError("llmos stdin closed while sending command") from exc
        try:
            resp = self._readline(timeout=timeout)
        except (EOFError, TimeoutError):
            self._sync_lost = True
            raise
        self.log.append((cmd, resp))
        return resp

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    self.proc.kill()
                    self.proc.wait(timeout=1.0)
                except Exception:
                    pass
            except Exception:
                try:
                    self.proc.kill()
                    self.proc.wait(timeout=1.0)
                except Exception:
                    pass
        for thread_name in ("_stdout_thread", "_stderr_thread"):
            thread = getattr(self, thread_name, None)
            if thread is not None and thread.is_alive():
                thread.join(timeout=0.2)


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

def command_for_log(cmd: str) -> str:
    """Return a terminal-safe representation of a command line."""
    if all(0x20 <= ord(ch) <= 0x7E for ch in cmd):
        return cmd
    return ascii(cmd)


def extract_ai_command(text: str) -> str:
    """Extract the command from an AI text response."""
    fenced_blocks: list[list[str]] = []
    block: list[str] = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            if in_fence:
                fenced_blocks.append(block)
                block = []
                in_fence = False
            else:
                block = []
                in_fence = True
            continue
        if in_fence:
            block.append(line)
    if in_fence:
        raise ValueError("unterminated command block")

    if fenced_blocks:
        if len(fenced_blocks) > 1:
            raise ValueError("ambiguous command blocks")
        lines = [line.strip() for line in fenced_blocks[-1] if line.strip()]
        if len(lines) > 1:
            raise ValueError("ambiguous command block")
    else:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    cmd = lines[-1]
    if len(cmd) >= 2 and cmd.startswith("`") and cmd.endswith("`"):
        cmd = cmd.strip("`").strip()
    return cmd


def mode_repl(session: LlmosSession) -> int:
    """Interactive REPL. Type commands, see responses."""
    print(f"[bridge] connected. kernel said: {session.banner}")
    print("[bridge] type a command (empty line to quit)")
    while True:
        try:
            cmd = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not cmd:
            return 0
        try:
            resp = session.send(cmd)
        except ValueError as e:
            print(f"[bridge] invalid command: {e}", file=sys.stderr)
            continue
        except TimeoutError as e:
            print(f"[bridge] timeout: {e}", file=sys.stderr)
            return 1
        except (EOFError, RuntimeError) as e:
            print(f"[bridge] disconnected: {e}", file=sys.stderr)
            return 1
        print(f"< {resp}")


def mode_script(
    session: LlmosSession,
    path: Path,
    lines: list[str] | None = None,
) -> int:
    """Send every non-comment, non-empty line from the given file."""
    if lines is None:
        lines = path.read_text(encoding="utf-8").splitlines()
    print(session.banner)
    for raw in lines:
        if not raw or raw.startswith("#"):
            if raw.startswith("#"):
                print(raw)
            continue
        print(f"> {command_for_log(raw)}")
        try:
            resp = session.send(raw)
        except ValueError as e:
            print(f"# invalid command: {e}")
            return 1
        except TimeoutError as e:
            print(f"# timeout: {e}")
            return 1
        except (EOFError, RuntimeError) as e:
            print(f"# disconnected: {e}")
            return 1
        print(f"< {resp}")
    return 0


def make_anthropic_client():
    if "ANTHROPIC_API_KEY" not in os.environ:
        print("error: set ANTHROPIC_API_KEY", file=sys.stderr)
        sys.exit(2)
    try:
        import anthropic
    except ImportError:
        print("error: pip install anthropic", file=sys.stderr)
        sys.exit(2)
    return anthropic.Anthropic()


def load_script_lines(path: Path) -> list[str]:
    if not path.is_file():
        print(f"error: script file not found: {path}", file=sys.stderr)
        sys.exit(2)
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as e:
        print(f"error: cannot read script file: {path}: {e}", file=sys.stderr)
        sys.exit(2)


def preflight_image_path(path: Path) -> None:
    if not path.is_file():
        print(f"error: image file not found: {path}", file=sys.stderr)
        sys.exit(2)


def preflight_qemu(qemu: str) -> None:
    if shutil.which(qemu) is None:
        print(f"error: qemu executable not found: {qemu}", file=sys.stderr)
        sys.exit(2)


def preflight_ai_limit(limit: int) -> None:
    if limit < 1:
        print("error: AI step limit must be at least 1", file=sys.stderr)
        sys.exit(2)


def preflight_ai_task(task: str) -> None:
    if not task.strip():
        print("error: AI task must not be empty", file=sys.stderr)
        sys.exit(2)


def mode_ai(
    session: LlmosSession,
    task: str,
    step_limit: int = 20,
    client=None,
) -> int:
    """Let Claude drive llmos to accomplish the given task.

    The conversation is a single multi-turn chat: each turn Claude proposes
    exactly one command, we execute it, we feed the response back, repeat.
    """
    if client is None:
        client = make_anthropic_client()
    system = (
        "You are connected to an operating system called llmos over a serial "
        "protocol. You have never seen this OS before — figure it out from "
        "the inside.\n\n"
        "Protocol:\n"
        "- You send exactly ONE command per turn, on its own line, no quotes "
        "or commentary.\n"
        "- The kernel replies with exactly one line, starting with `ok` or "
        "`err` followed by key=value fields.\n"
        "- You do not have a prompt or a shell. Every command is a single "
        "token followed by optional key=value arguments.\n"
        "- To discover what you can do, send `help`. To learn what a "
        "primitive does, send `describe NAME`.\n"
        "- When you have accomplished the task, send exactly: DONE\n"
        "- Otherwise, your entire response must be a single llmos command."
    )
    prompt = f"Task: {task}\n\nKernel banner on boot: {session.banner}\n\nWhat is your first command?"
    messages = [{"role": "user", "content": prompt}]
    model = os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL)
    print(f"# task: {task}")
    print(f"# banner: {session.banner}")

    for step in range(step_limit):
        try:
            resp = client.messages.create(
                model=model,
                max_tokens=256,
                system=system,
                messages=messages,
            )
        except Exception as e:
            print(f"# ai error: {e}")
            return 1
        try:
            cmd = "\n".join(
                b.text for b in resp.content if getattr(b, "type", None) == "text"
            ).strip()
        except Exception as e:
            print(f"# ai error: {e}")
            return 1
        try:
            cmd = extract_ai_command(cmd)
        except ValueError as e:
            print(f"# ai error: {e}")
            return 1
        if not cmd:
            print("# ai error: empty command")
            return 1
        print(f"> {command_for_log(cmd)}")
        if cmd.upper() == "DONE":
            print("# claude signalled task complete")
            return 0
        try:
            kernel_resp = session.send(cmd)
        except ValueError as e:
            kernel_resp = f"err code=bad_arg detail=\"{e}\""
        except TimeoutError as e:
            kernel_resp = f"err code=timeout detail=\"{e}\""
            print(f"< {kernel_resp}")
            print("# session desynchronized after timeout")
            return 1
        except (EOFError, RuntimeError) as e:
            print(f"# disconnected: {e}")
            return 1
        print(f"< {kernel_resp}")
        messages.append({"role": "assistant", "content": cmd})
        messages.append({"role": "user", "content": kernel_resp})
    print("# step limit reached")
    return 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="llmos serial bridge")
    p.add_argument(
        "--image",
        default=Path(__file__).parent.parent / "build" / "llmos.img",
        type=Path,
        help="path to llmos.img (default: ../build/llmos.img)",
    )
    p.add_argument(
        "--qemu",
        default="qemu-system-i386",
        help="qemu binary to invoke",
    )
    p.add_argument(
        "--qemu-arg",
        action="append",
        default=[],
        help="extra argument to pass through to QEMU (repeatable)",
    )
    sub = p.add_subparsers(dest="mode", required=True)
    sub.add_parser("repl", help="interactive REPL")
    sp_script = sub.add_parser("script", help="replay a transcript file")
    sp_script.add_argument("file", type=Path)
    sp_ai = sub.add_parser("ai", help="let Claude drive")
    sp_ai.add_argument("task", help="task description")
    sp_ai.add_argument("-n", "--limit", type=int, default=20, help="step limit")
    args = p.parse_args()

    if args.mode == "ai":
        preflight_ai_limit(args.limit)
        preflight_ai_task(args.task)
    script_lines = load_script_lines(args.file) if args.mode == "script" else None
    ai_client = make_anthropic_client() if args.mode == "ai" else None
    preflight_image_path(args.image)
    preflight_qemu(args.qemu)
    try:
        session = LlmosSession(image=args.image, qemu=args.qemu, qemu_args=args.qemu_arg)
    except (EOFError, OSError, RuntimeError, TimeoutError) as e:
        print(f"error: failed to start llmos: {e}", file=sys.stderr)
        return 2
    try:
        if args.mode == "repl":
            return mode_repl(session)
        elif args.mode == "script":
            return mode_script(session, args.file, script_lines)
        elif args.mode == "ai":
            return mode_ai(session, args.task, step_limit=args.limit, client=ai_client)
    finally:
        session.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
