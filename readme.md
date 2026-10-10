<div align="center">

# Baadgir: Mac fan control and temperature monitor

**A free, open-source menu bar app for Apple silicon Macs.**
See CPU, GPU, battery and SSD temperatures at a glance, and take control of your fans when macOS waits too long.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Apple silicon M1–M5](https://img.shields.io/badge/Apple%20silicon-M1%E2%80%93M5-blue)
![Swift](https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<p align="center">
  <img src="assets/cover.png" alt="Baadgir on a Mac: CPU temperature and fan speed in the menu bar, the popover with CPU, GPU, battery and SSD temperatures, 10-minute temperature and fan graphs and Auto, Curve and Max modes, and the Settings window with the custom fan curve editor, next to a list of features">
</p>

## Why Baadgir?

macOS keeps the fans quiet until your Mac is already hot. That's fine for email, but during a long export, build or game your MacBook Pro can throttle before the fans catch up. Baadgir lets you cool it down earlier, and hands control back to macOS when you're done.

- 🌡️ **Live temperatures in the menu bar.** CPU, GPU, battery and SSD readings, colored green, yellow or red, plus fan RPM, power draw and thermal pressure.
- 📈 **10-minute history graphs** of temperature and fan speed, right in the popover.
- 🌀 **Custom fan curve.** Set four temperature → RPM points. Baadgir only speeds the fans up, never runs them slower than macOS would, and enforces a safe minimum.
- 🚀 **One-click Max.** Full fan speed from the popover, the right-click menu, or <kbd>⌃</kbd><kbd>⌥</kbd><kbd>M</kbd> from any app.
- ⚡ **Automation.** Switch to Curve or Max when you plug in, back to Auto on battery. Also works with Shortcuts, `baadgir://` links and a command-line tool.
- 🛡️ **Safety first.** Fans go back to macOS automatic control on quit, sleep, a crash, overheating or a sensor failure.
- 🔒 **Private and lightweight.** Native Swift and SwiftUI with no dependencies, no network access, no analytics and no logs.

## Fan modes

| Mode | What it does |
| --- | --- |
| **Auto** | macOS controls the fans, as usual. |
| **Curve** | Your temperature → RPM curve, used only when it wants more cooling than macOS. |
| **Max** | Fans at full speed until you choose Auto. |
| **Manual** | A fixed speed you pick. Hidden behind Settings → Fans → Advanced. |

## Install

You need an Apple silicon Mac (M1 to M5), macOS 13 or later, and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/devbymak/baadgir.git
cd baadgir
./build.sh --install
```

This builds the app, installs a small root-owned fan-control helper, and copies Baadgir to `/Applications`. It asks for your password once, to install the helper and a sudo rule (`/etc/sudoers.d/baadgir`) that lets your account start only that helper without a password. After that, Baadgir switches modes without asking and starts the mode you last picked when it opens.

**Supported Macs:** Apple silicon Macs with fans, including two-fan 14" and 16" MacBook Pro models (both fans move together). On a fanless MacBook Air, Baadgir shows temperatures only. Run `baadgir status` to see the chip, fans and sensors it found.

<details>
<summary><b>Shortcuts, links and command line</b></summary>

Turn on Settings → Automation → Shortcuts, links, and command line first. It's off by default because any app or web page can open a link. Baadgir still asks for confirmation before it starts cooling or sets a manual speed.

- **Shortcuts:** add an *Open URLs* action with `baadgir://auto`, `baadgir://curve`, `baadgir://max` or `baadgir://manual?rpm=3000`.
- **Terminal:**

  ```sh
  ln -s /Applications/Baadgir.app/Contents/MacOS/baadgir /usr/local/bin/baadgir
  baadgir status        # read-only readings
  baadgir max           # or auto, curve, manual 3000
  ```

</details>

<details>
<summary><b>Uninstall</b></summary>

Choose Auto, quit Baadgir, delete the app, then run:

```sh
sudo rm -f /Library/PrivilegedHelperTools/local.baadgir.helper /var/db/local.baadgir.lock /etc/sudoers.d/baadgir
```

</details>

## Safety

> [!WARNING]
> Baadgir is experimental. It uses Apple's undocumented SMC interface, and fan control has not been verified on every Mac. Use it at your own risk.

<details>
<summary><b>How Baadgir keeps your Mac safe</b></summary>

- **Curve** never runs below a safe minimum for the current temperature (the fans' minimum up to 65°C, a quarter of their range at 72°C, half at 78°C). It switches to full speed at 80°C CPU/GPU, a 45°C battery, a 70°C SSD or high thermal pressure, and returns to Auto once macOS's own speed is enough.
- **Manual** only starts below 75°C, never goes under 1000 RPM, and returns to Auto at 80°C, a hot battery or SSD, high thermal pressure or a sensor failure.
- **Max** has no cutoff because it never lowers fan speed.
- **Watchdogs:** the root helper restores Auto if the app stops responding for 10 seconds, and a separate watchdog restores Auto if the helper itself stalls for 15 seconds.
- **Least privilege:** only a root-owned helper runs as root, never the app bundle, and the app checks that helper before starting it. The sudo rule covers only that helper, so any app running as you can start it without a password, but only within the limits above. Apple's thermal services are never disabled.

These are conservative software limits, not certified safety limits. If automatic control can't be restored, restart your Mac. Don't run other fan-control apps at the same time.

</details>

## FAQ

**Is Baadgir free?** Yes. It's open source under the MIT license.

**Does it work on M4 and M5 Macs?** Yes, M1 through M5 are supported. A newer chip still shows temperatures and offers Auto and Max until its sensors are added.

**Will it drain my battery?** Baadgir is a small native app that reads sensors once a second. The helper runs only while you use Curve, Max or Manual, and you can make it return to Auto on battery.

**Why the name?** *Baadgir* (بادگیر) means "windcatcher": the Persian towers that have cooled buildings by catching the wind for centuries.

## Credits

Sensor-key reference: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).

## License

MIT. See [license](license).
