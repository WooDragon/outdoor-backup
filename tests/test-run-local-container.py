#!/usr/bin/env python3
"""Behavior tests for the bounded local OpenWrt container runner."""

from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from collections import namedtuple
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
RUNNER = REPO / "tests" / "run-local-container.py"
IMAGE = "openwrt/rootfs:aarch64_generic-24.10.8@sha256:" + "a" * 64

SELECTOR_FAILURE_HOOK = '''\
import os
import selectors
if os.environ.get("MCPE_TEST_SELECTOR_SECOND_REGISTER") == "1" or os.environ.get("MCPE_TEST_STREAM_SETUP_DELAY"):
    original = selectors.DefaultSelector
    class FailSecondRegister:
        def __init__(self):
            if os.environ.get("MCPE_TEST_STREAM_SETUP_DELAY"):
                import time
                time.sleep(0.1)
            self.delegate = original()
            self.calls = 0
        def register(self, *args, **kwargs):
            self.calls += 1
            if self.calls == 2:
                raise OSError("injected second selector register failure")
            return self.delegate.register(*args, **kwargs)
        def __getattr__(self, name):
            return getattr(self.delegate, name)
    selectors.DefaultSelector = FailSecondRegister
'''

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys, threading, time
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ["FAKE_DOCKER_LOG"])
with log.open("a") as handle:
    handle.write(json.dumps(args) + "\n")
scenario = json.loads(os.environ.get("FAKE_DOCKER_SCENARIO", "{}"))
def cleanup_error(phase):
    message = scenario.get("cleanup_errors", {}).get(phase)
    if message:
        sys.stderr.write(message + "\n")
        raise SystemExit(1)
def fail(code, message):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)
if args[:1] == ["info"]:
    if scenario.get("info_rc", 0): fail(scenario["info_rc"], "daemon unavailable")
    print(scenario.get("server", "25.0")); raise SystemExit(0)
if args[:2] == ["ps", "-q"]:
    print(scenario.get("busy", "")); raise SystemExit(0)
if args[:3] == ["image", "inspect", os.environ["FAKE_IMAGE"]]:
    if scenario.get("image_missing"): fail(1, "No such image")
    print("[]"); raise SystemExit(0)
if args[:2] == ["system", "df"]:
    print("TYPE TOTAL ACTIVE SIZE RECLAIMABLE"); raise SystemExit(0)
