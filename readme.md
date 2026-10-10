# Parvanak

<img src="assets/app-icon.png" width="96" alt="Parvanak icon">

A small, open-source macOS menu bar app for temperature monitoring and fan control. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

## Features

- CPU/GPU/battery/SSD temperatures, fan RPM, and macOS thermal pressure, coloured green/yellow/red.
- Settings window (popover → Settings…, or right-click → Settings…) for menu bar readings, colours, and manual speed limits.
- No logs: readings and errors are never written to disk. Only preferences (limits, speed, menu bar choices) are saved.
- Auto / Manual / Max fan modes, from the popover or the menu bar icon's right-click menu. Manual and Max stay on until you choose Auto.
- Live manual-speed slider with editable, remembered minimum and maximum RPM limits.
- One administrator prompt per session; speed and mode changes inside a session need no new prompt.
- Automatic-control restoration attempted on Auto, quit, sleep, app crash or freeze, and monitoring failure.
- Auto also releases fans left in manual mode by a crashed session or another app.

## Build and run

Requires an Apple silicon Mac, macOS 13+, and Xcode Command Line Tools.

```sh
./test.sh
./build.sh
open Parvanak.app
```

Fan control requires macOS administrator authorization. Monitoring does not.

## Safety

Experimental: uses an undocumented SMC interface. Hardware control and restoration have not been verified on the target M5 MacBook Pro. Use at your own risk.

Manual speed stays within the reported hardware range, with a floor of 1000 RPM. CPU and GPU readings are required. Manual speed starts below 75°C and returns to Auto at 80°C, high thermal pressure, or sensor failure; a detected battery temperature of 45°C also ends manual control. Max has no temperature cutoff because it never lowers fan speed. The root helper returns fans to Auto if the app stops refreshing its target for 10 seconds. These are conservative software cutoffs, not certified safety limits. Your min/max settings only constrain manual speed; automatic cooling can exceed them.

The app does not disable Apple's thermal services. A separate root watchdog restores Auto if the helper is force-killed; killing both, or failed hardware writes, can prevent cleanup. Restart your Mac if automatic control cannot be restored. Avoid running other fan-control apps alongside Parvanak.

Sensor-key reference: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

## License

MIT — see [license](license).
