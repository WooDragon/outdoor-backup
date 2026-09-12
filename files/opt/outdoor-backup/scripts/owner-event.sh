#!/bin/sh
#
# Match a current backup-lock owner to a newer block remove event and request
# cancellation with one exact TERM. This source-only library owns no state.
#

# Emit a diagnostic without allowing a failed syslog backend to change behavior.
# Argument: human-readable, non-sensitive event classification.
owner_event_notice() {
    printf 'outdoor-backup: owner event: %s\n' "$1" >&2
    logger -t outdoor-backup -p daemon.notice "$1" 2>/dev/null || :
}

# Return success only if jq is available for raw NUL-safe argv parsing.
owner_event_require_jq() {
    command -v jq >/dev/null 2>&1
}

# Print jq definitions shared by event validation and raw argv matching.
owner_event_jq_definitions() {
    cat <<'JQ'
def ascii_devname_char:
  (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or
  (. >= 97 and . <= 122) or . == 45 or . == 46 or . == 95;
def valid_devname:
  if type != "string" then false else
    . as $text | ($text | explode) as $chars |
    ($chars | length) > 0 and $text != "." and $text != ".." and
    all($chars[]; ascii_devname_char)
  end;
def printable_text:
  type == "string" and all(explode[]; . >= 32 and . != 127);
def valid_devpath($devname):
  printable_text and startswith("/devices/") and (endswith("/") | not) and
  (ltrimstr("/") | split("/") | all(. != "" and . != "." and . != "..")) and
  (split("/")[-1] == $devname);
def decimal_chars($chars): all($chars[]; . >= 48 and . <= 57);
def valid_u64:
  if type != "string" then false else
    . as $text | ($text | explode) as $chars |
    ($chars | length) > 0 and decimal_chars($chars) and $chars[0] != 48 and
    (($text | length) < 20 or (($text | length) == 20 and $text <= "18446744073709551615"))
  end;
def valid_event($devname; $devpath; $seq):
  ($devname | valid_devname) and ($devpath | valid_devpath($devname)) and
  ($seq | valid_u64);
def u64_less($left; $right):
  ($left | length) as $left_length | ($right | length) as $right_length |
  ($left_length < $right_length) or
  ($left_length == $right_length and $left < $right);
def event_paths_match($owner_devname; $owner_devpath; $event_devname; $event_devpath):
  ($owner_devname == $event_devname and $owner_devpath == $event_devpath) or
  ($owner_devpath == $event_devpath + "/" + $owner_devname);
JQ
}

# Print one jq query after shared definitions. Argument: validate or cmdline.
owner_event_jq_program() {
    owner_event_jq_definitions
    case "$1" in
        validate) printf '%s\n' 'valid_event($devname; $devpath; $seq)' ;;
        cmdline) cat <<'JQ'
def nul: [0] | implode;
if endswith(nul) then split(nul)[:-1] else empty end |
if (length == 6 and (.[0] == "/bin/sh" or .[0] == "/bin/ash")) then
  . as $argv | ($argv[3]) as $owner_devname | ($argv[4]) as $owner_devpath |
  ($argv[5]) as $owner_seq |
  $argv[1] == $manager and $argv[2] == "add" and
  valid_event($owner_devname; $owner_devpath; $owner_seq) and
  valid_event($event_devname; $event_devpath; $event_seq) and
  u64_less($owner_seq; $event_seq) and
  event_paths_match($owner_devname; $owner_devpath; $event_devname; $event_devpath)
else false end
JQ
            ;;
        stop_cmdline) cat <<'JQ'
def nul: [0] | implode;
if endswith(nul) then split(nul)[:-1] else empty end |
. as $argv |
($argv | length) as $length |
($length == 5 or $length == 6) and
($argv[0] == "/bin/sh" or $argv[0] == "/bin/ash") and
$argv[1] == $manager and $argv[2] == "add" and
($argv[3] | valid_devname) and
(if $length == 5 then true
 else valid_event($argv[3]; $argv[4]; $argv[5])
 end)
JQ
            ;;
        *) return 1 ;;
    esac
}

# Validate one remove event. Arguments: DEVNAME, DEVPATH, SEQNUM.
# Returns zero only for canonical block uevent fields.
owner_event_validate_event() {
    owner_event_require_jq || {
        owner_event_notice 'jq is required for event validation'
        return 1
    }
    command -v target_device_valid_devname >/dev/null 2>&1 || {
        owner_event_notice 'target device name validator is unavailable'
        return 1
    }
    target_device_valid_devname "$1" || return 1
    owner_event_jq_program validate | jq -e -n -f /dev/stdin \
        --arg devname "$1" --arg devpath "$2" --arg seq "$3" >/dev/null
}

# Validate an absolute canonical manager script path. Argument: path.
owner_event_valid_manager_path() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        /|*[[:cntrl:]]*|*//*|*/./*|*/../*|*/.|*/..|*/)
            return 1
            ;;
    esac
    return 0
}

