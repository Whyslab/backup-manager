#!/usr/bin/env bash
# ui/hyprpanel_module.sh — a HyprPanel module.
# Runs AS THE USER, without root: everything comes from status.json (mode 644),
# written by bm after every run, plus live systemd state.
# Must always print valid JSON, or HyprPanel complains.

export LC_ALL=C          # parse dates consistently regardless of locale
STATUS=${BM_STATUS_FILE:-/var/lib/backup-manager/status.json}   # overridden in tests
UNITS=(bm-backup.service bm-full.service bm-check.service bm-drill.service)

emit() {  # emit <alt> <state_text> [other fields...]
    jq -nc \
        --arg alt "$1" --arg state "$2" \
        --arg time "${TIME:-—}"      --arg ago "${AGO:-—}" \
        --arg size "${SIZE:-—}"      --arg added "${ADDED:-—}" \
        --arg repo "${REPO_SZ:-—}"   --arg count "${COUNT:-0}" \
        --arg archive "${ARCHIVE:-—}" \
        --arg checked "${CHECKED:-never}" \
        --arg drilled "${DRILLED:-never}" \
        --arg next "${NEXT:-—}" \
        '{alt:$alt, state:$state, time:$time, ago:$ago, size:$size,
          added:$added, repo:$repo, count:$count, archive:$archive,
          checked:$checked, drilled:$drilled, next:$next}'
    exit 0
}

# Pretty date: "26.08 11:25"
fmt() { [[ -n "$1" ]] && date -d "$1" '+%d.%m %H:%M' 2>/dev/null || echo "—"; }

# "3h ago" / "12m ago" / "2d ago"
ago_of() {
    local ts=$1 now diff
    [[ -n "$ts" ]] || { echo "—"; return; }
    now=$(date +%s); diff=$(( now - $(date -d "$ts" +%s 2>/dev/null || echo "$now") ))
    (( diff < 0 )) && diff=0
    if   (( diff < 3600  )); then echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then echo "$(( diff / 3600 ))h ago"
    else                          echo "$(( diff / 86400 ))d ago"; fi
}

[[ -r "$STATUS" ]] || emit none "not configured"

ARCHIVE=$(jq -r '.archive  // ""' "$STATUS" 2>/dev/null)
START=$(  jq -r '.start    // ""' "$STATUS" 2>/dev/null)
SIZE=$(   jq -r '.size     // ""' "$STATUS" 2>/dev/null)
ADDED=$(  jq -r '.added    // ""' "$STATUS" 2>/dev/null)
REPO_SZ=$(jq -r '.repo     // ""' "$STATUS" 2>/dev/null)
COUNT=$(  jq -r '.count    // 0'  "$STATUS" 2>/dev/null)
CHK=$(    jq -r '.checked  // ""' "$STATUS" 2>/dev/null)
DRL=$(    jq -r '.drilled  // ""' "$STATUS" 2>/dev/null)

TIME=$(fmt "$START"); AGO=$(ago_of "$START")
CHECKED=$([[ -n "$CHK" ]] && echo "$(fmt "$CHK") ($(ago_of "$CHK"))" || echo "never")
DRILLED=$([[ -n "$DRL" ]] && echo "$(fmt "$DRL") ($(ago_of "$DRL"))" || echo "never")

NEXT_RAW=$(systemctl show -p NextElapseUSecRealtime --value bm-backup.timer 2>/dev/null)
NEXT=$(fmt "$NEXT_RAW")

# 1. Something failed — that outranks everything else.
for u in "${UNITS[@]}"; do
    [[ "$(systemctl is-failed "$u" 2>/dev/null)" == "failed" ]] && emit error "FAILED: $u"
done

# 2. A run is in progress right now.
for u in "${UNITS[@]}"; do
    case "$(systemctl is-active "$u" 2>/dev/null)" in
        active|activating) emit running "backing up…" ;;
    esac
done

# 3. No archives at all.
[[ -n "$ARCHIVE" ]] || emit none "no backups"

# 4. The snapshot is stale.
NOW=$(date +%s)
AGE_H=$(( ( NOW - $(date -d "$START" +%s 2>/dev/null || echo "$NOW") ) / 3600 ))
(( AGE_H > 48 )) && emit warning "last backup is ${AGE_H}h old"

# 5. Integrity has not been checked in a long time.
if [[ -n "$CHK" ]]; then
    CHK_D=$(( ( NOW - $(date -d "$CHK" +%s 2>/dev/null || echo "$NOW") ) / 86400 ))
    (( CHK_D > 21 )) && emit warning "integrity unchecked for ${CHK_D}d"
else
    emit warning "integrity has never been checked"
fi

# 6. All good.
emit ok "all good"
