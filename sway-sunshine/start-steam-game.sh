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
