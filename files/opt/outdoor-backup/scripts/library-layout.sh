#!/bin/sh
# Inert POSIX disk-layout admission, shared by mirror and future cleanup callers.
# No Perl, writes, mounts, lock ownership or JSON-policy inference here.

# Detect any date state, including dangling links and incomplete initialization.
# Args: directory. Returns 0 when suspicious state exists, 1 otherwise.
library_layout_has_state() {
    [ -e "$1/.outdoor-backup" ] || [ -L "$1/.outdoor-backup" ]
}

# Refuse marked/suspicious ancestors and symbolic path components, read-only.
# Args: canonical absolute root. Returns 0/1. Missing components are permitted.
library_layout_ancestors_clear() {
    layout_probe=$1
    case "$layout_probe" in /*) ;; *) return 1 ;; esac
    case "$layout_probe" in *//*|*/./*|*/../*|*/.|*/..|*[[:cntrl:]]*) return 1 ;; esac
    while :; do
        [ ! -L "$layout_probe" ] || return 1
        library_layout_has_state "$layout_probe" && return 1
        [ "$layout_probe" != / ] || break
        layout_probe=${layout_probe%/*}
        [ -n "$layout_probe" ] || layout_probe=/
    done
    return 0
}

# Mirror roots may hold mirror data but never date state anywhere beneath them.
# Args: configured canonical root. Returns 0/1; no partial destructive traversal.
library_layout_mirror_admit() {
    library_layout_ancestors_clear "$1" || return 1
    [ -e "$1" ] || return 0
    [ -d "$1" ] || return 1
    layout_state=$(find "$1" -name .outdoor-backup -print) || return 1
    [ -z "$layout_state" ]
}

# Date roots are direct children; ancestors must not already be a date library.
# Args: configured date root, configured target mount. Returns 0/1, read-only.
library_layout_date_admit() {
    layout_root=$1 layout_mount=$2
    case "$layout_root" in "$layout_mount"/*) layout_suffix=${layout_root#"$layout_mount"/} ;; *) return 1 ;; esac
    case "$layout_suffix" in ''|*/*) return 1 ;; esac
    library_layout_ancestors_clear "$layout_mount" || return 1
    [ ! -L "$layout_root" ] || return 1
    [ ! -e "$layout_root" ] || [ -d "$layout_root" ]
}

# Require a truly empty root for initialization, counting hidden names too.
# Args: directory. Returns 0/1. Does not create or remove anything.
library_layout_empty_root() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    for layout_item in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$layout_item" ] || [ -L "$layout_item" ]; then return 1; fi
    done
    return 0
}
