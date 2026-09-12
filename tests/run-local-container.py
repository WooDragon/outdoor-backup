#!/usr/bin/env python3
"""Run one bounded local OpenWrt test container without queuing competitors."""

from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

GIB = 1024**3
HOST_FREE_BYTES = 4 * GIB
CONTAINER_FREE_KIB = 2 * 1024 * 1024
DEFAULT_WATCHDOG_SECONDS = 1800
OUTPUT_CAP_BYTES = 8 * 1024 * 1024
OUTPUT_MARKER = b"\n[OUTPUT LIMIT: stream truncated at 8 MiB]\n"
READ_CHUNK_BYTES = 64 * 1024
POST_EXIT_DRAIN_SECONDS = 2
DIGEST_IMAGE = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
CONTAINER_ID = re.compile(r"^[0-9a-f]{64}$")
NOT_FOUND = re.compile(r"^(?:Error response from daemon: No such container:|Error: No such object:) ([0-9a-f]{64})$")
CONTAINER_PREFLIGHT = """set -eu
free=$(df -Pk / | awk 'NR == 2 { print $4 }')
case "$free" in
  ''|*[!0-9]*) printf '%s\\n' 'FAIL: cannot read container root free space' >&2; exit 125 ;;
esac
if [ "$free" -lt 2097152 ]; then
  printf '%s\\n' 'FAIL: container root has less than 2 GiB free' >&2
  exit 125
fi
exec "$@"
"""


@dataclass
class RunState:
    """Track the one container this invocation is permitted to clean."""

    evidence: Path
    run_label: str
    cid: str | None = None
    cancelled: int | None = None
    run_started: bool = False


def fail(message: str, code: int = 1) -> NoReturn:
    """Print a concise diagnostic and terminate with a nonzero status."""
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(code)


def command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    """Execute one Docker CLI request with captured diagnostic streams."""
    try:
        return subprocess.run(["docker", *arguments], text=True, capture_output=True, check=False)
    except OSError as error:
        return subprocess.CompletedProcess(["docker", *arguments], 127, "", str(error))


def require_success(arguments: list[str], purpose: str) -> str:
    """Run Docker command and fail loudly when its exit status is nonzero."""
    result = command(arguments)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Docker error"
        fail(f"{purpose}: {detail}")
    return result.stdout


def acquire_lock() -> object:
    """Acquire the persistent per-user advisory lock without waiting in line."""
    path = Path(f"/tmp/mcpe-openwrt-tests-{os.getuid()}.lock")
    handle = path.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        fail(f"local test lock busy: {path}")
    return handle


def validate_request(evidence: Path, image: str, command_argv: list[str]) -> None:
    """Reject incomplete evidence paths, mutable images, and empty commands."""
    if not evidence.is_dir():
        fail(f"evidence directory does not exist: {evidence}")
    if not DIGEST_IMAGE.fullmatch(image):
        fail("image must be pinned as IMAGE@sha256:<64 lowercase hex characters>")
    if not command_argv:
        fail("container command argv is required after the pinned image")
    if (evidence / "cleanup.pending").exists():
        fail(f"cleanup pending in {evidence}; inspect that evidence before retrying")
    if (evidence / "container.cid").exists():
        fail(f"stale container.cid in {evidence}; use a fresh evidence directory")


def host_space_preflight(evidence: Path) -> None:
    """Ensure the evidence filesystem has the test's conservative 4 GiB floor."""
    if shutil.disk_usage(evidence).free < HOST_FREE_BYTES:
        fail("evidence filesystem has less than 4 GiB free")


