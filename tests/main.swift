import Foundation

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ description: String) rethrows {
    guard try condition() else { fatalError("FAILED: \(description)") }
    checks += 1
}
func rejects(_ description: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAILED to reject: \(description)") }
    catch { checks += 1 }
}
let hardware = try HardwareBounds(ranges: [(1200, 6000), (1500, 5500)])
check(hardware.minimum == 1500 && hardware.maximum == 5500, "Shared limits must respect every fan")
let zeroMinimum = try HardwareBounds(ranges: [(0, 6000)])
check(zeroMinimum.minimum == 1000, "Zero RPM must never be offered")
rejects("Missing fans") { _ = try HardwareBounds(ranges: []) }
rejects("Disjoint fan ranges") { _ = try HardwareBounds(ranges: [(4000, 5000), (1200, 3500)]) }
rejects("Non-finite hardware limits") { _ = try HardwareBounds(ranges: [(.nan, 6000)]) }
rejects("Implausible hardware maximum") { _ = try HardwareBounds(ranges: [(1200, 16000)]) }
try CoolingPolicy.validateRange(rpm: 2000, minimum: 1500, maximum: 5000, hardware: hardware)
checks += 1
for (rpm, minimum, maximum) in [
    (0.0, 1500.0, 5000.0), (2000, 0, 5000), (2000, 1500, 6000),
    (6000, 1500, 5000), (2000, 3000, 5000), (2000, 5000, 1500),
    (2000, 2000, 2000), (Double.nan, 1500, 5000),
    (2000, Double.infinity, 5000), (2000, 1500, Double.infinity)
] {
    rejects("Invalid requested range \(rpm)/\(minimum)/\(maximum)") {
        try CoolingPolicy.validateRange(rpm: rpm, minimum: minimum, maximum: maximum, hardware: hardware)
    }
}
let normal = try Temperatures(cpu: [45, 60], gpu: [50], battery: [35])
check(normal.cpu == 60 && normal.highest == 60, "Use the hottest CPU sensor, not its average")
try CoolingPolicy.validateTemperature(normal, thermal: .nominal, starting: true)
checks += 1
rejects("Missing temperatures") { try CoolingPolicy.validateTemperature(nil, thermal: .nominal, starting: true) }
rejects("Missing CPU") { _ = try Temperatures(cpu: [], gpu: [40]) }
rejects("Missing GPU") { _ = try Temperatures(cpu: [40], gpu: []) }
rejects("Zero sensor") { _ = try Temperatures(cpu: [0], gpu: [40]) }
rejects("Non-finite sensor") { _ = try Temperatures(cpu: [40, .nan], gpu: [40]) }
rejects("Impossible sensor") { _ = try Temperatures(cpu: [140], gpu: [40]) }
let warm = try Temperatures(cpu: [75], gpu: [50])
rejects("Hot at session start") { try CoolingPolicy.validateTemperature(warm, thermal: .nominal, starting: true) }
try CoolingPolicy.validateTemperature(warm, thermal: .nominal, starting: false)
checks += 1
let hot = try Temperatures(cpu: [80], gpu: [60])
rejects("CPU temperature cutoff") { try CoolingPolicy.validateTemperature(hot, thermal: .nominal, starting: false) }
let hotGPU = try Temperatures(cpu: [50], gpu: [80])
rejects("GPU temperature cutoff") { try CoolingPolicy.validateTemperature(hotGPU, thermal: .nominal, starting: false) }
let hotBattery = try Temperatures(cpu: [50], gpu: [50], battery: [45])
rejects("Battery temperature cutoff") { try CoolingPolicy.validateTemperature(hotBattery, thermal: .nominal, starting: false) }
let hotSSD = try Temperatures(cpu: [50], gpu: [50], ssd: [CoolingPolicy.ssdLimit])
rejects("SSD temperature cutoff") { try CoolingPolicy.validateTemperature(hotSSD, thermal: .nominal, starting: false) }
rejects("Hot SSD at session start") { try CoolingPolicy.validateTemperature(hotSSD, thermal: .nominal, starting: true) }
try CoolingPolicy.validateTemperature(try Temperatures(cpu: [50], gpu: [50], battery: [44], ssd: [69]), thermal: .nominal, starting: true)
checks += 1
for level in [ThermalLevel.serious, .critical, .unknown] {
    rejects("High or unknown thermal pressure") { try CoolingPolicy.validateTemperature(normal, thermal: level, starting: false) }
}
check(CoolingPolicy.heartbeatTimeout <= 10, "Helper must give up quickly when the app stops responding")
var heartbeat = Heartbeat()
check(heartbeat.isFresh(stamp: 100, now: 0), "First heartbeat is fresh")
check(heartbeat.isFresh(stamp: 100, now: CoolingPolicy.heartbeatTimeout), "Unchanged heartbeat within timeout")
check(!heartbeat.isFresh(stamp: 100, now: CoolingPolicy.heartbeatTimeout + 0.1), "Unchanged heartbeat goes stale")
check(heartbeat.isFresh(stamp: 50, now: 11), "Any new stamp counts, even if the wall clock moved backwards")
check(!heartbeat.isFresh(stamp: 50, now: 30), "Stale again after the app stops updating")
try CoolingPolicy.validateLimits(minimum: 1500, maximum: 5500, hardware: hardware)
checks += 1
rejects("Limits outside hardware") { try CoolingPolicy.validateLimits(minimum: 1000, maximum: 5500, hardware: hardware) }
for target in [CoolingTarget.manual(rpm: 3200), .maximum] {
    try check(try CoolingTarget(encoded: target.encoded) == target, "Cooling target round trip")
}
try check(try CoolingTarget(encoded: "manual 2999.6") == .manual(rpm: 2999.6), "Manual target parsing")
for text in ["", "manual", "manual fast", "manual nan", "manual inf", "maximum 1", "auto", "manual 1 2"] {
    rejects("Malformed cooling target \(text)") { _ = try CoolingTarget(encoded: text) }
}
try check(try SMCValue.decode(type: "sp78", bytes: [0x18, 0x80]) == 24.5, "Temperature fixed-point decoding")
try check(try SMCValue.decode(type: "fpe2", bytes: [0x17, 0x70]) == 1500, "Fan fixed-point decoding")
try check(try SMCValue.decode(type: "ui8 ", bytes: [3]) == 3, "Fan mode decoding")
var float: Float = 63.25
let bytes = withUnsafeBytes(of: &float) { Array($0) }
try check(try SMCValue.decode(type: "flt ", bytes: bytes) == 63.25, "Apple silicon float decoding")
rejects("Malformed sensor format") { _ = try SMCValue.decode(type: "flt ", bytes: [0]) }
var invalid: Float = .infinity
rejects("Infinite float sensor") {
    _ = try SMCValue.decode(type: "flt ", bytes: withUnsafeBytes(of: &invalid) { Array($0) })
}
var modes = ["F0md": 1.0, "F1md": 3.0]
var writes: [String] = []
let restored = AutomaticRestoration.restore(keys: ["F0md", "F1md"],
    readMode: { modes[$0]! },
    writeAutomatic: { key in modes[key] = 0; writes.append(key) }, retryDelay: {})
