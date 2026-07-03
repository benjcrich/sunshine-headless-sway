#!/bin/bash
set -euo pipefail

# Headless Sway + Sunshine Game Streaming Setup
# Fork of https://github.com/daaaaan/sunshine-headless-sway with NVIDIA + multi-GPU
# fixes; verified only on Arch/CachyOS + KDE Plasma + NVIDIA. See README for caveats.
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

# AUR package preferred on Arch.
# We use sunshine-beta-bin (the binary repackaging of upstream's pre-release)
# rather than sunshine-git (source build) because the AUR -git PKGBUILD does
# not pull in `cuda` as a build dependency — sunshine compiled without CUDA
# bindings can detect h264_nvenc at startup (since libavcodec from the system
# provides the encoder symbol) but every actual NVENC session fails with
# "Couldn't scale frame: Invalid argument" because Sunshine can't do the GPU
# buffer interop. sunshine-beta-bin is the binary the LizardByte CI builds
# with full CUDA support, just packaged for Arch.
SUNSHINE_AUR_PACKAGE="sunshine-beta-bin"

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
    # Purely informational: the wayland-N number isn't baked in anywhere.
    # Sway publishes its real display name to $XDG_RUNTIME_DIR/sway-sunshine.display
    # at startup, and sunshine-headless.service reads it from there — guessing
    # the number at install time breaks when a previous headless session is
    # still holding a socket.
    HEADLESS_DISPLAY=$(cat "/run/user/$USER_ID/sway-sunshine.display" 2>/dev/null || true)
    if [[ -n "$HEADLESS_DISPLAY" ]]; then
        log_ok "Headless sway currently on: $HEADLESS_DISPLAY"
    else
        HEADLESS_DISPLAY="(published at service start)"
        log_info "Headless display name is published when sway-sunshine.service starts"
    fi
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
    log_info "Installing $SUNSHINE_AUR_PACKAGE from AUR via $AUR_HELPER..."
    log_info "  This is a binary repackage of upstream's pre-release build (no compilation)."
    log_info "  $AUR_HELPER will prompt you for sudo and may ask to replace the existing 'sunshine' package — that's expected."
    if ! "$AUR_HELPER" -S "$SUNSHINE_AUR_PACKAGE"; then
        log_err "AUR install failed. You can fall back to the upstream prebuilt with:"
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
        # The breaking failure (per-frame GL_INVALID_OPERATION → black screen)
        # is specific to NVIDIA + Wayland capture in v2025.x. On non-NVIDIA hosts
        # the old version often works fine (especially with software encoding),
        # so we hard-error only when NVIDIA is detected and merely warn otherwise.
        if (( HAS_NVIDIA )); then
            log_warn "Sunshine v$year.x detected on an NVIDIA host."
            log_warn "  Older versions throw GL_INVALID_OPERATION every frame on Wayland → black screen."
            log_warn "  v2026.x rewrote the Wayland NVENC capture path. Upgrade is REQUIRED."
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
                if (( IS_ARCH )); then
                    upgrade_sunshine_arch || exit 1
                else
                    log_err "Auto-upgrade is only implemented for Arch/CachyOS."
                    log_err "On Debian/Ubuntu, install the v2026.x .deb from upstream releases first:"
                    log_err "  https://github.com/LizardByte/Sunshine/releases"
                    exit 1
                fi
                SUNSHINE_PATH="$(command -v sunshine)"
                year=$(sunshine_year) || true
            else
                log_err "Refusing to proceed with outdated Sunshine on NVIDIA — would produce a black screen."
                exit 1
            fi
        else
            log_warn "Sunshine v$year.x detected — v2026.x is recommended (Wayland capture fixes)."
            log_warn "  On non-NVIDIA hosts the older version usually works for software-encode streaming"
            log_warn "  but it's still the upstream-recommended floor for this project."
            local prompt
            if (( IS_ARCH )) && [[ -n "$AUR_HELPER" ]]; then
                prompt="Upgrade to $SUNSHINE_AUR_PACKAGE via $AUR_HELPER now? [y/N] "
            elif (( IS_ARCH )); then
                prompt="Download & install upstream prebuilt now? [y/N] "
            else
                prompt=""
            fi
            if [[ -n "$prompt" ]]; then
                read -rp "$prompt" ans
                if [[ "$ans" =~ ^[Yy]$ ]]; then
                    upgrade_sunshine_arch || log_warn "Upgrade failed; continuing with $year version."
                    SUNSHINE_PATH="$(command -v sunshine)"
                    year=$(sunshine_year) || true
                fi
            fi
            if (( year < MIN_SUNSHINE_YEAR )); then
                log_warn "Continuing with Sunshine v$year.x. If you hit any 'Frame capture failed' or"
                log_warn "  'GL_INVALID_OPERATION' errors later, re-run install.sh and accept the upgrade."
            fi
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
    # All scripts derive the socket path from $(id -u) at runtime — plain copies
    cp "$SCRIPT_DIR/sway-sunshine/config"                   "$SWAY_CONFIG_DIR/config"
    cp "$SCRIPT_DIR/sway-sunshine/set-resolution.sh"        "$SWAY_CONFIG_DIR/set-resolution.sh"
    cp "$SCRIPT_DIR/sway-sunshine/reset-resolution.sh"      "$SWAY_CONFIG_DIR/reset-resolution.sh"
    cp "$SCRIPT_DIR/sway-sunshine/restore-default-sink.sh"  "$SWAY_CONFIG_DIR/restore-default-sink.sh"
    cp "$SCRIPT_DIR/sway-sunshine/start-steam-game.sh"      "$SWAY_CONFIG_DIR/start-steam-game.sh"
    cp "$SCRIPT_DIR/sway-sunshine/stop-steam-game.sh"       "$SWAY_CONFIG_DIR/stop-steam-game.sh"
    cp "$SCRIPT_DIR/sway-sunshine/fullscreen-enforcer.sh"   "$SWAY_CONFIG_DIR/fullscreen-enforcer.sh"
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
            || echo "audio_sink = sink-sunshine-headless" >> "$SUNSHINE_CONFIG_DIR/sunshine.conf"
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
        sed -e "s|/home/YOUR_USER/|$HOME/|g" \
            -e "s|/run/user/1000/|/run/user/$USER_ID/|g" \
            "$SCRIPT_DIR/sunshine/apps.json" > "$SUNSHINE_CONFIG_DIR/apps.json"
        log_ok "Created apps.json"
    else
        log_info "apps.json already exists, skipping"
    fi
}

