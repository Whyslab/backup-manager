#!/usr/bin/env bash
# lib/notify.sh — notify the user's graphical session from root.
# notify-send only: never a full-screen window.

notify_user() {
    local urgency=$1 title=$2 body=$3 icon=${4:-drive-harddisk}
    local uid bus
    uid=$(id -u "$REAL_USER" 2>/dev/null) || return 0
    bus="/run/user/${uid}/bus"

    if [[ ! -S "$bus" ]]; then
        log_warn "No graphical session for $REAL_USER — logging only: ${title}: ${body}"
        return 0
    fi

    # runuser with -- passes arguments straight through, no shell parsing.
    runuser -u "$REAL_USER" -- \
        env "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus}" \
        notify-send -a "Backup Manager" -u "$urgency" -i "$icon" "$title" "$body" \
        >/dev/null 2>&1 || log_warn "notify-send failed"
    return 0
}

notify_ok()    { notify_user normal   "Backup Manager" "$1" dialog-information; }
notify_warn()  { notify_user normal   "Backup Manager" "$1" dialog-warning; }
notify_fail()  { notify_user critical "Backup Manager" "$1" dialog-error; }
