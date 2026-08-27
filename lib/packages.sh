#!/usr/bin/env bash
# lib/packages.sh — lists of what is installed, so the system can be rebuilt.

export_packages() {
    local dest_dir=$1
    log_step "Exporting package lists"

    pacman -Qqen > "${dest_dir}/pacman.txt"       2>/dev/null || true
    pacman -Qqem > "${dest_dir}/aur.txt"          2>/dev/null || true
    pacman -Qqet > "${dest_dir}/explicit.txt"     2>/dev/null || true

    if command -v flatpak >/dev/null 2>&1; then
        flatpak list --app --columns=application > "${dest_dir}/flatpak.txt" 2>/dev/null || true
    fi

    # pip/npm/cargo run as the user: root's global environments have nothing
    # to do with the user's.
    if command -v npm >/dev/null 2>&1; then
        runuser -u "$REAL_USER" -- npm list -g --depth=0 \
            > "${dest_dir}/npm_global.txt" 2>/dev/null || true
    fi
    if command -v cargo >/dev/null 2>&1; then
        runuser -u "$REAL_USER" -- cargo install --list \
            > "${dest_dir}/cargo.txt" 2>/dev/null || true
    fi
    if command -v pipx >/dev/null 2>&1; then
        runuser -u "$REAL_USER" -- pipx list --short \
            > "${dest_dir}/pipx.txt" 2>/dev/null || true
    fi

    # Enabled units — without them a package list is useless when restoring.
    systemctl list-unit-files --state=enabled --no-legend --no-pager \
        > "${dest_dir}/systemd_system_enabled.txt" 2>/dev/null || true
    runuser -u "$REAL_USER" -- systemctl --user list-unit-files --state=enabled --no-legend --no-pager \
        > "${dest_dir}/systemd_user_enabled.txt" 2>/dev/null || true
}
