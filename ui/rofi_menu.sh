#!/usr/bin/env bash
# ui/rofi_menu.sh — a menu on top of bm.
#
# Two rules that must not be broken:
#  1. NEVER run pkexec in the same pipeline as rofi. In a pipeline both sides
#     start at once; rofi grabs the keyboard, and the polkit window underneath
#     cannot accept the password. Fetch the data first, then open rofi.
#  2. Anything that can be shown without root comes from status.json and
#     archives.txt (mode 644, written by bm). That way merely looking at the
#     status needs no pkexec at all.
#
# Menu entries are written as "key|label" (see MAIN/MORE below). The label is
# displayed, dispatch works on the key — so labels can be reworded freely
# without touching the logic or risking the two drifting apart.

BASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BM="${BASE_DIR}/bm"
SOURCES_FILE="${BASE_DIR}/config/sources.json"
ROFI_THEME="${BASE_DIR}/ui/monochrome-vivid.rasi"
STATE_DIR=/var/lib/backup-manager
STATUS="${STATE_DIR}/status.json"
ARCHIVES="${STATE_DIR}/archives.txt"

# --- wrappers that are swapped out in test mode -------------------------

rofi_menu() {   # rofi_menu <title>  (reads the list from stdin)
    if [[ -n "${BM_MENU_TEST:-}" ]]; then
        cat > /dev/null                       # swallow the list
        printf '%s\n' "${BM_TEST_CHOICE:-}"   # return the preset answer
    else
        rofi -dmenu -i -p "$1" -theme "$ROFI_THEME"
    fi
}

run() {         # perform a privileged action
    if [[ -n "${BM_MENU_TEST:-}" ]]; then
        echo "TEST: would run -> $*"
    else
        "$@"
    fi
}

notify() {
    if [[ -n "${BM_MENU_TEST:-}" ]]; then
        echo "TEST: notification -> $1"
    else
        notify-send -a "Backup Manager" -i drive-harddisk "Backup Manager" "$1"
    fi
}
notify_err() {
    if [[ -n "${BM_MENU_TEST:-}" ]]; then
        echo "TEST: notification(error) -> $1"
    else
        notify-send -a "Backup Manager" -u critical -i dialog-error "Backup Manager" "$1"
    fi
}

confirm() {
    [[ -n "${BM_MENU_TEST:-}" ]] && return "${BM_TEST_CONFIRM:-0}"
    [[ "$(printf 'No\nYes\n' | rofi_menu "$1")" == "Yes" ]]
}

term() {        # run in a terminal and wait
    if [[ -n "${BM_MENU_TEST:-}" ]]; then
        echo "TEST: in a terminal -> $*"
    else
        kitty -e bash -c "$1"
    fi
}

# --- data that needs no root --------------------------------------------

archive_list() {    # "name   date", one per line, newest first
    [[ -r "$ARCHIVES" ]] || return 1
    LC_ALL=C awk -F'\t' '{
        cmd = "date -d \"" $2 "\" \"+%d.%m.%Y %H:%M\" 2>/dev/null"
        cmd | getline when; close(cmd)
        printf "%-30s  %s\n", $1, (when == "" ? $2 : when)
    }' "$ARCHIVES"
}

status_lines() {
    if [[ ! -r "$STATUS" ]]; then
        echo "Status unavailable — run: pkexec bm refresh-status"
        return
    fi
    "${BASE_DIR}/ui/hyprpanel_module.sh" | jq -r '
        "Right now:         \(.state)",
        "",
        "Last backup:       \(.time)  (\(.ago))",
        "Its size:          \(.size)",
        "Backups in total:  \(.count)  ·  \(.repo) on disk",
        "Next backup:       \(.next)",
        "",
        "Backups intact:    checked \(.checked)",
        "Files restorable:  checked \(.drilled)"'
}

# --- actions ------------------------------------------------------------

