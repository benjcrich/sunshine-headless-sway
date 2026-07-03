#!/bin/bash
# Keeps the focused window fullscreen in the headless streaming session.
#
# The for_window rules fullscreen windows when they map, but clients can
# un-fullscreen themselves afterward (games switching to windowed mode,
# emulators like Xenia do this at startup). Sway honors that request and
# the windows fall back to tiling — Steam and the game end up split
# side by side in the stream.
#
# Subscribes to window events and re-enables fullscreen on the focused
# window after every change. "fullscreen enable" is idempotent, so the
# common case is a no-op.
#
# Started from the Sway config via exec; inherits SWAYSOCK from sway.

swaymsg -t subscribe -m '["window"]' | while read -r _; do
    swaymsg -q fullscreen enable 2> /dev/null
done
