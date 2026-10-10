# Baadgir

*Baadgir* (بادگیر, "windcatcher") is named after the Persian towers that cool buildings by catching the wind.

<img src="assets/app-icon.png" width="96" alt="Baadgir icon">

A small, open-source macOS menu bar app for temperature monitoring and fan control. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

## Features

- CPU/GPU/battery/SSD temperatures, fan RPM, and macOS thermal pressure, coloured green/yellow/red.
- System power draw and adapter input in watts (display only).
- Settings window (popover → Settings…, or right-click → Settings…) for launch at login, menu bar readings, colours, and manual speed limits.
- Last 10 minutes of CPU/GPU temperature and fan speed as small graphs in the popover, kept in memory only.
- No logs: readings and errors are never written to disk. Only preferences (limits, speed, menu bar choices) are saved.
- Auto / Curve / Manual / Max fan modes, from the popover or the menu bar icon's right-click menu. Curve, Manual and Max stay on until you choose Auto.
- Fan curve: four editable temperature → RPM points with a live preview. Curve mode only takes over when the curve asks for more than macOS is running, and never runs a fan below the speed macOS had chosen.
- Optional notification when fans return to Auto on their own (safety cutoff, sensor failure, helper exit), with the reason.
- ⌃⌥M switches between Max and Auto from any app (can be turned off in Settings).
- Shortcuts, links and command line: `baadgir://auto`, `baadgir://curve`, `baadgir://max`, `baadgir://manual?rpm=3000`, or `baadgir status | auto | curve | max | manual [RPM]`. Requests get the same safety checks as the app, and can be turned off in Settings.
- Live manual-speed slider with editable, remembered minimum and maximum RPM limits.
- One administrator prompt per session; speed and mode changes inside a session need no new prompt.
- Automatic-control restoration attempted on Auto, quit, sleep, app crash or freeze, and monitoring failure.
- Auto also releases fans left in manual mode by a crashed session or another app.

## Build and run

Requires an Apple silicon Mac, macOS 13+, and Xcode Command Line Tools.

```sh
./test.sh
./build.sh
open Baadgir.app
```

Fan control requires macOS administrator authorization. Monitoring does not.

### Shortcuts and the command line

In Shortcuts, add an **Open URLs** action with a link such as `baadgir://max`. For the terminal, link the executable onto your `PATH`:

```sh
ln -s "$PWD/Baadgir.app/Contents/MacOS/baadgir" /usr/local/bin/baadgir
baadgir status        # read-only readings
baadgir manual 3000   # asks the running app; it launches if needed
```

## Safety

Experimental: uses an undocumented SMC interface. Hardware control and restoration have not been verified on the target M5 MacBook Pro. Use at your own risk.

Manual speed stays within the reported hardware range, with a floor of 1000 RPM. CPU and GPU readings are required. Manual speed starts below 75°C and returns to Auto at 80°C, high thermal pressure, or sensor failure; a detected battery temperature of 45°C also ends manual control. Max has no temperature cutoff because it never lowers fan speed. Curve mode switches to maximum at 80°C, a 45°C battery, or high thermal pressure, eases speed down by at most 100 RPM per step, and hands the fans back to macOS once the curve stays at or below macOS's speed for 10 seconds. The root helper returns fans to Auto if the app stops refreshing its target for 10 seconds. These are conservative software cutoffs, not certified safety limits. Your min/max settings only constrain manual speed; automatic cooling can exceed them.

The app does not disable Apple's thermal services. A separate root watchdog restores Auto if the helper is force-killed; killing both, or failed hardware writes, can prevent cleanup. Restart your Mac if automatic control cannot be restored. Avoid running other fan-control apps alongside Baadgir.

Sensor-key reference: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

## License

MIT — see [license](license).
