#!/bin/bash
set -euo pipefail

# Reverse install.sh for Headless Sway + Sunshine.
# Stops the stack and removes files this project installed. Does not uninstall
# packages (sway, Sunshine, etc.) — those may be in use independently.

# ---------- Constants ----------
SWAY_CONFIG_DIR="$HOME/.config/sway-sunshine"
SUNSHINE_CONFIG_DIR="$HOME/.config/sunshine"
SYSTEMD_DIR="$HOME/.config/systemd/user"
DROPIN_DIR="$SYSTEMD_DIR/sway-sunshine.service.d"
KCMINPUTRC="$HOME/.config/kcminputrc"
PIPEWIRE_SINK="$HOME/.config/pipewire/pipewire.conf.d/sunshine-null-sink.conf"
PIPEWIRE_PIN="$HOME/.config/pipewire/pipewire-pulse.conf.d/50-sunshine-capture-pin.conf"
LEGACY_UDEV=/etc/udev/rules.d/85-sunshine-input-isolation.rules

SUNSHINE_VENDOR_DEC=48879
SUNSHINE_PRODUCT_DEC=57005

USER_ID=$(id -u)
SOCKET_PATH="/run/user/$USER_ID/sway-sunshine.sock"
DISPLAY_FILE="/run/user/$USER_ID/sway-sunshine.display"

ASSUME_YES=0
PURGE_SUNSHINE_CONFIG=0

# ---------- Logging helpers ----------
log_info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[31m[XX]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [options]

Stop and disable the headless Sway + Sunshine services, then remove the
config and unit files installed by install.sh.

Options:
  -y, --yes                   Skip the confirmation prompt
  --purge-sunshine-config      Also strip headless keys from sunshine.conf
                              and back up apps.json if it references this stack
  -h, --help                  Show this help

Not removed (may still be in use):
  sway, swaybg, xdg-desktop-portal-wlr, Sunshine packages/binaries
  ~/.config/sunshine credentials, logs, and pairing data
EOF
}

# ---------- Args ----------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --purge-sunshine-config) PURGE_SUNSHINE_CONFIG=1 ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

