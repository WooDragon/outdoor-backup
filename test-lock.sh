#!/bin/sh
#
# BDD tests for the atomic symlink-based backup lock (issue #8 rewrite: no
# flock, no TOCTOU echo-pid, no mkdir+separate-pid-write gap, timeout always
# reachable). The lock functions (lock_holder_alive/acquire_lock/release_lock)
# are extracted verbatim from the delivered backup-manager.sh via marker-
# anchored sed and sourced directly by real per-process ash instances; every
# acquirer/holder is a genuine OS process with its own PID, so `ln -s`,
# `/proc/<pid>` dereferencing, and `kill -9` all exercise real kernel state,
# not a simulation. log_info/log_error are the only fixtures.
#
# Design: acquiring the lock is one syscall -- `ln -s "/proc/$$" "$LOCK_LINK"`
# -- that publishes the holder's identity (its own /proc entry) atomically
# with the lock's existence. There is no intermediate state where the link
# exists but its payload is not yet usable: a dead holder's link simply
# dereferences to a dangling /proc entry, so identity and liveness collapse
# into one read (`$LOCK_LINK/cmdline`). `ln -sf` is never used in production
# code: -f overwrites an existing link instead of failing, which destroys the
# mutual exclusion this whole design depends on (see the KM01 mutation probe).
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-lock.sh --inside
fi

REPO_ROOT=/src
MANAGER="$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh"
TEST_ROOT="/tmp/outdoor-backup-lock-test.$$"
BIN="$TEST_ROOT/bin"
LOCK_LIB="$TEST_ROOT/lock-lib.sh"
RUNNER="$TEST_ROOT/backup-manager.sh"
CASES=0
ASSERTIONS=0
FAILED=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_equal() {
    actual=$1
    expected=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual])"
    fi
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$message"
    fi
}

assert_gt() {
    actual=$1
    threshold=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" -le "$threshold" ]; then
        fail "$message (actual=[$actual], must be > [$threshold])"
    fi
}

assert_between() {
    actual=$1
    low=$2
    high=$3
    message=$4
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" -lt "$low" ] || [ "$actual" -gt "$high" ]; then
        fail "$message (actual=[$actual], expected within [$low,$high])"
    fi
}

# Pull the three lock functions out of the real manager by marker, so tests
# execute the delivered code verbatim instead of a retyped copy. Args: none.
extract_lock_lib() {
    start=$(grep -n '^lock_holder_alive() {' "$MANAGER" | head -1 | cut -d: -f1)
    stop_marker=$(grep -n '^# Mount the source card' "$MANAGER" | head -1 | cut -d: -f1)
    [ -n "$start" ] && [ -n "$stop_marker" ] || return 1
    sed -n "$((start - 5)),$((stop_marker - 1))p" "$MANAGER" > "$LOCK_LIB"
}

# The runner is literally named backup-manager.sh so lock_holder_alive's real
# identity check (via $LOCK_IDENTITY, default "backup-manager.sh") recognizes
# it as a genuine holder unless a test deliberately overrides LOCK_IDENTITY.
write_runner() {
    cat > "$RUNNER" <<'EOF'
#!/bin/sh
LOCK_LINK=$1
snippet=$2
LOCK_HELD=0
LOCK_TIMEOUT=${LOCK_TIMEOUT:-300}
LOCK_INTERVAL=${LOCK_INTERVAL:-5}
LOCK_IDENTITY=${LOCK_IDENTITY:-backup-manager.sh}
# shellcheck disable=SC1090
. "$LOCK_LIB"
log_info() { printf 'INFO %s\n' "$*" >> "${TEST_LOG:-/dev/null}"; }
log_warn() { printf 'WARN %s\n' "$*" >> "${TEST_LOG:-/dev/null}"; }
log_error() { printf 'ERROR %s\n' "$*" >> "${TEST_LOG:-/dev/null}"; }
eval "$snippet"
EOF
    chmod 755 "$RUNNER"
}

prepare_suite() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$BIN"
    extract_lock_lib || { fail 'setup: could not extract lock functions from backup-manager.sh'; exit 1; }
    write_runner
}

# Run one lock op as a real ash process with its own PID; blocks until exit.
# Args: $1 outfile $2 locklink $3 snippet $4 timeout(optional) $5 interval(optional)
run_lock() {
    outfile=$1
    locklink=$2
    snippet=$3
    LOCK_LIB="$LOCK_LIB" LOCK_TIMEOUT="${4:-300}" LOCK_INTERVAL="${5:-5}" \
        /bin/ash "$RUNNER" "$locklink" "$snippet" > "$outfile" 2>&1
}