install_systemd_units() {
    mkdir -p "$SYSTEMD_DIR"
    # Units use %t for the runtime dir, so no UID templating needed
    cp "$SCRIPT_DIR/systemd/sway-sunshine.service" "$SYSTEMD_DIR/sway-sunshine.service"
    sed -e "s|\"/usr/bin/sunshine\"|\"$SUNSHINE_PATH\"|g" \
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

    # Find the NVIDIA Vulkan ICD so we can pin Vulkan apps (Steam, games)
    # to the discrete GPU on multi-GPU systems. Without this, Vulkan apps
    # see all ICDs (e.g. radv for AMD iGPU) and Steam picks the iGPU as
    # default — landing games on it instead of the dGPU.
    #
    # We set this via the systemd Environment because anything spawned
    # through `swaymsg exec` inherits sway's process env, NOT the env of
    # whoever called `swaymsg`. Setting VK_DRIVER_FILES inside
    # start-steam-game.sh would silently no-op.
    local nvidia_icd=""
    for cand in /usr/share/vulkan/icd.d/nvidia_icd.json \
                /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json; do
        if [[ -r "$cand" ]]; then nvidia_icd="$cand"; break; fi
    done

    mkdir -p "$DROPIN_DIR"
    {
        echo "# Auto-generated by install.sh — NVIDIA-specific environment for headless Sway."
        echo "# Pins wlroots to NVIDIA's render node and forces linear DMA-BUFs that"
        echo "# NVIDIA EGL can import (NVIDIA rejects most explicit modifiers, which"
        echo "# would otherwise produce EGL_BAD_MATCH on every frame capture)."
        echo "[Service]"
        echo "Environment=WLR_RENDER_DRM_DEVICE=$NVIDIA_RENDER_NODE"
        echo "Environment=WLR_DRM_NO_MODIFIERS=1"
        if [[ -n "$nvidia_icd" ]] && (( GPU_COUNT > 1 )); then
            echo "Environment=VK_DRIVER_FILES=$nvidia_icd"
        fi
    } > "$DROPIN_DIR/10-nvidia.conf"

    if [[ -n "$nvidia_icd" ]] && (( GPU_COUNT > 1 )); then
        log_ok "Installed NVIDIA drop-in at $DROPIN_DIR/10-nvidia.conf (with Vulkan ICD pin: $nvidia_icd)"
    elif [[ -z "$nvidia_icd" ]] && (( GPU_COUNT > 1 )); then
        log_warn "Multi-GPU host but NVIDIA Vulkan ICD JSON not found at the usual paths."
        log_warn "  Steam may pick a non-NVIDIA GPU for games. Investigate with: vulkaninfo --summary"
        log_ok "Installed NVIDIA drop-in at $DROPIN_DIR/10-nvidia.conf (without Vulkan pin)"
    else
        log_ok "Installed NVIDIA drop-in at $DROPIN_DIR/10-nvidia.conf"
    fi
}

