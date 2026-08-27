#!/usr/bin/env bash
# lib/manifest.sh — a passport of the system at snapshot time.

generate_manifest() {
    local dest_file=$1
    local os_version kernel_version hypr_version file_system uuid

    os_version=$(grep -oP '(?<=^PRETTY_NAME=").*(?="$)' /etc/os-release || echo unknown)
    kernel_version=$(uname -r)
    # hyprctl cannot see the instance from systemd — read the version from the package.
    hypr_version=$(pacman -Q hyprland 2>/dev/null | awk '{print $2}' || echo "not installed")
    file_system=$(df -T "$REPO" | awk 'NR==2 {print $2}')
    uuid=$(lsblk -no UUID "$(df --output=source "$REPO" | tail -1)" 2>/dev/null | head -1 || echo unknown)

    jq -n \
        --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg os "$os_version" \
        --arg kernel "$kernel_version" \
        --arg hypr "$hypr_version" \
        --arg user "$REAL_USER" \
        --arg host "$HOSTNAME" \
        --arg fs "$file_system" \
        --arg uuid "$uuid" \
        '{timestamp:$date, os:$os, kernel:$kernel, hyprland:$hypr,
          user:$user, hostname:$host, filesystem:$fs, fs_uuid:$uuid}' \
        > "$dest_file"
}
