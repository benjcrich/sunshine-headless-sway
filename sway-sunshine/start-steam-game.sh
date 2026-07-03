#!/bin/bash
# Launches a Steam game in the headless Sway session
# Usage: start-steam-game.sh <appid|bigpicture|0>
# Migrates Steam from the main desktop if it's running there

APPID="$1"
SWAYSOCK="/run/user/$(id -u)/sway-sunshine.sock"
export SWAYSOCK

# Note: env vars exported here do NOT propagate through `swaymsg exec`.
# That's because swaymsg sends an IPC message to sway, which spawns the
# command under sway's process tree — children inherit sway's env, not
# the env of whoever called swaymsg. Multi-GPU GPU selection
# (VK_DRIVER_FILES) lives in the sway-sunshine.service Environment
# (or the install.sh-generated NVIDIA drop-in) where it actually applies.

if [ -z "$APPID" ]; then
    echo "Usage: $0 <steam_appid|bigpicture|0>"
    exit 1
fi

# Shut down any running Steam instance
if pgrep -x steam > /dev/null 2>&1; then
    steam -shutdown 2>/dev/null
    # Wait for graceful shutdown
    for i in $(seq 1 15); do
        pgrep -x steam > /dev/null 2>&1 || break
        sleep 1
    done
    # Force kill only if still running
    if pgrep -x steam > /dev/null 2>&1; then
        pkill -x steam 2>/dev/null
        sleep 2
    fi
fi

# Clean up Steam IPC to prevent instance detection
rm -f ~/.steam/steam.pid 2>/dev/null
rm -f /tmp/steam_singleton_* 2>/dev/null

# Launch Steam in the headless Sway session
if [ "$APPID" = "bigpicture" ]; then
    swaymsg exec "steam steam://open/bigpicture"
elif [ "$APPID" = "0" ]; then
    swaymsg exec steam
else
    swaymsg exec "steam -applaunch $APPID"
fi

# steamwebhelper keeps rendering at its pre-resize size (1280x800) when sway
# fullscreens the window at map time, leaving the UI small in the top-left
# corner of the stream. Once the Steam window appears, cycle it through
# floating and back to force a resize event so CEF repaints at output size.
(
    for _ in $(seq 1 60); do
        sleep 1
        if swaymsg -t get_tree | grep -q '"class": "steam"'; then
            sleep 2
            swaymsg '[class="^steam$"] fullscreen disable, floating enable' > /dev/null
            sleep 1
            swaymsg '[class="^steam$"] floating disable, fullscreen enable' > /dev/null
            break
        fi
    done
) &
