import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct HardwareBounds {
    let minimum: Double
    let maximum: Double
    init(ranges: [(minimum: Double, maximum: Double)]) throws {
        guard !ranges.isEmpty, ranges.allSatisfy({
            $0.minimum.isFinite && $0.maximum.isFinite && $0.minimum >= 0 &&
            $0.minimum < $0.maximum && $0.maximum >= 1000 && $0.maximum <= 15000
        }) else { throw Failure("Fan limits are unavailable or invalid") }
        // Never offer fan-stop values, even if firmware reports a zero minimum.
        minimum = max(1000, ranges.map(\.minimum).max()!)
        maximum = ranges.map(\.maximum).min()!
        guard minimum < maximum else { throw Failure("Fans have no shared controllable RPM range") }
    }
}

struct Temperatures {
    let cpu: Double
    let gpu: Double
    let battery: Double?
    let ssd: Double?
    var highest: Double { max(cpu, gpu) }
    init(cpu: [Double], gpu: [Double], battery: [Double] = [], ssd: [Double] = []) throws {
        guard !cpu.isEmpty, !gpu.isEmpty else {
            throw Failure("CPU and GPU temperature sensors are required for manual control")
        }
        let values = cpu + gpu + battery + ssd
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 130 }) else {
            throw Failure("A temperature sensor returned an invalid value")
        }
        self.cpu = cpu.max()!; self.gpu = gpu.max()!; self.battery = battery.max(); self.ssd = ssd.max()
    }
}

/// Power draw in watts. Display only.
struct PowerReadings {
    /// Whole-system draw.
    let system: Double
    /// Power coming in from the adapter; nil when unplugged or unavailable.
    let adapter: Double?
    init(system: Double, adapter: Double?) throws {
        guard [system, adapter ?? 0].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 500 }) else {
            throw Failure("A power sensor returned an invalid value")
        }
        self.system = system
        // Adapter keys read a trickle when unplugged.
        self.adapter = adapter.flatMap { $0 >= 0.5 ? $0 : nil }
    }
    var text: String {
        String(format: "%.1f W", system) + (adapter.map { String(format: " · adapter %.1f W", $0) } ?? "")
    }
}

enum ThermalLevel { case nominal, fair, serious, critical, unknown }

/// Display colour band for a reading: green, yellow, red.
enum HeatLevel: Int, Comparable {
    case normal, warm, hot
    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }
    /// macOS thermal pressure can only raise the level, never lower it.
    func raised(by thermal: ThermalLevel) -> HeatLevel {
        switch thermal {
        case .fair: return max(self, .warm)
        case .serious, .critical: return .hot
        case .nominal, .unknown: return self
        }
    }
}

/// Which temperature the menu bar shows.
enum TemperatureReading: String, CaseIterable {
    case hottest, cpu, gpu, battery, ssd
    var title: String {
        switch self {
        case .hottest: return "Hottest (CPU or GPU)"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .ssd: return "SSD"
        }
    }
    /// One-letter prefix used when the menu bar shows several readings.
    var letter: String {
        switch self {
        case .hottest: return "H"
        case .cpu: return "C"
        case .gpu: return "G"
        case .battery: return "B"
        case .ssd: return "S"
        }
    }
    func value(in temperatures: Temperatures) -> Double? {
        switch self {
        case .hottest: return temperatures.highest
        case .cpu: return temperatures.cpu
        case .gpu: return temperatures.gpu
        case .battery: return temperatures.battery
        case .ssd: return temperatures.ssd
        }
    }
    /// Display bands only; the cooling cutoffs live in `CoolingPolicy`.
    func level(_ value: Double) -> HeatLevel {
        let (warm, hot): (Double, Double)
        switch self {
        case .battery: (warm, hot) = (35, 40)
        case .ssd: (warm, hot) = (55, 70)
        case .hottest, .cpu, .gpu: (warm, hot) = (70, 85)
        }
        return value >= hot ? .hot : value >= warm ? .warm : .normal
    }
}

