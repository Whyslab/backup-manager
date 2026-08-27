#!/usr/bin/env bash
# install.sh — install Backup Manager.
#
# Everything it writes outside the repository is listed in the "Uninstall"
# section of the README, and uninstall.sh removes exactly that set.
#
#   sudo ./install.sh                 install and set up the repository
#   sudo ./install.sh --dry-run       print every step, change nothing
#   ./install.sh --prefix /tmp/test   install into a sandbox (no root needed)
#
# --prefix exists so the installer can be tested without touching a real
# system: every path below is built from $PREFIX, and with a prefix set the
# script never calls pacman, systemctl or borg.

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}  ok${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}  !!${NC} $*"; }
die()  { printf '%b\n' "${RED}error:${NC} $*" >&2; exit 1; }

DRY=0
PREFIX=""
TARGET_USER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --prefix)  PREFIX="${2%/}"; shift 2 ;;
        --user)    TARGET_USER="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

OPT_DIR="${PREFIX}/opt/backup-manager"
ETC_DIR="${PREFIX}/etc/backup-manager"
BIN_DIR="${PREFIX}/usr/local/bin"
UNIT_DIR="${PREFIX}/etc/systemd/system"
LOGROTATE="${PREFIX}/etc/logrotate.d/backup-manager"
LOG_DIR="${PREFIX}/var/log/backup-manager"
STATE_DIR="${PREFIX}/var/lib/backup-manager"

run() {
    if (( DRY )); then printf '   would run: %s\n' "$*"; else "$@"; fi
}

# ---------------------------------------------------------------- checks

if [[ -z "$PREFIX" && $EUID -ne 0 ]]; then
    die "root privileges required: sudo ./install.sh (or use --prefix for a sandbox install)"
fi

if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] \
    || die "could not determine the target user; pass it explicitly: --user <name>"

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$TARGET_HOME" ]] || die "no home directory found for user '$TARGET_USER'"

say "Target user : ${TARGET_USER} (${TARGET_HOME})"
say "Install root: ${PREFIX:-/}"
(( DRY )) && warn "dry run — nothing will be written"

# ---------------------------------------------------------------- deps

REQUIRED=(borg jq openssl)
OPTIONAL=(rofi kitty notify-send fusermount3)