# Read an atomic lock symlink. Argument: lock path. Output: readlink text.
owner_event_read_lock() {
    readlink "$1"
}

# Preserve payload trailing newlines across command substitution. Argument: lock.
# Output: readlink text plus a final checked sentinel, or nonzero.
owner_event_read_lock_checked() {
    owner_event_read_lock "$1" && printf '.'
}

# Read one proc stat record. Argument: PID. Output: one raw stat line.
owner_event_read_stat_file() {
    sed -n '1p' "/proc/$1/stat"
}

# Return a live proc starttime. Argument: PID. Output: field 22 starttime.
# The state is validated on every read but is intentionally not an identity key.
owner_event_stat_identity() {
    owner_event_stat_record=$(owner_event_read_stat_file "$1") || return 1
    [ -n "$owner_event_stat_record" ] || return 1
    printf '%s\n' "$owner_event_stat_record" | awk '
        NR != 1 { bad = 1; next }
        {
            if (!match($0, /.*\) /)) { bad = 1; next }
            rest = substr($0, RSTART + RLENGTH)
            count = split(rest, value, " ")
            if (count < 20 || value[1] !~ /^[A-Z]$/ || value[20] !~ /^[0-9]+$/ ||
                value[1] == "Z" || value[1] == "X") { bad = 1; next }
            starttime = value[20]
        }
        END {
            if (NR != 1 || bad || starttime == "") exit 1
            print starttime
        }
    '
}

# Return the proc cmdline path for a verified PID. Argument: PID.
owner_event_cmdline_path() {
    printf '/proc/%s/cmdline\n' "$1"
}

# Match a raw NUL-terminated manager argv against a newer event. Arguments:
# cmdline path, manager path, DEVNAME, DEVPATH, SEQNUM. Returns zero on match.
owner_event_cmdline_matches() {
    owner_event_require_jq || return 1
    [ -r "$1" ] || return 1
    owner_event_jq_program cmdline | jq -eRs -f /dev/stdin \
        --arg manager "$2" --arg event_devname "$3" --arg event_devpath "$4" \
        --arg event_seq "$5" "$1" >/dev/null
}

# Match a raw NUL-terminated active manager argv for administrator stop.
# Arguments: cmdline path, canonical manager path. Returns zero only for exact
# legacy five-slot or canonical six-slot add argv.
owner_event_cmdline_matches_stop() {
    owner_event_require_jq || return 1
    [ -r "$1" ] || return 1
    owner_event_jq_program stop_cmdline | jq -eRs -f /dev/stdin \
        --arg manager "$2" "$1" >/dev/null
}

# Snapshot a lock target without command substitution trimming payload LFs.
# Argument: lock path. Success assigns owner_event_lock_snapshot_value.
owner_event_lock_snapshot() {
    owner_event_lock_capture=$(owner_event_read_lock_checked "$1") || return 1
    case "$owner_event_lock_capture" in
        *.) ;;
        *) return 1 ;;
    esac
    owner_event_lock_capture=${owner_event_lock_capture%.}
    owner_event_lock_lf='
'
    case "$owner_event_lock_capture" in
        *"$owner_event_lock_lf") ;;
        *) return 1 ;;
    esac
    owner_event_lock_snapshot_value=${owner_event_lock_capture%"$owner_event_lock_lf"}
    return 0
}