check(restored && modes["F0md"] == 0, "Manual fan restored and verified")
check(writes == ["F0md"], "Already automatic fan needs no writes")
var partialMode = 1.0
var partialWrites = 0
let partial = AutomaticRestoration.restore(keys: ["F0md"], readMode: { _ in partialMode },
    writeAutomatic: { _ in
        partialMode = 0; partialWrites += 1
        throw Failure("Firmware applied the write but reported an error")
    }, retryDelay: {})
check(partial && partialWrites == 1, "Confirm restoration after a partially applied write")
var secondFanMode = 1.0
let failed = AutomaticRestoration.restore(keys: ["F0md", "F1md"], readMode: { key in
    if key == "F0md" { throw Failure("Sensor unavailable") }
    return secondFanMode
}, writeAutomatic: { _ in secondFanMode = 0 }, retryDelay: {})
check(!failed && secondFanMode == 0, "Restore other fans even if one cannot be verified")
let rejected = AutomaticRestoration.restore(keys: ["F0md"], readMode: { _ in 1 },
    writeAutomatic: { _ in throw Failure("Write rejected") }, retryDelay: {})
check(!rejected, "Report failure when automatic control cannot be restored")
var smcFailures = 0
check(AutomaticRestoration.retry(isBusy: { _ in false }, delay: {}) {
    smcFailures += 1
    if smcFailures <= 100 { throw Failure("SMC unavailable") }
}, "Watchdog keeps restoring through SMC failures longer than a few seconds")
var busyTries = 0
check(!AutomaticRestoration.retry(isBusy: { _ in true }, delay: {}) { busyTries += 1; throw Failure("busy") } && busyTries == 30,
      "Watchdog stops waiting on a lock held by a new session")
