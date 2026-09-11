# Klipper PLR

**Exact Power Loss Recovery for Klipper**

Klipper PLR records the toolhead position, extruder position, G-code file path and the exact `virtual_sdcard.file_position` at the moment a configured power-loss input changes state. After restart it builds a recovery G-code file that returns the machine to the saved physical height and continues from the saved byte position.

> **Important:** Power-loss recovery is hardware-dependent. A backup supply/supercapacitor must keep the host and MCU alive long enough for the capture macro to execute. Test thoroughly before relying on it for valuable prints.

## Features

- Exact file-position recovery rather than replaying a complete layer.
- Saves X/Y/Z/E, file path and file offset in Klipper `save_variables`.
- Layer-height checkpoint as a secondary recovery aid.
- Automatic recovery-file generation after restart.
- Automatic cleanup after a recovery print reaches `END_PRINT`.
- Idempotent installer with backups.
- Moonraker Update Manager integration.
- Works with G-code stored in the normal `printer_data/gcodes` directory, including files copied from USB storage.

## Requirements

- Klipper with `virtual_sdcard.file_position` support.
- Moonraker plus Mainsail or Fluidd.
- A free MCU GPIO connected to a power-loss detection circuit.
- Backup power that keeps the host and MCU alive during the detection/capture window.
- Absolute extrusion (`M82`).

### G-Code Shell Command extension

This is required, and is not bundled here because KIAUH is GPL-3.0 licensed
while this repository is MIT.

The installer handles it for you, in this order:

1. If it is already in `~/klipper/klippy/extras/`, nothing happens.
2. If you have KIAUH cloned, the local copy is used. No network needed.
3. Otherwise it is downloaded from the KIAUH repository.

If the download fails or the KIAUH layout has changed, install it yourself
and re-run `install.sh`:

```bash
# through KIAUH:  Advanced -> G-Code Shell Command
# or, if KIAUH is already cloned:
cp ~/kiauh/kiauh/extensions/gcode_shell_cmd/assets/gcode_shell_command.py \
   ~/klipper/klippy/extras/
```

Note that updating Klipper can remove this extension. If PLR suddenly stops
working after a Klipper update with `Unknown config object
'gcode_shell_command'`, reinstall it the same way.

## Installation

```bash
git clone https://github.com/Novin3dp/klipper-plr.git
cd klipper-plr
./install.sh
```

If the cloned files do not have executable metadata on your system, use:

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

The installer automatically detects the current user and standard Klipper/Moonraker paths. On a fresh installation it asks only for:

1. **Power-loss GPIO**, for example `PB2`.
2. **Z lift**, measured on the actual printer.

The installer also asks for optional default bed/nozzle temperatures. Existing settings are stored locally in `printer_data/plr/install.conf`, so future Moonraker updates can reuse them.

### Measuring Z lift

Do not guess this value. A wrong value can cause a nozzle collision.

1. Remove the print from the bed.
2. Home all axes and bring the nozzle to the bed.
3. Raise Z exactly 10 mm.
4. Restart Klipper so the MCU position is forgotten.
5. Run `G28 X0 Y0`.
6. Measure the actual nozzle-to-bed distance.
7. `Z_LIFT = measured distance - 10`.

If you cannot safely measure this value, abort the installer and measure it first.

## Slicer setup

The installer cannot edit a slicer profile reliably, so these two settings remain manual:

### 1. Use absolute extrusion

Disable relative E distances / enable `M82` behavior in the printer profile.

### 2. Add a layer checkpoint

In **Before layer change G-code**, add the equivalent of:

```gcode
;BEFORE_LAYER_CHANGE
;[layer_z]
PLR_SAVE_LAYER Z=[layer_z]
```

The exact placeholder syntax depends on the slicer. OrcaSlicer/PrusaSlicer profiles commonly expose the layer height as `[layer_z]`.

## Verification

After installation:

```text
RESTART
QUERY_BUTTON BUTTON=power_loss
PLR_STATUS
```

With normal printer power present, the input should report `RELEASED`. If the electrical logic is inverted, change the `!` polarity in `~/printer_data/config/plr.cfg` and restart Klipper.

Before a real print, follow **TESTING.md** and perform the dry run with the bed clear and no filament.

## Recovery workflow

During a print, the configured power-loss input triggers `PLR_CAPTURE_POSITION`. The macro stores:

- X/Y/Z/E
- G-code file path
- exact file offset
- a recovery-pending flag

After the printer is powered back on and Klipper is restarted, a delayed macro builds a file under:

```text
~/printer_data/gcodes/plr/
```

The console then shows the recovery file name and the command to start it:

```text
SDCARD_PRINT_FILE FILENAME=plr/<file>.gcode
```

After a successful recovery print, the `END_PRINT` patch schedules automatic cleanup.

## Commands

| Command | Purpose |
|---|---|
| `PLR_STATUS` | Display saved recovery information |
| `PLR_CAPTURE_POSITION` | Manually capture the current position for testing |
| `PLR_SAVE_LAYER Z=...` | Store a layer-height checkpoint |
| `G31` | Clear PLR data when no recovery is pending |
| `PLR_FORCE_CLEAR` | Force-clear PLR data |

## Safety notes

- Never assume a recovery is safe until the dry run has been completed on the actual printer.
- Do not touch or manually move the machine after power loss unless your recovery procedure explicitly accounts for it.
- Recovery near the Z travel limit is refused instead of silently clamping the height.
- The resume builder deliberately moves X/Y before lowering Z to the saved layer height.
- Bed mesh is not automatically restored by the generated recovery header; add the appropriate mesh-load command if your machine requires it.
- If a recovery is cancelled midway, PLR data is intentionally retained so it can be investigated or retried.

## Uninstall

```bash
cd ~/klipper-plr
./uninstall.sh
```

The uninstall script removes the PLR include/configuration and generated recovery files, but intentionally leaves `gcode_shell_command.py` and the `END_PRINT` snippet untouched.

## Project status

This project is being developed and tested on real Klipper hardware. Compatibility depends on the printer's kinematics, homing behavior, slicer G-code and power-loss hardware.

## License

MIT. See [LICENSE](LICENSE).