/// Temperature → RPM points, interpolated linearly. Flat before the first and after the last point.
struct FanCurve: Equatable {
    struct Point: Equatable {
        var temperature: Double
        var rpm: Double
    }
    static let pointCount = 4
    /// Lowest temperature a point may use.
    static let lowestTemperature = 30.0
    let points: [Point]
    /// Checks the shape only; `validate(hardware:)` checks the speeds against the fans.
    init(_ points: [Point]) throws {
        guard points.count == Self.pointCount,
              points.allSatisfy({ $0.temperature.isFinite && $0.rpm.isFinite }),
              points.first!.temperature >= Self.lowestTemperature,
              points.last!.temperature < CoolingPolicy.stopLimit else {
            throw Failure("Curve temperatures must be between \(Int(Self.lowestTemperature))°C and \(Int(CoolingPolicy.stopLimit) - 1)°C")
        }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.temperature < $1.temperature }) else {
            throw Failure("Curve temperatures must increase from point to point")
        }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.rpm <= $1.rpm }) else {
            throw Failure("Curve speeds must not decrease as temperature rises")
        }
        self.points = points
    }
    func validate(hardware: HardwareBounds) throws {
        guard points.allSatisfy({ $0.rpm >= hardware.minimum && $0.rpm <= hardware.maximum }) else {
            throw Failure("Curve speeds must be within \(Int(ceil(hardware.minimum)))–\(Int(floor(hardware.maximum))) RPM")
        }
    }
    /// A gentle default spread across the hardware range.
    static func standard(for hardware: HardwareBounds) -> FanCurve {
        let low = ceil(hardware.minimum), high = floor(hardware.maximum)
        let speeds = [0.0, 0.3, 0.65, 1].map { ((low + (high - low) * $0) / 50).rounded(.down) * 50 }
        return try! FanCurve(zip([55.0, 65, 72, 78], speeds).map { Point(temperature: $0, rpm: max(low, $1)) })
    }
    func rpm(at temperature: Double) -> Double {
        guard temperature > points.first!.temperature else { return points.first!.rpm }
        for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
            return a.rpm + (b.rpm - a.rpm) * (temperature - a.temperature) / (b.temperature - a.temperature)
        }
        return points.last!.rpm
    }
}

/// What the helper should hold the fans at. The app rewrites it every second as a heartbeat.
enum CoolingTarget: Equatable {
    case manual(rpm: Double)
    case maximum
    case curve(FanCurve)
    var encoded: String {
        switch self {
        case .manual(let rpm): return "manual \(Int(rpm.rounded()))\n"
        case .maximum: return "maximum\n"
        case .curve(let curve):
            return "curve " + curve.points.map { "\(Int($0.temperature.rounded())) \(Int($0.rpm.rounded()))" }
                .joined(separator: " ") + "\n"
        }
    }
    init(encoded text: String) throws {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts == ["maximum"] { self = .maximum; return }
        if parts.first == "curve" {
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard numbers.count == parts.count - 1, numbers.count == FanCurve.pointCount * 2 else {
                throw Failure("Invalid cooling target")
            }
            self = .curve(try FanCurve(stride(from: 0, to: numbers.count, by: 2).map {
                FanCurve.Point(temperature: numbers[$0], rpm: numbers[$0 + 1])
            }))
            return
        }
        guard parts.count == 2, parts[0] == "manual", let rpm = Double(parts[1]), rpm.isFinite else {
            throw Failure("Invalid cooling target")
        }
        self = .manual(rpm: rpm)
    }
}

/// Runs Curve mode on top of macOS: fans stay automatic until the curve asks for clearly more than
/// macOS is doing, and while held they never drop below the speed macOS had chosen.
struct CurveController {
    /// Curve must exceed the fans' actual speed by this much before Baadgir takes over.
    static let engageMargin = 300.0
    /// How long the curve must sit at or below macOS's speed before handing the fans back.
    static let releaseDelay = 10.0
    /// Largest speed drop per update, so falling temperatures don't make fans hunt.
    static let rampDown = 100.0
    /// macOS's per-fan speeds when Baadgir took over; nil while macOS controls the fans.
    private(set) var floors: [Double]?
    private(set) var applied: [Double]?
    private var belowSince: Double?
    var engaged: Bool { floors != nil }
    /// Per-fan targets, or nil to leave the fans with macOS. `now` is monotonic seconds.
    mutating func targets(desired: Double, actual: [Double], maximums: [Double], now: Double) -> [Double]? {
        guard let floors, let applied else {
            guard desired >= (actual.max() ?? .infinity) + Self.engageMargin else { return nil }
            floors = actual; belowSince = nil
            applied = zip(actual, maximums).map { min(max(desired, $0), $1) }
            return applied
        }
        if desired <= floors.max()! {
            belowSince = belowSince ?? now
            if now - belowSince! >= Self.releaseDelay {
                self.floors = nil; self.applied = nil; belowSince = nil
                return nil
            }
        } else { belowSince = nil }
        let wanted = zip(floors, maximums).map { min(max(desired, $0), $1) }
        self.applied = zip(wanted, applied).map { $0 >= $1 ? $0 : max($0, $1 - Self.rampDown) }
        return self.applied
    }
}

