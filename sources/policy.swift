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

/// What the helper should hold the fans at. The app rewrites it every second as a heartbeat.
enum CoolingTarget: Equatable {
    case manual(rpm: Double)
    case maximum
    var encoded: String {
        switch self {
        case .manual(let rpm): return "manual \(Int(rpm.rounded()))\n"
        case .maximum: return "maximum\n"
        }
    }
    init(encoded text: String) throws {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts == ["maximum"] { self = .maximum; return }
        guard parts.count == 2, parts[0] == "manual", let rpm = Double(parts[1]), rpm.isFinite else {
            throw Failure("Invalid cooling target")
        }
        self = .manual(rpm: rpm)
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
