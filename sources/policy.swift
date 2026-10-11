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

/// Apple silicon CPU/GPU temperature keys per chip generation. The same key can mean something else on another
/// generation, so only the running chip's keys are probed; an unknown (newer) chip probes every known key.
/// Reference: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
enum SensorKeys {
    enum Generation: Int, CaseIterable { case m1 = 1, m2, m3, m4, m5 }
    /// "Apple M3 Pro" → .m3; nil for a chip this table doesn't know.
    static func generation(brand: String) -> Generation? {
        brand.split(separator: " ").lazy.compactMap { word -> Generation? in
            guard word.hasPrefix("M"), let number = Int(word.dropFirst()) else { return nil }
            return Generation(rawValue: number)
        }.first
    }
    static func cpu(_ generation: Generation?) -> [String] {
        guard let generation else { return unique(Generation.allCases.flatMap(cpu)) }
        switch generation {
        case .m1: return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case .m2: return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case .m3: return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                          "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case .m4: return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case .m5: return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
                          "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        }
    }
    static func gpu(_ generation: Generation?) -> [String] {
        guard let generation else { return unique(Generation.allCases.flatMap(gpu)) }
        switch generation {
        case .m1: return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2: return ["Tg0f", "Tg0j"]
        case .m3: return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4: return ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m5: return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        }
    }
    /// Manual and Curve can hold fans below what macOS would choose, so they need this chip's own sensor keys.
    /// An unknown chip's readings may come from keys that mean something else on it; it gets Auto and Max only.
    static func requireKnown(_ generation: Generation?) throws {
        guard generation != nil else {
            throw Failure("Baadgir doesn't know this chip's temperature sensors, so only Auto and Max are available")
        }
    }
    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
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

/// Display color band for a reading: green, yellow, red.
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

/// Which readings the menu bar shows: temperatures, and the fan speed.
enum TemperatureReading: String, CaseIterable {
    case hottest, cpu, gpu, battery, ssd, fan
    var title: String {
        switch self {
        case .hottest: return "Hottest (CPU or GPU)"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .ssd: return "SSD"
        case .fan: return "Fan speed"
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
        case .fan: return "F"
        }
    }
    /// Temperatures only; the fan speed comes from the fans.
    func value(in temperatures: Temperatures) -> Double? {
        switch self {
        case .hottest: return temperatures.highest
        case .cpu: return temperatures.cpu
        case .gpu: return temperatures.gpu
        case .battery: return temperatures.battery
        case .ssd: return temperatures.ssd
        case .fan: return nil
        }
    }
    /// "72°C" or "2500 RPM"; compact drops the unit to "72°" or "2500" when several readings share the menu bar.
    func text(_ value: Double?, compact: Bool) -> String {
        let number = value.map { String(Int($0.rounded())) } ?? "—"
        if self == .fan { return compact ? number : number + " RPM" }
        return number + (compact ? "°" : "°C")
    }
    /// The widest value to reserve room for, so the menu bar item never shifts as numbers change.
    var widest: Double { self == .fan ? 9999 : 130 }
    /// Display bands only; the cooling cutoffs live in `CoolingPolicy`. Fan speed is banded by `fanLevel`, against the fans' range.
    func level(_ value: Double) -> HeatLevel? {
        let (warm, hot): (Double, Double)
        switch self {
        case .battery: (warm, hot) = (35, 40)
        case .ssd: (warm, hot) = (55, 70)
        case .hottest, .cpu, .gpu: (warm, hot) = (70, 85)
        case .fan: return nil
        }
        return value >= hot ? .hot : value >= warm ? .warm : .normal
    }
    /// Fan speed by how far it sits between the fans' minimum and maximum: warm from half way, hot from 80%.
    static func fanLevel(_ rpm: Double, minimum: Double, maximum: Double) -> HeatLevel? {
        guard maximum > minimum else { return nil }
        let position = (rpm - minimum) / (maximum - minimum)
        return position >= 0.8 ? .hot : position >= 0.5 ? .warm : .normal
    }
}

extension TemperatureReading {
    /// What a Mac can show: a fanless Mac has no fan speed.
    static func available(fanless: Bool) -> [TemperatureReading] { fanless ? allCases.filter { $0 != .fan } : allCases }
    /// The chosen readings this Mac can show, falling back to the hottest temperature so the menu bar is never empty.
    static func shown(_ chosen: [TemperatureReading], fanless: Bool) -> [TemperatureReading] {
        let shown = chosen.filter(available(fanless: fanless).contains)
        return shown.isEmpty ? [.hottest] : shown
    }
}

/// Stacked menu bar readings: two to a column, read top to bottom, then left to right.
enum MenuBarLayout {
    static func columns(_ readings: [TemperatureReading]) -> [[TemperatureReading]] {
        stride(from: 0, to: readings.count, by: 2).map { Array(readings[$0..<min($0 + 2, readings.count)]) }
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
        for (index, point) in points.enumerated() {
            let floor = SafeMinimum.rpm(at: point.temperature, hardware: hardware)
            guard point.rpm >= floor else {
                throw Failure("Point \(index + 1) needs at least \(Int(floor)) RPM at \(Int(point.temperature))°C, the safe minimum")
            }
        }
    }
    func rpm(at temperature: Double) -> Double {
        guard temperature > points.first!.temperature else { return points.first!.rpm }
        for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
            return a.rpm + (b.rpm - a.rpm) * (temperature - a.temperature) / (b.temperature - a.temperature)
        }
        return points.last!.rpm
    }
}

/// Ready-made curves to start from. System is the default.
enum CurvePreset: CaseIterable {
    /// On the safe minimum: Curve never wants more than macOS until the floor does, so the fans keep macOS's own
    /// cooling and only get the extra margin when hot.
    case system
    /// Starts early and spreads the whole range from 55°C to 78°C.
    case balanced
    /// Starts at 45°C and reaches maximum at 72°C, trading quiet for lower temperatures.
    case performance
    var name: String {
        switch self {
        case .system: return "System"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        }
    }
    func curve(for hardware: HardwareBounds) -> FanCurve {
        let temperatures: [Double], shares: [Double]
        switch self {
        case .system: (temperatures, shares) = ([55, 65, 72, 78], [0, 0, 0, 0])
        case .balanced: (temperatures, shares) = ([55, 65, 72, 78], [0, 0.3, 0.65, 1])
        case .performance: (temperatures, shares) = ([45, 55, 65, 72], [0.2, 0.45, 0.75, 1])
        }
        let low = ceil(hardware.minimum), high = floor(hardware.maximum)
        // Round numbers where they fit, never below the safe minimum, which both only rise with temperature.
        return try! FanCurve(zip(temperatures, shares).map { temperature, share in
            let rpm = ((low + (high - low) * share) / 50).rounded(.down) * 50
            return FanCurve.Point(temperature: temperature, rpm: max(low, rpm, SafeMinimum.rpm(at: temperature, hardware: hardware)))
        })
    }
}

/// The slowest Curve may run at each temperature, as a share of the fans' range: the minimum up to 65°C, a quarter
/// of the range at 72°C, and half at 78°C. Interpolated between, flat after; from 80°C Curve runs at maximum anyway.
/// A share of the range rather than fixed RPM, since fan ranges differ between Macs.
enum SafeMinimum {
    static let points: [(temperature: Double, share: Double)] = [(65, 0), (72, 0.25), (78, 0.5)]
    static func rpm(at temperature: Double, hardware: HardwareBounds) -> Double {
        let share: Double
        if temperature <= points.first!.temperature { share = points.first!.share }
        else if let (a, b) = zip(points, points.dropFirst()).first(where: { temperature <= $1.temperature }) {
            share = a.share + (b.share - a.share) * (temperature - a.temperature) / (b.temperature - a.temperature)
        } else { share = points.last!.share }
        // Whole RPM, rounded up so a curve point shown as a whole number is never just under it.
        return ceil(hardware.minimum + share * (hardware.maximum - hardware.minimum))
    }
}

/// What the helper should hold the fans at. The app rewrites it every second as a heartbeat.
enum CoolingTarget: Equatable {
    case manual(rpm: Double)
    case maximum
    case curve(FanCurve)
    var isManual: Bool { if case .manual = self { return true } else { return false } }
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
/// A fan macOS has stopped (or runs below its minimum) counts as running at its minimum, so an idle Mac whose fans are off
/// is handed back once the curve asks for no more than that.
struct CurveController {
    /// Curve must exceed the fans' actual speed by this much before Baadgir takes over.
    static let engageMargin = 300.0
    /// How long the curve must sit at or below macOS's speed before handing the fans back.
    static let releaseDelay = 10.0
    /// Largest speed drop per update, so falling temperatures don't make fans hunt.
    static let rampDown = 100.0
    /// How far the curve must fall below the applied speed before the fans start slowing, so small wobbles in the
    /// steadied temperature don't make them hunt. Once started, the ramp goes all the way down.
    static let holdMargin = 150.0
    /// macOS's per-fan speeds when Baadgir took over; nil while macOS controls the fans.
    private(set) var floors: [Double]?
    private(set) var applied: [Double]?
    private var belowSince: Double?
    private var rampingDown = false
    var engaged: Bool { floors != nil }
    /// Per-fan targets, or nil to leave the fans with macOS. `now` is monotonic seconds.
    mutating func targets(desired: Double, actual: [Double], minimums: [Double], maximums: [Double], now: Double) -> [Double]? {
        guard let floors, let applied else {
            let running = zip(actual, minimums).map { max($0, $1) }
            guard desired >= (running.max() ?? .infinity) + Self.engageMargin else { return nil }
            floors = running; belowSince = nil
            applied = zip(running, maximums).map { min(max(desired, $0), $1) }
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
        if zip(wanted, applied).contains(where: { $1 - $0 >= Self.holdMargin }) { rampingDown = true }
        // Faster applies at once; slower only while ramping, otherwise the fans hold their speed.
        let next = zip(wanted, applied).map { $0 >= $1 ? $0 : rampingDown ? max($0, $1 - Self.rampDown) : $1 }
        if zip(next, wanted).allSatisfy({ $0 <= $1 }) { rampingDown = false }
        self.applied = next
        return next
    }
}

/// The temperature Curve follows: the hottest CPU/GPU reading, steadied so brief spikes don't make the fans hunt. It
/// follows a rise within seconds and a fall more slowly, so it errs toward cooling. Only the curve and its safe minimum
/// use it: the stop limit, thermal pressure and the battery and SSD cutoffs still act on the raw readings.
struct SteadyTemperature {
    /// Time constants in seconds: about two thirds of a step is followed in this time.
    static let riseTime = 6.0, fallTime = 20.0
    private(set) var value: Double?
    private var time = 0.0
    /// `now` is monotonic seconds.
    mutating func update(_ reading: Double, now: Double) -> Double {
        guard let value, value.isFinite else { self.value = reading; time = now; return reading }
        let constant = reading > value ? Self.riseTime : Self.fallTime
        let next = value + (reading - value) * (1 - exp(-max(0, now - time) / constant))
        self.value = next; time = now
        return next
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
    /// The watchdog kills the helper and restores Auto when the helper's loop stalls for this long.
    static let helperStallTimeout = 15.0
    // Conservative software cutoffs, not manufacturer-certified limits.
    static let startLimit = 75.0
    static let stopLimit = 80.0
    static let batteryLimit = 45.0
    static let ssdLimit = 70.0
    /// Battery and SSD are below their cutoffs, or have no sensor.
    static func othersBelowLimits(_ temperatures: Temperatures) -> Bool {
        (temperatures.battery.map { $0 < batteryLimit } ?? true) && (temperatures.ssd.map { $0 < ssdLimit } ?? true)
    }
    /// Curve speed for the current readings, never below the safe minimum; infinity (all fans at maximum) when it's hot.
    /// `following` is the steadied temperature the curve looks up; the cutoffs always use the raw readings.
    static func curveSpeed(_ curve: FanCurve, _ temperatures: Temperatures, following: Double? = nil,
                           thermal: ThermalLevel, hardware: HardwareBounds) -> Double {
        guard thermal == .nominal || thermal == .fair, temperatures.highest < stopLimit,
              othersBelowLimits(temperatures) else { return .infinity }
        let followed = following ?? temperatures.highest
        // Rounding must not leave the curve's range, which is within the fans' hardware range.
        let rounded = (curve.rpm(at: followed) / 50).rounded() * 50
        // Checked here as well as on the curve's points: past its last point the curve stays flat while the minimum rises.
        return max(min(max(rounded, curve.points.first!.rpm), curve.points.last!.rpm),
                   SafeMinimum.rpm(at: followed, hardware: hardware))
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
        guard temperatures.highest < limit else {
            throw Failure(starting ? "Manual speed starts below \(Int(startLimit))°C. Use Max to cool down first."
                                   : "Temperature is high; returning to automatic cooling")
        }
        guard othersBelowLimits(temperatures) else {
            throw Failure(starting ? "Battery or SSD is too warm for manual speed. Use Max to cool down first."
                                   : "Battery or SSD is hot; returning to automatic cooling")
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
            self = .manual(rpm: try rpm.map(Self.rpm))
        // Never repeat the link's text: any web page can open one, and Baadgir would show it as its own words.
        default: throw Failure("Unknown Baadgir command")
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
            self = .manual(rpm: try Self.rpm(words[1]))
        default: throw Failure("Unknown command")
        }
    }
    /// Above any fan's range, so the app can name the real limits, yet small enough to round to a whole number.
    static let rpmLimit = 20_000.0
    private static func rpm(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value >= 0, value <= rpmLimit else {
            throw Failure("Invalid RPM")
        }
        return value
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

/// True when `path` is a regular file and it and every folder above it are owned by root and writable only by root,
/// so no other account or app can replace what root will run.
func isRootOwned(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    var current = path
    var info = stat()
    guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
    while true {
        guard lstat(current, &info) == 0, info.st_uid == 0, info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        if current == "/" { return true }
        current = (current as NSString).deletingLastPathComponent
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
    /// The watchdog's retries once the helper is gone. SMC failures can last a while, so it keeps trying for `attempts`.
    /// The old helper closes its lock a moment after the pipe, so a lock still busy after `busyAttempts` belongs to a new
    /// session, which restores Auto itself, or to a stalled helper stuck in the kernel.
    static func retry(attempts: Int = 300, busyAttempts: Int = 30, isBusy: (Error) -> Bool,
                      delay: () -> Void, _ attempt: () throws -> Void) -> Bool {
        var busy = 0
        for _ in 0..<attempts {
            do { try attempt(); return true }
            catch where isBusy(error) {
                busy += 1
                if busy >= busyAttempts { return false }
            } catch { }
            delay()
        }
        return false
    }
}
