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
    var highest: Double { max(cpu, gpu) }
    init(cpu: [Double], gpu: [Double], battery: [Double] = []) throws {
        guard !cpu.isEmpty, !gpu.isEmpty else {
            throw Failure("CPU and GPU temperature sensors are required for manual control")
        }
        let values = cpu + gpu + battery
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 130 }) else {
            throw Failure("A temperature sensor returned an invalid value")
        }
        self.cpu = cpu.max()!; self.gpu = gpu.max()!; self.battery = battery.max()
    }
}

enum ThermalLevel { case nominal, fair, serious, critical, unknown }

struct CoolingPolicy {
    static let sessionSeconds = 60
    // Conservative software cutoffs, not manufacturer-certified limits.
    static let startLimit = 75.0
    static let stopLimit = 80.0
    static func validateRange(rpm: Double, minimum: Double, maximum: Double,
                              hardware: HardwareBounds) throws {
        guard [rpm, minimum, maximum].allSatisfy({ $0.isFinite }),
              minimum >= hardware.minimum, maximum <= hardware.maximum,
              minimum < maximum, rpm >= minimum, rpm <= maximum else {
            throw Failure("Choose ordered minimum and maximum limits within the hardware range, and an RPM inside those limits")
        }
    }
    static func validateTemperature(_ temperatures: Temperatures?, thermal: ThermalLevel,
                                    starting: Bool) throws {
        guard let temperatures else { throw Failure("Temperature readings are unavailable; keeping automatic cooling") }
        guard thermal == .nominal || thermal == .fair else {
            throw Failure("Thermal pressure is high; returning to automatic cooling")
        }
        let limit = starting ? startLimit : stopLimit
        guard temperatures.highest < limit,
              temperatures.battery.map({ $0 < 45 }) ?? true else {
            throw Failure("Temperature is high; returning to automatic cooling")
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