def docker_preflight(evidence: Path, image: str) -> None:
    """Check daemon, foreign OpenWrt work, cached image, and brief disk accounting."""
    candidates = require_success(
        ["ps", "-q", "--filter", "ancestor=openwrt/rootfs"], "cannot list running OpenWrt candidates"
    ).split()
    if candidates:
        fail(f"local OpenWrt test container busy: {', '.join(candidates)}")
    version = require_success(["info", "--format", "{{.ServerVersion}}"], "Docker daemon unavailable").strip()
    if not version:
        fail("Docker daemon returned an empty ServerVersion")
    require_success(["image", "inspect", image], "pinned image is not cached (will not pull)")
    accounting = require_success(["system", "df"], "cannot record Docker disk accounting")
    (evidence / "docker.df").write_text(accounting)


def watchdog_seconds() -> float:
    """Read the watchdog only when it is finite and within the 1800-second ceiling."""
    raw = os.environ.get("MCPE_LOCAL_TEST_WATCHDOG_SECONDS", str(DEFAULT_WATCHDOG_SECONDS))
    try:
        value = float(raw)
    except ValueError:
        fail("watchdog must be a finite number of seconds")
    if not math.isfinite(value) or not 0 < value <= DEFAULT_WATCHDOG_SECONDS:
        fail(f"watchdog must be greater than zero and at most {DEFAULT_WATCHDOG_SECONDS} seconds")
    return value


def run_arguments(state: RunState, image: str, command_argv: list[str]) -> list[str]:
    """Build the fixed Docker invocation and safely pass original command argv."""
    return [
        "run", "--rm", "--pull=never", "--cidfile", str(state.evidence / "container.cid"),
        "--label", "io.mcpe.test=manager-service", "--label", f"io.mcpe.test-run={state.run_label}",
        "--platform", "linux/aarch64_generic", "--network", "bridge", "--cap-add", "SYS_ADMIN",
        "--security-opt", "seccomp=unconfined", "--tmpfs", "/tmp:rw,exec,size=512m",
        "--tmpfs", "/opt:rw,exec,size=128m", "-v", f"{repo_root()}:/src:ro",
        "-v", f"{state.evidence}:/evidence", image, "/bin/ash", "-c", CONTAINER_PREFLIGHT,
        "container-preflight", *command_argv,
    ]


def repo_root() -> Path:
    """Resolve the repository from this file rather than the caller's cwd."""
    return Path(__file__).resolve().parents[1]


def capture_cid(state: RunState) -> None:
    """Read the cidfile if Docker has created it, never guessing another container."""
    cidfile = state.evidence / "container.cid"
    if cidfile.exists():
        value = cidfile.read_text().strip()
        if value:
            state.cid = value


def discover_cid(state: RunState) -> tuple[str | None, bool]:
    """Find a cid by exact label, distinguishing absence from Docker failure."""
    result = command(["ps", "-aq", "--no-trunc", "--filter", f"label=io.mcpe.test-run={state.run_label}"])
    if result.returncode:
        return None, False
    matches = result.stdout.split()
    if len(matches) == 1:
        return matches[0], True
    if len(matches) > 1:
        return "", True
    return None, True


def write_pending(state: RunState, reason: str) -> None:
    """Leave local, non-secret recovery facts when exact cleanup cannot be verified."""
    cid = state.cid or "unknown"
    (state.evidence / "cleanup.pending").write_text(
        f"cid={cid}\nrun_label={state.run_label}\nreason={reason}\n"
    )
    print(f"FAIL: cleanup pending: {reason}; inspect {state.evidence}", file=sys.stderr)


def confirmed_not_found(result: subprocess.CompletedProcess[str], cid: str) -> bool:
    """Accept only Docker's complete not-found line for this exact target CID."""
    messages = (result.stderr.strip(), result.stdout.strip())
    return any((match := NOT_FOUND.fullmatch(message)) and match.group(1) == cid for message in messages)


def inspect_ownership(state: RunState, cid: str) -> bool | None:
    """Return ownership truth, confirmed absence, or an untrusted Docker failure."""
    result = command(["container", "inspect", "--format", "{{json .Config.Labels}}", cid])
    if result.returncode:
        return None if confirmed_not_found(result, cid) else False
    try:
        labels = json.loads(result.stdout)
    except json.JSONDecodeError:
        return False
    return labels.get("io.mcpe.test") == "manager-service" and labels.get("io.mcpe.test-run") == state.run_label


