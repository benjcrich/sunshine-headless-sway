#!/bin/bash
set -euo pipefail

# Headless Sway + Sunshine Game Streaming Setup
# https://github.com/daaaaan/sunshine-headless-sway
#
# Re-run with --check to re-verify a previous install without making changes.

# ---------- Constants ----------
SWAY_CONFIG_DIR="$HOME/.config/sway-sunshine"
SUNSHINE_CONFIG_DIR="$HOME/.config/sunshine"
SYSTEMD_DIR="$HOME/.config/systemd/user"
DROPIN_DIR="$SYSTEMD_DIR/sway-sunshine.service.d"
KCMINPUTRC="$HOME/.config/kcminputrc"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Sunshine virtual input device IDs (vendor 0xBEEF, product 0xDEAD as decimals)
SUNSHINE_VENDOR_DEC=48879
SUNSHINE_PRODUCT_DEC=57005

# Minimum Sunshine release year (calver YYYY.MMDD.HHMMSS).
# v2026.x has the rewritten Wayland NVENC capture path.
MIN_SUNSHINE_YEAR=2026

# AUR package preferred on Arch (tracks upstream master).
SUNSHINE_AUR_PACKAGE="sunshine-git"

# Fallback for hosts without an AUR helper: pinned upstream prebuilt.
SUNSHINE_PKG_VERSION="2026.428.130031"
SUNSHINE_PKG_URL="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_PKG_VERSION}/sunshine-${SUNSHINE_PKG_VERSION}-1-x86_64.pkg.tar.zst"

# ---------- Globals (set by detection functions) ----------
IS_ARCH=0
AUR_HELPER=""
DETECTED_DE="unknown"
HAS_NVIDIA=0
HAS_AMD=0
HAS_INTEL=0
NVIDIA_RENDER_NODE=""
GPU_COUNT=0
SUNSHINE_PATH=""
SUNSHINE_UPGRADED=0
SUNSHINE_USED_PREBUILT=0   # set to 1 only when fallback prebuilt was used
USER_ID=$(id -u)
SOCKET_PATH="/run/user/$USER_ID/sway-sunshine.sock"
MAIN_WAYLAND=""
HEADLESS_DISPLAY=""

# ---------- Logging helpers ----------
log_info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
log_ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[31m[XX]\033[0m %s\n' "$*" >&2; }
have()     { command -v "$1" &>/dev/null; }

# ---------- Detection ----------
detect_distro() {
    if have pacman; then
        IS_ARCH=1
        log_ok "Arch-family distro detected (pacman)"
        detect_aur_helper
    elif have apt; then
        IS_ARCH=0
        log_ok "Debian-family distro detected (apt)"
    else
        log_err "No supported package manager (need pacman or apt)"
        exit 1
    fi
}

detect_aur_helper() {
    local h
    for h in paru yay pikaur trizen aurutils; do
        if have "$h"; then
            AUR_HELPER="$h"
            log_ok "AUR helper found: $h"
            return 0
        fi
    done
    log_info "No AUR helper detected (paru/yay/pikaur). Will fall back to upstream pkg.tar.zst if Sunshine needs upgrading."
    return 1
}

detect_desktop() {
    local de="${XDG_CURRENT_DESKTOP:-}"
    de="${de,,}"

    if [[ "$de" == *"gnome"* ]] || [[ "$de" == *"unity"* ]] || [[ "$de" == *"budgie"* ]]; then
        DETECTED_DE="gnome"
    elif [[ "$de" == *"kde"* ]] || [[ "$de" == *"plasma"* ]]; then
        DETECTED_DE="kde"
    elif have mutter; then
        DETECTED_DE="gnome"
    elif have kwin_wayland || have kwin_x11; then
        DETECTED_DE="kde"
    fi

    if [[ "$DETECTED_DE" == "unknown" ]]; then
        log_warn "Could not auto-detect desktop environment."
        echo "  1) GNOME"
        echo "  2) KDE Plasma"
        echo "  3) Other / skip input isolation"
        read -rp "Select [1/2/3]: " choice
        case "$choice" in
            1) DETECTED_DE="gnome" ;;
            2) DETECTED_DE="kde"   ;;
            *) DETECTED_DE="other" ;;
        esac
    fi
    log_ok "Desktop environment: $DETECTED_DE"
}