if args[:1] == ["run"]:
    required = ["--rm", "--pull=never", "--platform", "linux/aarch64_generic",
                "--network", "bridge", "--cap-add", "SYS_ADMIN", "--security-opt",
                "seccomp=unconfined"]
    if any(item not in args for item in required): fail(93, "run contract missing")
    labels = [args[index + 1] for index, item in enumerate(args[:-1]) if item == "--label"]
    if "io.mcpe.test=manager-service" not in labels or not any(item.startswith("io.mcpe.test-run=") for item in labels):
        fail(94, "label contract missing")
    mounts = [args[index + 1] for index, item in enumerate(args[:-1]) if item == "-v"]
    tmpfs = [args[index + 1] for index, item in enumerate(args[:-1]) if item == "--tmpfs"]
    if not any(item.endswith(":/src:ro") for item in mounts) or not any(item.endswith(":/evidence") for item in mounts):
        fail(95, "mount contract missing")
    if sorted(tmpfs) != ["/opt:rw,exec,size=128m", "/tmp:rw,exec,size=512m"]:
        fail(96, "tmpfs contract missing")
    if "/bin/ash" not in args or "container-preflight" not in args or not any('exec "$@"' in item for item in args):
        fail(97, "preflight argv contract missing")
    cidfile = Path(args[args.index("--cidfile") + 1])
    if not scenario.get("no_cid"):
        cidfile.write_text(scenario.get("cid", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") + "\n")
    if scenario.get("run_pid_file"):
        Path(scenario["run_pid_file"]).write_text(str(os.getpid()))
    if scenario.get("run_sleep"): time.sleep(float(scenario["run_sleep"]))
    if scenario.get("hold_pipe"):
        child = os.fork()
        if child == 0:
            Path(scenario["child_pid_file"]).write_text(str(os.getpid()))
            time.sleep(30)
            os._exit(0)
    flood = scenario.get("flood")
    if flood:
        payload = ("x" * 65536).encode()
        streams = [sys.stdout.buffer, sys.stderr.buffer] if flood == "both" else [sys.stderr.buffer]
        workers = [threading.Thread(target=lambda stream=stream: [stream.write(payload) for _ in range(160)]) for stream in streams]
        [worker.start() for worker in workers]
        [worker.join() for worker in workers]
    print("suite stdout")
    sys.stderr.write("suite stderr\n")
    raise SystemExit(scenario.get("run_rc", 0))
if args[:2] == ["ps", "-aq"]:
    if scenario.get("discover_daemon"): fail(1, "Cannot connect to the Docker daemon")
    found = scenario.get("discover", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    if "--no-trunc" not in args:
        found = found[:12]
    print(found); raise SystemExit(0)
if args[:2] == ["container", "inspect"]:
    cleanup_error("inspect")
    if scenario.get("inspect_daemon"): fail(1, "Cannot connect to the Docker daemon")
    if scenario.get("inspect_missing"): fail(1, "Error: No such object")
    run = next((json.loads(line) for line in reversed(log.read_text().splitlines())
                if json.loads(line)[:1] == ["run"]), [])
    labels = [run[index + 1] for index, item in enumerate(run[:-1]) if item == "--label"]
    run_label = next(item.split("=", 1)[1] for item in labels if item.startswith("io.mcpe.test-run="))
    labels = {"io.mcpe.test": "manager-service", "io.mcpe.test-run": "wrong" if scenario.get("label_mismatch") else run_label}
    print(json.dumps(labels)); raise SystemExit(0)
if args[:1] in (["stop"], ["rm"]):
    cleanup_error(args[0])
    if scenario.get("cleanup_daemon"): fail(1, "Cannot connect to the Docker daemon")
    print(args[-1]); raise SystemExit(0)
fail(99, "unexpected docker command: " + repr(args))
'''


class RunnerTest(unittest.TestCase):
    """Run the public CLI against an argv-checking Docker substitute."""

    def setUp(self) -> None:
        """Create isolated evidence, Docker substitute, and command audit log."""
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "docker"
        fake.write_text(FAKE_DOCKER)
        fake.chmod(0o755)
        self.log = self.root / "docker.jsonl"

    def tearDown(self) -> None:
        """Remove the isolated temporary fixture tree."""
        self.tempdir.cleanup()

    def invoke(self, scenario: dict | None = None, *, watchdog: str | None = None) -> subprocess.Popen[str]:
        """Start the real runner with a contract-checking Docker substitute."""
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            "FAKE_DOCKER_LOG": str(self.log),
            "FAKE_DOCKER_SCENARIO": json.dumps(scenario or {}),
            "FAKE_IMAGE": IMAGE,
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        if watchdog is not None:
            environment["MCPE_LOCAL_TEST_WATCHDOG_SECONDS"] = watchdog
        if (scenario or {}).get("selector_failure") or (scenario or {}).get("stream_setup_delay"):
            hooks = self.root / "hooks"
            hooks.mkdir(exist_ok=True)
            (hooks / "sitecustomize.py").write_text(SELECTOR_FAILURE_HOOK)
            environment["PYTHONPATH"] = f"{hooks}:{environment.get('PYTHONPATH', '')}"
            if (scenario or {}).get("selector_failure"):
                environment["MCPE_TEST_SELECTOR_SECOND_REGISTER"] = "1"
            if (scenario or {}).get("stream_setup_delay"):
                environment["MCPE_TEST_STREAM_SETUP_DELAY"] = "1"
        return subprocess.Popen(
            [sys.executable, str(RUNNER), "--evidence", str(self.evidence), "--", IMAGE,
             "/bin/ash", "-c", "printf smoke; exit 0"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )

    def result(self, scenario: dict | None = None, *, watchdog: str | None = None) -> tuple[int, str, str]:
        """Wait for a runner process and return its observable outcome."""
        process = self.invoke(scenario, watchdog=watchdog)
        stdout, stderr = process.communicate(timeout=10)
        return process.returncode, stdout, stderr

    def commands(self) -> list[list[str]]:
        """Read Docker argv records emitted by the substitute."""
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_no_run(self) -> None:
        """Assert that a rejected precondition never launched a container."""
        self.assertNotIn("run", [command[0] for command in self.commands()])

    def stop_fixture_pid(self, pid_file: Path) -> None:
        """Terminate only the fake Docker CLI recorded by this test fixture."""
        deadline = time.monotonic() + 1
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not pid_file.exists():
            return
        pid = int(pid_file.read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        os.kill(pid, signal.SIGTERM)

    def test_already_busy_never_starts_container(self) -> None:
        """Given an old OpenWrt container, reject without a second launch."""
        rc, _, stderr = self.result({"busy": "old-container"})
        self.assertNotEqual(rc, 0)
        self.assertIn("busy", stderr)
        self.assert_no_run()

    def test_lock_contention_never_starts_container(self) -> None:
        """Given the user lock is held, fail immediately without Docker run."""
        holder = subprocess.Popen([
            sys.executable, "-c", textwrap.dedent("""
                import fcntl, os, time
                path = f'/tmp/mcpe-openwrt-tests-{os.getuid()}.lock'
                handle = open(path, 'a+')
                fcntl.flock(handle, fcntl.LOCK_EX)
                print('locked', flush=True)
                time.sleep(5)
            """),
        ], text=True, stdout=subprocess.PIPE)
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        try:
            rc, _, stderr = self.result()
        finally:
            holder.terminate()
            holder.wait(timeout=5)
            holder.stdout.close()
        self.assertNotEqual(rc, 0)
        self.assertIn("lock busy", stderr)
        self.assertEqual(self.commands(), [])

    def test_low_host_space_never_starts_container(self) -> None:
        """Given less than four GiB at evidence, reject before Docker actions."""
        spec = importlib.util.spec_from_file_location("runner_under_test", RUNNER)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        usage = namedtuple("Usage", "total used free")(10 * 1024**3, 7 * 1024**3, 3 * 1024**3)
        with patch("shutil.disk_usage", return_value=usage), self.assertRaises(SystemExit):
            module.host_space_preflight(self.evidence)
        self.assertEqual(self.commands(), [])

    def test_missing_or_empty_server_version_never_starts_container(self) -> None:
        """Given an unusable daemon reply, reject before image or run actions."""
        for scenario in ({"server": ""}, {"info_rc": 1}):
            with self.subTest(scenario=scenario):
                self.log.unlink(missing_ok=True)
                rc, _, stderr = self.result(scenario)
                self.assertNotEqual(rc, 0)
                self.assertIn("Docker", stderr)
                self.assert_no_run()

    def test_missing_image_does_not_pull_or_start(self) -> None:
        """Given an uncached digest, reject without pull, build, or run."""
        rc, _, stderr = self.result({"image_missing": True})
        self.assertNotEqual(rc, 0)
        self.assertIn("cached", stderr)
        commands = self.commands()
        self.assert_no_run()
        self.assertNotIn("pull", [part for command in commands for part in command])

    def test_post_spawn_stream_setup_failures_cleanup_owned_container(self) -> None:
        """Stream open/register failure after Popen must still clean only the owned CID."""
        cases = (
            ("stdout-directory", "suite.stdout", {}),
            ("stderr-directory", "suite.stderr", {}),
            ("second-register", None, {"selector_failure": True}),
            ("wrong-label", "suite.stderr", {"label_mismatch": True}),
        )
        for index, (name, directory, scenario) in enumerate(cases):
            with self.subTest(name=name):
                self.log.unlink(missing_ok=True)
                self.evidence = self.root / f"post-spawn-{index}"
                self.evidence.mkdir()
                if directory:
                    (self.evidence / directory).mkdir()
                pid_file = self.evidence / "fake-run.pid"
                scenario = {**scenario, "run_sleep": 5, "run_pid_file": str(pid_file), "stream_setup_delay": True}
                try:
                    rc, _, _ = self.result(scenario)
                    commands = self.commands()
                    self.assertNotEqual(rc, 0)
                    self.assertIn("run", [command[0] for command in commands])
                    if name == "wrong-label":
                        self.assertTrue((self.evidence / "cleanup.pending").exists())
                        self.assertFalse(any(command[:1] in (["stop"], ["rm"]) for command in commands))
                    else:
                        self.assertTrue(any(command[:1] == ["rm"] for command in commands), commands)
                    self.assertTrue(pid_file.exists())
                    pid = int(pid_file.read_text())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                finally:
                    self.stop_fixture_pid(pid_file)
                opened = self.evidence / "suite.stdout"
                if opened.is_file():
                    opened.unlink()
                self.log.unlink()
                self.evidence = self.root / f"post-spawn-next-{index}"
                self.evidence.mkdir()
                next_rc, _, _ = self.result()
                self.assertEqual(next_rc, 0)

    def test_normal_exit_records_rc_and_removes_own_container(self) -> None:
        """Given a successful command, persist logs/rc and run exact cleanup."""
        rc, stdout, stderr = self.result()
        self.assertEqual(rc, 0, stderr)
        self.assertEqual(stdout, "")
        self.assertEqual((self.evidence / "suite.stdout").read_text(), "suite stdout\n")
        self.assertEqual((self.evidence / "suite.rc").read_text().strip(), "0")
        self.assertEqual((self.evidence / "suite.stderr").read_text(), "suite stderr\n")
        commands = self.commands()
        self.assertTrue(any(command[:1] == ["rm"] and command[-1] == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" for command in commands))
        self.assertFalse((self.evidence / "cleanup.pending").exists())

    def test_nonzero_and_signal_both_clean_only_own_container(self) -> None:
        """Given failure or SIGTERM, retain nonzero status and exact cleanup."""
        rc, _, _ = self.result({"run_rc": 7})
        self.assertEqual(rc, 7)
        self.assertEqual((self.evidence / "suite.rc").read_text().strip(), "7")
        self.log.unlink()
        self.evidence = self.root / "signal-evidence"
        self.evidence.mkdir()
        process = self.invoke({"run_sleep": 5})
        deadline = time.monotonic() + 5
        while not (self.evidence / "container.cid").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.evidence / "container.cid").exists())
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("cancel", stderr)
        commands = self.commands()
        self.assertTrue(any(command[:1] == ["rm"] and command[-1] == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" for command in commands), commands)

    def test_timeout_cleans_only_own_container(self) -> None:
        """Given the watchdog fires, terminate Docker CLI then exact-clean container."""
        rc, _, stderr = self.result({"run_sleep": 5}, watchdog="0.1")
        self.assertEqual(rc, 124)
        self.assertIn("watchdog", stderr)
        self.assertTrue(any(command[:1] == ["rm"] and command[-1] == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" for command in self.commands()))

    def test_missing_cid_uses_exact_label_or_leaves_pending(self) -> None:
        """Given cidfile races, recover one label match but reject ambiguity or outage."""
        rc, _, _ = self.result({"no_cid": True, "discover": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"})
        self.assertEqual(rc, 0)
        commands = self.commands()
        discovery = next(command for command in commands if command[:2] == ["ps", "-aq"])
        self.assertEqual(discovery[:3], ["ps", "-aq", "--no-trunc"])
        self.assertTrue(discovery[-1].startswith("label=io.mcpe.test-run="))
        self.assertTrue(any(command[:1] == ["rm"] for command in commands))
        cases = ({"no_cid": True, "discover": "one two"}, {"no_cid": True, "discover_daemon": True})
        for index, scenario in enumerate(cases):
            with self.subTest(scenario=scenario):
                self.log.unlink(missing_ok=True)
                self.evidence = self.root / f"cid-{index}"
                self.evidence.mkdir()
                rc, _, stderr = self.result(scenario)
                self.assertNotEqual(rc, 0)
                self.assertIn("cleanup pending", stderr)
                self.assertTrue((self.evidence / "cleanup.pending").exists())
                self.assertFalse(any(command[:1] in (["stop"], ["rm"]) for command in self.commands()))

    def test_malformed_cid_never_becomes_a_cleanup_target(self) -> None:
        """Reject malformed cidfile or exact-label output without Docker stop/rm."""
        for index, scenario in enumerate(({"cid": "short"}, {"no_cid": True, "discover": "short"})):
            with self.subTest(scenario=scenario):
                self.log.unlink(missing_ok=True)
                self.evidence = self.root / f"malformed-cid-{index}"
                self.evidence.mkdir()
                rc, _, stderr = self.result(scenario)
                self.assertNotEqual(rc, 0)
                self.assertIn("complete Docker container ID", stderr)
                self.assertTrue((self.evidence / "cleanup.pending").exists())
                self.assertFalse(any(command[:1] in (["stop"], ["rm"]) for command in self.commands()))

    def test_label_mismatch_refuses_cleanup(self) -> None:
        """Given a CID resolves to another run, never stop or remove it."""
        rc, _, stderr = self.result({"label_mismatch": True})
        self.assertNotEqual(rc, 0)
        self.assertIn("label mismatch", stderr)
        self.assertFalse(any(command[:1] in (["stop"], ["rm"]) for command in self.commands()))
        self.assertTrue((self.evidence / "cleanup.pending").exists())

    def test_only_exact_target_not_found_allows_cleanup(self) -> None:
        """Reject DNS, wrong CID, and mixed cleanup errors for every Docker phase."""
        target = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        messages = {
            "target": f"Error response from daemon: No such container: {target}",
            "dns": "lookup docker.invalid: no such host",
            "other": "Error: No such object: another-container",
            "mixed": f"Error: No such object: {target}\\nlookup docker.invalid: no such host",
        }
        for phase in ("inspect", "stop", "rm"):
            for name, message in messages.items():
                with self.subTest(phase=phase, message=name):
                    self.log.unlink(missing_ok=True)
                    self.evidence = self.root / f"not-found-{phase}-{name}"
                    self.evidence.mkdir()
                    rc, _, _ = self.result({"cleanup_errors": {phase: message}})
                    if name == "target":
                        self.assertEqual(rc, 0)
                        self.assertFalse((self.evidence / "cleanup.pending").exists())
                    else:
                        self.assertNotEqual(rc, 0)
                        self.assertTrue((self.evidence / "cleanup.pending").exists())

    def test_output_limit_truncates_both_pipes_and_releases_lock(self) -> None:
        """Abort flood output, cap each log, and allow the next bounded invocation."""
        rc, _, stderr = self.result({"flood": "both"})
        self.assertEqual(rc, 125)
        self.assertEqual((self.evidence / "suite.rc").read_text().strip(), "125")
        self.assertIn("output limit", stderr)
        payloads = [(self.evidence / name).read_bytes() for name in ("suite.stdout", "suite.stderr")]
        self.assertTrue(any(b"OUTPUT LIMIT" in payload for payload in payloads))
        capped_sizes = []
        for payload in payloads:
            self.assertLessEqual(len(payload), 8 * 1024 * 1024)
            if b"OUTPUT LIMIT" in payload:
                self.assertEqual(len(payload), 8 * 1024 * 1024)
                capped_sizes.append(len(payload))
        print(f"output_limit_capped_bytes={capped_sizes}")
        self.assertTrue(any(command[:1] == ["rm"] for command in self.commands()))
        self.log.unlink()
        self.evidence = self.root / "after-flood"
        self.evidence.mkdir()
        rc, _, _ = self.result()
        self.assertEqual(rc, 0)

    def test_post_exit_pipe_holder_fails_bounded_without_reader_leak(self) -> None:
        """A descendant-held pipe must expire after drain grace and release the lock."""
        pid_file = self.root / "held-pipe.pid"
        child_pid = None
        started = time.monotonic()
        process = self.invoke({"hold_pipe": True, "child_pid_file": str(pid_file)})
        try:
            _, stderr = process.communicate(timeout=5)
        finally:
            deadline = time.monotonic() + 1
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if pid_file.exists():
                child_pid = int(pid_file.read_text())
                os.kill(child_pid, signal.SIGTERM)
        elapsed = time.monotonic() - started
        self.assertEqual(process.returncode, 125)
        self.assertLess(elapsed, 4)
        print(f"post_exit_drain_elapsed_seconds={elapsed:.3f}")
        self.assertIn("post-exit output drain", stderr)
        sizes = {name: (self.evidence / name).stat().st_size for name in ("suite.stdout", "suite.stderr")}
        time.sleep(0.1)
        self.assertEqual(sizes, {name: (self.evidence / name).stat().st_size for name in sizes})
        self.assertIsNotNone(child_pid)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        else:
            self.fail(f"fixture pipe-holder pid {child_pid} survived cleanup")
        self.log.unlink()
        self.evidence = self.root / "after-held-pipe"
        self.evidence.mkdir()
        rc, _, _ = self.result()
        self.assertEqual(rc, 0)

    def test_capture_uses_nonblocking_selector_not_reader_threads(self) -> None:
        """Keep all pipe ownership in the runner thread before lock release."""
        source = RUNNER.read_text()
        self.assertIn("selectors.DefaultSelector", source)
        self.assertIn("os.set_blocking", source)
        self.assertIn("bufsize=0", source)
        self.assertNotIn("threading", source)

    def test_watchdog_value_is_finite_and_bounded_before_run(self) -> None:
        """Reject invalid watchdog values before Docker run; retain valid boundaries."""
        invalid = ("nan", "inf", "-inf", "1e999", "1801", "0", "-1", "word")
        for index, value in enumerate(invalid):
            with self.subTest(value=value):
                self.log.unlink(missing_ok=True)
                self.evidence = self.root / f"invalid-watchdog-{index}"
                self.evidence.mkdir()
                rc, _, stderr = self.result(watchdog=value)
                self.assertNotEqual(rc, 0)
                self.assertIn("watchdog", stderr)
                self.assert_no_run()
        for index, value in enumerate(("0.1", "1800")):
            with self.subTest(value=value):
                self.log.unlink(missing_ok=True)
                self.evidence = self.root / f"valid-watchdog-{index}"
                self.evidence.mkdir()
                rc, _, _ = self.result(watchdog=value)
                self.assertEqual(rc, 0)

    def test_daemon_cleanup_failure_leaves_pending_diagnostic(self) -> None:
        """Given cleanup cannot reach Docker, write recoverable local evidence."""
        rc, _, stderr = self.result({"cleanup_daemon": True})
        self.assertNotEqual(rc, 0)
        self.assertIn("cleanup pending", stderr)
        pending = (self.evidence / "cleanup.pending").read_text()
        self.assertIn("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", pending)
        self.assertNotIn("token", pending.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
