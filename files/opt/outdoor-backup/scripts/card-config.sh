#!/bin/sh
#
# SD card configuration reader.
# FieldBackup.conf is removable-media data, not shell code. This library is
# inert when sourced; card_config_load is the only entry point.
#

# Load the four supported card fields from a data-only configuration file.
# Args: $1 = readable FieldBackup.conf path.
# Returns: 0 after atomically assigning SD_UUID, BACKUP_MODE, CREATED_AT and
# SD_NAME; 1 for unreadable, malformed, duplicate, or invalid card metadata.
card_config_load() {
    local config_path=$1
    local parsed parsed_key parsed_value
    local parsed_uuid='' parsed_mode='' parsed_created_at='' parsed_name=''

    [ -r "$config_path" ] || {
        printf 'outdoor-backup: cannot read card configuration: %s\n' "$config_path" >&2
        return 1
    }

    # awk recognizes only complete KEY=VALUE data records. It never emits shell
    # syntax, and the tab separator is safe because all control characters fail.
    parsed=$(awk '
        function reject(reason) {
            failed = 1
            printf "outdoor-backup: invalid card configuration: %s\n", reason > "/dev/stderr"
            exit 1
        }
        function emit(key, value) {
            if (seen[key]++)
                reject("duplicate " key)
            print key "\t" value
        }
        {
            if ($0 ~ /[\001-\037\177]/)
                reject("control character")
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/)
                next
            if ($0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/)
                reject("non-data record")

            equal = index($0, "=")
            key = substr($0, 1, equal - 1)
            value = substr($0, equal + 1)
            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if (first == "\047" || first == "\042") {
                if (length(value) < 2 || last != first)
                    reject("unclosed quote")
                value = substr(value, 2, length(value) - 2)
                if (index(value, first) != 0)
                    reject("trailing data after quote")
            } else if (value !~ /^[^[:space:]\047\042;]+$/) {
                reject("invalid value")
            }

            records++
            if (key == "SD_UUID" || key == "BACKUP_MODE" || \
                key == "CREATED_AT" || key == "SD_NAME")
                emit(key, value)
        }
        END {
            if (!failed && records == 0)
                reject("empty file")
        }
    ' "$config_path") || return 1

    while IFS="$(printf '\t')" read -r parsed_key parsed_value; do
        case "$parsed_key" in
            SD_UUID)
                parsed_uuid=$parsed_value
                ;;
            BACKUP_MODE)
                parsed_mode=$parsed_value
                ;;
            CREATED_AT)
                parsed_created_at=$parsed_value
                ;;
            SD_NAME)
                parsed_name=$parsed_value
                ;;
            *)
                printf 'outdoor-backup: internal card parser error\n' >&2
                return 1
                ;;
        esac
    done <<EOF
$parsed
EOF

    if [ -z "$parsed_uuid" ] || ! is_valid_uuid "$parsed_uuid"; then
        printf '%s\n' 'outdoor-backup: invalid or missing card UUID' >&2
        return 1
    fi
    if [ -z "$parsed_mode" ]; then
        parsed_mode=PRIMARY
    fi
    case "$parsed_mode" in
        PRIMARY|REPLICA)
            ;;
        *)
            printf 'outdoor-backup: invalid card backup mode\n' >&2
            return 1
            ;;
    esac

    SD_UUID=$parsed_uuid
    BACKUP_MODE=$parsed_mode
    CREATED_AT=$parsed_created_at
    SD_NAME=$parsed_name
    return 0
}