var smcTries = 0
check(!AutomaticRestoration.retry(isBusy: { _ in false }, delay: {}) { smcTries += 1; throw Failure("SMC unavailable") } && smcTries == 300,
      "Watchdog gives up after 30 seconds of SMC failures")
check(TemperatureReading.cpu.level(69) == .normal && TemperatureReading.cpu.level(70) == .warm &&
      TemperatureReading.cpu.level(85) == .hot, "CPU color bands")
check(TemperatureReading.battery.level(34) == .normal && TemperatureReading.battery.level(35) == .warm &&
      TemperatureReading.battery.level(40) == .hot, "Battery color bands")
check(HeatLevel.normal.raised(by: .fair) == .warm && HeatLevel.hot.raised(by: .fair) == .hot &&
      HeatLevel.normal.raised(by: .serious) == .hot && HeatLevel.warm.raised(by: .nominal) == .warm,
      "Thermal pressure only raises the color")
check(TemperatureReading.ssd.level(54) == .normal && TemperatureReading.ssd.level(55) == .warm &&
      TemperatureReading.ssd.level(70) == .hot, "SSD color bands")
let withSSD = try Temperatures(cpu: [50], gpu: [50], ssd: [41, 48])
check(TemperatureReading.ssd.value(in: withSSD) == 48 && withSSD.highest == 50, "SSD is shown but not part of CPU/GPU hottest")
rejects("Invalid SSD sensor") { _ = try Temperatures(cpu: [50], gpu: [50], ssd: [.nan]) }
check(TemperatureReading.hottest.value(in: normal) == 60 && TemperatureReading.battery.value(in: warm) == nil,
      "Menu bar reading selection")
check(MenuBarLayout.columns([.cpu, .gpu, .battery]) == [[.cpu, .gpu], [.battery]] &&
      MenuBarLayout.columns([.hottest]) == [[.hottest]], "Stacked readings: two per column, odd one alone")
func points(_ values: [(Double, Double)]) -> [FanCurve.Point] {
    values.map { FanCurve.Point(temperature: $0.0, rpm: $0.1) }
}
let curve = try FanCurve(points([(50, 2000), (60, 3000), (70, 4000), (78, 5000)]))
check(curve.rpm(at: 40) == 2000 && curve.rpm(at: 55) == 2500 && curve.rpm(at: 79) == 5000, "Curve interpolation")
try curve.validate(hardware: hardware)
checks += 1
rejects("Curve below hardware minimum") {
    try FanCurve(points([(50, 1000), (60, 3000), (70, 4000), (78, 5000)])).validate(hardware: hardware)
}
for bad in [[(50.0, 2000.0), (50, 3000), (70, 4000), (78, 5000)], [(50, 3000), (60, 2000), (70, 4000), (78, 5000)],
            [(20, 2000), (60, 3000), (70, 4000), (78, 5000)], [(50, 2000), (60, 3000), (70, 4000), (80, 5000)],
            [(50, 2000), (60, 3000), (70, 4000)], [(50, .nan), (60, 3000), (70, 4000), (78, 5000)]] {
    rejects("Malformed curve \(bad)") { _ = try FanCurve(points(bad)) }
}
let balanced = CurvePreset.balanced.curve(for: hardware)
check(balanced.points.first!.rpm == 1500 && balanced.points.last!.rpm == 5500, "Balanced curve spans the hardware range")
check(CurvePreset.system.curve(for: hardware).points.allSatisfy { $0.rpm == SafeMinimum.rpm(at: $0.temperature, hardware: hardware) },
      "System curve sits on the safe minimum, leaving the fans to macOS until the floor asks for more")
