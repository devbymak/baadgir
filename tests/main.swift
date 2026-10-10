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
check(TemperatureReading.cpu.level(69) == .normal && TemperatureReading.cpu.level(70) == .warm &&
      TemperatureReading.cpu.level(85) == .hot, "CPU colour bands")
check(TemperatureReading.battery.level(34) == .normal && TemperatureReading.battery.level(35) == .warm &&
      TemperatureReading.battery.level(40) == .hot, "Battery colour bands")
check(HeatLevel.normal.raised(by: .fair) == .warm && HeatLevel.hot.raised(by: .fair) == .hot &&
      HeatLevel.normal.raised(by: .serious) == .hot && HeatLevel.warm.raised(by: .nominal) == .warm,
      "Thermal pressure only raises the colour")
check(TemperatureReading.ssd.level(54) == .normal && TemperatureReading.ssd.level(55) == .warm &&
      TemperatureReading.ssd.level(70) == .hot, "SSD colour bands")
let withSSD = try Temperatures(cpu: [50], gpu: [50], ssd: [41, 48])
check(TemperatureReading.ssd.value(in: withSSD) == 48 && withSSD.highest == 50, "SSD is shown but not part of CPU/GPU hottest")
rejects("Invalid SSD sensor") { _ = try Temperatures(cpu: [50], gpu: [50], ssd: [.nan]) }
check(TemperatureReading.hottest.value(in: normal) == 60 && TemperatureReading.battery.value(in: warm) == nil,
      "Menu bar reading selection")
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
let standard = FanCurve.standard(for: hardware)
try standard.validate(hardware: hardware)
check(standard.points.first!.rpm == 1500 && standard.points.last!.rpm == 5500, "Default curve spans the hardware range")
try check(try CoolingTarget(encoded: CoolingTarget.curve(curve).encoded) == .curve(curve), "Curve target round trip")
check(CoolingTarget.curve(curve).encoded.utf8.count <= 64, "Curve target fits the control file")
rejects("Curve target with missing speed") { _ = try CoolingTarget(encoded: "curve 50 2000 60 3000 70 4000 78") }
rejects("Curve target with text") { _ = try CoolingTarget(encoded: "curve 50 2000 60 3000 70 4000 78 fast") }
let cool = try Temperatures(cpu: [55], gpu: [40])
check(CoolingPolicy.curveSpeed(curve, cool, thermal: .nominal) == 2500, "Curve follows the hottest CPU/GPU sensor")
check(CoolingPolicy.curveSpeed(curve, hot, thermal: .nominal) == .infinity, "Curve runs maximum at the stop limit")
check(CoolingPolicy.curveSpeed(curve, cool, thermal: .serious) == .infinity, "Curve runs maximum under thermal pressure")
check(CoolingPolicy.curveSpeed(curve, hotBattery, thermal: .nominal) == .infinity, "Curve runs maximum with a hot battery")
var controller = CurveController()
check(controller.targets(desired: 2500, actual: [2300], maximums: [6000], now: 0) == nil,
      "Curve leaves fans with macOS unless it clearly wants more")
check(controller.targets(desired: 3000, actual: [2300], maximums: [6000], now: 1) == [3000], "Curve takes over above macOS")
check(controller.targets(desired: 2000, actual: [3000], maximums: [6000], now: 2) == [2900], "Speed drops gradually")
check(controller.targets(desired: 2000, actual: [3000], maximums: [6000], now: 3) == [2800], "Speed keeps dropping gradually")
for step in 4...30 { _ = controller.targets(desired: 2000, actual: [2300], maximums: [6000], now: Double(step) * 0.1 + 3) }
check(controller.applied == [2300], "Never below the speed macOS had chosen")
check(controller.targets(desired: 2000, actual: [2300], maximums: [6000], now: 12.5) == nil && !controller.engaged,
      "Hand fans back to macOS once the curve stays at or below its speed")
check(controller.targets(desired: .infinity, actual: [2300, 2500], maximums: [6000, 5800], now: 20) == [6000, 5800],
      "Maximum respects each fan's own limit")
check(controller.targets(desired: 3000, actual: [6000, 5800], maximums: [6000, 5800], now: 21) == [5900, 5700],
      "Leaving maximum also ramps down")
check(controller.targets(desired: 5950, actual: [3000, 3000], maximums: [6000, 5800], now: 21.5) == [5950, 5800],
      "Rising curve applies immediately")
print("Passed \(checks) safety and sensor-decoding checks. No hardware writes.")
