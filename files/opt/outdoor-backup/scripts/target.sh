#!/bin/sh
#
# Target mount FD anchor for outdoor-backup.
# Source this library from the long-lived manager shell; target_open must not
# run inside command substitution because its file descriptor is shell-local.
#

# Emit an error to stderr and syslog without creating any package directories.
# Argument: human-readable failure reason.
target_notice() {
    printf 'outdoor-backup: target error: %s\n' "$1" >&2
    logger -t outdoor-backup "$1" 2>/dev/null || :
}

# Remove only state owned by this library. This function does not close an FD.
target_clear_state() {
    unset TARGET_FD_OPEN TARGET_MOUNT_ID TARGET_DEVICE TARGET_FS_TYPE
    unset TARGET_FD_ROOT TARGET_MOUNT_PATH TARGET_BACKUP_ROOT TARGET_BACKUP_PATH
}

# Reject a non-canonical configured mount path.
# Argument: configured path. Output: normalized path, or nonzero.
target_normalize_path() {
    target_path=$1

    case "$target_path" in
        ''|/|/*)
            ;;
        *)
            target_notice 'configured mount path must be absolute and non-root'
            return 1
            ;;
    esac
    case "$target_path" in
        ''|/)
            target_notice 'configured mount path must be absolute and non-root'
            return 1
            ;;
        *[[:cntrl:]]*|*//*|*/./*|*/../*|*/.|*/..)
            target_notice 'configured mount path contains an unsafe segment'
            return 1
            ;;
    esac

    while [ "${target_path%/}" != "$target_path" ]; do
        target_path=${target_path%/}
    done
    printf '%s\n' "$target_path"
}

# Look up one mountinfo record by exact mount ID and expose its stable fields.
# Arguments: mount ID. Returns nonzero if the record is gone.
target_lookup_mount() {
    target_lookup_id=$1
    target_mount_record=$(awk -v expected_id="$target_lookup_id" '
        function decode(value) {
            gsub(/\\040/, " ", value)
            gsub(/\\011/, "\t", value)
            gsub(/\\012/, "\n", value)
            gsub(/\\134/, "\\", value)
            return value
        }
        $1 == expected_id {
            for (field = 7; field <= NF; field++) {
                if ($field == "-") {
                    print $1 "\t" $3 "\t" decode($5) "\t" \
                        $(field + 1) "\t" $6 "\t" $(field + 3)
                    exit
                }
            }
        }
    ' /proc/$$/mountinfo 2>/dev/null) || return 1
    [ -n "$target_mount_record" ] || return 1

    IFS='	' read -r TARGET_RECORD_ID TARGET_RECORD_DEVICE TARGET_RECORD_PATH \
        TARGET_RECORD_FS TARGET_RECORD_VFS_OPTIONS TARGET_RECORD_SUPER_OPTIONS <<EOF
$target_mount_record
EOF
    [ "$TARGET_RECORD_ID" = "$target_lookup_id" ] || return 1
}

# Return success only when both VFS and filesystem-specific options are rw.
# Arguments: VFS options, superblock options.
target_mount_is_rw() {
    case ",$1," in
        *,rw,*)
            ;;
        *)
            return 1
            ;;
    esac
    case ",$2," in
        *,rw,*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Close this library's anchor FD and erase its captured state. Idempotent.
# No arguments. Never unmounts a filesystem or affects other descriptors.
target_close() {
    if [ "${TARGET_FD_OPEN:-0}" = 1 ]; then
        exec 9<&- || :
    fi
    target_clear_state
    return 0
}

# Open and pin the configured target mount in FD 9.
# Argument: configured mount directory. Must run in the manager's current shell.
target_open() {
    target_close
    target_mount_path=$(target_normalize_path "$1") || return 1

    if [ -L "$target_mount_path" ]; then
        target_notice 'configured mount path must not itself be a symlink'
        return 1
    fi
    if [ ! -d "$target_mount_path" ]; then
        target_notice 'configured mount directory does not exist'
        return 1
    fi
    if [ -e /proc/$$/fd/9 ]; then
        target_notice 'target anchor FD is already in use outside this library'
        return 1
    fi
    if ! command exec 9<"$target_mount_path"; then
        target_notice 'cannot open configured mount directory'
        return 1
    fi
    TARGET_FD_OPEN=1
    TARGET_FD_ROOT="/proc/$$/fd/9"
    TARGET_MOUNT_ID=$(awk '$1 == "mnt_id:" { print $2; exit }' \
        "/proc/$$/fdinfo/9" 2>/dev/null) || TARGET_MOUNT_ID=
    if [ -z "$TARGET_MOUNT_ID" ] || ! target_lookup_mount "$TARGET_MOUNT_ID"; then
        target_notice 'opened directory has no live mountinfo record'
        target_close
        return 1
    fi
    if [ "$TARGET_RECORD_PATH" != "$target_mount_path" ]; then
        target_notice 'configured directory is not the exact mounted target'
        target_close
        return 1
    fi
    if ! target_mount_is_rw "$TARGET_RECORD_VFS_OPTIONS" \
        "$TARGET_RECORD_SUPER_OPTIONS"; then
        target_notice 'configured target mount is read-only'
        target_close
        return 1
    fi

    TARGET_DEVICE=$TARGET_RECORD_DEVICE
    TARGET_FS_TYPE=$TARGET_RECORD_FS
    TARGET_MOUNT_PATH=$target_mount_path
    return 0
}