check([40.0, 55, 65, 70, 75, 79].allSatisfy { degrees in
    let speeds = [CurvePreset.system, .balanced, .performance].map { $0.curve(for: hardware).rpm(at: degrees) }
    return speeds[0] <= speeds[1] && speeds[1] <= speeds[2]
}, "Presets cool more from System to Balanced to Performance")
try check(try CoolingTarget(encoded: CoolingTarget.curve(curve).encoded) == .curve(curve), "Curve target round trip")
check(CoolingTarget.curve(curve).encoded.utf8.count <= 64, "Curve target fits the control file")
rejects("Curve target with missing speed") { _ = try CoolingTarget(encoded: "curve 50 2000 60 3000 70 4000 78") }
rejects("Curve target with text") { _ = try CoolingTarget(encoded: "curve 50 2000 60 3000 70 4000 78 fast") }
let cool = try Temperatures(cpu: [55], gpu: [40])
check(CoolingPolicy.curveSpeed(curve, cool, thermal: .nominal, hardware: hardware) == 2500, "Curve follows the hottest CPU/GPU sensor")
check(CoolingPolicy.curveSpeed(curve, hot, thermal: .nominal, hardware: hardware) == .infinity, "Curve runs maximum at the stop limit")
check(CoolingPolicy.curveSpeed(curve, cool, thermal: .serious, hardware: hardware) == .infinity, "Curve runs maximum under thermal pressure")
check(CoolingPolicy.curveSpeed(curve, hotBattery, thermal: .nominal, hardware: hardware) == .infinity, "Curve runs maximum with a hot battery")
check(CoolingPolicy.curveSpeed(curve, hotSSD, thermal: .nominal, hardware: hardware) == .infinity, "Curve runs maximum with a hot SSD")
let oddHardware = try HardwareBounds(ranges: [(1217, 5779)])
let oddCurve = CurvePreset.balanced.curve(for: oddHardware)
let oddSpeeds = [30.0, 55, 60, 79].map { try! CoolingPolicy.curveSpeed(oddCurve, Temperatures(cpu: [$0], gpu: [$0]), thermal: .nominal, hardware: oddHardware) }
check(oddSpeeds.allSatisfy { $0 >= oddHardware.minimum && $0 <= oddHardware.maximum },
      "Rounding never takes the curve outside a hardware range that isn't a multiple of 50")
check([50.0, 65, 72, 75, 78, 79].map { SafeMinimum.rpm(at: $0, hardware: hardware) } == [1500, 1500, 2500, 3000, 3500, 3500],
      "Safe minimum rises from the fans' minimum at 65°C to half their range at 78°C")
check(SafeMinimum.rpm(at: 50, hardware: oddHardware) == oddHardware.minimum, "Safe minimum starts at the fans' own minimum")
for odd in [oddHardware, hardware] {
    for preset in CurvePreset.allCases {
        try preset.curve(for: odd).validate(hardware: odd)
        checks += 1
    }
}
rejects("Curve point below the safe minimum") {
    try FanCurve(points([(50, 2000), (60, 3000), (72, 2400), (78, 5000)])).validate(hardware: hardware)
}
let lowCurve = try FanCurve(points([(40, 1500), (50, 1500), (60, 1500), (70, 2300)]))
try lowCurve.validate(hardware: hardware)
checks += 1
try check(CoolingPolicy.curveSpeed(lowCurve, try Temperatures(cpu: [77], gpu: [50]), thermal: .nominal, hardware: hardware)
        == SafeMinimum.rpm(at: 77, hardware: hardware), "Curve never runs below the safe minimum past its last point")
