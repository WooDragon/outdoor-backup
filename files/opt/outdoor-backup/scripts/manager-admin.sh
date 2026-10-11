#!/bin/sh
# Lazy administrative argv validation. Reuse owner lexical policy, no event seq.
# Args: DEVNAME DEVPATH. Returns 0 only for canonical device/path relationship.
manager_admin_validate() {
    [ "$#" -eq 2 ] || return 1
    . "$SCRIPT_DIR/owner-event.sh"
    # The constant is only a validator input, never an EVENT_SEQNUM snapshot.
    owner_event_validate_event "$1" "$2" 1
}
