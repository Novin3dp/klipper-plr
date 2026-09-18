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
PLR_SHUTDOWN=""; SHUTDOWN_DELAY=""
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

# Only ask on a first install. A re-run - including an unattended one from
# Moonraker's update manager - keeps what is already stored.
if [ -f "$SETTINGS_FILE" ]; then
    ok "Using saved settings (pin ${PLR_PIN}, Z lift ${Z_LIFT}mm, bed ${DEF_BED}, nozzle ${DEF_EXT})"
    echo "    To change them: edit ${SETTINGS_FILE} and re-run this script."
else
    read -r -p "Default bed temperature [60]: " DEF_BED || true
    read -r -p "Default nozzle temperature [240]: " DEF_EXT || true
    DEF_BED="${DEF_BED:-60}"; DEF_EXT="${DEF_EXT:-240}"
fi

if [ -z "${PLR_SHUTDOWN:-}" ]; then
    echo ""
    echo "Safe host shutdown on power loss"
    echo "--------------------------------"
    echo "Halts the Pi after the capture so the SD card is not corrupted"
    echo "by the power cut. Requires a passwordless sudo rule for shutdown."
    echo ""
    echo "Only enable this if your backup power holds the host up long"
    echo "enough to halt (roughly 15 seconds or more)."
    echo ""
    read -r -p "Enable safe shutdown? [y/N]: " ans || true
    case "$ans" in
        [Yy]*) PLR_SHUTDOWN=1 ;;
        *)     PLR_SHUTDOWN=0 ;;
    esac
fi

if [ "$PLR_SHUTDOWN" = "1" ] && [ -z "${SHUTDOWN_DELAY:-}" ]; then
    read -r -p "Seconds to wait before halting [3]: " SHUTDOWN_DELAY || true
    SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-3}"
fi
SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-3}"
echo "$SHUTDOWN_DELAY" | grep -Eq '^[0-9]+$' || die "Shutdown delay must be a whole number of seconds."

cat > "$SETTINGS_FILE" <<EOF
PLR_PIN='$PLR_PIN'
PLR_SHUTDOWN='$PLR_SHUTDOWN'
SHUTDOWN_DELAY='$SHUTDOWN_DELAY'
Z_LIFT='$Z_LIFT'
DEF_BED='$DEF_BED'
DEF_EXT='$DEF_EXT'
EOF
chmod 600 "$SETTINGS_FILE"

# Install the external G-Code Shell Command extension only when needed.
# It is not bundled here because KIAUH is GPL-3.0 licensed.
#
# A local KIAUH checkout is preferred over downloading: it is faster, works
# offline, and matches the version the user already has.
shell_ext_valid() {
    grep -q "load_config_prefix" "$1" 2>/dev/null
}

if [ -f "$SHELL_EXT" ]; then
    ok "gcode_shell_command.py already installed"
else
    installed=0

    for candidate in \
        "${USER_HOME}/kiauh/kiauh/extensions/gcode_shell_cmd/assets/gcode_shell_command.py" \
        "${USER_HOME}/kiauh/resources/gcode_shell_command.py"
    do
        if [ -f "$candidate" ] && shell_ext_valid "$candidate"; then
            info "Using local KIAUH copy..."
            cp "$candidate" "$SHELL_EXT"
            chmod 644 "$SHELL_EXT"
            ok "gcode_shell_command.py installed from ${candidate}"
            installed=1
            break
        fi
    done

    if [ "$installed" -eq 0 ]; then
        info "Downloading gcode_shell_command.py from KIAUH..."
        command -v curl >/dev/null 2>&1 || die "curl is required to download gcode_shell_command.py"
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        curl -fsSL --retry 3 "$SHELL_URL" -o "$tmp" \
            || die "Could not download gcode_shell_command.py from ${SHELL_URL}"

        if ! shell_ext_valid "$tmp"; then
            echo -e "${R}FAIL${N} The downloaded file is not a valid Klipper extension."
            echo ""
            echo "The KIAUH repository layout may have changed."
            echo "Install the extension manually, then re-run this script:"
            echo ""
            echo "  through KIAUH:  Advanced -> G-Code Shell Command"
            echo ""
            echo "  or, if you already have KIAUH cloned:"
            echo "    cp ~/kiauh/kiauh/extensions/gcode_shell_cmd/assets/gcode_shell_command.py \\"
            echo "       ${SHELL_EXT}"
            echo ""
            exit 1
        fi

        cp "$tmp" "$SHELL_EXT"
        chmod 644 "$SHELL_EXT"
        ok "gcode_shell_command.py installed"
    fi
