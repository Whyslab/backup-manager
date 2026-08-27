#!/usr/bin/env bash
# lib/failure-notify.sh — invoked via OnFailure=. Argument: the name of the failed unit.
set -uo pipefail
BASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
UNIT="${1:-unknown unit}"

mkdir -p /var/log/backup-manager
MSG="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - Unit ${UNIT} failed"
echo "$MSG" | tee -a /var/log/backup-manager/errors.log >> /var/log/backup-manager/backup.log

REAL_USER=$(jq -r '.target_user' "${BASE_DIR}/config/settings.json" 2>/dev/null || echo "")
if [[ -z "$REAL_USER" || "$REAL_USER" == "null" ]]; then
    echo "[ERROR] target_user is not set in config/settings.json" >> /var/log/backup-manager/errors.log
    exit 0
fi
UID_N=$(id -u "$REAL_USER" 2>/dev/null) || exit 0
BUS="/run/user/${UID_N}/bus"
[[ -S "$BUS" ]] || exit 0

runuser -u "$REAL_USER" -- env "DBUS_SESSION_BUS_ADDRESS=unix:path=${BUS}" \
    notify-send -a "Backup Manager" -u critical -i dialog-error \
    "Backup failed" \
    "Unit ${UNIT}. See: journalctl -u ${UNIT} and /var/log/backup-manager/errors.log" \
    >/dev/null 2>&1 || true
exit 0
