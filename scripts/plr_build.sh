#!/bin/bash
# Build a recovery G-code file from the exact saved power-loss position.
set -u

USER_HOME="__USER_HOME__"
Z_LIFT=__Z_LIFT__
DEFAULT_BED=__DEF_BED__
DEFAULT_EXT=__DEF_EXT__

GCODE_DIR="${USER_HOME}/printer_data/gcodes"
PLR_PATH="${GCODE_DIR}/plr"
PLR_DIR="${USER_HOME}/printer_data/plr"
VARIABLES_FILE="${USER_HOME}/printer_data/config/variables.cfg"
PRINTER_CFG="${USER_HOME}/printer_data/config/printer.cfg"

SNAP=""
PART=""
cleanup() {
    [ -n "$SNAP" ] && rm -f "$SNAP"
    [ -n "$PART" ] && rm -f "$PART"
    return 0
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*"
    echo "PLR: recovery file NOT created."
    exit 1
}

mkdir -p "$PLR_PATH" "$PLR_DIR"

# ------------------------------------------------------------------
# Read the saved variables.
#
# Klipper's save_variables stores Python reprs, so the quoting depends on the
# content: a name containing an apostrophe is written in double quotes. A sed
# pattern cannot cover every case, so configparser + ast.literal_eval does the
# parsing and hands back shell-quoted assignments.
# ------------------------------------------------------------------
SRC=""; FPOS=""; RX=""; RY=""; RZ=""; RE=""

eval "$(python3 - "$VARIABLES_FILE" <<'PYEOF'
import ast
import configparser
import shlex
import sys

WANTED = {
    "plr_path": "SRC",
    "plr_fpos": "FPOS",
    "plr_x": "RX",
    "plr_y": "RY",
    "plr_z": "RZ",
    "plr_e": "RE",
}

out = {var: "" for var in WANTED.values()}
cfg = configparser.ConfigParser()
try:
    cfg.read(sys.argv[1], encoding="utf-8")
except Exception:
    pass

for section in cfg.sections():
    for key, var in WANTED.items():
        if cfg.has_option(section, key):
            raw = cfg.get(section, key)
            try:
                value = ast.literal_eval(raw)
            except (ValueError, SyntaxError):
                value = raw
            out[var] = str(value)

for var, value in out.items():
    print("%s=%s" % (var, shlex.quote(value)))
PYEOF
)" || fail "could not read ${VARIABLES_FILE}"

[ -n "$SRC" ] || fail "plr_path empty - nothing was captured"
[ "$SRC" != "None" ] || fail "plr_path is 'None' - the capture ran while idle"
[ -f "$SRC" ] || fail "file not found: $SRC"
case "$FPOS" in
    ''|*[!0-9]*) fail "plr_fpos is not a number: '$FPOS'" ;;
esac
[ "$FPOS" -gt 0 ] || fail "plr_fpos is 0 - nothing to resume"

echo "Source: $SRC"
echo "FPOS:   $FPOS"
echo "X=$RX Y=$RY Z=$RZ E=$RE"

BASENAME=$(basename "$SRC")
RESUME_FILE="${PLR_PATH}/${BASENAME}"

# ------------------------------------------------------------------
# Chained recovery.
#
# If power is lost again during a recovery print, the captured path is the
# resume file itself - which is also where this script writes. Rebuilding in
# place would delete the source mid-read and leave a header with no moves, so
# take a snapshot and read from that instead.
# ------------------------------------------------------------------
if [ -e "$RESUME_FILE" ] && [ "$SRC" -ef "$RESUME_FILE" ]; then
    echo "Chained recovery: the source IS the current resume file"
    SNAP="${PLR_DIR}/.plr_source.$$"
    cp "$SRC" "$SNAP" || fail "could not snapshot the source file"
    SRC="$SNAP"
    echo "Snapshot taken, rebuilding from it"
fi

[ "$FPOS" -le "$(wc -c < "$SRC")" ] || fail "plr_fpos ($FPOS) is past the end of the file"