# Same as run_lock but backgrounded; caller captures $! and later `wait`s it.
run_lock_bg() {
    outfile=$1
    locklink=$2
    snippet=$3
    ( LOCK_LIB="$LOCK_LIB" LOCK_TIMEOUT="${4:-300}" LOCK_INTERVAL="${5:-5}" \
        /bin/ash "$RUNNER" "$locklink" "$snippet" > "$outfile" 2>&1 ) &
}

# Existence must be checked with -L: a dangling symlink (dead holder) is -e
# false / -L true, so -e or -f would wrongly report "no lock" for a stale one.
wait_for_symlink() {
    path=$1
    attempts=0
    while [ ! -L "$path" ] && [ "$attempts" -lt 20 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    [ -L "$path" ]
}

# ---------------------------------------------------------------------------
# K01: two concurrent acquirers on the same lock link -> exactly one wins.
# The winner holds (stays alive) across the loser's whole timeout window so
# the loser's failure is a genuine contended timeout, not a stale reclaim of
# an already-exited winner (the loser's own timeout budget is deliberately
# shorter than the winner's hold, ruling out a "both eventually succeed, just
# sequentially" false green).
# ---------------------------------------------------------------------------
case_k01_two_concurrent_acquirers_exactly_one_wins() {
    begin_case K01 'two processes racing acquire_lock on the same link: exactly one succeeds'
    lockdir="$TEST_ROOT/k01.lock"
    snippet='acquire_lock; rc=$?; printf "RC=%s\n" "$rc"; if [ "$rc" -eq 0 ]; then /bin/sleep 4; release_lock; fi'
    run_lock_bg "$TEST_ROOT/k01.a" "$lockdir" "$snippet" 2 1
    pid_a=$!
    run_lock_bg "$TEST_ROOT/k01.b" "$lockdir" "$snippet" 2 1
    pid_b=$!
    wait "$pid_a" 2>/dev/null || :
    wait "$pid_b" 2>/dev/null || :
    a_win=$(grep -c '^RC=0$' "$TEST_ROOT/k01.a")
    b_win=$(grep -c '^RC=0$' "$TEST_ROOT/k01.b")
    assert_equal "$((a_win + b_win))" 1 'K01 exactly one of two simultaneous racers acquires'
    assert_success 'K01 lock link is released after both racers finish' \
        test ! -L "$lockdir"
}

# ---------------------------------------------------------------------------
# K02: after the winner releases, a later process can acquire the same link.
# ---------------------------------------------------------------------------
case_k02_second_acquirer_succeeds_after_release() {
    begin_case K02 'a fresh acquirer succeeds once the prior holder has released'
    lockdir="$TEST_ROOT/k02.lock"
    run_lock "$TEST_ROOT/k02.a" "$lockdir" 'acquire_lock; rc=$?; release_lock; printf "RC=%s\n" "$rc"'
    assert_equal "$(cat "$TEST_ROOT/k02.a")" 'RC=0' 'K02 first acquire+release succeeds'
    run_lock "$TEST_ROOT/k02.b" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"'
    assert_equal "$(cat "$TEST_ROOT/k02.b")" 'RC=0' 'K02 second process acquires the now-free lock'
}

# ---------------------------------------------------------------------------
# K03: a process that never won the race must not delete the real holder's
# lock when it calls release_lock (LOCK_HELD guards this).
# ---------------------------------------------------------------------------
case_k03_non_owner_release_leaves_holders_lock_intact() {
    begin_case K03 'release_lock from a non-owner (LOCK_HELD=0) never deletes the real holder lock'
    lockdir="$TEST_ROOT/k03.lock"
    run_lock_bg "$TEST_ROOT/k03.holder" "$lockdir" 'acquire_lock; /bin/sleep 3; release_lock' 300 5
    holder_pid=$!
    assert_success 'K03 holder published the lock link' wait_for_symlink "$lockdir"
    run_lock "$TEST_ROOT/k03.loser" "$lockdir" 'release_lock; printf "HELD=%s\n" "$LOCK_HELD"'
    assert_equal "$(cat "$TEST_ROOT/k03.loser")" 'HELD=0' 'K03 non-owner release leaves LOCK_HELD at 0'
    assert_success 'K03 lock link still exists right after the non-owner release call' test -L "$lockdir"
    wait "$holder_pid" 2>/dev/null || :
    assert_success 'K03 real holder eventually releases its own lock' test ! -L "$lockdir"
}

# ---------------------------------------------------------------------------
# K04: a lock left behind by a now-dead PID (a dangling /proc symlink) is
# reclaimed well inside timeout.
# ---------------------------------------------------------------------------
case_k04_stale_lock_from_dead_pid_is_reclaimed() {
    begin_case K04 'a dangling symlink to a now-dead PID is reclaimed within timeout'
    lockdir="$TEST_ROOT/k04.lock"
    /bin/sleep 1 &
    dead_pid=$!
    wait "$dead_pid" 2>/dev/null || :
    ln -s "/proc/$dead_pid" "$lockdir"
    assert_success 'K04 fixture link is dangling (-e false, -L true)' test ! -e "$lockdir"
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -L "$lockdir" ] || fail 'K04 fixture link reports -L true for the dangling symlink'
    start=$(date +%s)
    run_lock "$TEST_ROOT/k04.a" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"' 6 1
    end=$(date +%s)
    assert_equal "$(cat "$TEST_ROOT/k04.a")" 'RC=0' 'K04 acquire reclaims the dangling lock and succeeds'
    assert_between "$((end - start))" 0 4 'K04 reclaim happens promptly, not after the full timeout'
}

