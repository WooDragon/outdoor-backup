#!/bin/bash
#
# BDD test suite for issue #8: atomic lock, no CPU spin, reachable timeout.
# Tests both the flock primitive and the mkdir fallback (forced by hiding
# flock from PATH).
#

# Not using `set -e`: tests deliberately probe failure/contention paths.

TEST_ROOT="/tmp/outdoor-backup-lock-test"
SCRIPTS_SRC="$(cd "$(dirname "$0")/files/opt/outdoor-backup/scripts" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

test_passed() { echo -e "${GREEN}✓ PASSED${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
test_failed() { echo -e "${RED}✗ FAILED${NC}: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Build a sourcable env. $1 = "flock" | "noflock" (noflock removes flock from
# PATH so the atomic-mkdir fallback is exercised deterministically).
lock_env_setup() {
	local mode="$1"
	rm -rf "$TEST_ROOT"
	mkdir -p "$TEST_ROOT/opt/scripts" "$TEST_ROOT/opt/var/lock" \
		"$TEST_ROOT/opt/log" "$TEST_ROOT/opt/conf"
	cp "$SCRIPTS_SRC/common.sh" "$TEST_ROOT/opt/scripts/common.sh"
	cp "$SCRIPTS_SRC/backup-manager.sh" "$TEST_ROOT/opt/scripts/backup-manager.sh"
	if [ "$mode" = "noflock" ]; then
		# Standard tools live in /usr/bin and /bin; flock (on this host) does
		# not, so this PATH makes `command -v flock` fail without breaking
		# cat/sleep/mkdir/kill/awk/etc.
		RUN_PATH="/usr/bin:/bin"
	else
		RUN_PATH="$PATH"
	fi
}

# Run a shell snippet with backup-manager sourced. Snippet sees acquire_lock/
# release_lock and all globals. Honors $RUN_PATH set by lock_env_setup.
lock_run() {
	local snippet="$1"
	(
		set +e
		export OUTDOOR_BACKUP_SOURCED=1
		export PATH="${RUN_PATH:-$PATH}"
		SCRIPT_DIR="$TEST_ROOT/opt/scripts"
		BASE_DIR="$TEST_ROOT/opt"
		# shellcheck disable=SC1090
		. "$TEST_ROOT/opt/scripts/backup-manager.sh" "add" "sda1" "/d"
		set +e
		LOG_TAG=test
		LED_RED=/nonexistent/r; LED_GREEN=/nonexistent/g
		eval "$snippet"
	)
}

main() {
	echo "========================================"
	echo "  Outdoor Backup - Atomic Lock Suite (#8)"
	echo "========================================"

	test_acquire_release_flock
	test_acquire_release_mkdir
	test_contention_times_out_no_spin
	test_stale_lock_reclaimed_mkdir
	test_release_only_own_lock
	test_flock_sentinel_persists
	test_concurrent_stale_reclaim_single_winner

	echo ""
	echo "========================================"
	echo "  Test Results"
	echo "========================================"
	echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
	echo -e "${RED}Failed: $TESTS_FAILED${NC}"
	rm -rf "$TEST_ROOT"
	[ $TESTS_FAILED -eq 0 ] && { echo -e "${GREEN}All tests passed!${NC}"; exit 0; }
	echo -e "${RED}Some tests failed.${NC}"; exit 1
}

# PLACEHOLDER_TESTS

# Normal acquire then release using the real flock primitive.
test_acquire_release_flock() {
	echo ""
	echo "=== #8: acquire + release (flock) ==="
	lock_env_setup flock
	if ! command -v flock >/dev/null 2>&1; then
		echo "  (flock not on host; skipping flock-specific test)"
		return
	fi
	local out
	out=$(lock_run '
		acquire_lock && echo "ACQ:$LOCK_METHOD:$LOCK_HELD"
		release_lock && echo "REL:$LOCK_HELD"
	')
	echo "$out" | grep -q "ACQ:flock:1" \
		&& test_passed "flock lock acquired" \
		|| test_failed "flock acquire failed: $out"
	echo "$out" | grep -q "REL:0" \
		&& test_passed "flock lock released (state cleared)" \
		|| test_failed "flock release did not clear state: $out"
}

# Normal acquire then release using the mkdir fallback (flock hidden).
test_acquire_release_mkdir() {
	echo ""
	echo "=== #8: acquire + release (mkdir fallback) ==="
	lock_env_setup noflock
	local out
	out=$(lock_run '
		command -v flock >/dev/null 2>&1 && echo "FLOCK-VISIBLE-BUG"
		acquire_lock && echo "ACQ:$LOCK_METHOD:$LOCK_HELD"
		[ -d "$LOCK_DIR" ] && echo "DIR-EXISTS"
		release_lock && echo "REL:$LOCK_HELD"
		[ -d "$LOCK_DIR" ] || echo "DIR-GONE"
	')
	echo "$out" | grep -q "FLOCK-VISIBLE-BUG" \
		&& test_failed "flock still visible — noflock env broken" \
		|| test_passed "flock hidden, fallback path taken"
	echo "$out" | grep -q "ACQ:mkdir:1" \
		&& test_passed "mkdir lock acquired" \
		|| test_failed "mkdir acquire failed: $out"
	echo "$out" | grep -q "DIR-EXISTS" \
		&& test_passed "lock dir created on acquire" \
		|| test_failed "lock dir missing after acquire"
	echo "$out" | grep -q "DIR-GONE" \
		&& test_passed "lock dir removed on release" \
		|| test_failed "lock dir leaked after release"
}

# THE core #8 bug: when the lock is held by a LIVE process, the loser must
# back off (sleep) and give up at timeout — NOT spin the CPU and loop forever.
# We assert two things: (a) acquire returns failure, (b) wall-clock ≈ timeout
# (proving it slept rather than busy-spinning). Uses the mkdir fallback so the
# "held by live PID" state is explicit and deterministic.
test_contention_times_out_no_spin() {
	echo ""
	echo "=== #8: contention backs off + times out, no CPU spin ==="
	lock_env_setup noflock
	# Pre-create the lock dir owned by THIS test process (alive), so the
	# acquirer always sees a live holder.
	mkdir -p "$TEST_ROOT/opt/var/lock/backup.lock.d"
	echo "$$" > "$TEST_ROOT/opt/var/lock/backup.lock.d/pid"

	local start end dur out
	start=$(date +%s)
	out=$(LOCK_TIMEOUT=6 LOCK_INTERVAL=2 lock_run '
		LOCK_TIMEOUT=6 LOCK_INTERVAL=2
		acquire_lock; echo "RC=$?"
	')
	end=$(date +%s)
	dur=$((end - start))

	echo "$out" | grep -q "RC=1" \
		&& test_passed "contended acquire returns failure (not hang)" \
		|| test_failed "expected RC=1 on timeout, got: $out"

	# Slept ~timeout (>=4s for a 6s budget). A busy-spin would return in ~0s.
	if [ "$dur" -ge 4 ]; then
		test_passed "backed off via sleep (~${dur}s, no busy-spin)"
	else
		test_failed "returned in ${dur}s — looks like a CPU spin, not backoff"
	fi
}

# A lock held by a DEAD pid (mkdir fallback) must be reclaimed, not waited on.
test_stale_lock_reclaimed_mkdir() {
	echo ""
	echo "=== #8: stale lock from dead PID is reclaimed ==="
	lock_env_setup noflock
	mkdir -p "$TEST_ROOT/opt/var/lock/backup.lock.d"
	# A PID that is essentially guaranteed not to exist.
	echo "999999" > "$TEST_ROOT/opt/var/lock/backup.lock.d/pid"

	local out
	out=$(LOCK_TIMEOUT=10 LOCK_INTERVAL=1 lock_run '
		LOCK_TIMEOUT=10 LOCK_INTERVAL=1
		acquire_lock; echo "RC=$?:$LOCK_METHOD"
	')
	echo "$out" | grep -q "RC=0:mkdir" \
		&& test_passed "stale lock reclaimed, acquire succeeds" \
		|| test_failed "stale lock not reclaimed: $out"
}

# release_lock must NOT free a lock this process never acquired (LOCK_HELD=0).
test_release_only_own_lock() {
	echo ""
	echo "=== #8: release only frees a lock we actually hold ==="
	lock_env_setup noflock
	# Simulate another process holding the mkdir lock.
	mkdir -p "$TEST_ROOT/opt/var/lock/backup.lock.d"
	echo "$$" > "$TEST_ROOT/opt/var/lock/backup.lock.d/pid"

	lock_run '
		# We never called acquire_lock, so LOCK_HELD=0.
		release_lock
	' >/dev/null 2>&1

	if [ -d "$TEST_ROOT/opt/var/lock/backup.lock.d" ]; then
		test_passed "release left another holder's lock intact"
	else
		test_failed "release wrongly deleted a lock we do not hold"
	fi
}

# Regression guard for the flock-unlink race: release must NOT unlink the
# sentinel file. Unlinking the inode while a waiter holds an open FD lets a
# newcomer create a fresh inode and lock it -> two holders.
test_flock_sentinel_persists() {
	echo ""
	echo "=== #8: flock release keeps sentinel inode (no unlink race) ==="
	lock_env_setup flock
	if ! command -v flock >/dev/null 2>&1; then
		echo "  (flock not on host; skipping)"
		return
	fi
	local ino_before ino_after
	lock_run 'acquire_lock; release_lock' >/dev/null 2>&1
	if [ -f "$TEST_ROOT/opt/var/lock/backup.pid" ]; then
		test_passed "sentinel file still present after release"
	else
		test_failed "sentinel unlinked on release (flock-unlink race reintroduced)"
	fi
}

# Smoke test for concurrent stale-reclaim: many losers racing on a stale
# (dead-PID) mkdir lock should yield exactly ONE winner. NOTE: this is a smoke
# test, not a tight regression guard — the blind-rm race window is narrow and
# shell process-startup jitter tends to serialize contenders, so a buggy
# reclaim can still pass here. The real guarantee for single-winner is
# structural: reclaim steals the stale dir via an atomic `mv` (only the winning
# rename removes it), so a second loser's rename of an already-moved dir fails
# and it re-competes for a fresh mkdir. This test catches gross breakage (e.g.
# every contender "winning").
test_concurrent_stale_reclaim_single_winner() {
	echo ""
	echo "=== #8: concurrent stale-reclaim yields a single winner (smoke) ==="
	lock_env_setup noflock
	mkdir -p "$TEST_ROOT/opt/var/lock/backup.lock.d"
	echo "999999" > "$TEST_ROOT/opt/var/lock/backup.lock.d/pid"  # dead PID

	local win_dir="$TEST_ROOT/wins"
	mkdir -p "$win_dir"
	# Launch 8 acquirers concurrently against the stale lock. Winners record a
	# marker and HOLD without releasing until past the losers' timeout, so the
	# marker count reflects SIMULTANEOUS holders: 1 if mutual exclusion holds,
	# 2+ if two losers both reclaimed and both acquired. (Releasing would allow
	# correct sequential handoffs and wrongly inflate the count.)
	local i
	for i in $(seq 1 8); do
		(
			RUN_PATH="/usr/bin:/bin"
			LOCK_TIMEOUT=3 LOCK_INTERVAL=1 lock_run "
				LOCK_TIMEOUT=3 LOCK_INTERVAL=1
				if acquire_lock; then
					: > \"$win_dir/win.\$\$\"
					sleep 5
				fi
			" >/dev/null 2>&1
		) &
	done
	wait

	local winners
	winners=$(find "$win_dir" -name 'win.*' 2>/dev/null | wc -l | tr -d ' ')
	if [ "$winners" = "1" ]; then
		test_passed "exactly 1 simultaneous winner among 8 stale-reclaimers"
	else
		test_failed "expected 1 winner, got $winners (mutual exclusion broken)"
	fi
}



main "$@"