install_pipewire_sink() {
    local pipewire_dir="$HOME/.config/pipewire/pipewire.conf.d"
    mkdir -p "$pipewire_dir"
    cp "$SCRIPT_DIR/pipewire/sunshine-null-sink.conf" "$pipewire_dir/sunshine-null-sink.conf"
    log_ok "Installed PipeWire persistent audio sink"

    # pipewire-pulse rule: pin Sunshine's capture to the persistent sink so the
    # default-sink restore doesn't drag it onto host audio
    local pipewire_pulse_dir="$HOME/.config/pipewire/pipewire-pulse.conf.d"
    mkdir -p "$pipewire_pulse_dir"
    cp "$SCRIPT_DIR/pipewire/sunshine-capture-pin.conf" "$pipewire_pulse_dir/50-sunshine-capture-pin.conf"
    log_ok "Installed Sunshine capture pin rule"
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
    [[ -f "$f" ]] || return 0

    if (( HAS_NVIDIA )); then
        # On NVIDIA hosts the broken rule definitely breaks streaming, so just remove.
        log_info "Removing legacy udev rule at $f"
        log_info "  (broken on modern systemd-udevd; would prevent Sway from seeing Sunshine virtual inputs)"
        sudo rm -f "$f"
        sudo udevadm control --reload-rules
        return 0
    fi

    # Non-NVIDIA host: ask before touching it. Some users on older systemd
    # may still have a working setup — let them decide.
    log_warn "Found legacy udev rule at $f"
    log_warn "  This rule is BROKEN on modern systemd-udevd and is the most common cause"
    log_warn "  of 'Sway has no Sunshine virtual KB/mouse' problems."
    log_warn "  See README → Troubleshooting → Input isolation for how to verify."
    read -rp "Remove it? [Y/n] " ans
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
        sudo rm -f "$f"
        sudo udevadm control --reload-rules
        log_ok "Removed."
    else
        log_warn "Left in place. If input isolation breaks, remove with:"
        log_warn "  sudo rm $f && sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=input"
    fi
}

# ---------- Service lifecycle ----------
enable_services() {
    systemctl --user daemon-reload
    systemctl --user enable sway-sunshine.service     >/dev/null
    systemctl --user enable sunshine-headless.service >/dev/null
    # Pick up the null sink and capture pin rule
    systemctl --user restart pipewire.service pipewire-pulse.service 2>/dev/null || true
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

        # Look for the SILENT FALLTHROUGH symptom — Sunshine claimed nvenc support
        # at startup but every actual session failed and got swapped for software.
        # This is what happens with sunshine-git (CUDA-less build) or with a missing
        # WLR env var. Catches the case where streaming "works" on libx264 without
        # the user realizing.
        if grep -q "Couldn't find any working encoder matching \[nvenc\]" "$HOME/.config/sunshine/sunshine.log" 2>/dev/null; then
            log_err "NVENC failed to actually start a session at least once (silent fallthrough to software)."
            log_err "  Inspect: grep -E 'Couldn|Encoder \\[' ~/.config/sunshine/sunshine.log"
            log_err "  Common causes:"
            log_err "    - Using sunshine-git (built without CUDA) instead of sunshine-beta-bin"
            log_err "    - Missing WLR_DRM_NO_MODIFIERS=1 in sway-sunshine.service env"
            log_err "    - Wrong adapter_name in sunshine.conf"
            fails=$((fails + 1))
        fi

        # Live NVENC session probe — only meaningful if a Moonlight client is currently connected
        local nvenc_active
        nvenc_active=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
        if [[ "$nvenc_active" =~ ^[0-9]+$ ]] && (( nvenc_active > 0 )); then
            log_ok "NVENC currently active ($nvenc_active session(s))"
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
        log_info "  No IgnorePkg pin needed — sunshine-beta-bin's conflicts with the distro"
        log_info "  'sunshine' package prevent it from re-installing on 'pacman -Syu'."
        log_info "  Refresh to a newer upstream pre-release with:  $AUR_HELPER -S $SUNSHINE_AUR_PACKAGE"
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