if [[ -z "$PREFIX" ]]; then
    missing=()
    for d in "${REQUIRED[@]}"; do command -v "$d" >/dev/null || missing+=("$d"); done
    if (( ${#missing[@]} )); then
        say "Installing dependencies: ${missing[*]}"
        if command -v pacman >/dev/null; then
            declare -A PKG=([borg]=borg [jq]=jq [openssl]=openssl)
            pkgs=(); for m in "${missing[@]}"; do pkgs+=("${PKG[$m]}"); done
            run pacman -S --needed --noconfirm "${pkgs[@]}"
        else
            die "missing: ${missing[*]} — install them with your package manager, then re-run"
        fi
    else
        ok "all required dependencies present"
    fi
    for d in "${OPTIONAL[@]}"; do
        command -v "$d" >/dev/null || warn "optional dependency missing: ${d} (the rofi menu / notifications / bm mount need it)"
    done
fi

# ---------------------------------------------------------------- code

say "Installing code into ${OPT_DIR}"
if [[ -d "$OPT_DIR" ]]; then
    BACKUP="${OPT_DIR}.orig-$(date +%Y%m%d_%H%M%S)"
    warn "${OPT_DIR} already exists — saving the previous copy to ${BACKUP}"
    run cp -a "$OPT_DIR" "$BACKUP"
fi
run install -d -m 755 "$OPT_DIR" "$OPT_DIR/lib" "$OPT_DIR/ui" "$OPT_DIR/config" "$OPT_DIR/systemd"
run install -m 755 "${SRC_DIR}/bm"                    "${OPT_DIR}/bm"
run install -m 644 "${SRC_DIR}"/lib/*.sh              "${OPT_DIR}/lib/"
run chmod 755 "${OPT_DIR}/lib/failure-notify.sh" 2>/dev/null || true
run install -m 755 "${SRC_DIR}"/ui/*.sh               "${OPT_DIR}/ui/"
run install -m 644 "${SRC_DIR}"/ui/*.rasi             "${OPT_DIR}/ui/"
run install -m 644 "${SRC_DIR}"/systemd/*             "${OPT_DIR}/systemd/"
ok "code installed"

# ---------------------------------------------------------------- config

say "Generating configuration"
SETTINGS="${OPT_DIR}/config/settings.json"
SOURCES="${OPT_DIR}/config/sources.json"

if [[ -f "$SETTINGS" ]]; then
    warn "settings.json already exists — keeping it as is"
else
    if (( DRY )); then
        printf '   would write: %s (target_user=%s, repo=%s/backup/borg-repo)\n' \
            "$SETTINGS" "$TARGET_USER" "$TARGET_HOME"
    else
        sed -e "s|__USER__|${TARGET_USER}|g" \
            -e "s|__HOME__|${TARGET_HOME}|g" \
            "${SRC_DIR}/config/settings.example.json" > "$SETTINGS"
        chmod 644 "$SETTINGS"
        ok "settings.json written"
    fi
fi

if [[ -f "$SOURCES" ]]; then
    warn "sources.json already exists — keeping it as is"
else
    run install -m 644 "${SRC_DIR}/config/sources.example.json" "$SOURCES"
    ok "sources.json written (review it: bm sources)"
fi

# ---------------------------------------------------------------- symlinks, dirs

say "Creating command symlinks"
run install -d -m 755 "$BIN_DIR"
run ln -sfn /opt/backup-manager/bm                "${BIN_DIR}/bm"
run ln -sfn /opt/backup-manager/ui/rofi_menu.sh   "${BIN_DIR}/backup-manager"
ok "bm and backup-manager available on PATH"

say "Creating log and state directories"
run install -d -m 755 "$LOG_DIR" "$STATE_DIR"
run install -d -m 755 "$(dirname "$LOGROTATE")"
run install -m 644 "${SRC_DIR}/logrotate.backup-manager" "$LOGROTATE"
ok "logs rotate weekly, 8 kept"

# ---------------------------------------------------------------- systemd

say "Installing systemd units"
run install -d -m 755 "$UNIT_DIR"
run install -m 644 "${SRC_DIR}"/systemd/bm-*.service "${SRC_DIR}"/systemd/bm-*.timer "$UNIT_DIR/"
if [[ -z "$PREFIX" ]]; then
    run systemctl daemon-reload
fi
ok "units installed (not enabled yet)"

# ---------------------------------------------------------------- repository

if [[ -n "$PREFIX" ]]; then
    say "Sandbox install — skipping repository creation"
    echo
    ok "Sandbox install finished: ${PREFIX}"
    exit 0
fi

echo
say "Creating the borg repository and passphrase"
if (( DRY )); then
    printf '   would run: bm init\n'
else
    "${OPT_DIR}/bm" init
fi

# ---------------------------------------------------------------- timers

echo
say "Timers"
cat <<'TIMERS'
   bm-backup.timer   daily 03:20   tier 1 snapshot
   bm-full.timer     Sun   03:40   full snapshot (tiers 1+2)
   bm-check.timer    Mon   04:00   integrity check
   bm-drill.timer    1st   04:30   deep check + restore drill
TIMERS
echo
if (( DRY )); then
    printf '   would ask whether to enable the timers\n'
else
    read -rp "Enable the timers now? [Y/n] " answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
        systemctl enable --now bm-backup.timer bm-full.timer bm-check.timer bm-drill.timer
        ok "timers enabled"
    else
        warn "timers left disabled — enable them later with:"
        echo "     sudo systemctl enable --now bm-backup.timer bm-full.timer bm-check.timer bm-drill.timer"
    fi
fi

echo
ok "Installation finished."
echo
echo "  Check what will be backed up:  bm sources"
echo "  Take the first snapshot:       sudo bm backup"
echo "  See how things stand:          sudo bm status"
echo "  Open the menu:                 backup-manager"