check(CoolingTarget.manual(rpm: 2000).isManual && !CoolingTarget.maximum.isManual && !CoolingTarget.curve(curve).isManual,
      "Only a manual target counts as already in Manual, so switching from Max or Curve uses the start limit")
var controller = CurveController()
check(controller.targets(desired: 2500, actual: [2300], minimums: [1000], maximums: [6000], now: 0) == nil,
      "Curve leaves fans with macOS unless it clearly wants more")
check(controller.targets(desired: 3000, actual: [2300], minimums: [1000], maximums: [6000], now: 1) == [3000], "Curve takes over above macOS")
check(controller.targets(desired: 2000, actual: [3000], minimums: [1000], maximums: [6000], now: 2) == [2900], "Speed drops gradually")
check(controller.targets(desired: 2000, actual: [3000], minimums: [1000], maximums: [6000], now: 3) == [2800], "Speed keeps dropping gradually")
for step in 4...30 { _ = controller.targets(desired: 2000, actual: [2300], minimums: [1000], maximums: [6000], now: Double(step) * 0.1 + 3) }
check(controller.applied == [2300], "Never below the speed macOS had chosen")
check(controller.targets(desired: 2000, actual: [2300], minimums: [1000], maximums: [6000], now: 12.5) == nil && !controller.engaged,
      "Hand fans back to macOS once the curve stays at or below its speed")
check(controller.targets(desired: .infinity, actual: [2300, 2500], minimums: [1000, 1000], maximums: [6000, 5800], now: 20) == [6000, 5800],
      "Maximum respects each fan's own limit")
check(controller.targets(desired: 3000, actual: [6000, 5800], minimums: [1000, 1000], maximums: [6000, 5800], now: 21) == [5900, 5700],
      "Leaving maximum also ramps down")
check(controller.targets(desired: 5950, actual: [3000, 3000], minimums: [1000, 1000], maximums: [6000, 5800], now: 21.5) == [5950, 5800],
      "Rising curve applies immediately")
var held = CurveController()
_ = held.targets(desired: 4000, actual: [2300], minimums: [1000], maximums: [6000], now: 0)
check(held.targets(desired: 3900, actual: [4000], minimums: [1000], maximums: [6000], now: 1) == [4000],
      "A small drop holds the speed, so the fans don't hunt")
check(held.targets(desired: 3800, actual: [4000], minimums: [1000], maximums: [6000], now: 2) == [3900],
      "A larger drop starts ramping down")
check(held.targets(desired: 3800, actual: [3900], minimums: [1000], maximums: [6000], now: 3) == [3800],
      "Once started, the ramp goes all the way down")
check(held.targets(desired: 3700, actual: [3800], minimums: [1000], maximums: [6000], now: 4) == [3800],
      "After reaching the curve, small drops hold again")
check(held.targets(desired: 3850, actual: [3800], minimums: [1000], maximums: [6000], now: 5) == [3850],
      "Any rise applies at once")
var steady = SteadyTemperature()
check(steady.update(60, now: 0) == 60, "Steady temperature starts at the first reading")
let risen = steady.update(70, now: 6)
check(risen > 66 && risen < 67, "A rise is mostly followed within its time constant")
var falling = SteadyTemperature()
_ = falling.update(70, now: 0)
let fallen = falling.update(60, now: 6)
check(fallen > 67 && fallen < 68, "A fall is followed more slowly than a rise")
var swinging = SteadyTemperature()
var swings: [Double] = []
for second in 0..<300 { swings.append(swinging.update(second % 2 == 0 ? 60 : 71, now: Double(second))) }
check(swings.suffix(60).allSatisfy { $0 > 67 && $0 < 70 }, "A reading swinging 60–71°C every second steadies within 3°C, toward the hot end")
let swingingTemperatures = try Temperatures(cpu: [80], gpu: [40])
check(CoolingPolicy.curveSpeed(curve, swingingTemperatures, following: 60, thermal: .nominal, hardware: hardware) == .infinity,
      "The stop limit uses the raw reading, not the steadied one")
