#!/bin/bash
# Build a recovery G-code file from the exact saved power-loss position.
set -u

USER_HOME="__USER_HOME__"
Z_LIFT=__Z_LIFT__
DEFAULT_BED=__DEF_BED__
DEFAULT_EXT=__DEF_EXT__

GCODE_DIR="${USER_HOME}/printer_data/gcodes"
PLR_PATH="${GCODE_DIR}/plr"
VARIABLES_FILE="${USER_HOME}/printer_data/config/variables.cfg"
PRINTER_CFG="${USER_HOME}/printer_data/config/printer.cfg"

mkdir -p "$PLR_PATH"

getvar() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'\?\([^']*\)'\?[[:space:]]*$/\1/p" \
        "$VARIABLES_FILE" | head -1
}

SRC=$(getvar plr_path)
FPOS=$(getvar plr_fpos)
RX=$(getvar plr_x)
RY=$(getvar plr_y)
RZ=$(getvar plr_z)
RE=$(getvar plr_e)

[ -z "$SRC" ] && { echo "ERROR: plr_path empty"; exit 1; }
[ ! -f "$SRC" ] && { echo "ERROR: file not found: $SRC"; exit 1; }
[ -z "$FPOS" ] || [ "$FPOS" = "0" ] && { echo "ERROR: plr_fpos invalid"; exit 1; }

echo "Source: $SRC"
echo "FPOS:   $FPOS"
echo "X=$RX Y=$RY Z=$RZ E=$RE"

BASENAME=$(basename "$SRC")
RESUME_FILE="${PLR_PATH}/${BASENAME}"

LAYER_Z=$(head -c "$FPOS" "$SRC" | grep -o "^;Z:[0-9.]\+" | tail -1 | cut -d: -f2)
[ -z "$LAYER_Z" ] && LAYER_Z="$RZ"

echo "Layer Z: $LAYER_Z"

START_LINE=$(grep -m1 '^[[:space:]]*START_PRINT' "$SRC" || true)
BED_TEMP=$(printf '%s\n' "$START_LINE" | sed -n 's/.*BED_TEMP=\([0-9.]*\).*/\1/p')
EXT_TEMP=$(printf '%s\n' "$START_LINE" | sed -n 's/.*EXTRUDER_TEMP=\([0-9.]*\).*/\1/p')
[ -z "$BED_TEMP" ] && BED_TEMP=$DEFAULT_BED
[ -z "$EXT_TEMP" ] && EXT_TEMP=$DEFAULT_EXT

echo "Bed: $BED_TEMP  Ext: $EXT_TEMP"

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

rm -f "$RESUME_FILE"
{
    echo "M118 PLR START"
    echo "M82"
    echo "M140 S${BED_TEMP}"
    echo "M190 S${BED_TEMP}"
    echo "M104 S${EXT_TEMP}"
    echo "M109 S${EXT_TEMP}"
    echo "G28 X0 Y0"
    echo "SET_KINEMATIC_POSITION Z=${SAFE_Z}"
    echo "G1 X${RX} Y${RY} F6000"
    echo "G1 Z${LAYER_Z} F600"
    echo "G92 E${RE}"
    echo "M118 PLR RESUMING"
} >> "$RESUME_FILE"

tail -c +$((FPOS + 1)) "$SRC" | awk '
/^[[:space:]]*;/ {next}
/^[[:space:]]*$/ {next}
/^[[:space:]]*[GM][0-9]+([[:space:]]|$)/ {print;next}
/^[[:space:]]*SET_[A-Z_]+([[:space:]]|$)/ {print;next}
/^[[:space:]]*(END_PRINT|PLR_SAVE_LAYER)([[:space:]]|$)/ {print;next}
' >> "$RESUME_FILE"

chmod 644 "$RESUME_FILE"
echo "Created: $RESUME_FILE"
wc -l "$RESUME_FILE"