detect_gpus() {
    HAS_NVIDIA=0; HAS_AMD=0; HAS_INTEL=0
    NVIDIA_RENDER_NODE=""
    local node card vendor

    for node in /dev/dri/renderD*; do
        [[ -e "$node" ]] || continue
        card=$(basename "$node")
        vendor=$(cat "/sys/class/drm/$card/device/vendor" 2>/dev/null || true)
        case "$vendor" in
            0x10de)
                HAS_NVIDIA=1
                NVIDIA_RENDER_NODE="$node"
                log_ok "NVIDIA GPU at $node"
                ;;
            0x1002)
                HAS_AMD=1
                log_ok "AMD GPU at $node"
                ;;
            0x8086)
                HAS_INTEL=1
                log_ok "Intel GPU at $node"
                ;;
            *)
                log_info "Unknown GPU vendor $vendor at $node"
                ;;
        esac
    done

    GPU_COUNT=$((HAS_NVIDIA + HAS_AMD + HAS_INTEL))
    if (( GPU_COUNT == 0 )); then
        log_warn "No GPU render nodes found. Streaming will fall back to software encode."
    elif (( GPU_COUNT > 1 )); then
        log_info "Multi-GPU system detected (count=$GPU_COUNT)"
    fi

    # Sanity check NVIDIA driver health if NVIDIA was detected
    if (( HAS_NVIDIA )); then
        if ! have nvidia-smi; then
            log_warn "nvidia-smi not found — NVIDIA proprietary driver may not be installed."
            log_warn "  NVENC requires the proprietary driver, not nouveau."
            HAS_NVIDIA=0
            NVIDIA_RENDER_NODE=""
        elif ! nvidia-smi -L &>/dev/null; then
            log_warn "nvidia-smi present but driver not responding. Will skip NVENC config."
            HAS_NVIDIA=0
            NVIDIA_RENDER_NODE=""
        else
            log_ok "NVIDIA proprietary driver healthy"
        fi
    fi
}

detect_wayland_displays() {
    MAIN_WAYLAND=$(ls /run/user/$USER_ID/wayland-* 2>/dev/null | grep -v lock | sort | tail -1 | xargs -r basename || true)
    if [[ -z "$MAIN_WAYLAND" ]]; then
        HEADLESS_DISPLAY="wayland-1"
        log_info "No active Wayland display detected; assuming headless display = wayland-1"
    elif [[ "$MAIN_WAYLAND" == "wayland-0" ]]; then
        HEADLESS_DISPLAY="wayland-1"
    else
        HEADLESS_DISPLAY="wayland-$((${MAIN_WAYLAND##wayland-} + 1))"
    fi
    log_ok "Main display: ${MAIN_WAYLAND:-none}, headless will be: $HEADLESS_DISPLAY"
}

# ---------- Sunshine handling ----------
sunshine_year() {
    # Returns just the year (e.g. "2026") from `sunshine --version`
    # output like "Sunshine version: 2026.428.130031 commit: ...".
    local v
    v=$("$SUNSHINE_PATH" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1) || return 1
    [[ -n "$v" ]] || return 1
    echo "${v%%.*}"
}

upgrade_sunshine_arch() {
    if [[ -n "$AUR_HELPER" ]]; then
        upgrade_sunshine_aur
    else
        log_warn "No AUR helper available — falling back to upstream prebuilt package."
        upgrade_sunshine_prebuilt
    fi
}

