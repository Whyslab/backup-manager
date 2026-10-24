#!/usr/bin/env bash
# lib/engine.sh — the one place borg is actually invoked.

STATE_DIR="/var/lib/backup-manager"

engine_env() {
    export BORG_REPO="$REPO"
    export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"
    # Never silently accept a moved or swapped repository — that is a sign of tampering.
    export BORG_RELOCATED_REPO_ACCESS_IS_OK=no
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no
    export BORG_HOSTNAME_IS_UNIQUE=yes
    [[ -n "$REPO_RSH" ]] && export BORG_RSH="$REPO_RSH"
    umask 077
}

# A repository on another machine: there the server creates and guards the directory.
engine_repo_remote() {
    [[ "$REPO" == ssh://* ]]
}

engine_repo_exists() {
    if engine_repo_remote; then
        ( engine_env; borg info "$REPO" >/dev/null 2>&1 )
    else
        [[ -f "${REPO}/config" ]]
    fi
}

engine_require_repo() {
    engine_repo_exists || {
        log_err "Repository not found: ${REPO}. Run this first: bm init"
        exit 1
    }
    [[ -r "$PASSPHRASE_FILE" ]] || {
        log_err "Cannot read the passphrase file: ${PASSPHRASE_FILE}"
        exit 1
    }
}

engine_init() {
    if engine_repo_exists; then
        log_warn "Repository already exists: ${REPO}"
        return 0
    fi

    log_step "Creating the passphrase and repository"

    install -d -m 700 -o root -g root "$(dirname "$PASSPHRASE_FILE")"
    if [[ ! -s "$PASSPHRASE_FILE" ]]; then
        openssl rand -base64 32 > "$PASSPHRASE_FILE"
        chmod 600 "$PASSPHRASE_FILE"; chown root:root "$PASSPHRASE_FILE"
        log_info "Passphrase generated: ${PASSPHRASE_FILE} (600 root:root)"
    else
        log_info "Using the existing passphrase: ${PASSPHRASE_FILE}"
    fi

    engine_repo_remote || install -d -m 700 -o root -g root "$REPO"
    engine_env
    borg init --encryption=repokey-blake2 "$REPO"
    engine_repo_remote || chmod -R go-rwx "$REPO"
    log_info "Repository created: ${REPO}"
}

# Collects package lists and a system manifest into STATE_DIR so they end up in the archive.
engine_snapshot_state() {
    local pkg_dir="${STATE_DIR}/packages"
    install -d -m 755 "$STATE_DIR" "$pkg_dir"
    export_packages "$pkg_dir"
    generate_manifest "${STATE_DIR}/manifest.json"
}

# engine_create <tier: 1|all> [--dry-run]
engine_create() {
    local tier=$1 dry=${2:-}
    local prefix; prefix=$(archive_prefix_for "$tier")

    build_tier "$tier"

    if (( ${#MISSING_PATHS[@]} )); then
        local p
        for p in "${MISSING_PATHS[@]}"; do log_warn "Path from sources.json not found, skipping: $p"; done
    fi
    (( ${#ROOTS[@]} )) || { log_err "Not a single existing source for tier '${tier}'"; exit 1; }

    local -a common=(
        --compression "$COMPRESSION"
        --one-file-system
        --exclude-caches
        --exclude-if-present .nobackup
        --keep-exclude-tags
    )

    if [[ "$dry" == "--dry-run" ]]; then
        log_step "Dry run (tier ${tier}): nothing is written"
        borg create --dry-run --list \
            "${common[@]}" "${EXCLUDE_ARGS[@]}" \
            "::${prefix}-{now:%Y%m%d_%H%M%S}" "${ROOTS[@]}"
        return 0
    fi

    engine_snapshot_state
    ROOTS+=("$STATE_DIR")

    log_step "Snapshot (tier ${tier}): ${#ROOTS[@]} sources"
    local out rc=0
    out=$(borg create --json --stats \
            "${common[@]}" "${EXCLUDE_ARGS[@]}" \
            "::${prefix}-{now:%Y%m%d_%H%M%S}" "${ROOTS[@]}") || rc=$?
    # borg's own exit codes: 1 is a warning (e.g. a source file changed while
    # being read), not a failure — the archive is still written. Only 2+ is
    # a real error. Without this, `set -e` aborted the whole run (and the
    # systemd unit) on every warning, skipping prune/check/status.
    if (( rc > 1 )); then
        log_err "borg create failed (code ${rc})"
        exit "$rc"
    elif (( rc == 1 )); then
        log_warn "borg create finished with a warning (code 1) — a source file changed during backup; archive was still written"
    fi

    local name orig comp dedup nfiles
    name=$(jq -r '.archive.name'                          <<<"$out")
    orig=$(jq -r '.archive.stats.original_size'           <<<"$out")
    comp=$(jq -r '.archive.stats.compressed_size'         <<<"$out")
    dedup=$(jq -r '.archive.stats.deduplicated_size'      <<<"$out")
    nfiles=$(jq -r '.archive.stats.nfiles'                <<<"$out")

    log_info "Archive ${name}: ${nfiles} files, original $(human "$orig"), compressed $(human "$comp"), written to disk $(human "$dedup")"

    # Quick check of the archive just created.
    log_step "Quick integrity check"
    borg check --repository-only "$REPO"
    log_info "Check passed"

    echo "$name"
}

engine_prune() {
    local prefix keep_d keep_w keep_m
    log_step "Applying the retention policy"
    while IFS= read -r prefix; do
        keep_d=$(jq -r ".retention[\"${prefix}\"].keep_daily"   "$SETTINGS_FILE")
        keep_w=$(jq -r ".retention[\"${prefix}\"].keep_weekly"  "$SETTINGS_FILE")
        keep_m=$(jq -r ".retention[\"${prefix}\"].keep_monthly" "$SETTINGS_FILE")
        log_info "  ${prefix}-*: daily ${keep_d}, weekly ${keep_w}, monthly ${keep_m}"
        borg prune --glob-archives "${prefix}-*" \
            --keep-daily "$keep_d" --keep-weekly "$keep_w" --keep-monthly "$keep_m" \
            --stats "$REPO" 2>&1 | grep -E 'Deleted data|Pruning archive' || true
    done < <(jq -r '.retention | keys[]' "$SETTINGS_FILE")

    log_step "Compacting the repository"
    borg compact "$REPO"
}

engine_check() {
    local deep=${1:-}
    if [[ "$deep" == "--deep" ]]; then
        log_step "Full check, reading all data (this takes a while)"
        borg check --verify-data "$REPO"
    else
        log_step "Checking the repository and archives"
        borg check "$REPO"
    fi
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STATE_DIR}/last-check"
    log_info "Integrity check passed"
}

engine_last_archive() {
    local prefix=${1:-}
    if [[ -n "$prefix" ]]; then
        borg list --glob-archives "${prefix}-*" --last 1 --format '{archive}' "$REPO"
    else
        borg list --last 1 --format '{archive}' "$REPO"
    fi
}

STATUS_FILE="${STATE_DIR}/status.json"
ARCHIVES_FILE="${STATE_DIR}/archives.txt"

# A status snapshot for the bar and the menu. Mode 644 — there are no secrets
# inside, only archive names, sizes and dates. That is what lets HyprPanel and
# rofi read the status WITHOUT root, so merely displaying it needs no privileges.
write_status() {
    install -d -m 755 "$STATE_DIR"

    local list_json info_json last_name last_start arch_json
    list_json=$(borg list --json "$REPO" 2>/dev/null) || return 0
    info_json=$(borg info --json "$REPO" 2>/dev/null) || return 0

    # Archive list for the menu: name <TAB> ISO date. ISO rather than {time},
    # because {time} is locale-dependent and breaks parsing.
    jq -r '.archives[] | "\(.name)\t\(.start)"' <<<"$list_json" \
        | sort -k2 -r > "${ARCHIVES_FILE}.tmp"
    mv -f "${ARCHIVES_FILE}.tmp" "$ARCHIVES_FILE"
    chmod 644 "$ARCHIVES_FILE"

    last_name=$(jq -r '(.archives | sort_by(.start) | last).name // ""' <<<"$list_json")
    last_start=$(jq -r '(.archives | sort_by(.start) | last).start // ""' <<<"$list_json")

    local a_orig=0 a_dedup=0
    if [[ -n "$last_name" ]]; then
        arch_json=$(borg info --json "::${last_name}" 2>/dev/null || echo '{}')
        a_orig=$(jq -r '.archives[0].stats.original_size     // 0' <<<"$arch_json")
        a_dedup=$(jq -r '.archives[0].stats.deduplicated_size // 0' <<<"$arch_json")
    fi

    local repo_size count last_check last_drill
    repo_size=$(jq -r '.cache.stats.unique_csize // 0' <<<"$info_json")
    count=$(jq -r '.archives | length' <<<"$list_json")
    last_check=$(cat "${STATE_DIR}/last-check" 2>/dev/null || echo "")
    last_drill=$(cat "${STATE_DIR}/last-drill" 2>/dev/null || echo "")

    jq -n \
        --arg updated    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg archive    "$last_name" \
        --arg start      "$last_start" \
        --arg size       "$(human "$a_orig")" \
        --arg added      "$(human "$a_dedup")" \
        --arg repo       "$(human "$repo_size")" \
        --argjson count  "${count:-0}" \
        --arg checked    "$last_check" \
        --arg drilled    "$last_drill" \
        '{updated:$updated, archive:$archive, start:$start,
          size:$size, added:$added, repo:$repo, count:$count,
          checked:$checked, drilled:$drilled}' > "${STATUS_FILE}.tmp"
    mv -f "${STATUS_FILE}.tmp" "$STATUS_FILE"
    chmod 644 "$STATUS_FILE"
}
