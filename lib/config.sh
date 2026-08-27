#!/usr/bin/env bash
# lib/config.sh — the one place where sources.json becomes borg arguments.

# Filled in by config_load
REAL_USER=""; REAL_HOME=""; REPO=""; PASSPHRASE_FILE=""; COMPRESSION=""
MOUNT_POINT=""; RESTORE_STAGING=""; STALE_AFTER_HOURS=""; DRILL_SAMPLE_SIZE=""

# Filled in by build_tier
declare -a ROOTS=()
declare -a EXCLUDE_ARGS=()
declare -a MISSING_PATHS=()

config_load() {
    SETTINGS_FILE="${BASE_DIR}/config/settings.json"
    SOURCES_FILE="${BASE_DIR}/config/sources.json"

    local f
    for f in "$SETTINGS_FILE" "$SOURCES_FILE"; do
        [[ -r "$f" ]] || { log_err "Cannot read config: $f"; exit 1; }
        jq empty "$f" 2>/dev/null || { log_err "Malformed JSON: $f"; exit 1; }
    done

    REAL_USER=$(jq -r '.target_user' "$SETTINGS_FILE")
    [[ -n "$REAL_USER" && "$REAL_USER" != "null" ]] \
        || { log_err "target_user is not set in settings.json"; exit 1; }
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    [[ -n "$REAL_HOME" ]] || { log_err "No home directory found for $REAL_USER"; exit 1; }

    REPO=$(jq -r '.targets[] | select(.name=="local") | .repo' "$SETTINGS_FILE")
    PASSPHRASE_FILE=$(jq -r '.passphrase_file' "$SETTINGS_FILE")
    COMPRESSION=$(jq -r '.compression' "$SETTINGS_FILE")
    MOUNT_POINT=$(jq -r '.mount_point' "$SETTINGS_FILE")
    RESTORE_STAGING=$(jq -r '.restore_staging' "$SETTINGS_FILE")
    STALE_AFTER_HOURS=$(jq -r '.stale_after_hours' "$SETTINGS_FILE")
    DRILL_SAMPLE_SIZE=$(jq -r '.drill_sample_size' "$SETTINGS_FILE")
}

# ~ → the target user's home directory. No eval involved.
expand_path() {
    local p=$1
    [[ "$p" == "~"* ]] && p="${REAL_HOME}${p#\~}"
    echo "$p"
}

# Builds ROOTS[] and EXCLUDE_ARGS[] for a tier.
#   build_tier 1     — tier 1 only
#   build_tier all   — tier 1 + tier 2
build_tier() {
    local want=$1
    local filter
    if [[ "$want" == "all" ]]; then
        filter='.sources[]'
    else
        filter=".sources[] | select(.tier == ${want})"
    fi

    ROOTS=(); EXCLUDE_ARGS=(); MISSING_PATHS=()

    # Global exclusions — applied to everything.
    local pat
    while IFS= read -r pat; do
        [[ -n "$pat" ]] && EXCLUDE_ARGS+=(--exclude "sh:${pat}")
    done < <(jq -r '.never[]?' "$SOURCES_FILE")

    # Sources: a path plus its own exclusions, anchored to that path.
    local line src_path src_excludes abs
    while IFS= read -r line; do
        src_path=$(jq -r '.path' <<<"$line")
        abs=$(expand_path "$src_path")

        if [[ ! -e "$abs" ]]; then
            MISSING_PATHS+=("$abs")
            continue
        fi
        ROOTS+=("$abs")

        while IFS= read -r pat; do
            [[ -z "$pat" ]] && continue
            # Anchor the pattern to its own source, so that "Cache" in one
            # directory does not exclude "Cache" in another.
            EXCLUDE_ARGS+=(--exclude "sh:${abs%/}/${pat}")
        done < <(jq -r '.exclude[]?' <<<"$line")

        # Big things that are not needed daily: dropped from tier 1,
        # kept in the full (weekly) run.
        if [[ "$want" != "all" ]]; then
            while IFS= read -r pat; do
                [[ -z "$pat" ]] && continue
                EXCLUDE_ARGS+=(--exclude "sh:${abs%/}/${pat}")
            done < <(jq -r '.exclude_unless_full[]?' <<<"$line")
        fi
    done < <(jq -c "$filter" "$SOURCES_FILE")
}

archive_prefix_for() {
    local want=$1
    if [[ "$want" == "all" ]]; then
        jq -r '.tiers["2"].archive_prefix' "$SOURCES_FILE"
    else
        jq -r ".tiers[\"${want}\"].archive_prefix" "$SOURCES_FILE"
    fi
}