# Extract only a canonical non-self PID from one lock target. Argument: link target.
owner_event_lock_pid() {
    case "$1" in
        /proc/*) owner_event_pid=${1#/proc/} ;;
        *) return 1 ;;
    esac
    case "$owner_event_pid" in
        ''|0*|1|*[!0-9]*) return 1 ;;
    esac
    [ "$owner_event_pid" != "$$" ] || return 1
    printf '%s\n' "$owner_event_pid"
}

# Send one TERM request. Argument: PID. This small seam permits failure testing.
owner_event_send_term() {
    kill -TERM "$1"
}

# Capture a live proven owner. Argument: event or stop matching mode. Both modes
# keep the same lock/stat/cmdline proof sequence; only argv policy differs.
# Returns zero with link, PID and first stat globals, otherwise emits a notice.
owner_event_capture_matching_owner() {
    owner_event_match_kind=$1
    owner_event_lock_snapshot "$owner_event_lock" 2>/dev/null || {
        owner_event_notice 'no readable owner lock'
        return 1
    }
    owner_event_link_before=$owner_event_lock_snapshot_value
    owner_event_pid=$(owner_event_lock_pid "$owner_event_link_before") || {
        owner_event_notice 'owner lock target is not an eligible PID'
        return 1
    }
    owner_event_stat_before=$(owner_event_stat_identity "$owner_event_pid") || {
        owner_event_notice 'owner stat evidence is unavailable or inactive'
        return 1
    }
    owner_event_cmdline=$(owner_event_cmdline_path "$owner_event_pid") || {
        owner_event_notice 'owner cmdline path is unavailable'
        return 1
    }
    case "$owner_event_match_kind" in
        event)
            owner_event_cmdline_matches "$owner_event_cmdline" "$owner_event_manager" \
                "$owner_event_event_devname" "$owner_event_event_devpath" \
                "$owner_event_event_seq"
            ;;
        stop)
            owner_event_cmdline_matches_stop "$owner_event_cmdline" \
                "$owner_event_manager"
            ;;
        *) return 1 ;;
    esac || {
        owner_event_notice 'owner argv or event identity does not match'
        return 1
    }
    return 0
}

# Re-read mutable owner evidence immediately before signalling. No arguments.
# Returns zero only when stat/starttime and lock target are unchanged.
owner_event_matching_owner_is_stable() {
    owner_event_stat_after=$(owner_event_stat_identity "$owner_event_pid") || {
        owner_event_notice 'owner stat changed or became inactive'
        return 1
    }
    [ "$owner_event_stat_before" = "$owner_event_stat_after" ] || {
        owner_event_notice 'owner stat changed during validation'
        return 1
    }
    owner_event_lock_snapshot "$owner_event_lock" 2>/dev/null || {
        owner_event_notice 'owner lock changed during validation'
        return 1
    }
    owner_event_link_after=$owner_event_lock_snapshot_value
    [ "$owner_event_link_before" = "$owner_event_link_after" ] || {
        owner_event_notice 'owner lock changed during validation'
        return 1
    }
    return 0
}

# Request cancellation of the current lock owner. Arguments: lock link,
# canonical manager path, DEVNAME, DEVPATH, SEQNUM. Returns zero for no owner,
# stale or mismatched evidence; nonzero for bad event, missing dependency, or TERM failure.
owner_event_cancel() {
    owner_event_lock=$1
    owner_event_manager=$2
    owner_event_event_devname=$3
    owner_event_event_devpath=$4
    owner_event_event_seq=$5

    owner_event_validate_event "$owner_event_event_devname" \
        "$owner_event_event_devpath" "$owner_event_event_seq" || {
        owner_event_notice 'invalid remove event fields'
        return 1
    }
    owner_event_valid_manager_path "$owner_event_manager" || {
        owner_event_notice 'manager path is not canonical'
        return 1
    }
    owner_event_capture_matching_owner event || return 0
    owner_event_matching_owner_is_stable || return 0
    owner_event_send_term "$owner_event_pid" || {
        owner_event_notice 'failed to request owner cancellation'
        return 1
    }
    owner_event_notice 'requested cancellation from matching owner'
    return 0
}

# Validate administrator stop arguments and required parser dependencies.
# Arguments: lock link, canonical manager path, optional opaque prior identity.
owner_event_validate_stop_arguments() {
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || return 1
    owner_event_require_jq || {
        owner_event_notice 'jq is required for owner stop validation'
        return 1
    }
    command -v target_device_valid_devname >/dev/null 2>&1 || {
        owner_event_notice 'target device name validator is unavailable'
        return 1
    }
    owner_event_valid_manager_path "$2" || {
        owner_event_notice 'manager path is not canonical'
        return 1
    }
    return 0
}

# Stop only a fully proven current manager owner. Arguments: lock link, canonical
# manager path, optional opaque previous PID:starttime identity. Returns 0 after
# one TERM or a verified same-identity skip, 2 only if the lock does not exist,
# and 1 for every invalid, unproven, changing, or signalling-failure state.
# Success exports OWNER_EVENT_STOP_IDENTITY; every failure clears it.
owner_event_stop() {
    unset OWNER_EVENT_STOP_IDENTITY
    owner_event_validate_stop_arguments "$@" || return 1
    owner_event_lock=$1
    owner_event_manager=$2
    owner_event_stop_previous=${3-}

    if [ ! -e "$owner_event_lock" ] && [ ! -L "$owner_event_lock" ]; then
        return 2
    fi
    owner_event_capture_matching_owner stop || return 1
    owner_event_matching_owner_is_stable || return 1
    owner_event_stop_identity="$owner_event_pid:$owner_event_stat_after"
    if [ "$owner_event_stop_identity" = "$owner_event_stop_previous" ]; then
        OWNER_EVENT_STOP_IDENTITY=$owner_event_stop_identity
        owner_event_notice 'current owner already received stop request'
        return 0
    fi
    owner_event_send_term "$owner_event_pid" || {
        owner_event_notice 'failed to request owner stop'
        unset OWNER_EVENT_STOP_IDENTITY
        return 1
    }
    OWNER_EVENT_STOP_IDENTITY=$owner_event_stop_identity
    owner_event_notice 'requested stop from proven owner'
    return 0
}
