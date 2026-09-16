#!/bin/bash
set -euo pipefail

USER_HOME="$HOME"
CONFIG_DIR="${USER_HOME}/printer_data/config"
PLR_DIR="${USER_HOME}/printer_data/plr"
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"
MOONRAKER_CFG="${CONFIG_DIR}/moonraker.conf"

[ "$EUID" -eq 0 ] && { echo "Do not run as root."; exit 1; }

read -r -p "Remove Klipper PLR installation? [y/N]: " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

stamp=$(date +%Y%m%d_%H%M%S)

if [ -f "$PRINTER_CFG" ]; then
    cp "$PRINTER_CFG" "$PRINTER_CFG.bak.$stamp"
    sed -i '/^\[include[[:space:]]\+plr\.cfg\]$/d' "$PRINTER_CFG"
fi

if [ -f "$MOONRAKER_CFG" ]; then
    cp "$MOONRAKER_CFG" "$MOONRAKER_CFG.bak.$stamp"
    python3 - "$MOONRAKER_CFG" <<'PY'
import re, sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
s=re.sub(r'\n?\[update_manager klipper-plr\]\n(?:[^\n]*\n)*?(?=\n\[|\Z)', '\n', s)
open(p,'w',encoding='utf-8').write(s)
PY
fi

rm -f "$CONFIG_DIR/plr.cfg"
rm -rf "$PLR_DIR"
rm -rf "${USER_HOME}/printer_data/gcodes/plr"

if [ -f /etc/sudoers.d/klipper-plr ]; then
    sudo rm -f /etc/sudoers.d/klipper-plr && echo "Removed sudoers rule"
fi

echo "Klipper PLR files removed."
echo "The END_PRINT snippet and gcode_shell_command.py were left untouched."
echo "A printer.cfg/moonraker.conf backup was created before removal."
echo "Run RESTART when ready."
