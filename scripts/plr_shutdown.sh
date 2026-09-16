#!/bin/bash
# Safe host shutdown after a power-loss capture.
#
# This is called from the capture macro, so it must return immediately:
# Klipper shuts itself down as soon as the TMC drivers lose power, and a
# blocking child would be killed along with it.
#
# setsid puts the worker in its own session so it survives klippy exiting.
# The delay is passed as an argument and the worker body is single-quoted,
# so nothing here is subject to surprise expansion.
set -u

DELAY=__SHUTDOWN_DELAY__

setsid bash -c '
    delay="$1"
    # Give Klipper time to finish writing variables.cfg.
    sleep "$delay"
    # Flush buffers twice so the capture data is really on the card.
    sync
    sleep 1
    sync
    /usr/bin/sudo /sbin/shutdown -h now "Klipper PLR: power loss"
' _ "$DELAY" >/dev/null 2>&1 </dev/null &

exit 0
