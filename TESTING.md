# Klipper PLR testing procedure

Do not skip the dry run. Power-loss recovery moves an unhomed machine and must be validated on the actual printer.

## 1. Configuration

After installation, run:

```text
RESTART
```

Fix every configuration error before continuing.

## 2. Detection input

With normal printer power present:

```text
QUERY_BUTTON BUTTON=power_loss
```

Expected result: `RELEASED`.

Cut the printer's main power while backup power remains available. The console should show:

```text
PLR CAPTURE OK
```

If the state is inverted, change `pin: !PB2` in `plr.cfg` to `pin: PB2` (or vice versa) and restart Klipper.

## 3. Verify the captured position

Start a small print and wait until the toolhead has moved several times. Run:

```text
PLR_CAPTURE_POSITION
```

Let the print continue, then cancel it. Inspect:

```bash
cat ~/printer_data/config/variables.cfg
```

Confirm that `plr_x`, `plr_y`, `plr_z`, `plr_e`, `plr_fpos` and `plr_path` contain the expected values.

The exact byte position should end on a G-code line boundary. A useful check is:

```bash
POS=<plr_fpos>
F=<full-path-to-gcode>
head -c "$POS" "$F" | tail -2
```

Do not continue if the captured position does not match the expected last executed line.

## 4. Build the recovery file

```bash
~/printer_data/plr/plr_build.sh
ls -lh ~/printer_data/gcodes/plr/
```

Read the script's own output. It reports the layer height it chose, the
extrusion mode, the fan state, whether a preview was copied, and finally how to
start the file. Any warning it prints is worth reading before you continue.

Then inspect the generated header. Thumbnail comments come first, so skip to the
real header:

```bash
sed -n '/^M118 PLR START/,/^M118 PLR RESUMING/p' ~/printer_data/gcodes/plr/<file>.gcode
tail -5 ~/printer_data/gcodes/plr/<file>.gcode
```

Check that it homes X/Y first, establishes safe Z, moves X/Y at that safe
height, and only then lowers Z to the saved layer height. The tail must contain
`END_PRINT` — without it the heaters stay on when the recovery finishes.

## 5. Dry run — no filament

Clear the bed. Remove filament if practical. Keep your hand on the power switch.

Create a no-heat copy of the generated recovery file:

```bash
cd ~/printer_data/gcodes/plr
grep -vE '^(M104|M109|M140|M190)' <file>.gcode > DRYRUN.gcode
```

Restart Klipper and run:

```text
SDCARD_PRINT_FILE FILENAME=plr/DRYRUN.gcode
```

Watch the first movements carefully:

1. Z moves to the calculated safe height.
2. X/Y home.
3. X/Y travel to the saved coordinates while Z remains safe.
4. Z lowers to the saved layer height.
5. E is restored.

If Z moves toward the bed unexpectedly, cut power immediately.

Stopping later with an extrusion-temperature error is acceptable for this no-heat test; the purpose is to validate the motion order.

## 6. Full power-loss test

Only after the dry run passes:

1. Load filament.
2. Start a small print.
3. Cut the printer's main power at a known mid-print point.
4. Restore power.
5. Run `FIRMWARE_RESTART`.
6. Check `PLR_STATUS`.
7. Run `PLR_RESUME`.
8. Watch the entire recovery movement.

At the end, the console should show the PLR cleanup message and `PLR_STATUS` should show zero/empty recovery data.

## 7. Test cancellation behavior

Start a recovery and cancel it before completion. Verify that the recovery data remains available. This is intentional: cancellation must not falsely mark a recovery as completed.

Use `PLR_FORCE_CLEAR` only when you deliberately want to discard a pending recovery.

## 8. Power loss while idle

With no print running, cut power. The console should show:

```text
PLR power loss while idle - nothing to recover
```

Then restart Klipper. Nothing should be announced, and `PLR_STATUS` should still
read all zeros. A false recovery here is a bug: it would overwrite real recovery
data the next time it mattered.

## 9. Chained recovery (optional, but worth doing once)

Start a recovery print and cut power again part-way through it. After restarting,
the build script should print:

```text
Chained recovery: the source IS the current resume file
Snapshot taken, rebuilding from it
```

Verify the rebuilt file still has a real body and still ends with `END_PRINT`:

```bash
wc -l ~/printer_data/gcodes/plr/<file>.gcode
tail -3 ~/printer_data/gcodes/plr/<file>.gcode
```

A file that shrank to roughly a dozen lines means the source was destroyed
during the rebuild — stop and report it.