upgrade_sunshine_aur() {
    log_info "Building $SUNSHINE_AUR_PACKAGE from AUR via $AUR_HELPER..."
    log_info "  This may take 5-10 minutes (compiles from upstream master)."
    log_info "  $AUR_HELPER will prompt you for sudo and may ask to replace the existing 'sunshine' package — that's expected."
    if ! "$AUR_HELPER" -S "$SUNSHINE_AUR_PACKAGE"; then
        log_err "AUR build failed. You can fall back to the upstream prebuilt with:"
        log_err "    curl -fLO $SUNSHINE_PKG_URL && sudo pacman -U $(basename "$SUNSHINE_PKG_URL")"
        return 1
    fi
    log_ok "Installed $SUNSHINE_AUR_PACKAGE"
    SUNSHINE_UPGRADED=1
}

upgrade_sunshine_prebuilt() {
    local pkg=/tmp/sunshine-upstream.pkg.tar.zst
    log_info "Downloading $SUNSHINE_PKG_URL"
    if ! curl -fL --progress-bar -o "$pkg" "$SUNSHINE_PKG_URL"; then
        log_err "Download failed."
        return 1
    fi
    log_info "Installing via pacman -U (you'll be prompted for sudo)..."
    sudo pacman -U --noconfirm "$pkg"
    log_ok "Upgraded Sunshine to v$SUNSHINE_PKG_VERSION"
    SUNSHINE_UPGRADED=1
    SUNSHINE_USED_PREBUILT=1
    rm -f "$pkg"
}

ensure_sunshine() {
    if have sunshine; then
        SUNSHINE_PATH="$(command -v sunshine)"
    elif [[ -f "$HOME/Apps/sunshine.AppImage" ]]; then
        SUNSHINE_PATH="$HOME/Apps/sunshine.AppImage"
    else
        log_warn "Sunshine not found."
        echo "  Install from: https://github.com/LizardByte/Sunshine/releases"
        read -rp "Path to your Sunshine binary/AppImage: " SUNSHINE_PATH
        if [[ ! -f "$SUNSHINE_PATH" ]]; then
            log_err "$SUNSHINE_PATH not found"
            exit 1
        fi
    fi
    log_ok "Using Sunshine at: $SUNSHINE_PATH"

    local year
    if ! year=$(sunshine_year); then
        log_err "Could not parse 'sunshine --version' output."
        log_err "Make sure '$SUNSHINE_PATH --version' runs."
        exit 1
    fi

    if (( year < MIN_SUNSHINE_YEAR )); then
        log_warn "Sunshine version is older than v${MIN_SUNSHINE_YEAR}.x (detected year $year)."
        log_warn "  v2026.x has the rewritten Wayland NVENC capture path."
        log_warn "  Older versions throw GL_INVALID_OPERATION every frame on NVIDIA."
        if (( IS_ARCH )); then
            local prompt
            if [[ -n "$AUR_HELPER" ]]; then
                prompt="Build $SUNSHINE_AUR_PACKAGE from AUR via $AUR_HELPER now? [Y/n] "
            else
                prompt="Download & install upstream sunshine $SUNSHINE_PKG_VERSION now? [y/N] "
            fi
            read -rp "$prompt" ans
            local default_yes=0
            [[ -n "$AUR_HELPER" ]] && default_yes=1
            if (( default_yes )) && [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] || [[ "$ans" =~ ^[Yy]$ ]]; then
                upgrade_sunshine_arch || exit 1
                # Re-resolve in case path moved
                SUNSHINE_PATH="$(command -v sunshine)"
                year=$(sunshine_year) || true
            else
                log_err "Refusing to proceed with an outdated Sunshine."
                exit 1
            fi
        else
            log_err "On Debian/Ubuntu, install the v2026.x .deb from upstream releases first."
            exit 1
        fi
    fi
    log_ok "Sunshine version OK (year=$year)"
}

# ---------- Dependency install ----------
install_pkg() {
    if (( IS_ARCH )); then
        sudo pacman -S --needed --noconfirm "$@"
    else
        sudo apt install -y "$@"
    fi
}

is_pkg_installed() {
    if (( IS_ARCH )); then
        pacman -Qi "$1" &>/dev/null
    else
        dpkg -s "$1" &>/dev/null 2>&1
    fi
}