check(CoolingPolicy.curveSpeed(curve, hot, following: 55, thermal: .nominal, hardware: hardware) == .infinity,
      "A steadied temperature never delays maximum at the stop limit")
try check(CoolingPolicy.curveSpeed(curve, cool, following: 65, thermal: .nominal, hardware: hardware)
      == CoolingPolicy.curveSpeed(curve, try Temperatures(cpu: [65], gpu: [40]), thermal: .nominal, hardware: hardware)
      && CoolingPolicy.curveSpeed(curve, cool, following: 65, thermal: .nominal, hardware: hardware) != 2500,
      "The curve looks up the steadied temperature, not the raw one")
var idle = CurveController()
check(idle.targets(desired: 1200, actual: [0, 0], minimums: [1200, 1000], maximums: [6000, 5800], now: 0) == nil,
      "A stopped fan counts as its minimum, so the curve's lowest speed leaves it with macOS")
check(idle.targets(desired: 2000, actual: [0, 0], minimums: [1200, 1000], maximums: [6000, 5800], now: 1) == [2000, 2000],
      "Curve takes over stopped fans when it clearly wants more than their minimum")
check(idle.applied!.allSatisfy { $0 >= 1200 }, "Never targets a stopped fan below its minimum")
for step in 2...30 { _ = idle.targets(desired: 1200, actual: [1500, 1500], minimums: [1200, 1000], maximums: [6000, 5800], now: Double(step)) }
check(!idle.engaged, "Hand fans that macOS had stopped back once the curve falls to their minimum")
var ring = RingBuffer<Int>(capacity: 3)
for value in 1...2 { ring.append(value) }
check(ring.elements == [1, 2], "History keeps order before it fills")
for value in 3...7 { ring.append(value) }
check(ring.elements == [5, 6, 7] && ring.count == 3, "History drops the oldest samples once full")
let plugged = try PowerReadings(system: 25.76, adapter: 28.34)
check(plugged.text == "25.8 W · adapter 28.3 W", "Power text with adapter")
try check(try PowerReadings(system: 9, adapter: 0.1).adapter == nil, "Ignore adapter trickle when unplugged")
rejects("Invalid power reading") { _ = try PowerReadings(system: .nan, adapter: nil) }
rejects("Implausible power reading") { _ = try PowerReadings(system: 900, adapter: nil) }
for (text, command) in [("baadgir://auto", RemoteCommand.auto), ("baadgir://curve", .curve), ("BAADGIR://Max", .maximum),
                        ("baadgir://maximum", .maximum), ("baadgir://manual", .manual(rpm: nil)),
                        ("baadgir://manual?rpm=3000", .manual(rpm: 3000))] {
    try check(try RemoteCommand(url: URL(string: text)!) == command, "Link \(text)")
    try check(try RemoteCommand(url: command.url) == command, "Link round trip \(text)")
}
for text in ["https://max", "baadgir://off", "baadgir://manual?rpm=fast", "baadgir://manual?rpm=nan", "baadgir:max",
             "baadgir://manual?rpm=1e20", "baadgir://manual?rpm=-1"] {
    rejects("Bad link \(text)") { _ = try RemoteCommand(url: URL(string: text)!) }
}
try check(try RemoteCommand(arguments: ["manual", "2500"]) == .manual(rpm: 2500), "Command-line manual speed")
try check(try RemoteCommand(arguments: ["MAX"]) == .maximum, "Command-line words ignore case")
try check(try RemoteCommand(url: RemoteCommand(arguments: ["manual", "20000"]).url) == .manual(rpm: 20000),
          "The largest accepted speed still forms a link")