act_backup() {      # act_backup 1|full "<what is included>"
    local tier=$1 what=$2
    confirm "Start a backup? It will include: ${what}" || return 0
    notify "Backing up…"
    if run pkexec "$BM" backup --tier "$tier"; then
        notify "Backup done"
    else
        notify_err "Failed. See journalctl -u bm-backup / errors.log"
    fi
}

act_list() {
    local list
    list=$(archive_list) || { notify_err "List unavailable. Run: pkexec bm refresh-status"; return 1; }
    [[ -n "$list" ]] || { notify "No backups yet"; return 0; }
    printf '%s\n' "$list" | rofi_menu "All backups" >/dev/null
}

act_mount() {
    local list archive
    list=$(archive_list) || { notify_err "List unavailable"; return 1; }
    # rofi has finished and closed BEFORE the password prompt appears.
    archive=$(printf '%s\n' "$list" | rofi_menu "Which backup to open" | awk '{print $1}')
    [[ -n "$archive" ]] || return 0
    if run pkexec "$BM" mount "$archive"; then
        notify "Backup opened as the folder /mnt/backup"
        [[ -n "${BM_MENU_TEST:-}" ]] || xdg-open /mnt/backup >/dev/null 2>&1 &
    else
        notify_err "Could not open the backup"
    fi
}

act_umount() { run pkexec "$BM" umount && notify "Backup closed"; }

act_status() {
    status_lines | rofi_menu "How the backup is doing" >/dev/null
}

act_check()   { term "pkexec '$BM' check;  echo; read -rp 'Enter to close'"; }
act_drill()   { term "pkexec '$BM' drill;  echo; read -rp 'Enter to close'"; }
act_sources() { term "'$BM' sources | less -R"; }
act_edit()    { term "\${EDITOR:-nano} '$SOURCES_FILE' && echo 'Checking:' && '$BM' sources && read -rp 'Enter to close'"; }

# --- menus --------------------------------------------------------------

MAIN=(
    "backup1|󰆓  Back up — essentials only"
    "backupF|󰆓  Back up — absolutely everything"
    "mount|󰉋  Open a backup, browse the files"
    "status|󰋼  How the backup is doing"
    "more|󰇘  More…"
)

MORE=(
    "umount|󰅖  Close the opened backup"
    "list|󰋊  All backups — list"
    "check|󰕥  Verify the backups are intact"
    "drill|󰁯  Verify a file can be restored"
    "sources|󰋼  What goes into a backup"
    "edit|󰏫  Change what goes into a backup"
    "back|󰌍  Back"
)

show_menu() {   # show_menu <title> <array name> → prints the key of the choice
    local title=$1 chosen entry
    local -n items=$2
    chosen=$(printf '%s\n' "${items[@]#*|}" | rofi_menu "$title")
    [[ -n "$chosen" ]] || return 0
    for entry in "${items[@]}"; do
        [[ "${entry#*|}" == "$chosen" ]] && { printf '%s\n' "${entry%%|*}"; return 0; }
    done
    notify_err "Unknown entry: $chosen"
    return 1
}

dispatch() {
    case "$1" in
        backup1)  act_backup 1    "configs, projects, documents" ;;
        backupF)  act_backup full "everything, media and chat apps included" ;;
        mount)    act_mount ;;
        status)   act_status ;;
        more)     dispatch "$(show_menu "More" MORE)" ;;
        umount)   act_umount ;;
        list)     act_list ;;
        check)    act_check ;;
        drill)    act_drill ;;
        sources)  act_sources ;;
        edit)     act_edit ;;
        back)     dispatch "$(show_menu "Backup Manager" MAIN)" ;;
        "")       return 0 ;;
        *)        notify_err "Unknown action: $1"; return 1 ;;
    esac
}

[[ "${BM_MENU_NO_MAIN:-}" == "1" ]] || dispatch "$(show_menu "Backup Manager" MAIN)"