/// Detects a stalled app by watching for control-file updates on a monotonic clock,
/// so changes to the system clock cannot hide a stall.
struct Heartbeat {
    private var stamp: Double?
    private var updated = 0.0
    /// `stamp` is the control file's modification time; `now` is monotonic seconds.
    mutating func isFresh(stamp: Double, now: Double) -> Bool {
        if stamp != self.stamp { self.stamp = stamp; updated = now }
        return now - updated <= CoolingPolicy.heartbeatTimeout
    }
}

struct CoolingPolicy {
    /// The helper returns fans to Auto when the app stops refreshing its target for this long.
    static let heartbeatTimeout = 10.0
    // Conservative software cutoffs, not manufacturer-certified limits.
    static let startLimit = 75.0
    static let stopLimit = 80.0
    /// Curve speed for the current readings; infinity (all fans at maximum) when it's hot.
    static func curveSpeed(_ curve: FanCurve, _ temperatures: Temperatures, thermal: ThermalLevel) -> Double {
        guard thermal == .nominal || thermal == .fair, temperatures.highest < stopLimit,
              temperatures.battery.map({ $0 < 45 }) ?? true else { return .infinity }
        return (curve.rpm(at: temperatures.highest) / 50).rounded() * 50
    }
    static func validateLimits(minimum: Double, maximum: Double, hardware: HardwareBounds) throws {
        guard minimum.isFinite, maximum.isFinite, minimum >= hardware.minimum,
              maximum <= hardware.maximum, minimum < maximum else {
            throw Failure("Choose a minimum below the maximum, within the hardware range")
        }
    }
    static func validateRange(rpm: Double, minimum: Double, maximum: Double,
                              hardware: HardwareBounds) throws {
        try validateLimits(minimum: minimum, maximum: maximum, hardware: hardware)
        guard rpm.isFinite, rpm >= minimum, rpm <= maximum else {
            throw Failure("Choose a speed inside your minimum and maximum limits")
        }
    }
    static func validateTemperature(_ temperatures: Temperatures?, thermal: ThermalLevel,
                                    starting: Bool) throws {
        guard let temperatures else { throw Failure("Temperature readings are unavailable; keeping automatic cooling") }
        guard thermal == .nominal || thermal == .fair else {
            throw Failure(starting ? "Thermal pressure is high; manual speed is unavailable"
                                   : "Thermal pressure is high; returning to automatic cooling")
        }
        let limit = starting ? startLimit : stopLimit
        guard temperatures.highest < limit,
              temperatures.battery.map({ $0 < 45 }) ?? true else {
            throw Failure(starting ? "Manual speed starts below \(Int(startLimit))°C. Use Max to cool down first."
                                   : "Temperature is high; returning to automatic cooling")
        }
    }
}

enum FanMode: String, Hashable { case auto, curve, manual, maximum }

enum PowerSource { case adapter, battery, unknown }