def cleanup(state: RunState) -> bool:
    """Stop and remove only a container verified as belonging to this invocation."""
    if not state.run_started:
        return True
    capture_cid(state)
    cid = state.cid
    if cid is None:
        cid, lookup_ok = discover_cid(state)
        if not lookup_ok:
            write_pending(state, "cannot query Docker for cid after run start")
            return False
    if cid == "":
        write_pending(state, "multiple containers match this run label")
        return False
    if cid is None:
        return True
    if not CONTAINER_ID.fullmatch(cid):
        write_pending(state, "cid is not a complete Docker container ID")
        return False
    state.cid = cid
    owned = inspect_ownership(state, cid)
    if owned is None:
        return True
    if not owned:
        write_pending(state, "container label mismatch or Docker inspection failed")
        return False
    for arguments in (["stop", "--time", "10", cid], ["rm", "-v", cid]):
        result = command(arguments)
        if result.returncode and not confirmed_not_found(result, cid):
            write_pending(state, f"Docker {' '.join(arguments[:1])} failed")
            return False
    return True


@dataclass
class StreamCapture:
    """Hold one evidence log's file handle and capped-write state."""

    name: str
    target: object | None
    written: int = 0
    truncated: bool = False


def write_limited(capture: StreamCapture, chunk: bytes) -> bool:
    """Write a chunk up to cap, append one marker, and report first overflow."""
    assert capture.target is not None
    budget = OUTPUT_CAP_BYTES - len(OUTPUT_MARKER)
    keep = min(len(chunk), max(budget - capture.written, 0))
    if keep:
        capture.target.write(chunk[:keep])
        capture.written += keep
    if keep < len(chunk) and not capture.truncated:
        capture.target.write(OUTPUT_MARKER)
        capture.truncated = True
        return True
    return False


def close_streams(selector: selectors.BaseSelector, captures: dict[object, StreamCapture]) -> list[str]:
    """Close every runner-owned resource, retaining errors without aborting cleanup."""
    errors = []
    for source, capture in captures.items():
        for closer in (lambda: selector.unregister(source), source.close, lambda: capture.target and capture.target.close()):
            try:
                closer()
            except (KeyError, ValueError):
                pass
            except OSError as error:
                errors.append(str(error))
    try:
        selector.close()
    except OSError as error:
        errors.append(str(error))
    return errors


def drain_ready(selector: selectors.BaseSelector) -> tuple[str | None, str | None]:
    """Fairly read at most one fixed chunk per ready pipe and report failures."""
    overflow = None
    for key, _ in selector.select(timeout=0):
        source = key.fileobj
        capture = key.data
        try:
            chunk = os.read(source.fileno(), READ_CHUNK_BYTES)
            if not chunk:
                selector.unregister(source)
                source.close()
                capture.target.close()
            elif write_limited(capture, chunk):
                overflow = overflow or capture.name
        except (OSError, ValueError) as error:
            return overflow, f"output {capture.name} read/write failed: {error}"
    return overflow, None


def end_process(process: subprocess.Popen[bytes]) -> None:
    """Terminate only the Docker CLI and do not wait forever for it to exit."""
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def open_streams(process: subprocess.Popen[bytes], evidence: Path) -> tuple[selectors.BaseSelector, dict[object, StreamCapture]]:
    """Open both streams atomically, closing every partial resource on failure."""
    selector = selectors.DefaultSelector()
    captures: dict[object, StreamCapture] = {}
    try:
        for name, source in (("stdout", process.stdout), ("stderr", process.stderr)):
            capture = StreamCapture(name, None)
            captures[source] = capture
            os.set_blocking(source.fileno(), False)
            capture.target = (evidence / f"suite.{name}").open("wb")
            selector.register(source, selectors.EVENT_READ, capture)
        return selector, captures
    except OSError as error:
        close_errors = close_streams(selector, captures)
        if close_errors:
            raise OSError(f"{error}; partial stream close failed: {'; '.join(close_errors)}") from error
        raise


