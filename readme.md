# Baadgir

*Baadgir* (بادگیر, "windcatcher") is named after the Persian towers that cool buildings by catching the wind.

<img src="assets/app-icon.png" width="96" alt="Baadgir icon">

A small, open-source macOS menu bar app for temperature monitoring and fan control. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

## Features

- CPU/GPU/battery/SSD temperatures, fan RPM, and macOS thermal pressure, colored green/yellow/red.
- Menu bar shows any mix of hottest, CPU, GPU, battery, and SSD temperature and average fan speed (Settings → Appearance).
- System power draw and adapter input in watts (display only).
- Menu bar readings in one row, or stacked two to a column in a smaller font (Settings → Appearance → Layout). The fan icon can be hidden to save space.
- Settings window (popover → Settings…, or right-click → Settings…) with General, Appearance (menu bar readings, layout, colors, history graphs), Fans (manual speed limits, the fan curve), and Automation (power rules, the hotkey, Shortcuts and links) tabs.
- Popover graphs of the last 10 minutes of CPU/GPU temperature and fan speed, with value and time axes (hover for exact values), kept in memory only.
- No logs: readings and errors are never written to disk. Only preferences (limits, speed, menu bar choices) are saved.
- Auto / Curve / Manual / Max fan modes, from the popover or the menu bar icon's right-click menu. Curve, Manual, and Max stay on until you choose Auto.
- Fan curve: four editable temperature → RPM points with a live preview. Curve mode only takes over when the curve asks for more than macOS is running (a fan macOS has stopped counts as its minimum speed), and never runs a fan below the speed macOS had chosen.
- Rules: return to Auto (and stay there) on battery; switch to Curve or Max when plugged in, including at launch.
- Optional notification when fans return to Auto on their own (safety cutoff, sensor failure, helper exit), with the reason.
- ⌃⌥M switches between Max and Auto from any app (can be turned off in Settings → Automation).
- Shortcuts, links, and command line: `baadgir://auto`, `baadgir://curve`, `baadgir://max`, `baadgir://manual?rpm=3000`, or `baadgir status | auto | curve | max | manual [RPM]`. Requests get the same safety checks as the app, and one that would start cooling or pick a manual speed asks for confirmation in Baadgir first. Off by default; turn them on in Settings.
- Live manual-speed slider with editable, remembered minimum and maximum RPM limits.
- One administrator prompt per session; speed and mode changes inside a session need no new prompt.
- Automatic-control restoration attempted on Auto, quit, sleep, app crash or freeze, and monitoring failure.
- Auto also releases fans left in manual mode by a crashed session or another app.

## Build and run

Requires an Apple silicon Mac, macOS 13+, and Xcode Command Line Tools.

Works on M1 through M5 chips, using each generation's own sensor keys; a newer chip probes every known key to show temperatures, but offers only Auto and Max until its sensor keys are added, since Manual and Curve rely on them. Macs with two fans (14" and 16" MacBook Pro) are controlled together within the speed range both fans support. Fanless Macs, such as the MacBook Air, show temperatures only. `baadgir status` prints the chip, fans, and sensor keys it found.

```sh
./test.sh
./build.sh --install   # builds, installs the root-owned fan-control helper (asks for your password), replaces /Applications/Baadgir.app, and opens it
```

`./build.sh` alone builds `Baadgir.app` here without installing it. Only one copy runs at a time; a second launch quits immediately.

Fan control requires macOS administrator authorization and the helper that `--install` puts at `/Library/PrivilegedHelperTools/local.baadgir.helper`. Monitoring needs neither. To uninstall, choose Auto and quit Baadgir, delete the app, and run `sudo rm -f /Library/PrivilegedHelperTools/local.baadgir.helper /var/db/local.baadgir.lock`.

### Shortcuts and the command line

First turn on Settings → Automation → Shortcuts, links, and command line. Any web page or app can open a link, so leave it off if you don't use it. A request that would start Curve, Manual, or Max shows a Baadgir confirmation before macOS asks for your password. A request for Manual is always confirmed, even during a running session, since it can run the fans slower than macOS would; switching to Max or Curve during a running session, or returning to Auto, is not. In Shortcuts, add an **Open URLs** action with a link such as `baadgir://max`. For the terminal, link the executable onto your `PATH`:

```sh
ln -s /Applications/Baadgir.app/Contents/MacOS/baadgir /usr/local/bin/baadgir
baadgir status        # read-only readings
baadgir manual 3000   # asks the running app; it launches the installed copy if needed
```

## Safety

Experimental: uses an undocumented SMC interface. Hardware control and restoration have not been verified on the target M5 MacBook Pro. Use at your own risk.

Manual speed stays within the reported hardware range, with a floor of 1000 RPM. CPU and GPU readings are required. Manual speed starts below 75°C and returns to Auto at 80°C, high thermal pressure, or sensor failure; a detected battery temperature of 45°C or SSD temperature of 70°C also ends manual control. Max has no temperature cutoff because it never lowers fan speed. Curve mode switches to maximum at 80°C, a 45°C battery, a 70°C SSD, or high thermal pressure, eases speed down by at most 100 RPM per step, and hands the fans back to macOS once the curve stays at or below macOS's speed (or the fans' minimum, if macOS had stopped them) for 10 seconds. The root helper returns fans to Auto if the app stops refreshing its target for 10 seconds, and its watchdog stops the helper and restores Auto if the helper itself stalls for 15 seconds; that restore needs only each fan's mode, not its other readings. Manual and Curve need a chip whose sensor keys Baadgir knows. These are conservative software cutoffs, not certified safety limits. Your min/max settings only constrain manual speed; automatic cooling can exceed them.

Root only ever runs the root-owned helper, never the app bundle, which apps running as you could replace; the app checks the helper is root-owned and matches its own build before asking for your password. The helper runs with an empty environment and reads its controls only from a private folder owned by the app's user. The app does not disable Apple's thermal services. A separate root watchdog restores Auto if the helper is force-killed; killing both, or failed hardware writes, can prevent cleanup. Restart your Mac if automatic control cannot be restored. Avoid running other fan-control apps alongside Baadgir.

Sensor-key reference: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

## License

MIT — see [license](license).
