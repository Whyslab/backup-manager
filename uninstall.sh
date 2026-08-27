#!/usr/bin/env bash
# uninstall.sh — remove Backup Manager.
#
# By default it removes the program and leaves your data alone: the borg
# repository, the passphrase and the logs stay where they are. Removing the
# repository is a separate, explicit flag, because without the passphrase
# those backups can never be read again.
#
#   sudo ./uninstall.sh                remove the program, keep the backups
#   sudo ./uninstall.sh --purge        also remove logs, state and the passphrase
#   sudo ./uninstall.sh --dry-run      print what would happen
#   ./uninstall.sh --prefix /tmp/test  undo a sandbox install

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}  ok${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}  !!${NC} $*"; }
die()  { printf '%b\n' "${RED}error:${NC} $*" >&2; exit 1; }

DRY=0; PURGE=0; PREFIX=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --purge)   PURGE=1; shift ;;
        --prefix)  PREFIX="${2%/}"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$PREFIX" || $EUID -eq 0 ]] || die "root privileges required: sudo ./uninstall.sh"

OPT_DIR="${PREFIX}/opt/backup-manager"
ETC_DIR="${PREFIX}/etc/backup-manager"
BIN_DIR="${PREFIX}/usr/local/bin"
UNIT_DIR="${PREFIX}/etc/systemd/system"
LOG_DIR="${PREFIX}/var/log/backup-manager"
STATE_DIR="${PREFIX}/var/lib/backup-manager"
LOGROTATE="${PREFIX}/etc/logrotate.d/backup-manager"

run() { if (( DRY )); then printf '   would run: %s\n' "$*"; else "$@"; fi; }

REPO=""
if [[ -r "${OPT_DIR}/config/settings.json" ]] && command -v jq >/dev/null; then
    REPO=$(jq -r '.targets[] | select(.name=="local") | .repo' "${OPT_DIR}/config/settings.json" 2>/dev/null || echo "")
fi

(( DRY )) && warn "dry run — nothing will be removed"

# ---------------------------------------------------------------- timers

if [[ -z "$PREFIX" ]]; then
    say "Stopping and disabling timers"
    for t in bm-backup bm-full bm-check bm-drill; do
        if systemctl list-unit-files "${t}.timer" --no-legend 2>/dev/null | grep -q .; then
            run systemctl disable --now "${t}.timer"
        fi
    done
    ok "timers stopped"

    if mountpoint -q /mnt/backup 2>/dev/null; then
        say "Unmounting /mnt/backup"
        run borg umount /mnt/backup || warn "could not unmount — do it by hand: borg umount /mnt/backup"
    fi
fi

# ---------------------------------------------------------------- files

say "Removing units"
run rm -f "${UNIT_DIR}"/bm-backup.service "${UNIT_DIR}"/bm-backup.timer \
          "${UNIT_DIR}"/bm-full.service   "${UNIT_DIR}"/bm-full.timer \
          "${UNIT_DIR}"/bm-check.service  "${UNIT_DIR}"/bm-check.timer \
          "${UNIT_DIR}"/bm-drill.service  "${UNIT_DIR}"/bm-drill.timer \
          "${UNIT_DIR}"/bm-failure@.service
[[ -z "$PREFIX" ]] && run systemctl daemon-reload
ok "units removed"

say "Removing symlinks"
run rm -f "${BIN_DIR}/bm" "${BIN_DIR}/backup-manager"

say "Removing the program"
run rm -rf "$OPT_DIR"
run rm -f "$LOGROTATE"
ok "program removed"

# ---------------------------------------------------------------- data

if (( PURGE )); then
    say "--purge: removing logs, state and the passphrase"
    run rm -rf "$LOG_DIR" "$STATE_DIR"
    run rm -rf "$ETC_DIR"
    ok "logs, state and passphrase removed"
    echo
    warn "The passphrase is gone. If the borg repository still exists,"
    warn "it can no longer be read. Restore the passphrase from your own"
    warn "written copy before trying to open it."
else
    say "Keeping your data"
    echo "   logs       : ${LOG_DIR}"
    echo "   state      : ${STATE_DIR}"
    echo "   passphrase : ${ETC_DIR}/passphrase"
fi

echo
if [[ -n "$REPO" ]]; then
    say "The borg repository was NOT touched:"
    echo "   ${REPO}"
    echo
    echo "   It is still a valid borg repository. To read it without this tool:"
    echo "     export BORG_PASSCOMMAND='cat ${ETC_DIR}/passphrase'"
    echo "     borg list ${REPO}"
    echo
    echo "   To delete it permanently (this cannot be undone):"
    echo "     borg delete ${REPO}"
fi
echo
ok "Uninstall finished."
