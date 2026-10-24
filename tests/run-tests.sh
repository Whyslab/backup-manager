#!/usr/bin/env bash
# tests/run-tests.sh — the Backup Manager test suite.
#
# These tests never touch a real system: they do not install anything outside
# a temporary directory, never call borg against a real repository, and never
# need root. What they check is the part that can be checked safely — that the
# scripts parse, that the status module always emits valid JSON, that every
# menu entry dispatches, and that an install into a sandbox can be undone.
#
# Run: bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

ok()    { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
nok()   { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }
group() { printf '\n\033[0;34m==>\033[0m %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
group "Shell syntax"
# --------------------------------------------------------------------------
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"
    else nok "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1 | head -1)"; fi
done < <(find "$ROOT" \( -name '*.sh' -o -name bm \) -not -path '*/.git/*' | sort)

# --------------------------------------------------------------------------
group "Shipped JSON is valid"
# --------------------------------------------------------------------------
for f in "$ROOT"/config/*.json; do
    if jq empty "$f" 2>/dev/null; then ok "valid JSON: $(basename "$f")"
    else nok "invalid JSON: $(basename "$f")" "$(jq empty "$f" 2>&1 | head -1)"; fi
done

# Every source must declare a tier, and the tier must exist in .tiers.
src="$ROOT/config/sources.example.json"
bad=$(jq -r '[.sources[] | select((.tier|tostring) as $t | ($t != "1" and $t != "2"))] | length' "$src")
if [[ "$bad" == "0" ]]; then ok "every source declares tier 1 or 2"
else nok "sources with an unknown tier: $bad"; fi

# --------------------------------------------------------------------------
group "The installer substitutes every placeholder"
# --------------------------------------------------------------------------
# settings.example.json carries __USER__ / __HOME__ tokens. If install.sh stops
# substituting one, the installed config gets a literal __HOME__ path in it and
# borg fails at the first run with a confusing error. Catch it here instead.
tokens=$(grep -o '__[A-Z_]*__' "$ROOT/config/settings.example.json" | sort -u)
missing=""
while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    grep -q -- "$t" "$ROOT/install.sh" || missing+="$t "
done <<< "$tokens"
if [[ -z "$missing" ]]; then ok "install.sh substitutes: $(echo "$tokens" | tr '\n' ' ')"
else nok "install.sh does not substitute: $missing"; fi

# --------------------------------------------------------------------------
group "The status module always emits valid JSON"
# --------------------------------------------------------------------------
mod="$ROOT/ui/hyprpanel_module.sh"

# 1. No status file at all.
out=$(BM_STATUS_FILE="$TMP/does-not-exist.json" "$mod" 2>/dev/null)
if jq -e '.alt == "none"' <<<"$out" >/dev/null 2>&1; then ok "missing status file -> alt=none"
else nok "missing status file" "got: $out"; fi

# 2. A corrupt status file must not produce broken JSON on stdout.
echo 'this is not json {{{' > "$TMP/broken.json"
out=$(BM_STATUS_FILE="$TMP/broken.json" "$mod" 2>/dev/null)
if jq empty <<<"$out" 2>/dev/null; then ok "corrupt status file -> still valid JSON"
else nok "corrupt status file breaks the JSON output" "got: $out"; fi

# 3. A healthy, fresh status file.
jq -n --arg now "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --arg chk "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
   '{updated:$now, archive:"bm-t1-20260101_032000", start:$now,
     size:"1.5 GB", added:"4.3 MB", repo:"12.0 GB", count:11,
     checked:$chk, drilled:$chk}' > "$TMP/fresh.json"
out=$(BM_STATUS_FILE="$TMP/fresh.json" "$mod" 2>/dev/null)
if jq -e '.alt == "ok"' <<<"$out" >/dev/null 2>&1; then ok "fresh backup -> alt=ok"
else nok "fresh backup should report ok" "got: $out"; fi

# 4. A stale snapshot must raise a warning, not stay silent.
jq -n --arg old "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
   '{updated:$old, archive:"bm-t1-old", start:$old, size:"1 GB", added:"1 MB",
     repo:"1 GB", count:1, checked:$old, drilled:$old}' > "$TMP/stale.json"
out=$(BM_STATUS_FILE="$TMP/stale.json" "$mod" 2>/dev/null)
if jq -e '.alt == "warning"' <<<"$out" >/dev/null 2>&1; then ok "stale backup -> alt=warning"
else nok "stale backup should warn" "got: $out"; fi

# 5. Every emitted state carries the full set of fields the menu reads.
for f in "$TMP/fresh.json" "$TMP/stale.json" "$TMP/does-not-exist.json"; do
    out=$(BM_STATUS_FILE="$f" "$mod" 2>/dev/null)
    if jq -e 'has("state") and has("time") and has("ago") and has("size")
              and has("count") and has("checked") and has("drilled") and has("next")' \
          <<<"$out" >/dev/null 2>&1; then
        ok "all fields present ($(basename "$f"))"
    else
        nok "missing fields ($(basename "$f"))" "got: $out"
    fi
done

# --------------------------------------------------------------------------
group "A repository on another machine (ssh://)"
# --------------------------------------------------------------------------
# A remote repo must not be created or chmod-ed locally, and its "rsh" must
# reach borg as BORG_RSH. A local repo must keep working as before.
mkdir -p "$TMP/remote/config"
cp "$ROOT/config/sources.example.json" "$TMP/remote/config/sources.json"
jq '.target_user = "root" | .targets[0].repo = "ssh://bm@backup.example/srv/repo"
    | .targets[0].rsh = "ssh -i /root/.ssh/bm_key"' \
    "$ROOT/config/settings.example.json" > "$TMP/remote/config/settings.json"
out=$(BASE_DIR="$TMP/remote" bash -c "
    source '$ROOT/lib/core.sh'; source '$ROOT/lib/config.sh'; source '$ROOT/lib/engine.sh'
    config_load; engine_env
    engine_repo_remote && echo remote; echo \"rsh=\$BORG_RSH\"" 2>&1)
if grep -q '^remote$' <<<"$out" && grep -q '^rsh=ssh -i /root/.ssh/bm_key$' <<<"$out"; then
    ok "ssh:// repo is remote and its rsh becomes BORG_RSH"
else
    nok "ssh:// repo handling" "$(head -3 <<<"$out")"
fi
jq '.target_user = "root" | .targets[0].repo = "/var/backup/repo"' \
    "$ROOT/config/settings.example.json" > "$TMP/remote/config/settings.json"
out=$(BASE_DIR="$TMP/remote" bash -c "
    source '$ROOT/lib/core.sh'; source '$ROOT/lib/config.sh'; source '$ROOT/lib/engine.sh'
    config_load; engine_env
    engine_repo_remote && echo remote || echo local; echo \"rsh=\${BORG_RSH:-none}\"" 2>&1)
if grep -q '^local$' <<<"$out" && grep -q '^rsh=none$' <<<"$out"; then
    ok "a plain path stays local, BORG_RSH untouched"
else
    nok "local repo handling" "$(head -3 <<<"$out")"
fi

# --------------------------------------------------------------------------
group "Sizes are locale-independent"
# --------------------------------------------------------------------------
# Under a locale with a comma decimal separator numfmt produces "1,5 GB", which
# would end up in status.json and in notifications. Sizes must not depend on
# the system locale.
for loc in C ru_RU.UTF-8 de_DE.UTF-8; do
    out=$(LC_ALL="$loc" bash -c "source '$ROOT/lib/core.sh' 2>/dev/null; human 1610612736" 2>/dev/null)
    if [[ "$out" == "1.5 GB" ]]; then
        ok "human() under LC_ALL=${loc} -> ${out}"
    else
        nok "human() under LC_ALL=${loc}" "expected '1.5 GB', got '${out}'"
    fi
done

# --------------------------------------------------------------------------
group "Every menu entry dispatches to an action"
# --------------------------------------------------------------------------
# The menu stores entries as "key|label". If a label is reworded but the key is
# left dangling, the entry silently does nothing when clicked. Drive each label
# through the real dispatcher in test mode and require that no entry reports an
# unknown action.
menu="$ROOT/ui/rofi_menu.sh"

# Two separate properties are checked, because they can break independently:
#   1. every label still resolves back to its key (a reworded label that no
#      longer matches its entry resolves to nothing);
#   2. every key is handled by dispatch (a key with no case arm does nothing).
# "more" and "back" only switch menus, so they are checked for resolution
# alone — driving them through dispatch would re-enter show_menu with the same
# canned answer and fail for a reason that has nothing to do with the entry.
NAV_KEYS=" more back "
total_entries=0

for arr in MAIN MORE; do
    entries=$(BM_MENU_NO_MAIN=1 bash -c "source '$menu'; printf '%s\n' \"\${${arr}[@]}\"" 2>/dev/null)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        total_entries=$((total_entries+1))
        key="${entry%%|*}"; label="${entry#*|}"

        resolved=$(BM_MENU_TEST=1 BM_MENU_NO_MAIN=1 BM_TEST_CHOICE="$label" \
                   bash -c "source '$menu'; show_menu 'test' ${arr}" 2>/dev/null)
        if [[ "$resolved" != "$key" ]]; then
            nok "${arr}: label does not resolve to its key (${key})" "got: '${resolved}'"
            continue
        fi

        if [[ "$NAV_KEYS" == *" $key "* ]]; then
            ok "${arr}: ${key} resolves (navigation entry)"
            continue
        fi

        # BM_TEST_CONFIRM=1 makes confirm() answer "no", so a destructive entry
        # stops at the prompt instead of pretending to run.
        out=$(BM_MENU_TEST=1 BM_MENU_NO_MAIN=1 BM_TEST_CONFIRM=1 \
              bash -c "source '$menu'; dispatch '${key}'" 2>&1)
        if grep -q "Unknown action" <<<"$out"; then
            nok "${arr}: key not handled by dispatch: ${key}" "$(head -2 <<<"$out")"
        else
            ok "${arr}: ${key} dispatches"
        fi
    done <<< "$entries"
done

if (( total_entries >= 12 )); then ok "menu defines ${total_entries} entries"
else nok "expected at least 12 menu entries, found ${total_entries}"; fi

# --------------------------------------------------------------------------
group "bm runs without root and without a repository"
# --------------------------------------------------------------------------
for args in "" "--help" "help"; do
    # shellcheck disable=SC2086
    if out=$("$ROOT/bm" $args 2>&1) && grep -q "borg-based backup" <<<"$out"; then
        ok "bm ${args:-<no args>} prints usage"
    else
        nok "bm ${args:-<no args>} should print usage" "$(head -2 <<<"$out")"
    fi
done

if out=$("$ROOT/bm" nonsense-command 2>&1); then
    nok "an unknown command should exit non-zero"
else
    grep -q "Unknown command" <<<"$out" && ok "unknown command is rejected" \
        || nok "unknown command gives no clear message" "$(head -2 <<<"$out")"
fi

# --------------------------------------------------------------------------
group "Sandbox install and uninstall leave nothing behind"
# --------------------------------------------------------------------------
SB="$TMP/sandbox"
if "$ROOT/install.sh" --prefix "$SB" --user "$(id -un)" >/dev/null 2>&1; then
    ok "install.sh --prefix succeeds"
else
    nok "install.sh --prefix failed" "$("$ROOT/install.sh" --prefix "$SB" --user "$(id -un)" 2>&1 | tail -3)"
fi

for p in opt/backup-manager/bm usr/local/bin/bm etc/systemd/system/bm-backup.timer \
         opt/backup-manager/config/settings.json etc/logrotate.d/backup-manager; do
    [[ -e "$SB/$p" ]] && ok "installed: /$p" || nok "not installed: /$p"
done

# A symlink whose target does not exist inside the sandbox would still pass an
# -e check on a machine that happens to have a real install at the same path.
for l in usr/local/bin/bm usr/local/bin/backup-manager; do
    target=$(readlink -f "$SB/$l" 2>/dev/null || echo "")
    if [[ "$target" == "$SB"/* && -e "$target" ]]; then
        ok "symlink /$l resolves inside the sandbox"
    else
        nok "symlink /$l points outside the sandbox" "target: ${target:-<dangling>}"
    fi
done

# The generated settings must carry no leftover placeholders.
if grep -q '__[A-Z_]*__' "$SB/opt/backup-manager/config/settings.json" 2>/dev/null; then
    nok "settings.json still contains placeholders" "$(grep -o '__[A-Z_]*__' "$SB/opt/backup-manager/config/settings.json" | sort -u | tr '\n' ' ')"
else
    ok "settings.json has every placeholder substituted"
fi

if "$ROOT/uninstall.sh" --prefix "$SB" --purge >/dev/null 2>&1; then
    left=$(find "$SB" -type f -o -type l 2>/dev/null | wc -l)
    if (( left == 0 )); then ok "uninstall.sh --purge removes everything"
    else nok "uninstall left ${left} files behind" "$(find "$SB" -type f -o -type l | head -3)"; fi
else
    nok "uninstall.sh --prefix failed"
fi

# --------------------------------------------------------------------------
group "Nothing personal shipped"
# --------------------------------------------------------------------------
# This repository was extracted from a working system. Anything that identifies
# the machine it came from is a bug, not a detail.
# run-tests.sh and ci.yml both spell out the patterns they search for, so they
# would match themselves; everything else is fair game.
if hits=$(grep -rniE 'bogdan|dodg1403' "$ROOT" --exclude-dir=.git \
              --exclude='run-tests.sh' --exclude='ci.yml' 2>/dev/null); then
    nok "personal identifiers found" "$(head -3 <<<"$hits")"
else
    ok "no personal identifiers"
fi

# README.md is allowed exactly one Cyrillic line: the link to the translation.
if hits=$(grep -rlIP '[\x{0400}-\x{04FF}]' "$ROOT" --exclude-dir=.git \
              --exclude='*.ru.md' --exclude='README.md' 2>/dev/null); then
    nok "non-English text outside README.ru.md" "$(head -3 <<<"$hits")"
else
    ok "user-facing text is English (README.ru.md aside)"
fi

stray=$(grep -nP '[\x{0400}-\x{04FF}]' "$ROOT/README.md" 2>/dev/null | grep -v 'README\.ru\.md' || true)
if [[ -z "$stray" ]]; then
    ok "README.md is English apart from the translation link"
else
    nok "untranslated text in README.md" "$(head -2 <<<"$stray")"
fi

# --------------------------------------------------------------------------
printf '\n\033[0;34m==>\033[0m Result: \033[0;32m%d passed\033[0m, ' "$PASS"
if (( FAIL )); then printf '\033[0;31m%d failed\033[0m\n\n' "$FAIL"; exit 1
else printf '0 failed\n\n'; exit 0; fi