fi

subst(){
    sed -e "s|__USER_HOME__|${USER_HOME}|g" \
        -e "s|__PLR_PIN__|${PLR_PIN}|g" \
        -e "s|__Z_LIFT__|${Z_LIFT}|g" \
        -e "s|__DEF_BED__|${DEF_BED}|g" \
        -e "s|__DEF_EXT__|${DEF_EXT}|g" \
        -e "s|__SHUTDOWN_DELAY__|${SHUTDOWN_DELAY}|g" "$1" > "$2"
}

info "Installing PLR files..."
subst "$REPO_DIR/config/plr.cfg" "$CONFIG_DIR/plr.cfg.new"
subst "$REPO_DIR/scripts/plr_build.sh" "$PLR_DIR/plr_build.sh.new"
subst "$REPO_DIR/scripts/clear_plr.sh" "$PLR_DIR/clear_plr.sh.new"
subst "$REPO_DIR/scripts/plr_shutdown.sh" "$PLR_DIR/plr_shutdown.sh.new"
chmod +x "$PLR_DIR/plr_build.sh.new" "$PLR_DIR/clear_plr.sh.new" "$PLR_DIR/plr_shutdown.sh.new"

if [ -f "$CONFIG_DIR/plr.cfg" ]; then
    cp "$CONFIG_DIR/plr.cfg" "$CONFIG_DIR/plr.cfg.bak.$(date +%Y%m%d_%H%M%S)"
fi
mv "$CONFIG_DIR/plr.cfg.new" "$CONFIG_DIR/plr.cfg"
mv "$PLR_DIR/plr_build.sh.new" "$PLR_DIR/plr_build.sh"
mv "$PLR_DIR/clear_plr.sh.new" "$PLR_DIR/clear_plr.sh"
mv "$PLR_DIR/plr_shutdown.sh.new" "$PLR_DIR/plr_shutdown.sh"
ok "PLR configuration and scripts installed"

# ============================================================
# Safe host shutdown (optional)
# ============================================================
SUDOERS_FILE="/etc/sudoers.d/klipper-plr"

if [ "$PLR_SHUTDOWN" = "1" ]; then
    # Ask for sudo up front and let the prompt be visible. Hiding stderr here
    # swallows the password prompt and the script looks like it has hung.
    have_sudo=0
    if sudo -n true 2>/dev/null; then
        have_sudo=1
    else
        echo ""
        info "The shutdown rule needs root. You may be asked for your password."
        if sudo -v; then
            have_sudo=1
        fi
    fi

    if [ "$have_sudo" -eq 1 ]; then
        tmp_sudo="$(mktemp)"
        printf '%s ALL=(root) NOPASSWD: /sbin/shutdown\n' "$(id -un)" > "$tmp_sudo"

        # visudo -c refuses to install a broken rule, which would otherwise
        # lock the user out of sudo entirely.
        if sudo visudo -c -f "$tmp_sudo" >/dev/null 2>&1; then
            sudo install -m 0440 -o root -g root "$tmp_sudo" "$SUDOERS_FILE"
            ok "Passwordless shutdown rule installed"
        else
            warn "Generated sudoers rule failed validation - shutdown disabled"
            PLR_SHUTDOWN=0
        fi
        rm -f "$tmp_sudo"
    else
        warn "No sudo access - cannot install the shutdown rule"
        PLR_SHUTDOWN=0
    fi
fi

if [ "$PLR_SHUTDOWN" != "1" ]; then
    # Comment the shutdown call out of the installed config.
    sed -i \
        -e 's|^\( *\)M118 PLR shutting down host|\1#M118 PLR shutting down host|' \
        -e 's|^\( *\)RUN_SHELL_COMMAND CMD=PLR_SHUTDOWN|\1#RUN_SHELL_COMMAND CMD=PLR_SHUTDOWN|' \
        "${CONFIG_DIR}/plr.cfg"
    ok "Safe shutdown disabled (host stays powered after capture)"
fi

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