/// Optional rules that change fan mode when the Mac is plugged in or unplugged.
struct PowerRules: Equatable {
    /// On battery, end any session and keep automatic cooling.
    var autoOnBattery = false
    /// Mode to start when power is connected (or at launch while plugged in): Curve or Max, or nil.
    var onAdapter: FanMode?
    /// The mode to switch to after the source changes from `old` (nil at launch) to `new`, given the current mode.
    func mode(from old: PowerSource?, to new: PowerSource, current: FanMode) -> FanMode? {
        guard old != new else { return nil }
        switch new {
        case .battery: return autoOnBattery && current != .auto ? .auto : nil
        // Only from Auto: never override a mode the user picked.
        case .adapter: return current == .auto && onAdapter != .auto ? onAdapter : nil
        case .unknown: return nil
        }
    }
    /// Why `mode` can't be chosen right now, if a rule forbids it.
    func blocker(for mode: FanMode, on source: PowerSource) -> String? {
        guard autoOnBattery, source == .battery, mode != .auto else { return nil }
        return "On battery, Baadgir keeps automatic cooling. Change this in Settings › Rules."
    }
}

/// A fan-mode request from a baadgir:// link, Shortcuts, or the command line.
/// It goes through the same checks as choosing the mode in the app.
enum RemoteCommand: Equatable {
    case auto, curve, maximum
    case manual(rpm: Double?)
    init(url: URL) throws {
        guard url.scheme?.lowercased() == "baadgir", let name = url.host?.lowercased() else {
            throw Failure("Not a Baadgir link")
        }
        let rpm = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rpm" }?.value
        switch name {
        case "auto": self = .auto
        case "curve": self = .curve
        case "max", "maximum": self = .maximum
        case "manual":
            guard let rpm else { self = .manual(rpm: nil); return }
            guard let value = Double(rpm), value.isFinite else { throw Failure("Invalid RPM in link: \(rpm)") }
            self = .manual(rpm: value)
        default: throw Failure("Unknown Baadgir command: \(name)")
        }
    }
    /// Parses command-line words such as `max` or `manual 3000`.
    init(arguments: [String]) throws {
        switch arguments.map({ $0.lowercased() }) {
        case ["auto"]: self = .auto
        case ["curve"]: self = .curve
        case ["max"], ["maximum"]: self = .maximum
        case ["manual"]: self = .manual(rpm: nil)
        case let words where words.count == 2 && words[0] == "manual":
            guard let rpm = Double(words[1]), rpm.isFinite else { throw Failure("Invalid RPM: \(words[1])") }
            self = .manual(rpm: rpm)
        default: throw Failure("Unknown command")
        }
    }
    var url: URL {
        switch self {
        case .auto: return URL(string: "baadgir://auto")!
        case .curve: return URL(string: "baadgir://curve")!
        case .maximum: return URL(string: "baadgir://max")!
        case .manual(let rpm): return URL(string: "baadgir://manual" + (rpm.map { "?rpm=\(Int($0.rounded()))" } ?? ""))!
        }
    }
}

/// Fixed-size, oldest-first history kept in memory only. Never written to disk.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var start = 0
    init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }
    var count: Int { storage.count }
    mutating func append(_ element: Element) {
        if storage.count < capacity { storage.append(element); return }
        storage[start] = element
        start = (start + 1) % capacity
    }
    var elements: [Element] { Array(storage[start...] + storage[..<start]) }
}

/// One second of readings for the popover's history graphs. Nil where a reading was unavailable.
struct HistorySample {
    let cpu: Double?
    let gpu: Double?
    let fan: Double?
}

struct SMCValue {
    static func decode(type: String, bytes: [UInt8]) throws -> Double {
        let value: Double
        switch (type, bytes.count) {
        case ("flt ", 4): value = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case ("sp78", 2): value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("fpe2", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default: throw Failure("Unsupported SMC value format: \(type)")
        }
        guard value.isFinite else { throw Failure("Non-finite sensor value") }
        return value
    }
}

struct AutomaticRestoration {
    static func restore(keys: [String], readMode: (String) throws -> Double,
                        writeAutomatic: (String) throws -> Void,
                        retryDelay: () -> Void) -> Bool {
        var success = true
        for key in keys {
            var restored = false
            for _ in 0..<3 {
                do {
                    let mode = try readMode(key)
                    if mode == 0 || mode == 3 { restored = true; break }
                    try writeAutomatic(key)
                    let confirmed = try readMode(key)
                    if confirmed == 0 || confirmed == 3 { restored = true; break }
                } catch { }
                retryDelay()
            }
            // Continue restoring the remaining fans even when one fails.
            success = success && restored
        }
        return success
    }
}
