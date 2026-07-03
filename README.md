# Headless Sway + Sunshine Game Streaming

> **Fork notice:** this is a personal fork of [daaaaan/sunshine-headless-sway](https://github.com/daaaaan/sunshine-headless-sway) with changes targeted at multi-GPU NVIDIA hosts on modern systemd. I've only verified it on my own setup (Arch / CachyOS + KDE Plasma + NVIDIA RTX 5080) and don't have hardware to test other distros, desktops, or GPU vendors. It's published as-is and I'm not maintaining it as a general-purpose project — if your setup differs, the [upstream repo](https://github.com/daaaaan/sunshine-headless-sway) is likely a better starting point.

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
- **GPU**: NVIDIA with proprietary drivers (for NVENC)
- **Packages**: `sway`, `swaybg`, `pipewire`, `wireplumber`, `xdg-desktop-portal-wlr`
- **Sunshine**: [LizardByte Sunshine](https://github.com/LizardByte/Sunshine/releases) **v2026.x** (the Wayland NVENC capture path was rewritten in this series). On Arch the installer can install [`sunshine-beta-bin`](https://aur.archlinux.org/packages/sunshine-beta-bin) for you.
- **Client**: [Moonlight](https://moonlight-stream.org/) on any device

## Quick install

```bash
git clone https://github.com/benjcrich/sunshine-headless-sway.git
cd sunshine-headless-sway
./install.sh
```

The install script will:
- Install missing dependencies (`sway`, `swaybg`, `xdg-desktop-portal-wlr`) via pacman or apt
- Auto-detect your desktop environment (GNOME or KDE) for input isolation
- Auto-detect your Sunshine installation path, GPUs, and Wayland display number
- Template all config files with your system's paths
- On NVIDIA: install a `10-nvidia.conf` systemd drop-in and configure NVENC in `sunshine.conf`
- Install and enable the systemd services, preserving any existing Sunshine config

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
│  └─ Audio → sink-sunshine-headless → Moonlight stream │
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

The Sway service uses `WLR_RENDERER=gles2` by default. On NVIDIA the installer adds a `10-nvidia.conf` drop-in that pins wlroots to NVIDIA's render node and forces linear DMA-BUFs (`WLR_DRM_NO_MODIFIERS=1`) — without it, frame capture fails with `EGL_BAD_MATCH`.

### Audio isolation

Game audio is routed exclusively to the Moonlight stream without touching your host audio:

- A persistent PipeWire null sink (`sink-sunshine-headless`) is created via config drop-in — it always exists, even when Moonlight is disconnected or backgrounded
- `PULSE_SINK=sink-sunshine-headless` is set in the Sway service environment, so PulseAudio-protocol apps launched in the headless session output to this sink
- `PIPEWIRE_PROPS={ target.object = sink-sunshine-headless }` is also set there for PipeWire-native clients (Steam, SDL3 games), which ignore `PULSE_SINK` and would otherwise follow the system default sink to your host speakers
- `audio_sink = sink-sunshine-headless` in `sunshine.conf` tells Sunshine which sink to make the default at stream start
- A `pulse.rules` drop-in (`sunshine-capture-pin.conf`) pins Sunshine's capture stream to the sink. Sunshine actually captures *the monitor of the default sink* and follows default changes — without the pin, restoring the host default (next bullet) drags Sunshine's capture onto your host audio
- `restore-default-sink.sh` runs as a prep command to prevent Sunshine from hijacking your host's default audio sink — it detects the change and restores it within seconds
- The sink name is deliberately *not* `sink-sunshine-stereo` — Sunshine auto-creates its own virtual sinks with that name (`sink-sunshine-stereo`, `-surround51`, `-surround71`), and a name collision makes routing ambiguous
- When Moonlight is backgrounded, game audio stays in the persistent null sink (silent) instead of reverting to your host speakers
- Your main desktop audio continues through your normal output device

### Steam window sizing

The Sway config force-fullscreens every window (`for_window [class=".*"] focus, fullscreen enable`) since the compositor exists only to be streamed — otherwise Sway tiles Steam and the game side by side. Two quirks need extra handling:

- When Sway fullscreens Steam's window at map time, steamwebhelper keeps rendering at its default 1280x800 and the UI sits small in the top-left corner of the stream. `start-steam-game.sh` works around this by cycling the Steam window through floating and back once it appears, forcing a repaint at the real output size.
- `for_window` rules only fire when a window maps. Clients can un-fullscreen themselves afterward (games switching to windowed mode — emulators like Xenia do this at startup), dropping everything back to side-by-side tiling. `fullscreen-enforcer.sh`, started from the Sway config, subscribes to window events and re-enables fullscreen on the focused window whenever that happens.

### Dynamic resolution

When a Moonlight client connects, Sunshine runs `set-resolution.sh` as a prep command. This uses `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, and `SUNSHINE_CLIENT_FPS` environment variables to resize the headless output to match the client exactly. On disconnect, `reset-resolution.sh` reverts to 1080p.

### Wayland display numbering

The headless Sway session's display number (`wayland-1`, `wayland-2`, ...) depends on what else is running, so it's never baked into config. At startup, Sway writes its actual display name to `$XDG_RUNTIME_DIR/sway-sunshine.display`, and `sunshine-headless.service` reads it from there. To check manually:

```bash
cat /run/user/$(id -u)/sway-sunshine.display
```

### IPC socket

Sway creates its IPC socket at the path specified by `SWAYSOCK` (`/run/user/<uid>/sway-sunshine.sock`). The service cleans up stale sockets on restart via `ExecStartPre`. All `swaymsg` commands in the apps and scripts reference this socket explicitly.

## Troubleshooting

Re-run `./install.sh --check` at any time to verify the install without touching any files.

### Blank display / `Frame capture failed`

- `EGL_BAD_MATCH` in the sway journal means the NVIDIA drop-in didn't apply. Re-run `./install.sh`.
- `GL: [00000502]` (`GL_INVALID_OPERATION`) every frame means your Sunshine is older than v2026.x. Re-run `./install.sh` and accept the upgrade prompt.
- NVENC failures fall through to software encoding silently. Check mid-stream with `nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader`; if `0`, grep `sunshine.log` for `Encoder [nvenc] failed`.
- Ensure `WLR_RENDERER=gles2` is set (not `vulkan`).

### Input isolation

The installer writes per-device `Enabled=false` entries to `~/.config/kcminputrc` for each Sunshine virtual device. KWin honors these on device (re)attach — if isolation isn't taking effect, reboot, log out, or `systemctl --user restart sunshine-headless.service`. Older versions of this project installed a udev rule for input isolation; if `swaymsg -t get_inputs` doesn't show the Sunshine passthrough devices, remove any leftover `/etc/udev/rules.d/85-sunshine-input-isolation.rules` and reload udev — it strips `ID_INPUT_*` tags and hides the devices from libinput entirely.

### Games don't launch

- Verify the Sway IPC socket exists: `ls -la /run/user/$(id -u)/sway-sunshine.sock`
- Test manually: `SWAYSOCK=/run/user/$(id -u)/sway-sunshine.sock swaymsg -t get_tree`
- If the socket is stale after a restart, the `ExecStartPre` cleanup in the service handles it

### No audio in the stream (or host audio in the stream)

- While streaming, check what Sunshine is capturing: `pactl list source-outputs` — the `sunshine` entry's source must be the monitor of `sink-sunshine-headless`, not your host device. If it's on your host device's monitor, the capture pin rule isn't active: verify `~/.config/pipewire/pipewire-pulse.conf.d/50-sunshine-capture-pin.conf` exists and restart `pipewire-pulse.service`
- WirePlumber may have memorized a bad route from before the pin existed. Clear it: stop the stream, then `systemctl --user stop wireplumber && sed -i '/sunshine/d' ~/.local/state/wireplumber/restore-stream && systemctl --user start wireplumber`
- PipeWire-native clients (Steam, SDL3 games) ignore `PULSE_SINK` and follow the system default sink — which `restore-default-sink.sh` intentionally points back at your host device. Verify `Environment="PIPEWIRE_PROPS={ target.object = sink-sunshine-headless }"` is set in `sway-sunshine.service`
- Test routing: `SWAYSOCK=/run/user/$(id -u)/sway-sunshine.sock swaymsg exec 'pw-play /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga'`, then check `pw-dump` / `pactl list sink-inputs` — the stream should target `sink-sunshine-headless`
- Don't rename the sink to `sink-sunshine-stereo`: Sunshine auto-creates its own sinks with that name and the collision breaks routing

### Game launches but the wrong window is on screen

The sway config force-fullscreens every new window and `fullscreen-enforcer.sh` re-fullscreens the focused window if a client drops out of fullscreen on its own. If a session still gets stuck (e.g. the wrong window won the focus race), rescue it over SSH — the stream has no real keyboard:

```bash
export SWAYSOCK=/run/user/$(id -u)/sway-sunshine.sock
swaymsg -t get_tree | grep -E '"app_id"|"class"'   # find the game's class/app_id
swaymsg '[class="^YourGame"] focus, fullscreen enable'
```

### Audio bleeds to host

- Verify `audio_sink = sink-sunshine-headless` is in `~/.config/sunshine/sunshine.conf`
- Check `PULSE_SINK=sink-sunshine-headless` is in `sway-sunshine.service`
- Verify the `restore-default-sink.sh` prep command is in `apps.json` — without it, Sunshine sets `sink-sunshine-headless` as the system-wide default, routing all host audio into the stream
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
cp sway-sunshine/*.sh ~/.config/sway-sunshine/
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
- `apps.json`: update `/home/YOUR_USER/` to your home directory, and the `SWAYSOCK` path in `env` if your UID isn't 1000

The systemd units use the `%t` specifier for the runtime dir and the scripts use `$(id -u)`, so neither needs UID edits.

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
├── kcminputrc                  # KDE-only: per-device Enabled=false for Sunshine virtual inputs
├── pipewire/pipewire.conf.d/
│   └── sunshine-null-sink.conf # Persistent audio sink (survives disconnect)
├── sway-sunshine/
│   ├── config                  # Headless Sway compositor config (input isolation)
│   ├── set-resolution.sh       # Dynamic resolution on connect
│   ├── reset-resolution.sh     # Reset resolution on disconnect
│   └── restore-default-sink.sh # Prevents Sunshine from hijacking host audio
├── sunshine/
│   ├── sunshine.conf           # Sunshine server config
│   └── apps.json               # Game/app entries for Moonlight
└── systemd/user/
    ├── sway-sunshine.service   # Headless Sway compositor service
    ├── sway-sunshine.service.d/
    │   └── 10-nvidia.conf      # NVIDIA-only drop-in (created when NVIDIA detected)
    └── sunshine-headless.service # Sunshine streaming service
```

## License

MIT — do whatever you want with it, but don't blame us if something breaks.