install_deps() {
    local missing=()
    have sway   || missing+=(sway)
    have swaybg || missing+=(swaybg)
    if ((${#missing[@]} > 0)); then
        log_info "Installing: ${missing[*]}"
        install_pkg "${missing[@]}"
    fi
    if ! is_pkg_installed xdg-desktop-portal-wlr; then
        log_info "Installing xdg-desktop-portal-wlr"
        install_pkg xdg-desktop-portal-wlr
    fi
}

# ---------- File install ----------
install_sway_configs() {
    mkdir -p "$SWAY_CONFIG_DIR"
    cp "$SCRIPT_DIR/sway-sunshine/config" "$SWAY_CONFIG_DIR/config"
    sed "s|/run/user/1000/|/run/user/$USER_ID/|g" \
        "$SCRIPT_DIR/sway-sunshine/set-resolution.sh" > "$SWAY_CONFIG_DIR/set-resolution.sh"
    sed "s|/run/user/1000/|/run/user/$USER_ID/|g" \
        "$SCRIPT_DIR/sway-sunshine/reset-resolution.sh" > "$SWAY_CONFIG_DIR/reset-resolution.sh"
    cp "$SCRIPT_DIR/sway-sunshine/restore-default-sink.sh" "$SWAY_CONFIG_DIR/restore-default-sink.sh"
    cp "$SCRIPT_DIR/sway-sunshine/start-steam-game.sh"      "$SWAY_CONFIG_DIR/start-steam-game.sh"
    cp "$SCRIPT_DIR/sway-sunshine/stop-steam-game.sh"       "$SWAY_CONFIG_DIR/stop-steam-game.sh" 2>/dev/null || true
    chmod +x "$SWAY_CONFIG_DIR"/*.sh
    log_ok "Sway configs installed in $SWAY_CONFIG_DIR"
}

install_sunshine_conf() {
    mkdir -p "$SUNSHINE_CONFIG_DIR"
    if [[ ! -f "$SUNSHINE_CONFIG_DIR/sunshine.conf" ]]; then
        cp "$SCRIPT_DIR/sunshine/sunshine.conf" "$SUNSHINE_CONFIG_DIR/sunshine.conf"
        log_ok "Created sunshine.conf"
    else
        # Migrate old 'sink' option if present
        if grep -q "^sink " "$SUNSHINE_CONFIG_DIR/sunshine.conf" && ! grep -q "^audio_sink" "$SUNSHINE_CONFIG_DIR/sunshine.conf"; then
            sed -i 's/^sink = /audio_sink = /' "$SUNSHINE_CONFIG_DIR/sunshine.conf"
            log_ok "Migrated 'sink' to 'audio_sink' in existing sunshine.conf"
        fi
        grep -q "^audio_sink" "$SUNSHINE_CONFIG_DIR/sunshine.conf" \
            || echo "audio_sink = sink-sunshine-stereo" >> "$SUNSHINE_CONFIG_DIR/sunshine.conf"
        grep -q "^capture"    "$SUNSHINE_CONFIG_DIR/sunshine.conf" \
            || echo "capture = wlr"                     >> "$SUNSHINE_CONFIG_DIR/sunshine.conf"
        log_info "sunshine.conf already exists — only filled in missing required keys"
    fi

    if (( HAS_NVIDIA )); then
        if ! grep -q "^encoder" "$SUNSHINE_CONFIG_DIR/sunshine.conf"; then
            echo "encoder = nvenc" >> "$SUNSHINE_CONFIG_DIR/sunshine.conf"
            log_ok "Set encoder = nvenc in sunshine.conf"
        else
            log_info "encoder line already in sunshine.conf — leaving user's value"
        fi
        if ! grep -q "^adapter_name" "$SUNSHINE_CONFIG_DIR/sunshine.conf"; then
            echo "adapter_name = $NVIDIA_RENDER_NODE" >> "$SUNSHINE_CONFIG_DIR/sunshine.conf"
            log_ok "Set adapter_name = $NVIDIA_RENDER_NODE in sunshine.conf"
        else
            log_info "adapter_name line already in sunshine.conf — leaving user's value"
        fi
    fi
}

install_apps_json() {
    if [[ ! -f "$SUNSHINE_CONFIG_DIR/apps.json" ]]; then
        sed "s|/home/YOUR_USER/|$HOME/|g" \
            "$SCRIPT_DIR/sunshine/apps.json" > "$SUNSHINE_CONFIG_DIR/apps.json"
        log_ok "Created apps.json"
    else
        log_info "apps.json already exists, skipping"
    fi
}

install_systemd_units() {
    mkdir -p "$SYSTEMD_DIR"
    sed -e "s|/run/user/1000/|/run/user/$USER_ID/|g" \
        "$SCRIPT_DIR/systemd/sway-sunshine.service" > "$SYSTEMD_DIR/sway-sunshine.service"
    sed -e "s|WAYLAND_DISPLAY=wayland-1|WAYLAND_DISPLAY=$HEADLESS_DISPLAY|g" \
        -e "s|/run/user/1000/|/run/user/$USER_ID/|g" \
        -e "s|ExecStart=.*|ExecStart=$SUNSHINE_PATH|g" \
        "$SCRIPT_DIR/systemd/sunshine-headless.service" > "$SYSTEMD_DIR/sunshine-headless.service"
    log_ok "Installed systemd unit files"
}

install_nvidia_dropin() {
    if (( ! HAS_NVIDIA )); then
        # Clean up an old drop-in if the user moved away from NVIDIA
        if [[ -f "$DROPIN_DIR/10-nvidia.conf" ]]; then
            rm -f "$DROPIN_DIR/10-nvidia.conf"
            rmdir --ignore-fail-on-non-empty "$DROPIN_DIR" 2>/dev/null || true
            log_info "Removed stale 10-nvidia.conf drop-in"
        fi
        return
    fi
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN_DIR/10-nvidia.conf" <<EOF
# Auto-generated by install.sh — NVIDIA-specific environment for headless Sway.
# Pins wlroots to NVIDIA's render node and forces linear DMA-BUFs that
# NVIDIA EGL can import (NVIDIA rejects most explicit modifiers, which
# would otherwise produce EGL_BAD_MATCH on every frame capture).
[Service]
Environment=WLR_RENDER_DRM_DEVICE=$NVIDIA_RENDER_NODE
Environment=WLR_DRM_NO_MODIFIERS=1
EOF
    log_ok "Installed NVIDIA systemd drop-in at $DROPIN_DIR/10-nvidia.conf"
}

install_pipewire_sink() {
    local pipewire_dir="$HOME/.config/pipewire/pipewire.conf.d"
    mkdir -p "$pipewire_dir"
    cp "$SCRIPT_DIR/pipewire/sunshine-null-sink.conf" "$pipewire_dir/sunshine-null-sink.conf"
    log_ok "Installed PipeWire persistent audio sink"
}

# ---------- Input isolation ----------
ensure_kcm_disabled() {
    # Idempotently add an [Enabled=false] kcminputrc section.
    # $1 is the section header content WITHOUT outer brackets,
    # e.g. "Libinput][48879][57005][Mouse passthrough"
    local section="$1"
    if grep -Fxq "[$section]" "$KCMINPUTRC" 2>/dev/null; then
        log_info "kcminputrc already has [$section] — leaving as-is"
        return
    fi
    {
        echo
        echo "[$section]"
        echo "Enabled=false"
    } >> "$KCMINPUTRC"
    log_ok "Disabled [$section] in kcminputrc"
}

install_input_isolation() {
    case "$DETECTED_DE" in
        kde)
            mkdir -p "$(dirname "$KCMINPUTRC")"
            touch "$KCMINPUTRC"
            for s in \
                "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Keyboard passthrough" \
                "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Mouse passthrough" \
                "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Mouse passthrough (absolute)" \
                "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Touch passthrough" \
                "Libinput][${SUNSHINE_VENDOR_DEC}][${SUNSHINE_PRODUCT_DEC}][Pen passthrough" \
                "Libinput][1356][3302][Sunshine PS5 (virtual) pad Touchpad"
            do
                ensure_kcm_disabled "$s"
            done
            log_info "KWin will pick up these changes when each device next (re)attaches."
            log_info "  Quickest: reboot, or disconnect+reconnect Moonlight after sunshine restarts."
            ;;
        gnome)
            log_warn "GNOME input isolation is currently UNSOLVED in this project."
            log_warn "  The previous mutter-device-ignore udev rule is rejected by modern systemd-udevd"
            log_warn "  (env property names containing '-' fail with 'Invalid argument', and the failure"
            log_warn "  aborts processing of the entire device — so 60-input-id.rules never tags it,"
            log_warn "  and libinput can't see Sunshine's virtual KB/mouse at all)."
            log_warn "  Sunshine virtual inputs will appear as duplicate devices on your GNOME desktop."
            log_warn "  Workaround: run KDE Plasma on the host (kcminputrc-based isolation works there)."
            ;;
        *)
            log_warn "Skipping input isolation — unknown desktop. Sunshine virtual KB/mouse may"
            log_warn "  fire on your host desktop while a Moonlight session is connected."
            ;;
    esac
}

cleanup_legacy_artifacts() {
    local f=/etc/udev/rules.d/85-sunshine-input-isolation.rules
    if [[ -f "$f" ]]; then
        log_info "Removing legacy broken udev rule at $f"
        sudo rm -f "$f"
        sudo udevadm control --reload-rules
    fi
}

# ---------- Service lifecycle ----------
enable_services() {
    systemctl --user daemon-reload
    systemctl --user enable sway-sunshine.service     >/dev/null
    systemctl --user enable sunshine-headless.service >/dev/null
    log_ok "Services enabled"
}

maybe_start_services() {
    read -rp "Start the services now? [Y/n] " start
    if [[ "${start:-Y}" =~ ^[Yy]?$ ]]; then
        systemctl --user restart sway-sunshine.service
        # sunshine-headless.service has Requires=, will follow
        log_info "Waiting 3s for services to settle..."
        sleep 3
        run_post_install_checks || log_warn "Some checks failed — see above and re-run with --check after fixing."
    fi
}

# ---------- Verification ----------
run_post_install_checks() {
    echo
    echo "=== Post-install verification ==="
    local fails=0
    _check() {
        local label=$1; shift
        if "$@" &>/dev/null; then
            log_ok "$label"
        else
            log_err "$label"
            fails=$((fails + 1))
        fi
    }

    # Detect again in --check mode (when these globals weren't set)
    if [[ -z "$SUNSHINE_PATH" ]] && have sunshine; then
        SUNSHINE_PATH="$(command -v sunshine)"
    fi
    detect_gpus &>/dev/null || true

    if [[ -n "$SUNSHINE_PATH" ]]; then
        local year
        year=$(sunshine_year 2>/dev/null || echo 0)
        if (( year >= MIN_SUNSHINE_YEAR )); then
            log_ok "Sunshine v${year}.x (>= v${MIN_SUNSHINE_YEAR}.x)"
        else
            log_err "Sunshine version too old (year=$year < $MIN_SUNSHINE_YEAR)"
            fails=$((fails + 1))
        fi
    else
        log_err "Sunshine binary not found"
        fails=$((fails + 1))
    fi

    _check "sway-sunshine.service active"     systemctl --user is-active --quiet sway-sunshine.service
    _check "sunshine-headless.service active" systemctl --user is-active --quiet sunshine-headless.service

    if [[ -S "$SOCKET_PATH" ]]; then
        if SWAYSOCK="$SOCKET_PATH" swaymsg -t get_inputs 2>/dev/null | grep -q "\"vendor\": ${SUNSHINE_VENDOR_DEC}"; then
            log_ok "sway sees Sunshine virtual inputs"
        else
            log_err "sway does not see Sunshine virtual inputs (libinput visibility broken?)"
            fails=$((fails + 1))
        fi
    else
        log_warn "Sway IPC socket not present at $SOCKET_PATH (skipping input visibility check)"
    fi

    if (( HAS_NVIDIA )); then
        if grep -q 'Found H.264 encoder: h264_nvenc' "$HOME/.config/sunshine/sunshine.log" 2>/dev/null; then
            log_ok "NVENC encoder probed by Sunshine"
        else
            log_warn "h264_nvenc not yet seen in sunshine.log (try connecting from Moonlight first)"
        fi
    fi

    # Check for the canonical NVIDIA failure mode in recent journal
    if journalctl --user -u sway-sunshine.service --since "5 minutes ago" 2>/dev/null \
            | grep -q EGL_BAD_MATCH; then
        log_err "EGL_BAD_MATCH in sway journal — DMA-BUF modifier issue (is WLR_DRM_NO_MODIFIERS=1 set?)"
        fails=$((fails + 1))
    else
        log_ok "No EGL_BAD_MATCH in recent sway journal"
    fi

    echo
    if (( fails == 0 )); then
        log_ok "All checks passed."
    else
        log_err "$fails check(s) failed."
    fi
    return $fails
}

# ---------- Summary ----------
print_summary() {
    echo
    echo "=== Installation complete ==="
    echo
    echo "  Desktop:        $DETECTED_DE"
    echo "  GPU(s):         NVIDIA=$HAS_NVIDIA AMD=$HAS_AMD INTEL=$HAS_INTEL"
    if (( HAS_NVIDIA )); then
        echo "  NVIDIA node:    $NVIDIA_RENDER_NODE  (NVENC enabled)"
    fi
    echo "  Sunshine:       $SUNSHINE_PATH"
    echo "  Headless WL:    $HEADLESS_DISPLAY"
    echo
    echo "Start now:        systemctl --user start sway-sunshine.service"
    echo "Status:           systemctl --user status sway-sunshine sunshine-headless"
    echo "Re-verify later:  $0 --check"
    echo
    echo "Add Steam games to: $SUNSHINE_CONFIG_DIR/apps.json"
    echo "Pair Moonlight at:  https://$(hostname):47990"
    echo

    if (( IS_ARCH )) && (( SUNSHINE_USED_PREBUILT )); then
        log_warn "You installed the upstream prebuilt sunshine package. To prevent"
        log_warn "  a future 'pacman -Syu' from replacing it with the distro version,"
        log_warn "  add this line to /etc/pacman.conf under [options]:"
        echo
        echo "      IgnorePkg = sunshine"
        echo
    elif (( IS_ARCH )) && (( SUNSHINE_UPGRADED )); then
        log_info "Installed $SUNSHINE_AUR_PACKAGE from AUR."
        log_info "  No IgnorePkg pin needed — the AUR package's provides=sunshine"
        log_info "  prevents the distro version from re-installing on 'pacman -Syu'."
        log_info "  Rebuild against latest upstream master with:  $AUR_HELPER -S $SUNSHINE_AUR_PACKAGE"
    fi
}

# ---------- Main ----------
main() {
    local mode=install
    if [[ "${1:-}" == "--check" ]]; then
        mode=check
    fi

    echo "=== Headless Sway + Sunshine Installer ==="
    echo

    detect_distro
    detect_gpus

    if [[ "$mode" == "check" ]]; then
        run_post_install_checks
        exit $?
    fi

    detect_desktop
    install_deps
    ensure_sunshine
    detect_wayland_displays

    echo
    log_info "Installing config files..."
    install_sway_configs
    install_sunshine_conf
    install_apps_json
    install_systemd_units
    install_nvidia_dropin
    install_pipewire_sink

    echo
    log_info "Configuring input isolation..."
    cleanup_legacy_artifacts
    install_input_isolation

    echo
    enable_services
    print_summary
    maybe_start_services
}

main "$@"
