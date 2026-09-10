#!/bin/bash
# Klipper PLR installer / updater
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
info(){ echo -e "${B}==>${N} $1"; }
ok(){ echo -e "${G} OK ${N} $1"; }
warn(){ echo -e "${Y}WARN${N} $1"; }
die(){ echo -e "${R}FAIL${N} $1"; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="$HOME"
KLIPPER_DIR="${USER_HOME}/klipper"
CONFIG_DIR="${USER_HOME}/printer_data/config"
GCODE_DIR="${USER_HOME}/printer_data/gcodes"
PLR_DIR="${USER_HOME}/printer_data/plr"
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"
MOONRAKER_CFG="${CONFIG_DIR}/moonraker.conf"
SETTINGS_FILE="${PLR_DIR}/install.conf"
SHELL_EXT="${KLIPPER_DIR}/klippy/extras/gcode_shell_command.py"
SHELL_URL="https://raw.githubusercontent.com/dw-0/kiauh/master/kiauh/extensions/gcode_shell_cmd/assets/gcode_shell_command.py"

[ "$EUID" -eq 0 ] && die "Do not run as root. Run as the Klipper user."
[ -d "$KLIPPER_DIR" ] || die "Klipper not found: $KLIPPER_DIR"
[ -f "$PRINTER_CFG" ] || die "printer.cfg not found: $PRINTER_CFG"
[ -d "$CONFIG_DIR" ] || die "Config directory not found: $CONFIG_DIR"

echo ""
echo "============================================================"
echo "  Klipper PLR - Exact Power Loss Recovery"
echo "============================================================"
echo ""

# Detect multi-instance paths where possible, while keeping the standard
# printer_data layout as the default used by Mainsail installations.
if ! grep -q "file_position" "${KLIPPER_DIR}/klippy/extras/virtual_sdcard.py" 2>/dev/null; then
    die "This Klipper build does not expose virtual_sdcard.file_position. Update Klipper first."
fi
ok "Klipper file_position support detected"

mkdir -p "$PLR_DIR" "$GCODE_DIR/plr"

# Load previous settings for non-interactive Moonraker updates.
PLR_PIN=""; Z_LIFT=""; DEF_BED="60"; DEF_EXT="240"
if [ -f "$SETTINGS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SETTINGS_FILE"
fi

if [ -z "${PLR_PIN:-}" ]; then
    echo "Power-loss detection GPIO (example: PB2):"
    read -r -p "Pin: " PLR_PIN
    [ -n "$PLR_PIN" ] || die "No GPIO pin supplied."
fi

if [ -z "${Z_LIFT:-}" ]; then
    echo ""
    echo "Z_LIFT must be measured on the real printer. Do not guess it."
    echo "Raise Z by exactly 10 mm, restart Klipper, run G28 X0 Y0,"
    echo "measure the actual nozzle height, then subtract 10 mm."
    read -r -p "Z lift in mm: " Z_LIFT
    [ -n "$Z_LIFT" ] || die "No Z lift supplied."
fi

echo "$Z_LIFT" | grep -Eq '^[0-9]+([.][0-9]+)?$' || die "Z_LIFT must be a positive number."

if [ -f "$SETTINGS_FILE" ]; then
    read -r -p "Default bed temperature [${DEF_BED}]: " new_bed || true
    read -r -p "Default nozzle temperature [${DEF_EXT}]: " new_ext || true
    DEF_BED="${new_bed:-$DEF_BED}"
    DEF_EXT="${new_ext:-$DEF_EXT}"
else
    read -r -p "Default bed temperature [60]: " DEF_BED || true
    read -r -p "Default nozzle temperature [240]: " DEF_EXT || true
    DEF_BED="${DEF_BED:-60}"; DEF_EXT="${DEF_EXT:-240}"
fi

cat > "$SETTINGS_FILE" <<EOF
PLR_PIN='$PLR_PIN'
Z_LIFT='$Z_LIFT'
DEF_BED='$DEF_BED'
DEF_EXT='$DEF_EXT'
EOF
chmod 600 "$SETTINGS_FILE"

# Install the external G-Code Shell Command extension only when needed.
# It is not bundled here because KIAUH is GPL-3.0 licensed.
if [ -f "$SHELL_EXT" ]; then
    ok "gcode_shell_command.py already installed"
else
    info "Downloading gcode_shell_command.py from KIAUH..."
    command -v curl >/dev/null 2>&1 || die "curl is required to download gcode_shell_command.py"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL --retry 3 "$SHELL_URL" -o "$tmp" || die "Could not download gcode_shell_command.py"
    grep -q "gcode_shell_command" "$tmp" || die "Downloaded shell command extension looks invalid"
    cp "$tmp" "$SHELL_EXT"
    chmod 644 "$SHELL_EXT"
    ok "gcode_shell_command.py installed"
fi

subst(){
    sed -e "s|__USER_HOME__|${USER_HOME}|g" \
        -e "s|__PLR_PIN__|${PLR_PIN}|g" \
        -e "s|__Z_LIFT__|${Z_LIFT}|g" \
        -e "s|__DEF_BED__|${DEF_BED}|g" \
        -e "s|__DEF_EXT__|${DEF_EXT}|g" "$1" > "$2"
}

info "Installing PLR files..."
subst "$REPO_DIR/config/plr.cfg" "$CONFIG_DIR/plr.cfg.new"
subst "$REPO_DIR/scripts/plr_build.sh" "$PLR_DIR/plr_build.sh.new"
subst "$REPO_DIR/scripts/clear_plr.sh" "$PLR_DIR/clear_plr.sh.new"
chmod +x "$PLR_DIR/plr_build.sh.new" "$PLR_DIR/clear_plr.sh.new"

if [ -f "$CONFIG_DIR/plr.cfg" ]; then
    cp "$CONFIG_DIR/plr.cfg" "$CONFIG_DIR/plr.cfg.bak.$(date +%Y%m%d_%H%M%S)"
fi
mv "$CONFIG_DIR/plr.cfg.new" "$CONFIG_DIR/plr.cfg"
mv "$PLR_DIR/plr_build.sh.new" "$PLR_DIR/plr_build.sh"
mv "$PLR_DIR/clear_plr.sh.new" "$PLR_DIR/clear_plr.sh"
ok "PLR configuration and scripts installed"

# Add include once, before SAVE_CONFIG.
if ! grep -qE '^\[include[[:space:]]+plr\.cfg\]$' "$PRINTER_CFG"; then
    cp "$PRINTER_CFG" "$PRINTER_CFG.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$PRINTER_CFG" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
line='[include plr.cfg]\n\n'
marker='#*# <---------------------- SAVE_CONFIG'
if marker in s:
    i=s.index(marker)
    s=s[:i]+line+s[i:]
else:
    s=s.rstrip()+"\n\n"+line
open(p,'w',encoding='utf-8').write(s)
PY
    ok "Added [include plr.cfg]"
else
    ok "[include plr.cfg] already present"
fi

# Patch END_PRINT only if an END_PRINT macro exists.
cp "$REPO_DIR/scripts/patch_end_print.py" "$PLR_DIR/patch_end_print.py"
chmod +x "$PLR_DIR/patch_end_print.py"
set +e
PATCH_OUT=$(python3 "$PLR_DIR/patch_end_print.py" "$CONFIG_DIR")
PATCH_RC=$?
set -e
case "$PATCH_RC" in
    0) ok "END_PRINT patched: $PATCH_OUT" ;;
    2) ok "END_PRINT already contains PLR cleanup: $PATCH_OUT" ;;
    *) warn "No END_PRINT macro was found. Add the PLR cleanup snippet manually." ;;
esac

# Moonraker Update Manager entry.
if [ -f "$MOONRAKER_CFG" ] && ! grep -q '^\[update_manager klipper-plr\]$' "$MOONRAKER_CFG"; then
    cp "$MOONRAKER_CFG" "$MOONRAKER_CFG.bak.$(date +%Y%m%d_%H%M%S)"
    cat >> "$MOONRAKER_CFG" <<EOF

[update_manager klipper-plr]
type: git_repo
path: ${REPO_DIR}
origin: https://github.com/Novin3dp/klipper-plr.git
primary_branch: main
managed_services: klipper
install_script: install.sh
EOF
    ok "Moonraker Update Manager entry added"
fi

# Make repository-local installer updates work even if the file was cloned
# without executable metadata.
chmod +x "$REPO_DIR/install.sh" 2>/dev/null || true

info "Installation files are ready."
echo ""
echo "Next: RESTART"
echo "Then: QUERY_BUTTON BUTTON=power_loss"
echo "Then: PLR_STATUS"
echo ""
echo "Before a real print, follow TESTING.md and perform the dry run."
echo ""
