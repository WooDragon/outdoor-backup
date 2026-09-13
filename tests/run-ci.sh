#!/usr/bin/env bash
# Run every root behavior suite through the existing bounded OpenWrt runner.

set -euo pipefail

readonly IMAGE='openwrt/rootfs:aarch64_generic-24.10.8@sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'
export LC_ALL=C

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

main() {
    [ "$#" -eq 1 ] || fail "usage: $0 ABSOLUTE_EVIDENCE_DIR"

    local evidence_root=$1
    case $evidence_root in
        /*) ;;
        *) fail "evidence directory must be absolute: $evidence_root" ;;
    esac
    [ ! -e "$evidence_root" ] && [ ! -L "$evidence_root" ] || fail "evidence directory already exists: $evidence_root"
    mkdir -- "$evidence_root" || fail "cannot create evidence directory: $evidence_root"

    local script_path repo_root suite suite_name suite_evidence suite_rc
    local -a suites
    script_path=$(realpath -- "${BASH_SOURCE[0]}") || fail 'cannot resolve runner path'
    repo_root=$(dirname -- "$(dirname -- "$script_path")")

    shopt -s nullglob
    suites=("$repo_root"/test-*.sh)
    shopt -u nullglob
    [ "${#suites[@]}" -gt 0 ] || fail "no root test-*.sh suites found in: $repo_root"

    printf 'CI pulling pinned image: %s\n' "$IMAGE"
    docker pull "$IMAGE" || fail 'cannot pull pinned OpenWrt image'

    for suite in "${suites[@]}"; do
        suite_name=$(basename -- "$suite")
        suite_evidence="$evidence_root/${suite_name%.sh}"
        mkdir -- "$suite_evidence" || fail "cannot create evidence directory for $suite_name"

        printf 'CI suite=%s start\n' "$suite_name"
        if python3 "$repo_root/tests/run-local-container.py" --evidence "$suite_evidence" -- \
            "$IMAGE" /bin/ash /src/tests/ci-suite.sh "$suite_name"; then
            suite_rc=0
        else
            suite_rc=$?
        fi
        printf 'CI suite=%s rc=%s\n' "$suite_name" "$suite_rc"
        [ "$suite_rc" -eq 0 ] || exit "$suite_rc"
    done

    printf 'CI suites completed=%s\n' "${#suites[@]}"
}

main "$@"