# ------------------------------------------------------------------
# Real layer height.
#
# The captured Z may be mid z-hop, so the layer comment written before the cut
# point is the reliable source.
# ------------------------------------------------------------------
LAYER_Z=$(head -c "$FPOS" "$SRC" | grep -o "^;Z:[0-9.]\+" | tail -1 | cut -d: -f2)
if [ -z "$LAYER_Z" ]; then
    LAYER_Z="$RZ"
    echo "WARNING: no ';Z:' layer comment before the cut point."
    echo "         Falling back to the captured Z (${RZ}), which may be a"
    echo "         z-hop height rather than the real layer height. Check the"
    echo "         'G1 Z' line in the resume file before starting the print."
fi
echo "Layer Z: $LAYER_Z"

# ------------------------------------------------------------------
# Extrusion mode.
#
# With M83 the body carries relative deltas, so the absolute E position is
# irrelevant and restoring it would be wrong.
# ------------------------------------------------------------------
E_MODE=$(head -c "$FPOS" "$SRC" | awk '
/^[[:space:]]*M82([[:space:]]|$)/ { m = "M82" }
/^[[:space:]]*M83([[:space:]]|$)/ { m = "M83" }
END { if (m != "") print m }
')
[ -z "$E_MODE" ] && E_MODE="M82"
echo "E mode: $E_MODE"

# ------------------------------------------------------------------
# Temperatures from START_PRINT.
# ------------------------------------------------------------------
START_LINE=$(grep -m1 '^[[:space:]]*START_PRINT' "$SRC" || true)
BED_TEMP=$(printf '%s\n' "$START_LINE" | sed -n 's/.*BED_TEMP=\([0-9.]*\).*/\1/p')
EXT_TEMP=$(printf '%s\n' "$START_LINE" | sed -n 's/.*EXTRUDER_TEMP=\([0-9.]*\).*/\1/p')
[ -z "$BED_TEMP" ] && BED_TEMP=$DEFAULT_BED
[ -z "$EXT_TEMP" ] && EXT_TEMP=$DEFAULT_EXT
echo "Bed: $BED_TEMP  Ext: $EXT_TEMP"

# ------------------------------------------------------------------
# Last part-cooling fan state before the cut point.
#
# M106 sits earlier in the file than FPOS, so it is not part of the resumed
# body and the fan would otherwise stay off for the rest of the print.
# Secondary fans (P1, P2 ...) are skipped - only the default part fan.
# ------------------------------------------------------------------
FAN_CMD=$(head -c "$FPOS" "$SRC" | awk '
/^[[:space:]]*M107([[:space:]]|$)/ { last = "M107"; next }
/^[[:space:]]*M106([[:space:]]|$)/ {
    if ($0 ~ /[[:space:]]P[1-9]/) next
    line = $0
    sub(/[[:space:]]*;.*$/, "", line)
    sub(/[[:space:]]+$/, "", line)
    last = line
    next
}
END { if (last != "") print last }
')

if [ -n "$FAN_CMD" ]; then
    echo "Fan:    $FAN_CMD"
else
    echo "Fan:    none found before cut point"
fi

# ------------------------------------------------------------------
# Height guard.
#
# SAFE_Z must express the real physical height after homing. Clamping it would
# point the nozzle at the wrong place, so an unreachable height is refused.
# ------------------------------------------------------------------
Z_MAX=$(awk '/^\[stepper_z\]/{inz=1;next}/^\[/{inz=0}inz && /^[[:space:]]*position_max[[:space:]]*:/{sub(/.*:[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit}' "$PRINTER_CFG")
[ -z "$Z_MAX" ] && Z_MAX=300
SAFE_Z=$(awk -v z="$LAYER_Z" -v l="$Z_LIFT" 'BEGIN{printf "%.3f",z+l}')

echo "Z max:  $Z_MAX"
echo "Safe Z: $SAFE_Z"

if awk -v s="$SAFE_Z" -v zm="$Z_MAX" 'BEGIN{exit !(s>zm)}'; then
    echo "ERROR: Safe Z ($SAFE_Z) exceeds Z max ($Z_MAX)"
    echo "Resume at this height is not safe. Manual intervention required."
    exit 1
fi

# ------------------------------------------------------------------
# Build into a temporary file.
#
# The existing resume file is only replaced once the new one is known to hold
# real moves, so a failed build never destroys a working recovery.
# ------------------------------------------------------------------
PART="${PLR_DIR}/.plr_build.$$"
: > "$PART" || fail "could not create the build file"

# Preview image: Moonraker extracts thumbnails only when it can identify the
# slicer, so the original header is copied verbatim - signature and thumbnail
# blocks together. Comment lines only, so nothing executable can slip in.
THUMB_END=$(head -n 5000 "$SRC" | grep -nE '^;[[:space:]]*thumbnail[^ ]* end' | tail -1 | cut -d: -f1)
if [ -n "$THUMB_END" ]; then
    head -n "$THUMB_END" "$SRC" | grep -E '^[[:space:]]*;' >> "$PART"
    echo "Preview: header copied (${THUMB_END} lines)"
else
    echo "Preview: no thumbnail block found"
fi

{
    echo "M118 PLR START"
    echo "$E_MODE"
    echo "M140 S${BED_TEMP}"
    echo "M190 S${BED_TEMP}"
    echo "M104 S${EXT_TEMP}"
    echo "M109 S${EXT_TEMP}"
    echo "G28 X0 Y0"
    echo "SET_KINEMATIC_POSITION Z=${SAFE_Z}"
    echo "G1 X${RX} Y${RY} F6000"
    echo "G1 Z${LAYER_Z} F600"
    if [ "$E_MODE" = "M83" ]; then
        echo "G92 E0"
    else
        echo "G92 E${RE}"
    fi
    [ -n "$FAN_CMD" ] && echo "$FAN_CMD"
    echo "M118 PLR RESUMING"
} >> "$PART"

BODY_LINES=$(tail -c +$((FPOS + 1)) "$SRC" | awk '
# Layer markers are kept so that a second power loss during this recovery can
# still read the real layer height instead of falling back to the captured Z.
/^;Z:[0-9.]+$/ {print;next}
/^[[:space:]]*;/ {next}
/^[[:space:]]*$/ {next}
/^[[:space:]]*[GM][0-9]+([[:space:]]|$)/ {print;next}
/^[[:space:]]*SET_[A-Z_]+([[:space:]]|$)/ {print;next}
/^[[:space:]]*(END_PRINT|PLR_SAVE_LAYER)([[:space:]]|$)/ {print;next}
' | tee -a "$PART" | wc -l)

# A read error here is silent - tail through a pipe still reports success - so
# the body is counted rather than trusted.
if [ "$BODY_LINES" -lt 1 ]; then
    fail "the resume body is empty; nothing to print after byte ${FPOS}"
fi

if ! grep -q '^[[:space:]]*END_PRINT' "$PART"; then
    echo "WARNING: no END_PRINT in the resume file - heaters will stay on"
    echo "         when it finishes. Run END_PRINT by hand afterwards."
fi

mv "$PART" "$RESUME_FILE" || fail "could not install the resume file"
PART=""
chmod 644 "$RESUME_FILE"

# Klipper splits extended parameters with shlex, so the name is single-quoted
# and any apostrophe in it is escaped the way a shell would.
QUOTED=${BASENAME//\'/\'\\\'\'}

echo "----------------------------------------"
echo "PLR: recovery file ready  (${BODY_LINES} G-code lines)"
echo "  plr/${BASENAME}"
echo ""
echo "  Start it with:   PLR_RESUME"
echo "  or:              SDCARD_PRINT_FILE FILENAME='plr/${QUOTED}'"
echo "----------------------------------------"
exit 0
