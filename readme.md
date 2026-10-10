# Parvanak

<img src="assets/app-icon.png" width="96" alt="Parvanak icon">

A small, open-source macOS menu bar app for monitoring fans and requesting a short cooling boost. Built with Swift and AppKit, with no third-party dependencies.

## Features

- Live fan RPM and macOS thermal pressure.
- Maximum cooling for up to 60 seconds.
- An option to end the boost and return to automatic control.
- Automatic-control restoration attempted on timeout, quit, or detected app crash.

## Build and run

Requires an Apple silicon Mac and Xcode Command Line Tools.

```sh
./build.sh
open Parvanak.app
```

Cooling boosts require macOS administrator authorization. Monitoring does not.

## Safety

Experimental: uses an undocumented SMC interface. Built for an M5 MacBook Pro, but hardware control and restoration have not been verified. Use at your own risk.

The app only requests the reported maximum fan speed; it cannot slow or stop fans. It does not disable Apple's thermal services. Cleanup can fail if the helper is killed or hardware access fails. If automatic control cannot be restored, restart your Mac.

## License

MIT — see [license](license).