for words in [[], ["status", "x"], ["manual", "fast"], ["manual", "1", "2"], ["off"], ["manual", "1e20"], ["manual", "inf"]] {
    rejects("Bad command \(words)") { _ = try RemoteCommand(arguments: words) }
}
var rules = PowerRules()
check(rules.mode(from: .adapter, to: .battery, current: .maximum) == nil && rules.mode(from: nil, to: .adapter, current: .auto) == nil,
      "Rules do nothing until turned on")
rules.autoOnBattery = true; rules.onAdapter = .curve
check(rules.mode(from: .adapter, to: .battery, current: .manual) == .auto, "Unplugging returns to Auto")
check(rules.mode(from: .adapter, to: .battery, current: .auto) == nil, "Already on Auto when unplugged")
check(rules.mode(from: .battery, to: .adapter, current: .auto) == .curve, "Plugging in starts the chosen mode")
check(rules.mode(from: nil, to: .adapter, current: .auto) == .curve, "Launching while plugged in starts the chosen mode")
check(rules.mode(from: .battery, to: .adapter, current: .manual) == nil, "Plugging in never overrides the user's mode")
check(rules.mode(from: .adapter, to: .adapter, current: .auto) == nil, "No change, no action")
check(rules.mode(from: .adapter, to: .unknown, current: .manual) == nil, "Unknown power source changes nothing")
check(rules.blocker(for: .maximum, on: .battery) != nil && rules.blocker(for: .auto, on: .battery) == nil &&
      rules.blocker(for: .curve, on: .adapter) == nil, "Battery rule blocks only non-Auto modes on battery")
check(TemperatureReading.fan.text(2496.4, compact: false) == "2496 RPM" && TemperatureReading.fan.text(2496.4, compact: true) == "2496" &&
      TemperatureReading.cpu.text(71.6, compact: false) == "72°C" && TemperatureReading.cpu.text(nil, compact: true) == "—°",
      "Menu bar text uses RPM for the fan and °C for temperatures")
check(TemperatureReading.fan.level(6000) == nil && TemperatureReading.fan.value(in: normal) == nil &&
      TemperatureReading.fan.text(TemperatureReading.fan.widest, compact: true).count >= 4,
      "Fan speed has no temperature color, isn't a temperature, and reserves four digits")
check(TemperatureReading.fanLevel(2400, minimum: 1000, maximum: 4000) == .normal &&
      TemperatureReading.fanLevel(2500, minimum: 1000, maximum: 4000) == .warm &&
      TemperatureReading.fanLevel(3400, minimum: 1000, maximum: 4000) == .hot &&
      TemperatureReading.fanLevel(2000, minimum: 0, maximum: 0) == nil, "Fan speed color bands follow the fans' range")
let userFile = NSTemporaryDirectory() + "baadgir-test-" + UUID().uuidString
FileManager.default.createFile(atPath: userFile, contents: Data())
check(isRootOwned("/bin/sh") && !isRootOwned(userFile) && !isRootOwned("/bin") && !isRootOwned("bin/sh") &&
      !isRootOwned("/nonexistent/helper"), "Only root-owned files in root-owned folders are trusted")
try? FileManager.default.removeItem(atPath: userFile)
check(SensorKeys.generation(brand: "Apple M1") == .m1 && SensorKeys.generation(brand: "Apple M2 Max") == .m2 &&
      SensorKeys.generation(brand: "Apple M3 Pro") == .m3 && SensorKeys.generation(brand: "Apple M4") == .m4 &&
      SensorKeys.generation(brand: "Apple M5 Pro") == .m5, "Chip names map to their sensor generation")
check(SensorKeys.generation(brand: "Apple M9") == nil && SensorKeys.generation(brand: "") == nil &&
      SensorKeys.generation(brand: "Intel(R) Core(TM) i7") == nil, "Unknown chips have no generation")
