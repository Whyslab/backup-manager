#!/usr/bin/env bash
# lib/core.sh — logging, error handling, dependency checks.

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

LOG_DIR="/var/log/backup-manager"
LOG_FILE="${LOG_DIR}/backup.log"
ERR_FILE="${LOG_DIR}/errors.log"

# Without root we cannot write to /var/log — log to the screen only, so that
# read-only commands (bm sources) still work as a regular user.
if [[ $EUID -eq 0 ]]; then
    mkdir -p "$LOG_DIR"
elif [[ ! -w "$LOG_FILE" ]]; then
    LOG_FILE=""; ERR_FILE=""
fi

_log() {
    local level=$1 color=$2 msg
    shift 2
    msg="[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    printf '%b%s%b\n' "$color" "$msg" "$NC" >&2
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
    [[ "$level" == "ERROR" && -n "$ERR_FILE" ]] && echo "$msg" >> "$ERR_FILE"
    return 0
}

log_info() { _log INFO  "$GREEN"  "$@"; }
log_warn() { _log WARN  "$YELLOW" "$@"; }
log_err()  { _log ERROR "$RED"    "$@"; }
log_step() { _log STEP  "$BLUE"   "$@"; }

# Directories to remove on abnormal exit. Filled in by the caller.
declare -a CLEANUP_PATHS=()
cleanup_register() { CLEANUP_PATHS+=("$1"); }

_cleanup() {
    # Main process only. A subshell (inside <(...), say) would inherit the trap
    # and wipe the parent's work directory out from under it.
    [[ "$BASHPID" == "$$" ]] || return 0
    local p
    for p in "${CLEANUP_PATHS[@]:-}"; do
        [[ -n "$p" && -d "$p" ]] && rm -rf -- "$p"
    done
    return 0
}

trap_err() {
    local line=$1 err=$2
    log_err "Fatal error on line $line (exit code $err)"
    _cleanup
    exit "$err"
}
trap 'trap_err $LINENO $?' ERR
trap '_cleanup' EXIT

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Root privileges required: run with sudo (or pkexec) ${0##*/} ..." >&2
        exit 1
    fi
}

check_deps() {
    local missing=()
    local dep
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if (( ${#missing[@]} )); then
        log_err "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# Human-readable size from bytes. numfmt glues the number to the unit
# ("12.1GB") — split them, or the status-bar tooltip reads badly.
#
# LC_ALL=C is not cosmetic: under a locale that uses a comma as the decimal
# separator numfmt emits "1,5 GB", which then lands in status.json and in every
# notification. Sizes are formatted the same way regardless of the system locale.
human() {
    local b=${1:-0} out
    out=$(LC_ALL=C numfmt --to=iec --suffix=B --format='%.1f' "$b" 2>/dev/null) || { echo "${b} B"; return; }
    sed -E 's/([0-9])([KMGTPE]?B)$/\1 \2/' <<<"$out"
}

# Directory size, tolerant of permission denials (du returns 1, and pipefail
# would turn that into a failure of the whole script).
dir_size() {
    local p=$1 s=""
    s=$( { du -sh --apparent-size "$p" 2>/dev/null || true; } | cut -f1 )
    [[ -n "$s" ]] || s="?"
    echo "$s"
}