# Reject mounts that would divert a protected target path away from the anchor.
# The configured backup root is optional until target_prepare_root has accepted it.
# No arguments. Returns nonzero when another mount covers protected path space.
target_mount_tree_healthy() {
    TARGET_CHECK_MOUNT_ID=$TARGET_MOUNT_ID \
        TARGET_CHECK_MOUNT_PATH=$TARGET_MOUNT_PATH \
        TARGET_CHECK_BACKUP_PATH=${TARGET_BACKUP_PATH:-} \
        awk '
        function decode(value) {
            gsub(/\\040/, " ", value)
            gsub(/\\011/, "\t", value)
            gsub(/\\012/, "\n", value)
            gsub(/\\134/, "\\", value)
            return value
        }
        function below_or_same(path, root) {
            return path == root || index(path, root "/") == 1
        }
        function root_intermediate(path, mount, root, suffix, part, count, index_part, probe) {
            if (index(root, mount "/") != 1)
                return 0
            suffix = substr(root, length(mount) + 2)
            count = split(suffix, part, "/")
            probe = mount
            for (index_part = 1; index_part < count; index_part++) {
                probe = probe "/" part[index_part]
                if (path == probe)
                    return 1
            }
            return 0
        }
        $1 != ENVIRON["TARGET_CHECK_MOUNT_ID"] {
            mount_path = decode($5)
            target_path = ENVIRON["TARGET_CHECK_MOUNT_PATH"]
            backup_path = ENVIRON["TARGET_CHECK_BACKUP_PATH"]
            if (mount_path == target_path || \
                (backup_path != "" && (below_or_same(mount_path, backup_path) || \
                 root_intermediate(mount_path, target_path, backup_path)))) {
                exit 1
            }
        }
        ' /proc/$$/mountinfo 2>/dev/null
    if [ $? -ne 0 ]; then
        target_notice 'target path is covered by a different mount'
        return 1
    fi
    return 0
}

# Confirm the original FD, mount ID, path, device, filesystem, rw state, and
# that no child mount diverts the configured backup root.
# No arguments. Nonzero means the manager must stop using the target.
target_anchor_healthy() {
    if [ "${TARGET_FD_OPEN:-0}" != 1 ] || [ -z "${TARGET_MOUNT_ID:-}" ] || \
        [ ! -d "${TARGET_FD_ROOT:-/nonexistent}" ]; then
        target_notice 'target anchor FD is closed or unavailable'
        return 1
    fi

    target_current_id=$(awk '$1 == "mnt_id:" { print $2; exit }' \
        "/proc/$$/fdinfo/9" 2>/dev/null) || target_current_id=
    if [ "$target_current_id" != "$TARGET_MOUNT_ID" ] || \
        ! target_lookup_mount "$TARGET_MOUNT_ID"; then
        target_notice 'target mount was detached or replaced'
        return 1
    fi
    if [ "$TARGET_RECORD_PATH" != "$TARGET_MOUNT_PATH" ] || \
        [ "$TARGET_RECORD_DEVICE" != "$TARGET_DEVICE" ] || \
        [ "$TARGET_RECORD_FS" != "$TARGET_FS_TYPE" ]; then
        target_notice 'target mount identity changed'
        return 1
    fi
    if ! target_mount_is_rw "$TARGET_RECORD_VFS_OPTIONS" \
        "$TARGET_RECORD_SUPER_OPTIONS"; then
        target_notice 'target mount became read-only'
        return 1
    fi
    target_mount_tree_healthy || return 1
    return 0
}

# Create a relative directory below the live FD anchor without following links.
# Argument: non-empty relative path. Returns nonzero without using bare mounts.
target_prepare_directory() {
    target_anchor_healthy || return 1
    target_relative_path=$1
    case "$target_relative_path" in
        ''|/*|.|..|*/./*|*/../*|*/.|*/..|*[[:cntrl:]]*)
            target_notice 'target directory path contains an unsafe segment'
            return 1
            ;;
    esac

    target_prepare_rest=$target_relative_path
    target_prepare_path=$TARGET_FD_ROOT
    while [ -n "$target_prepare_rest" ]; do
        target_prepare_component=${target_prepare_rest%%/*}
        case "$target_prepare_component" in
            ''|.|..)
                target_notice 'target directory path contains an unsafe segment'
                return 1
                ;;
        esac
        target_prepare_path=$target_prepare_path/$target_prepare_component
        if [ -L "$target_prepare_path" ]; then
            target_notice 'target directory contains a symlink component'
            return 1
        fi
        if [ ! -e "$target_prepare_path" ]; then
            target_anchor_healthy || return 1
            mkdir "$target_prepare_path" || {
                target_notice 'cannot create target directory through anchor FD'
                return 1
            }
        fi
        [ -d "$target_prepare_path" ] || {
            target_notice 'target directory component is not a directory'
            return 1
        }
        case "$target_prepare_rest" in
            */*) target_prepare_rest=${target_prepare_rest#*/} ;;
            *) target_prepare_rest= ;;
        esac
    done
    target_anchor_healthy
}

# Prepare the configured backup root as a strict child of the open target mount.
# Argument: configured absolute backup root. Success exports TARGET_BACKUP_ROOT.
target_prepare_root() {
    target_configured_root=$(target_normalize_path "$1") || return 1
    case "$target_configured_root" in
        "$TARGET_MOUNT_PATH"/*)
            target_root_relative=${target_configured_root#"$TARGET_MOUNT_PATH"/}
            ;;
        *)
            target_notice 'backup root must be a strict child of target mount'
            return 1
            ;;
    esac
    [ -n "$target_root_relative" ] || {
        target_notice 'backup root must be a strict child of target mount'
        return 1
    }
    TARGET_BACKUP_PATH=$target_configured_root
    if ! target_prepare_directory "$target_root_relative"; then
        unset TARGET_BACKUP_PATH
        return 1
    fi
    TARGET_BACKUP_ROOT=$TARGET_FD_ROOT/$target_root_relative
    return 0
}