check(SensorKeys.Generation.allCases.allSatisfy { !SensorKeys.cpu($0).isEmpty && !SensorKeys.gpu($0).isEmpty },
      "Every generation has CPU and GPU keys, which control requires")
check(SensorKeys.gpu(.m3).contains("Tf14") && SensorKeys.cpu(.m3).contains("Tf04") && !SensorKeys.gpu(.m3).contains("Tg0j"),
      "M3 uses its own Tf GPU and performance-core keys, not other generations' keys")
check(SensorKeys.cpu(.m2).contains("Tp1h") && SensorKeys.gpu(.m2).contains("Tg0f") && SensorKeys.gpu(.m1).contains("Tg0T"),
      "M1 and M2 include every known key")
let allCPU = SensorKeys.cpu(nil), allGPU = SensorKeys.gpu(nil)
check(SensorKeys.Generation.allCases.allSatisfy { Set(SensorKeys.cpu($0)).isSubset(of: allCPU) && Set(SensorKeys.gpu($0)).isSubset(of: allGPU) } &&
      Set(allCPU).count == allCPU.count && Set(allGPU).count == allGPU.count,
      "An unknown chip probes every known key once")
check((SensorKeys.Generation.allCases.map(Optional.some) + [nil]).allSatisfy {
          (SensorKeys.cpu($0) + SensorKeys.gpu($0)).allSatisfy { $0.utf8.count == 4 && $0.first == "T" } },
      "Sensor keys are four-character temperature keys")
check(!TemperatureReading.available(fanless: true).contains(.fan) && TemperatureReading.available(fanless: false).contains(.fan),
      "A fanless Mac offers no fan speed reading")
check(TemperatureReading.shown([.cpu, .fan], fanless: true) == [.cpu] && TemperatureReading.shown([.fan], fanless: true) == [.hottest] &&
      TemperatureReading.shown([.cpu, .fan], fanless: false) == [.cpu, .fan],
      "A fanless Mac drops fan speed from the menu bar and never shows nothing")
rejects("An unknown chip gets no Manual or Curve") { try SensorKeys.requireKnown(nil) }
try SensorKeys.Generation.allCases.forEach { try SensorKeys.requireKnown($0) }
checks += 1
// Graph axes
check(GraphScale(peak: 6000, minimum: 1000).ticks == [0, 2000, 4000, 6000], "Fan axis ends at the fans' maximum")
check(GraphScale(peak: 5500, minimum: 1000).top == 6000 && GraphScale(peak: 7200, minimum: 1000).top == 7500, "Fan axis rounds up")
check(GraphScale(low: 43, high: 67, span: 20, intervals: 4).ticks == [40, 50, 60, 70], "Temperature axis in 10° steps")
check(GraphScale(low: 38, high: 97, span: 20, intervals: 4).ticks == [20, 40, 60, 80, 100], "A wide spread takes 20° steps")
check(GraphScale(low: 48, high: 52, span: 20, intervals: 4).ticks == [40, 50, 60, 70], "A steady reading still gets a 20° range")
check(GraphScale(low: .nan, high: .infinity, span: 20).ticks.count >= 2, "Invalid readings never crash the axis")
for scale in [GraphScale(low: -.greatestFiniteMagnitude, high: .greatestFiniteMagnitude, span: 20, intervals: 4),
              GraphScale(low: -1, high: 1, span: 0, intervals: 1), GraphScale(low: 50, high: 50, span: 0)] {
    check(scale.top > scale.bottom && scale.step > 0 && scale.ticks.allSatisfy(\.isFinite), "Extreme readings end with a usable axis")
}
check(TimeTick.ticks(span: 600).map(\.label) == ["Now", "2 min", "4 min", "6 min", "8 min", "10 min"], "Ten-minute axis")
check(TimeTick.ago(1) == "Now" && TimeTick.ago(25) == "25 s ago" && TimeTick.ago(185) == "3 min 5 s ago", "Hover ages")
print("Passed \(checks) safety and sensor-decoding checks. No hardware writes.")
