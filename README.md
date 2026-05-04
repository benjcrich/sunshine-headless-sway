# Headless Sway + Sunshine Game Streaming

> **DISCLAIMER**: This is provided as-is with absolutely no warranty or guarantee. Use at your own risk. This may break your system, eat your configs, set your GPU on fire, or summon an elder god. The author(s) take no responsibility for anything that happens as a result of using this software. You have been warned.

![Architecture Diagram](diagram.svg)

Stream games from a headless Sway session using [Sunshine](https://github.com/LizardByte/Sunshine) and [Moonlight](https://moonlight-stream.org/), without disrupting your main desktop session.

This setup runs a separate headless Wayland compositor (Sway) dedicated to game streaming. Your primary desktop (GNOME, KDE, etc.) continues running normally — audio, display, and input are fully isolated.

## Why headless?

- Stream games without taking over your main display
- Dynamic resolution matching — the headless output adapts to your Moonlight client
- Game audio routes only to the stream, host audio is unaffected
- Works with NVIDIA GPUs using NVENC hardware encoding
- Minimal overhead when idle (~420MB RAM, negligible CPU)

## Requirements

- **OS**: Linux with systemd user services (tested on CachyOS/Arch and Ubuntu 25.10)
- **GPU**: NVIDIA with proprietary drivers (for NVENC), or any GPU for software-encoded streaming
- **Packages**: `sway`, `swaybg`, `pipewire`, `wireplumber`, `xdg-desktop-portal-wlr`
- **Sunshine**: [LizardByte Sunshine](https://github.com/LizardByte/Sunshine/releases) **v2026.x** (any 2026-series release; the Wayland NVENC capture path was rewritten in this series). The installer will refuse to proceed against older Sunshine and offer to upgrade automatically.
- **Client**: [Moonlight](https://moonlight-stream.org/) on any device

> **Note on CachyOS:** the CachyOS repo currently ships an older Sunshine snapshot (`2025.924.x`) which has a broken Wayland NVENC capture path on NVIDIA. The installer detects this and offers to install [`sunshine-git`](https://aur.archlinux.org/packages/sunshine-git) from the AUR (preferred — tracks upstream master, builds with all features). If no AUR helper is present, it falls back to downloading the upstream prebuilt `pkg.tar.zst` from GitHub releases (in which case you'll want `IgnorePkg = sunshine` in `/etc/pacman.conf` under `[options]` to keep `pacman -Syu` from downgrading it).

## Quick install

```bash
git clone https://github.com/daaaaan/sunshine-headless-sway.git
cd sunshine-headless-sway
./install.sh
```

The install script will:
- Install missing dependencies (`sway`, `swaybg`, `xdg-desktop-portal-wlr`) via pacman or apt
- Detect every GPU on the system via DRM sysfs and identify NVIDIA's render node
- Verify Sunshine version is **v2026.x or newer** (and offer to upgrade on Arch/CachyOS — `sunshine-git` from AUR if a helper like paru/yay is installed, otherwise the upstream prebuilt package)
- Auto-detect your desktop environment for input isolation (KDE only — see [GNOME limitation](#gnome-input-isolation-limitation))
- Auto-detect Sunshine installation path, Wayland display number, and user ID
- Template all config files with your system's paths
- On NVIDIA hosts: install a systemd drop-in (`10-nvidia.conf`) with `WLR_RENDER_DRM_DEVICE` and `WLR_DRM_NO_MODIFIERS=1`; append `encoder = nvenc` and `adapter_name = /dev/dri/renderDXXX` to `sunshine.conf`
- Preserve any existing Sunshine config you already have
- Run a post-install verification pass

You can re-run verification at any time without touching files:

```bash
./install.sh --check
```

## Manual setup

If you prefer to install manually, see the [manual setup guide](#manual-setup-guide) below.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Main Desktop (GNOME/KDE)          wayland-0        │
│  └─ Normal apps, browser, etc.                      │
│  └─ Audio → your speakers/headphones                │
├─────────────────────────────────────────────────────┤
│  Headless Sway                     wayland-1        │
│  └─ Games launched via Sunshine                     │
│  └─ Audio → sink-sunshine-stereo → Moonlight stream │
│  └─ Video → wlr-screencopy → NVENC → Moonlight     │
└─────────────────────────────────────────────────────┘
```

Two systemd user services manage the stack:

1. **`sway-sunshine.service`** — runs a headless Sway compositor with no physical display
2. **`sunshine-headless.service`** — runs Sunshine pointed at the headless Sway session

## Adding games

Edit `~/.config/sunshine/apps.json` to add Steam games. Find the app ID on [SteamDB](https://steamdb.info/) and add an entry:

```json
{
  "name": "Game Name",
  "detached": [
    "swaymsg exec 'steam steam://rungameid/APP_ID'"
  ],
  "prep-cmd": [
    {
      "do": "~/.config/sway-sunshine/set-resolution.sh",
      "undo": ""
    }
  ]
}
```

Restart Sunshine after editing: `systemctl --user restart sunshine-headless.service`

## How it works

### NVIDIA + headless Sway renderer

On NVIDIA hosts the installer drops a systemd override at `~/.config/systemd/user/sway-sunshine.service.d/10-nvidia.conf` containing two extra environment variables:

```ini
Environment=WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128   # detected NVIDIA render node
Environment=WLR_DRM_NO_MODIFIERS=1
```

Both are necessary for streaming to work on NVIDIA:

- **`WLR_RENDER_DRM_DEVICE`** pins wlroots to NVIDIA on multi-GPU systems. Without it, wlroots auto-picks a render device (often the AMD iGPU on Ryzen CPUs), which then forces a cross-vendor DMA-BUF copy into NVENC and breaks frame capture.
- **`WLR_DRM_NO_MODIFIERS=1`** forces wlroots to allocate linear DMA-BUFs. NVIDIA EGL rejects most explicit DRM format modifiers and would otherwise return `EGL_BAD_MATCH` on every `eglCreateImageKHR` during `wlr-screencopy` capture — visible as `[wayland] Frame capture failed` in `sunshine.log`.

Stick with `WLR_RENDERER=gles2` (the default). The Vulkan renderer has more modifier issues with NVIDIA headless and isn't worth the headache.

### Multi-GPU game routing

On hosts with both NVIDIA and another GPU (AMD iGPU on Ryzen, Intel iGPU, etc.), Steam's Vulkan loader will pick the iGPU as the default GPU unless told otherwise. The shipped `start-steam-game.sh` exports `VK_DRIVER_FILES` to NVIDIA's ICD when present, restricting Vulkan enumeration to the NVIDIA card so Steam launches games on the discrete GPU. The check is a no-op on hosts without NVIDIA — same script works everywhere.

### Audio isolation

Game audio is routed exclusively to the Moonlight stream without touching your host audio:

- A persistent PipeWire null sink (`sink-sunshine-stereo`) is created via config drop-in — it always exists, even when Moonlight is disconnected or backgrounded
- `PULSE_SINK=sink-sunshine-stereo` is set in the Sway service environment, so apps launched in the headless session output to this sink
- `audio_sink = sink-sunshine-stereo` in `sunshine.conf` tells Sunshine to capture from that sink
- `restore-default-sink.sh` runs as a prep command to prevent Sunshine from hijacking your host's default audio sink — it detects the change and restores it within seconds
- When Moonlight is backgrounded, game audio stays in the persistent null sink (silent) instead of reverting to your host speakers
- Your main desktop audio continues through your normal output device

### Dynamic resolution

When a Moonlight client connects, Sunshine runs `set-resolution.sh` as a prep command. This uses `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, and `SUNSHINE_CLIENT_FPS` environment variables to resize the headless output to match the client exactly. On disconnect, `reset-resolution.sh` reverts to 1080p.

### Wayland display numbering

The headless Sway session typically gets `wayland-1` (assuming your main desktop is `wayland-0`). The install script detects this automatically. To check manually:

```bash
ls /run/user/$(id -u)/wayland-*
```

### IPC socket

Sway creates its IPC socket at the path specified by `SWAYSOCK` (`/run/user/<uid>/sway-sunshine.sock`). The service cleans up stale sockets on restart via `ExecStartPre`. All `swaymsg` commands in the apps and scripts reference this socket explicitly.

## Troubleshooting

### Re-run the verification step at any time

```bash
./install.sh --check
```

This re-runs all the post-install probes (Sunshine version, services active, sway sees virtual inputs, NVENC probed, no `EGL_BAD_MATCH` in journal) without touching any files.

### Blank display / `Frame capture failed`

- Check `~/.config/sunshine/sunshine.log` for `[wayland] Frame capture failed`. If present, also check the sway journal: `journalctl --user -u sway-sunshine.service | grep -i EGL_BAD_MATCH`. If you see the EGL error, your `10-nvidia.conf` drop-in is missing or `WLR_DRM_NO_MODIFIERS=1` isn't taking effect — re-run `./install.sh` to regenerate.
- If the log shows repeated `Error: GL: ... [00000502]` (`GL_INVALID_OPERATION`) every frame, your Sunshine is too old. Required version is **v2026.x** — re-run `./install.sh` and accept the upgrade prompt, or install upstream's Arch package manually.
- Ensure `WLR_RENDERER=gles2` is set in `sway-sunshine.service` (not `vulkan`)
- Verify Sunshine is connecting to the correct Wayland display

### Sunshine downgraded after a system update (Arch/CachyOS)

If you went the AUR `sunshine-git` route via `install.sh`, this shouldn't happen — the AUR package declares `provides=sunshine` and `conflicts=sunshine`, so pacman won't re-install the distro version on top of it. To rebuild against the latest upstream master at any time:

```
paru -S sunshine-git    # or your AUR helper of choice
```

If you went the **upstream prebuilt** route (no AUR helper present), pacman *will* try to replace it with the distro `sunshine` package on `pacman -Syu`. Pin it by adding to `/etc/pacman.conf` under `[options]`:

```
IgnorePkg = sunshine
```

### Input isolation

Sunshine creates virtual input devices (vendor `0xBEEF`, product `0xDEAD`) that need to be hidden from your host desktop while remaining usable by the headless Sway session.

> **Heads up:** previous versions of this project shipped udev rules for GNOME and KDE. Both broke on modern systemd/wlroots and have been **removed** — see [Why udev rules don't work anymore](#why-udev-rules-dont-work-anymore) below.

#### KDE Plasma (KWin) — supported

The installer writes `Enabled=false` entries to `~/.config/kcminputrc` for each of Sunshine's well-known virtual devices:

```ini
[Libinput][48879][57005][Mouse passthrough]
Enabled=false

[Libinput][48879][57005][Keyboard passthrough]
Enabled=false
# ... and so on for Mouse passthrough (absolute), Touch passthrough, Pen passthrough,
# and Sunshine PS5 (virtual) pad Touchpad
```

KWin honors the `Enabled` key and suspends the device at the libinput level. The headless Sway has its own libinput context and ignores this file, so the devices stay visible inside the streaming session.

The catch: KWin only re-evaluates `Enabled` for a device when it (re)attaches. If you edit `kcminputrc` while Sunshine is running, the change won't apply until you reboot, log out and back in, disconnect+reconnect Moonlight (which causes Sunshine to recreate its virtual devices), or restart `sunshine-headless.service`.

#### GNOME input isolation limitation

GNOME's `mutter-device-ignore` mechanism is rejected by modern `systemd-udevd` because the property name contains a hyphen — udev returns "Invalid argument" and aborts processing the entire device, which means the device gets *no* tags at all and libinput can't see it for *either* compositor. There's no clean alternative on GNOME today.

The installer detects GNOME and warns; it does **not** install any udev rule. Sunshine's virtual KB/mouse will appear as duplicate input devices in your GNOME session while a Moonlight client is connected. If this matters, run KDE Plasma on the host for now, or track upstream GNOME for a fix.

#### Why udev rules don't work anymore

- **GNOME rule** (`mutter-device-ignore`): modern `systemd-udevd` rejects env var names containing hyphens. The rule fails with `Invalid argument` and udev *aborts processing the whole device*, so the standard `60-input-id.rules` never tags it and libinput skips it. Result: headless Sway can't see Sunshine's virtual KB/mouse.
- **KDE rule** (strip `ID_INPUT*`): worked when KWin used a different input enumeration path. Today, KWin and headless Sway both use libinput's udev backend, which keys on those exact tags. Stripping them blinds *both* compositors equally.

The kcminputrc approach for KDE sidesteps both problems by living entirely in user space — KWin reads it, libinput doesn't.

#### How the rest of isolation works

- The headless Sway uses `WLR_BACKENDS=headless,libinput` with `LIBSEAT_BACKEND=noop` and runs under the `input` group via `sg` to access input devices without a logind seat
- The **Sway config** disables all physical host devices and only enables Sunshine's passthrough devices, so your physical keyboard and mouse don't leak into the streaming session
- Gamepads are read directly by Steam via evdev, bypassing the compositor entirely

### No input / can't control games

- The `xdg-desktop-portal-wlr` package must be installed
- Check that `/dev/uinput` is accessible to your user (Sunshine's udev rules should handle this)
- Verify the libinput backend is active: `SWAYSOCK=/run/user/$(id -u)/sway-sunshine.sock swaymsg -t get_inputs` should show Sunshine passthrough devices with `events: enabled`
- If `swaymsg` shows no `48879:57005:*passthrough*` entries, check `/etc/udev/rules.d/` for any leftover `85-sunshine-input-isolation.rules` from an old install of this project — `install.sh` removes it automatically, but a stale copy will strip `ID_INPUT_*` and hide the devices from libinput. Delete it and run `sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=input`.

### Games don't launch

- Verify the Sway IPC socket exists: `ls -la /run/user/$(id -u)/sway-sunshine.sock`
- Test manually: `SWAYSOCK=/run/user/$(id -u)/sway-sunshine.sock swaymsg -t get_tree`
- If the socket is stale after a restart, the `ExecStartPre` cleanup in the service handles it

### Audio bleeds to host

- Verify `audio_sink = sink-sunshine-stereo` is in `~/.config/sunshine/sunshine.conf`
- Check `PULSE_SINK=sink-sunshine-stereo` is in `sway-sunshine.service`
- Verify the `restore-default-sink.sh` prep command is in `apps.json` — without it, Sunshine sets `sink-sunshine-stereo` as the system-wide default, routing all host audio into the stream
- Confirm your default sink after connecting: `wpctl status | grep '\*'`

### UPnP port mapping failures

These errors (`Failed to map UDP/TCP`) are harmless if you're connecting over LAN or a VPN like Tailscale. They only matter for WAN connections through your router.

## Manual setup guide

If you'd rather not use the install script:

### 1. Install dependencies

**Arch / CachyOS:**
```bash
sudo pacman -S sway swaybg xdg-desktop-portal-wlr
```

**Ubuntu / Debian:**
```bash
sudo apt install sway swaybg xdg-desktop-portal-wlr
```

### 2. Copy config files

```bash
# Sway config and scripts
mkdir -p ~/.config/sway-sunshine
cp sway-sunshine/config ~/.config/sway-sunshine/
cp sway-sunshine/set-resolution.sh ~/.config/sway-sunshine/
cp sway-sunshine/reset-resolution.sh ~/.config/sway-sunshine/
chmod +x ~/.config/sway-sunshine/*.sh

# Sunshine config
cp sunshine/sunshine.conf ~/.config/sunshine/sunshine.conf
cp sunshine/apps.json ~/.config/sunshine/apps.json

# PipeWire persistent audio sink
mkdir -p ~/.config/pipewire/pipewire.conf.d
cp pipewire/sunshine-null-sink.conf ~/.config/pipewire/pipewire.conf.d/
systemctl --user restart pipewire.service

# Systemd services
mkdir -p ~/.config/systemd/user
cp systemd/sway-sunshine.service ~/.config/systemd/user/
cp systemd/sunshine-headless.service ~/.config/systemd/user/
```

### 3. Edit paths

Update the following in the copied files to match your system:

- `sunshine-headless.service`: set `ExecStart` to your Sunshine path, `WAYLAND_DISPLAY` to your headless display
- `sway-sunshine.service`: update `/run/user/1000/` to `/run/user/$(id -u)/` if your UID isn't 1000
- `apps.json`: update `/home/YOUR_USER/` to your home directory
- `set-resolution.sh` / `reset-resolution.sh`: update the socket path if your UID isn't 1000

### 4. Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable --now sway-sunshine.service
systemctl --user enable --now sunshine-headless.service
```

### 5. Pair with Moonlight

Open Moonlight, find your host, and pair using the PIN at `https://YOUR_HOST:47990`.

## File structure

```
~/.config/
├── kcminputrc                          # KDE-only: per-device Enabled=false for Sunshine virtual inputs
├── pipewire/pipewire.conf.d/
│   └── sunshine-null-sink.conf         # Persistent audio sink (survives disconnect)
├── sway-sunshine/
│   ├── config                          # Headless Sway compositor config (input isolation)
│   ├── set-resolution.sh               # Dynamic resolution on connect
│   ├── reset-resolution.sh             # Reset resolution on disconnect
│   ├── restore-default-sink.sh         # Prevents Sunshine from hijacking host audio
│   ├── start-steam-game.sh             # Steam launcher (with multi-GPU Vulkan pinning)
│   └── stop-steam-game.sh              # Cleanup helper
├── sunshine/
│   ├── sunshine.conf                   # Sunshine server config (encoder=nvenc on NVIDIA)
│   └── apps.json                       # Game/app entries for Moonlight
└── systemd/user/
    ├── sway-sunshine.service           # Headless Sway compositor service
    ├── sway-sunshine.service.d/
    │   └── 10-nvidia.conf              # NVIDIA-only: WLR_RENDER_DRM_DEVICE + WLR_DRM_NO_MODIFIERS
    └── sunshine-headless.service       # Sunshine streaming service
```

`install.sh` only writes the `10-nvidia.conf` drop-in when an NVIDIA render node is detected. On AMD-only or Intel-only hosts that file isn't created.

## License

MIT — do whatever you want with it, but don't blame us if something breaks.