confirm() {
    if (( ASSUME_YES )); then
        return 0
    fi
    echo "This will stop the streaming stack and remove:"
    echo "  $SWAY_CONFIG_DIR"
    echo "  $SYSTEMD_DIR/sway-sunshine.service"
    echo "  $SYSTEMD_DIR/sunshine-headless.service"
    echo "  $DROPIN_DIR/10-nvidia.conf (if present)"
    echo "  $PIPEWIRE_SINK"
    echo "  $PIPEWIRE_PIN"
    echo "  Sunshine virtual-input entries in $KCMINPUTRC (if present)"
    if (( PURGE_SUNSHINE_CONFIG )); then
        echo "  Headless keys in $SUNSHINE_CONFIG_DIR/sunshine.conf"
        echo "  Backup of apps.json if it references sway-sunshine"
    else
        echo
        echo "Sunshine's own config at $SUNSHINE_CONFIG_DIR will be left in place."
    fi
    echo
    read -rp "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- Services ----------
stop_and_disable_services() {
    local unit
    for unit in sunshine-headless.service sway-sunshine.service; do
        if systemctl --user --quiet is-active "$unit" 2>/dev/null; then
            log_info "Stopping $unit"
            systemctl --user stop "$unit" || log_warn "Failed to stop $unit"
        fi
        if systemctl --user --quiet is-enabled "$unit" 2>/dev/null; then
            log_info "Disabling $unit"
            systemctl --user disable "$unit" >/dev/null || log_warn "Failed to disable $unit"
        fi
    done
}

remove_systemd_units() {
    rm -f "$SYSTEMD_DIR/sway-sunshine.service"
    rm -f "$SYSTEMD_DIR/sunshine-headless.service"
    rm -f "$DROPIN_DIR/10-nvidia.conf"
    rmdir --ignore-fail-on-non-empty "$DROPIN_DIR" 2>/dev/null || true
    systemctl --user daemon-reload
    log_ok "Removed systemd units and reloaded user daemon"
}

# ---------- Files ----------
remove_sway_configs() {
    if [[ -d "$SWAY_CONFIG_DIR" ]]; then
        rm -rf "$SWAY_CONFIG_DIR"
        log_ok "Removed $SWAY_CONFIG_DIR"
    else
        log_info "No $SWAY_CONFIG_DIR to remove"
    fi
}

remove_pipewire_dropins() {
    local removed=0
    if [[ -f "$PIPEWIRE_SINK" ]]; then
        rm -f "$PIPEWIRE_SINK"
        log_ok "Removed PipeWire null-sink drop-in"
        removed=1
    fi
    if [[ -f "$PIPEWIRE_PIN" ]]; then
        rm -f "$PIPEWIRE_PIN"
        log_ok "Removed Sunshine capture pin rule"
        removed=1
    fi
    if (( removed )); then
        systemctl --user restart pipewire.service pipewire-pulse.service 2>/dev/null || true
        log_ok "Restarted PipeWire to drop the virtual sink"
    else
        log_info "No PipeWire drop-ins from this project found"
    fi
}

remove_runtime_files() {
    rm -f "$SOCKET_PATH" "$DISPLAY_FILE"
}

# Remove a full INI section whose header matches exactly, plus its body until
# the next section. Used for the kcminputrc isolation entries install.sh adds.
remove_kcm_section() {
    local section="$1"
    local file="$2"
    local tmp
    tmp=$(mktemp)
    awk -v target="[$section]" '
        BEGIN { skip=0 }
        /^\[/ { skip = ($0 == target) }
        { if (!skip) print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

remove_input_isolation() {
    [[ -f "$KCMINPUTRC" ]] || return 0

    local s
    for s in \
        "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Keyboard passthrough" \
        "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Mouse passthrough" \
        "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Mouse passthrough (absolute)" \
        "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Touch passthrough" \
        "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Pen passthrough" \
        "Libinput][1356][3302][Sunshine PS5 (virtual) pad Touchpad"
    do
        if grep -Fxq "[$s]" "$KCMINPUTRC"; then
            remove_kcm_section "$s" "$KCMINPUTRC"
        fi
    done
    log_ok "Removed Sunshine virtual-input isolation from kcminputrc (if present)"
}

remove_legacy_udev() {
    [[ -f "$LEGACY_UDEV" ]] || return 0
    log_info "Removing leftover udev rule at $LEGACY_UDEV"
    sudo rm -f "$LEGACY_UDEV"
    sudo udevadm control --reload-rules
    log_ok "Removed leftover udev rule"
}

# ---------- Optional Sunshine config ----------
purge_sunshine_config() {
    local conf="$SUNSHINE_CONFIG_DIR/sunshine.conf"
    local apps="$SUNSHINE_CONFIG_DIR/apps.json"

    if [[ -f "$conf" ]]; then
        local bak="${conf}.headless-uninstalled.$(date +%Y%m%d%H%M%S)"
        cp "$conf" "$bak"
        # Drop keys this installer writes. Leave everything else (credentials live elsewhere).
        sed -i \
            -e '/^audio_sink[[:space:]]*=/d' \
            -e '/^capture[[:space:]]*=/d' \
            -e '/^encoder[[:space:]]*=/d' \
            -e '/^adapter_name[[:space:]]*=/d' \
            "$conf"
        log_ok "Stripped headless keys from sunshine.conf (backup: $bak)"
    fi

    if [[ -f "$apps" ]] && grep -q 'sway-sunshine' "$apps"; then
        local bak="${apps}.headless-uninstalled.$(date +%Y%m%d%H%M%S)"
        mv "$apps" "$bak"
        log_ok "Moved apps.json aside (referenced sway-sunshine scripts): $bak"
        log_info "Sunshine will recreate a default apps.json on next start if needed."
    fi
}

# ---------- Summary ----------
print_summary() {
    echo
    echo "=== Uninstall complete ==="
    echo
    echo "Removed the headless Sway session, systemd units, PipeWire sink,"
    echo "and KDE input-isolation entries written by install.sh."
    echo
    echo "Left in place:"
    echo "  Packages: sway, swaybg, xdg-desktop-portal-wlr, Sunshine"
    if (( ! PURGE_SUNSHINE_CONFIG )); then
        echo "  $SUNSHINE_CONFIG_DIR  (pairing, apps, logs)"
        echo
        echo "To also strip headless keys from sunshine.conf:"
        echo "  $0 --purge-sunshine-config"
    fi
    echo
    echo "If you no longer need the compositor packages:"
    echo "  sudo pacman -Rs sway swaybg xdg-desktop-portal-wlr"
    echo "  # or: sudo apt remove sway swaybg xdg-desktop-portal-wlr"
    echo
}

# ---------- Main ----------
main() {
    parse_args "$@"

    echo "=== Headless Sway + Sunshine Uninstaller ==="
    echo

    if ! confirm; then
        log_info "Aborted."
        exit 0
    fi

    echo
    stop_and_disable_services
    remove_systemd_units
    remove_sway_configs
    remove_pipewire_dropins
    remove_runtime_files
    remove_input_isolation
    remove_legacy_udev

    if (( PURGE_SUNSHINE_CONFIG )); then
        purge_sunshine_config
    fi

    print_summary
}

main "$@"