# ---------------------------------------------------------------------------
# K05: identity mismatch is judged stale even when the link's target PID is
# genuinely alive. This is the PID-reuse guard, exercised deterministically
# by overriding the contender's LOCK_IDENTITY so it does not match the real
# (alive, correctly-named) holder's cmdline -- simulating "this PID belongs
# to someone else now" without needing a real PID-reuse race.
# ---------------------------------------------------------------------------
case_k05_identity_mismatch_is_stale_even_though_the_pid_is_alive() {
    begin_case K05 'a live holder whose cmdline does not match LOCK_IDENTITY is still judged stale'
    lockdir="$TEST_ROOT/k05.lock"
    run_lock_bg "$TEST_ROOT/k05.holder" "$lockdir" 'acquire_lock; /bin/sleep 5' 300 5
    holder_pid=$!
    assert_success 'K05 holder published the lock link' wait_for_symlink "$lockdir"
    ( LOCK_LIB="$LOCK_LIB" LOCK_TIMEOUT=6 LOCK_INTERVAL=1 LOCK_IDENTITY='unrelated-identity-should-not-match' \
        /bin/ash "$RUNNER" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"' \
        > "$TEST_ROOT/k05.contender" 2>&1 )
    assert_equal "$(cat "$TEST_ROOT/k05.contender")" 'RC=0' \
        'K05 contender with mismatched LOCK_IDENTITY reclaims despite the real holder being alive'
    kill -9 "$holder_pid" 2>/dev/null || :
    wait "$holder_pid" 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# K05b: after the lock is reclaimed from a process that still believes it holds
# it, that process's release_lock must not delete the new holder's lock. This
# guards against a scenario where the holder is killed externally (or times out
# in a previous holder's eyes) while the holder believes it still owns the lock.
# Mirrors K03 structure: holder sleeps with lock, we externally reclaim it,
# then a test process with LOCK_HELD=1 calls release_lock and verifies it leaves
# the new holder's lock alone.
# ---------------------------------------------------------------------------
case_k05b_reclaimed_lock_release_does_not_delete_new_holder() {
    begin_case K05b 'after reclaim, a process that believed it held the lock does not delete the new holder'"'"'s lock'
    lockdir="$TEST_ROOT/k05b.lock"
    run_lock_bg "$TEST_ROOT/k05b.holder" "$lockdir" 'acquire_lock; /bin/sleep 3; release_lock' 300 5
    holder_pid=$!
    assert_success 'K05b holder published the lock link' wait_for_symlink "$lockdir"
    # Externally reclaim the holder's lock: move the old link away and create a new one
    # pointing to the main test process ($$)
    stale_lock="$lockdir.stale"
    mv "$lockdir" "$stale_lock" 2>/dev/null || :
    rm -f "$stale_lock"
    ln -s "/proc/$$" "$lockdir" 2>/dev/null
    assert_success 'K05b main process published the new lock link' test -L "$lockdir"
    # A process that thinks it holds the lock (LOCK_HELD=1) calls release_lock.
    # It should detect the link now points elsewhere and leave it alone.
    run_lock "$TEST_ROOT/k05b.release" "$lockdir" 'LOCK_HELD=1; release_lock; [ -L "$LOCK_LINK" ] && echo LINK_EXISTS'
    assert_equal "$(cat "$TEST_ROOT/k05b.release")" 'LINK_EXISTS' \
        'K05b release_lock left the reclaimed lock link intact'
    assert_equal "$(readlink "$lockdir")" "/proc/$$" \
        'K05b lock still points to the new holder after old holder'"'"'s release_lock'
    # The assertions above run before the background holder reaches its own
    # release_lock, so they only prove the code path. Join it and read the link
    # once more to prove the real holder's exit path also left the lock alone.
    wait "$holder_pid" 2>/dev/null || :
    assert_equal "$(readlink "$lockdir")" "/proc/$$" \
        'K05b the exited holder'"'"'s own release_lock also left the new lock intact'
}

# ---------------------------------------------------------------------------
# K06: a genuinely alive, identity-matching holder keeps the lock for its
# full hold duration; a contender must time out, not reclaim early.
# ---------------------------------------------------------------------------
case_k06_live_matching_holder_blocks_reclaim_until_it_releases() {
    begin_case K06 'a live identity-matching holder is never reclaimed; contenders time out while it holds'
    lockdir="$TEST_ROOT/k06.lock"
    run_lock_bg "$TEST_ROOT/k06.holder" "$lockdir" 'acquire_lock; /bin/sleep 5; release_lock' 300 5
    holder_pid=$!
    assert_success 'K06 holder published the lock link' wait_for_symlink "$lockdir"
    run_lock "$TEST_ROOT/k06.contender" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"' 3 1
    assert_equal "$(cat "$TEST_ROOT/k06.contender")" 'RC=1' \
        'K06 contender exhausts its own timeout while the real holder stays alive'
    assert_success 'K06 lock link remains, still held by the live holder' test -L "$lockdir"
    wait "$holder_pid" 2>/dev/null || :
    assert_success 'K06 holder releases after its hold window' test ! -L "$lockdir"
}

# ---------------------------------------------------------------------------
# K07: timeout is reachable in bounded wall-clock time, and every contended
# iteration advances elapsed -- proven by counting real sleep(1) calls.
# sleep_count must equal timeout/interval exactly (no CPU-spin skip).
# ---------------------------------------------------------------------------
case_k07_timeout_reachable_with_exact_sleep_call_count() {
    begin_case K07 'timeout is reached in bounded time with exactly timeout/interval sleep calls'
    lockdir="$TEST_ROOT/k07.lock"
    cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
case "${1:-}" in
    ''|*[!0-9]*)
        printf 'sleep fixture rejected non-integer=[%s]\n' "${1:-}" >&2
        exit 64
        ;;
esac
printf 'sleep %s\n' "$1" >> "$TEST_SLEEP_TRACE"
exec /bin/sleep "$1"
EOF
    chmod 755 "$BIN/sleep"
    run_lock_bg "$TEST_ROOT/k07.holder" "$lockdir" 'acquire_lock; /bin/sleep 6; release_lock' 300 5
    holder_pid=$!
    assert_success 'K07 holder published the lock link' wait_for_symlink "$lockdir"
    : > "$TEST_ROOT/k07.sleeps"
    start=$(date +%s)
    ( PATH="$BIN:$PATH" TEST_SLEEP_TRACE="$TEST_ROOT/k07.sleeps" LOCK_LIB="$LOCK_LIB" \
        LOCK_TIMEOUT=4 LOCK_INTERVAL=1 \
        /bin/ash "$RUNNER" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"' \
        > "$TEST_ROOT/k07.contender" 2>&1 )
    end=$(date +%s)
    assert_equal "$(cat "$TEST_ROOT/k07.contender")" 'RC=1' 'K07 contended acquire returns nonzero at timeout'
    assert_equal "$(wc -l < "$TEST_ROOT/k07.sleeps")" 4 'K07 sleep is called exactly timeout/interval=4 times'
    assert_between "$((end - start))" 3 8 'K07 wall-clock time is bounded near the timeout, not zero (no spin) and not runaway'
    wait "$holder_pid" 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# K08: a holder killed with SIGKILL (no chance to release) leaves a dangling
# symlink behind; the next acquirer reclaims it and succeeds.
# ---------------------------------------------------------------------------
case_k08_sigkilled_holder_lock_is_reclaimed() {
    begin_case K08 'a SIGKILLed holder leaves a reclaimable dangling lock behind'
    lockdir="$TEST_ROOT/k08.lock"
    run_lock_bg "$TEST_ROOT/k08.holder" "$lockdir" \
        'acquire_lock; echo "$$" > "'"$TEST_ROOT"'/k08.pid"; /bin/sleep 60' 300 5
    assert_success 'K08 holder published the lock link' wait_for_symlink "$lockdir"
    attempts=0
    while [ ! -s "$TEST_ROOT/k08.pid" ] && [ "$attempts" -lt 5 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    assert_success 'K08 holder recorded its own PID' test -s "$TEST_ROOT/k08.pid"
    holder_real_pid=$(cat "$TEST_ROOT/k08.pid")
    kill -9 "$holder_real_pid" 2>/dev/null || :
    assert_success 'K08 lock link survives the SIGKILL (no cleanup ran, still dangling)' test -L "$lockdir"
    run_lock "$TEST_ROOT/k08.a" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"' 6 1
    assert_equal "$(cat "$TEST_ROOT/k08.a")" 'RC=0' 'K08 next acquirer reclaims the orphaned lock and succeeds'
}

# ---------------------------------------------------------------------------
# K09: after release, a lingering unrelated background child (simulating the
# LED auto-off timer) does not keep the lock held. Structural regression
# guard against ever going back to an FD-based lock a forked child inherits.
# ---------------------------------------------------------------------------
case_k09_lingering_background_child_does_not_hold_lock() {
    begin_case K09 'a lingering LED-timer-like background child cannot hold the symlink lock after release'
    lockdir="$TEST_ROOT/k09.lock"
    run_lock "$TEST_ROOT/k09.a" "$lockdir" \
        'acquire_lock; ( /bin/sleep 30 & ); release_lock; printf "RC=%s\n" "$?"'
    assert_equal "$(cat "$TEST_ROOT/k09.a")" 'RC=0' 'K09 acquire+background-spawn+release completes cleanly'
    assert_success 'K09 lock link is gone after release despite the lingering child' test ! -L "$lockdir"
    run_lock "$TEST_ROOT/k09.b" "$lockdir" 'acquire_lock; printf "RC=%s\n" "$?"'
    assert_equal "$(cat "$TEST_ROOT/k09.b")" 'RC=0' \
        'K09 a fresh acquirer succeeds immediately; no residual FD-based holding'
}

# ---------------------------------------------------------------------------
# K10: release_lock is idempotent for the real owner (second call is a no-op)
# and stays non-destructive for a non-owner across repeated calls.
# ---------------------------------------------------------------------------
case_k10_release_lock_is_idempotent() {
    begin_case K10 'release_lock is idempotent for the owner and harmless for a non-owner'
    lockdir="$TEST_ROOT/k10.lock"
    run_lock "$TEST_ROOT/k10.a" "$lockdir" \
        'acquire_lock; release_lock; release_lock; printf "HELD=%s\n" "$LOCK_HELD"'
    assert_equal "$(cat "$TEST_ROOT/k10.a")" 'HELD=0' 'K10 double release_lock by the owner leaves HELD=0 without error'
    assert_success 'K10 lock link is gone after the owner double-release' test ! -L "$lockdir"

    run_lock_bg "$TEST_ROOT/k10.holder" "$lockdir" 'acquire_lock; /bin/sleep 3; release_lock' 300 5
    holder_pid=$!
    assert_success 'K10 second holder published the lock link' wait_for_symlink "$lockdir"
    run_lock "$TEST_ROOT/k10.b" "$lockdir" 'release_lock; release_lock; printf "DONE\n"'
    assert_equal "$(cat "$TEST_ROOT/k10.b")" 'DONE' 'K10 double release_lock by a non-owner does not error'
    assert_success 'K10 non-owner double-release left the real holder lock intact' test -L "$lockdir"
    wait "$holder_pid" 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# K11: the lock never exists in an intermediate state -- publish and identity
# are the same syscall, so link-exists implies identity-usable, always, both
# from the acquirer's own view at the instant it wins and from a concurrent
# observer's view while the holder stays alive. This replaces the old mkdir-
# design's "empty pid file" window, which cannot occur with this primitive.
# ---------------------------------------------------------------------------
case_k11_lock_never_exists_without_a_usable_identity() {
    begin_case K11 'the lock link never exists without an immediately usable holder identity'
    lockdir="$TEST_ROOT/k11.lock"
    run_lock "$TEST_ROOT/k11.a" "$lockdir" \
        'acquire_lock; rc=$?;
         link_exists=no; identity_ok=no
         [ -L "$LOCK_LINK" ] && link_exists=yes
         lock_holder_alive && identity_ok=yes
         printf "RC=%s LINK=%s IDENTITY=%s\n" "$rc" "$link_exists" "$identity_ok"
         release_lock'
    assert_equal "$(cat "$TEST_ROOT/k11.a")" 'RC=0 LINK=yes IDENTITY=yes' \
        'K11 the instant acquire_lock returns success, the link exists with an already-usable identity'

    run_lock_bg "$TEST_ROOT/k11.holder" "$lockdir" 'acquire_lock; /bin/sleep 3; release_lock' 300 5
    holder_pid=$!
    assert_success 'K11 holder published the lock link' wait_for_symlink "$lockdir"
    run_lock "$TEST_ROOT/k11.observer" "$lockdir" \
        'link_exists=no; identity_ok=no
         [ -L "$LOCK_LINK" ] && link_exists=yes
         lock_holder_alive && identity_ok=yes
         printf "LINK=%s IDENTITY=%s\n" "$link_exists" "$identity_ok"'
    assert_equal "$(cat "$TEST_ROOT/k11.observer")" 'LINK=yes IDENTITY=yes' \
        'K11 a concurrent observer sees the same link-implies-identity invariant while the holder is alive'
    wait "$holder_pid" 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# KM01: mutation probe. Swap the atomic `ln -s` publish for `ln -sf`, which
# always "succeeds" by overwriting whatever was there, and prove the SAME
# K01-style concurrent scenario turns red -- every racer reports success.
# This demonstrates the suite actually detects a regression to a non-atomic
# publish, then discards the mutated copy (no git; a throwaway temp file).
# ---------------------------------------------------------------------------
case_km01_mutation_probe_ln_sf_is_caught() {
    begin_case KM01 'mutation probe: ln -sf instead of ln -s makes every concurrent racer "win"'
    mutated="$TEST_ROOT/lock-lib-mutated.sh"
    sed 's/ln -s "\/proc\/\$\$" "\$LOCK_LINK"/ln -sf "\/proc\/\$\$" "$LOCK_LINK"/' \
        "$LOCK_LIB" > "$mutated"
    ASSERTIONS=$((ASSERTIONS + 1))
    if diff -q "$LOCK_LIB" "$mutated" >/dev/null 2>&1; then
        fail 'KM01 mutation sed did not change the lock library (pattern drifted)'
        rm -f "$mutated"
        return
    fi
    lockdir="$TEST_ROOT/km01.lock"
    win_dir="$TEST_ROOT/km01.wins"
    mkdir -p "$win_dir"
    i=1
    while [ "$i" -le 3 ]; do
        ( LOCK_LIB="$mutated" LOCK_TIMEOUT=10 LOCK_INTERVAL=1 \
            /bin/ash "$RUNNER" "$lockdir" \
            "acquire_lock && { : > \"$win_dir/win.\$\$\"; /bin/sleep 3; }" \
            >"$TEST_ROOT/km01.$i.out" 2>&1 ) &
        i=$((i + 1))
    done
    wait
    winners=$(find "$win_dir" -name 'win.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_gt "$winners" 1 'KM01 the ln -sf mutation lets every racer "win" simultaneously (red, as expected)'
    rm -f "$mutated"
    rm -rf "$win_dir"
}

main() {
    trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
    prepare_suite
    case_k01_two_concurrent_acquirers_exactly_one_wins
    case_k02_second_acquirer_succeeds_after_release
    case_k03_non_owner_release_leaves_holders_lock_intact
    case_k04_stale_lock_from_dead_pid_is_reclaimed
    case_k05_identity_mismatch_is_stale_even_though_the_pid_is_alive
    case_k05b_reclaimed_lock_release_does_not_delete_new_holder
    case_k06_live_matching_holder_blocks_reclaim_until_it_releases
    case_k07_timeout_reachable_with_exact_sleep_call_count
    case_k08_sigkilled_holder_lock_is_reclaimed
    case_k09_lingering_background_child_does_not_hold_lock
    case_k10_release_lock_is_idempotent
    case_k11_lock_never_exists_without_a_usable_identity
    case_km01_mutation_probe_ln_sf_is_caught
    assert_equal "$CASES" 13 'all required lock cases executed'
    if [ "$ASSERTIONS" -ne 45 ]; then
        fail "all required assertions executed (expected=45, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"
