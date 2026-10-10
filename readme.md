# Parvanak

<img src="assets/app-icon.png" width="96" alt="Parvanak icon">

A small, open-source macOS menu bar app for temperature monitoring and fan control. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

## Features

- CPU/GPU temperatures, fan RPM, and macOS thermal pressure.
- Fan-speed slider with editable minimum and maximum RPM limits.
- Manual sessions and maximum-cooling boosts lasting up to 60 seconds.
- Automatic-control restoration attempted on timeout, quit, detected app crash, or monitoring failure.

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

Manual speed stays within the reported hardware range, with a floor of 1000 RPM. CPU and GPU readings are required. Manual sessions start below 75°C and return to Auto at 80°C, high thermal pressure, or sensor failure; a detected battery temperature of 45°C also ends manual control. These are conservative software cutoffs, not certified safety limits. Your min/max settings only constrain manual speed; automatic cooling can exceed them.

The app does not disable Apple's thermal services. A killed or frozen helper or failed hardware writes can prevent cleanup. Restart your Mac if automatic control cannot be restored. Avoid running other fan-control apps alongside Parvanak.

Sensor-key reference: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

## License

MIT — see [license](license).