def run_container(state: RunState, image: str, command_argv: list[str], watchdog: float) -> int:
    """Run Docker with nonblocking bounded pipes and a finite post-exit drain."""
    if state.cancelled is not None:
        print("FAIL: cancellation received before Docker run", file=sys.stderr)
        return 128 + state.cancelled
    try:
        process = subprocess.Popen(["docker", *run_arguments(state, image, command_argv)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    except OSError as error:
        fail(f"Docker run cannot start: {error}")
    state.run_started = True
    try:
        selector, captures = open_streams(process, state.evidence)
    except OSError as error:
        print(f"FAIL: output capture initialization failed: {error}", file=sys.stderr)
        end_process(process)
        return 125
    started = time.monotonic()
    post_exit_deadline = None
    result = None
    try:
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            capture_cid(state)
            overflow, error = drain_ready(selector)
            if error:
                print(f"FAIL: {error}", file=sys.stderr)
                if process.poll() is None:
                    end_process(process)
                result = 125
                break
            if overflow:
                print(f"FAIL: output limit exceeded on {overflow}; terminating Docker CLI", file=sys.stderr)
                end_process(process)
                result = 125
                break
            if state.cancelled is not None or now - started >= watchdog:
                timed_out = state.cancelled is None
                print("FAIL: watchdog expired; terminating Docker CLI" if timed_out else "FAIL: cancellation received; terminating Docker CLI", file=sys.stderr)
                end_process(process)
                result = 124 if timed_out else 128 + state.cancelled
                break
            if process.poll() is not None:
                post_exit_deadline = post_exit_deadline or now + POST_EXIT_DRAIN_SECONDS
                if now >= post_exit_deadline:
                    print("FAIL: post-exit output drain did not reach EOF", file=sys.stderr)
                    result = 125
                    break
            selector.select(timeout=0.02)
    finally:
        close_errors = close_streams(selector, captures)
    if close_errors:
        print(f"FAIL: output capture close failed: {'; '.join(close_errors)}", file=sys.stderr)
        return 125
    return process.returncode if result is None else result


def parse_arguments(argv: list[str]) -> tuple[Path, str, list[str]]:
    """Parse the fixed public CLI and preserve all command arguments after --."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("remainder", nargs=argparse.REMAINDER)
    namespace = parser.parse_args(argv)
    remainder = namespace.remainder
    if not remainder or remainder[0] != "--":
        parser.error("use --evidence DIR -- IMAGE@sha256:... [container command argv...]")
    if len(remainder) < 3:
        parser.error("pinned image and container command argv are required after --")
    return namespace.evidence.resolve(), remainder[1], remainder[2:]


def install_signal_handlers(state: RunState) -> None:
    """Record cancellation only; Docker I/O happens later in the execution loop."""
    def remember(signum: int, _frame: object) -> None:
        state.cancelled = signum
    signal.signal(signal.SIGINT, remember)
    signal.signal(signal.SIGTERM, remember)


def main(argv: list[str]) -> int:
    """Own the lock from preflight through confirmed cleanup and return suite status."""
    evidence, image, command_argv = parse_arguments(argv)
    validate_request(evidence, image, command_argv)
    lock = acquire_lock()
    state = RunState(evidence=evidence, run_label=f"{evidence.name}-{uuid.uuid4().hex}")
    install_signal_handlers(state)
    result = 1
    try:
        host_space_preflight(evidence)
        docker_preflight(evidence, image)
        result = run_container(state, image, command_argv, watchdog_seconds())
    except SystemExit as error:
        result = error.code if isinstance(error.code, int) else 1
    finally:
        if not cleanup(state):
            result = result or 1
        (evidence / "suite.rc").write_text(f"{result}\n")
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()
    return result


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
