import AppKit
import SwiftUI
import IOKit
import Darwin
import ServiceManagement

struct Fan {
    let index: Int
    let rpm: Float
    let minimum: Float
    let maximum: Float
    let modeKey: String
    let mode: UInt8
}
final class SMC {
    var connection: io_connect_t = 0
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw Failure("AppleSMC is unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw Failure("Cannot open AppleSMC: \(result)") }
    }
    deinit { IOServiceClose(connection) }
    func call(_ key: String, command: UInt8, size: UInt32 = 0, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, bytes.count <= 32 else { throw Failure("Invalid SMC request") }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        withUnsafeBytes(of: code) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: size) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = command
        input.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        var output = [UInt8](repeating: 0, count: 80)
        var count = 80
        let result = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                IOConnectCallStructMethod(connection, 2, src.baseAddress, 80, dst.baseAddress, &count)
            }
        }
        guard result == KERN_SUCCESS, count == 80, output[40] == 0 else {
            throw Failure("SMC \(key) command \(command) rejected (IOKit \(result), SMC \(output[40]))")
        }
        return output
    }
    func read(_ key: String) throws -> (String, [UInt8]) {
        let info = try call(key, command: 9)
        let size = info[28..<32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard size > 0, size <= 32 else { throw Failure("Unexpected key size") }
        let type = String(bytes: info[32..<36].reversed(), encoding: .ascii) ?? ""
        let data = try call(key, command: 5, size: size)
        return (type, Array(data[48..<(48 + Int(size))]))
    }
    func number(_ key: String) throws -> Float {
        let (type, data) = try read(key)
        let value = try SMCValue.decode(type: type, bytes: data)
        guard value >= 0 else { throw Failure("Invalid value for \(key)") }
        return Float(value)
    }
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var batteryKeys: [String] = []
    private var ssdKeys: [String] = []
    private var discoveredTemperatures = false
    func temperatures() throws -> Temperatures {
        if !discoveredTemperatures {
            // Known Apple silicon CPU/GPU sensor IDs, including M5.
            // Reference: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
            let cpuCandidates = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j",
                "Tp0m", "Tp0p", "Tp0u", "Tp0y", "Tp01", "Tp05", "Tp09", "Tp0D",
                "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0b", "Tp0V", "Tp0Y", "Tp0e",
                "Te05", "Te0S", "Te09", "Te0H"]
            let gpuCandidates = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g",
                "Tg05", "Tg0D", "Tg0L", "Tg0G", "Tg0H", "Tg0K", "Tg0e", "Tg0k", "Tg1U", "Tg1k"]
            func available(_ keys: [String]) -> [String] {
                keys.filter { key in
                    guard let value = try? number(key) else { return false }
                    return value > 0 && value <= 130
                }
            }
            cpuKeys = available(cpuCandidates)
            gpuKeys = available(gpuCandidates)
            batteryKeys = available(["TB0T", "TB1T", "TB2T"])
            // SSD (NAND) sensors; display only.
            ssdKeys = available(["TH0x", "TH0A", "TH0B", "TH0a", "TH0b"])
            guard !cpuKeys.isEmpty, !gpuKeys.isEmpty else {
                throw Failure("CPU and GPU temperature readings are unavailable")
            }
            discoveredTemperatures = true
        }
        // Once discovered, every sensor must stay readable. Never silently discard a failed sensor.
        return try Temperatures(cpu: cpuKeys.map { Double(try number($0)) },
                                gpu: gpuKeys.map { Double(try number($0)) },
                                battery: batteryKeys.map { Double(try number($0)) },
                                ssd: ssdKeys.map { Double(try number($0)) })
    }
    func fans() throws -> [Fan] {
        let count = try number("FNum")
        guard count >= 1, count <= 8, count.rounded() == count else { throw Failure("No supported fans") }
        return try (0..<Int(count)).map { index in
            let prefix = "F\(index)"
            let modeKey = (try? read(prefix + "md")) != nil ? prefix + "md" : prefix + "Md"
            let mode = try number(modeKey)
            guard [Float(0), 1, 3].contains(mode) else { throw Failure("Unknown fan mode") }
            let maximum = try number(prefix + "Mx")
            guard maximum >= 1000, maximum <= 15000 else { throw Failure("Unexpected maximum RPM") }
            let minimum = try number(prefix + "Mn")
            guard minimum < maximum else { throw Failure("Unexpected minimum RPM") }
            let rpm = try number(prefix + "Ac")
            guard rpm <= 20000 else { throw Failure("Implausible fan RPM") }
            return Fan(index: index, rpm: rpm, minimum: minimum, maximum: maximum,
                       modeKey: modeKey, mode: UInt8(mode))
        }
    }
    // The only writable keys are fan target and mode. No diagnostic unlocks.
    func write(_ key: String, expectedType: String, bytes: [UInt8]) throws {
        guard key.count == 4, key.first == "F", key.dropFirst().first?.isNumber == true,
              ["Tg", "md", "Md"].contains(String(key.suffix(2))) else { throw Failure("Write blocked") }
        let (type, old) = try read(key)
        guard type == expectedType, old.count == bytes.count else { throw Failure("Write format mismatch") }
        _ = try call(key, command: 6, size: UInt32(bytes.count), bytes: bytes)
    }
    func target(_ fan: Fan, rpm: Float? = nil) throws {
        var value = rpm ?? fan.maximum
        guard value.isFinite, value >= max(1000, fan.minimum), value <= fan.maximum else {
            throw Failure("Target outside the hardware range")
        }
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        try write("F\(fan.index)Tg", expectedType: "flt ", bytes: bytes)
    }
    func mode(_ fan: Fan, _ value: UInt8) throws {
        guard value == 0 || value == 1 else { throw Failure("Mode blocked") }
        try write(fan.modeKey, expectedType: "ui8 ", bytes: [value])
    }
}

func thermalLevel() -> ThermalLevel {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .unknown
    }
}
var interrupted: sig_atomic_t = 0
func handleSignal(_ signal: Int32) { interrupted = 1 }
func acquireLock() throws -> Int32 {
    let lock = open("/var/run/local.baadgir.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw Failure("Cannot create cooling session lock") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        close(lock)
        throw Failure(lockBusy)
    }
    return lock
}
/// Reads the app's requested target and the control file's modification time.
func readControl(_ path: String) throws -> (target: CoolingTarget, modified: Double) {
    // Non-blocking so a FIFO in place of the file cannot stall the helper while fans are manual.
    let file = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard file >= 0 else { throw Failure("Cooling controls are unavailable; returning to automatic cooling") }
    defer { close(file) }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 else {
        throw Failure("Cooling controls are invalid")
    }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(file, &buffer, buffer.count)
    guard count > 0 else { throw Failure("Cooling controls are empty") }
    let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return (try CoolingTarget(encoded: String(decoding: buffer[0..<count], as: UTF8.self)), modified)
}
func coolingSession(parent: pid_t, directory: String) throws {
    guard geteuid() == 0 else { throw Failure("Fan control requires administrator authorization") }
    let lock = try acquireLock()
    defer { close(lock) }
    let stopPath = directory + "/stop", controlPath = directory + "/control"
    func cancelled() -> Bool { kill(parent, 0) != 0 || FileManager.default.fileExists(atPath: stopPath) }
    guard !cancelled() else { throw Failure("Cooling session was cancelled before it started") }
    let smc = try SMC()
    let fans = try smc.fans()
    guard fans.allSatisfy({ $0.rpm <= $0.maximum }) else {
        throw Failure("Actual RPM exceeds the reported limit; keeping system control")
    }
    guard fans.allSatisfy({ $0.mode != 1 }) else {
        throw Failure("Another app already controls a fan. Return it to Auto first.")
    }
    let bounds = try HardwareBounds(ranges: fans.map { (Double($0.minimum), Double($0.maximum)) })
    var heartbeat = Heartbeat()
    func requestedTarget() throws -> CoolingTarget {
        let (target, modified) = try readControl(controlPath)
        guard heartbeat.isFresh(stamp: modified, now: ProcessInfo.processInfo.systemUptime) else {
            throw Failure("Baadgir stopped responding; returning to automatic cooling")
        }
        if case .manual(let rpm) = target {
            try CoolingPolicy.validateRange(rpm: rpm, minimum: bounds.minimum, maximum: bounds.maximum, hardware: bounds)
        }
        return target
    }
    func rpm(for fan: Fan, _ target: CoolingTarget) -> Float {
        if case .manual(let rpm) = target { return Float(rpm) }
        return fan.maximum
    }
    // The first target must also be recent by wall clock; later checks use the monotonic heartbeat.
    guard abs(Date().timeIntervalSince1970 - (try readControl(controlPath)).modified) <= CoolingPolicy.heartbeatTimeout else {
        throw Failure("Cooling controls are stale")
    }
    if case .manual = try requestedTarget() {
        try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: true)
    }
    signal(SIGTERM, handleSignal); signal(SIGINT, handleSignal); signal(SIGHUP, handleSignal)
    // Started before any fan is touched; it restores Auto even if this process is force-killed.
    let watchdog = try startWatchdog(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
    defer { close(watchdog) }
    var touched: [Fan] = []
    func restore() -> Bool {
        AutomaticRestoration.restore(keys: touched.map(\.modeKey),
            readMode: { Double(try smc.number($0)) },
            writeAutomatic: { try smc.write($0, expectedType: "ui8 ", bytes: [0]) },
            retryDelay: { usleep(100_000) })
    }
    do {
        guard !cancelled() else { throw Failure("Cooling session was cancelled") }
        for fan in fans {
            // Start at maximum to avoid entering manual mode with a stale low target.
            touched.append(fan)
            try smc.target(fan)
            try smc.mode(fan, 1)
            guard try smc.number(fan.modeKey) == 1,
                  abs(try smc.number("F\(fan.index)Tg") - fan.maximum) <= 1 else {
                throw Failure("Fan controller did not confirm maximum cooling")
            }
        }
        var applied = CoolingTarget.maximum
        let clock = ContinuousClock()
        var previous = clock.now
        var changed = previous
        // Runs until the app chooses Auto, quits, stops responding, or a safety check fails.
        while interrupted == 0 {
            let now = clock.now
            if previous.duration(to: now) > .seconds(3) || cancelled() { break }
            previous = now
            let target = try requestedTarget()
            if case .manual = target {
                try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: false)
            }
            if target != applied {
                for fan in fans { try smc.target(fan, rpm: rpm(for: fan, target)) }
                applied = target; changed = now
            }
            let live = try smc.fans()
            guard live.count == fans.count else { throw Failure("Fan configuration changed") }
            for (fan, original) in zip(live, fans) {
                let expected = rpm(for: original, applied)
                guard fan.minimum == original.minimum, fan.maximum == original.maximum,
                      fan.mode == 1, abs(try smc.number("F\(fan.index)Tg") - expected) <= 1 else {
                    throw Failure("System reclaimed fan control; session ended")
                }
                if changed.duration(to: now) > .seconds(5), fan.rpm < max(300, expected * 0.35) {
                    throw Failure("Fan speed did not respond; returning to automatic cooling")
                }
            }
            usleep(500_000)
        }
    } catch {
        if !restore() {
            throw Failure("Automatic control could not be verified. Restart your Mac. Original error: \(error)")
        }
        throw error
    }
    guard restore() else { throw Failure("Automatic control could not be verified. Restart your Mac.") }
}
/// Spawns `executable --watchdog` with the read end of a pipe as stdin and returns the write end.
/// The watchdog sees end-of-file when this process exits for any reason, including SIGKILL.
func startWatchdog(executable: String) throws -> Int32 {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw Failure("Cannot start the safety watchdog") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO)
    // Detached output: no log files, and the administrator prompt's pipe isn't held open.
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Inherit nothing else (notably the session lock) and leave this process group's signals behind.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    let argv = [executable, "--watchdog"].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    close(fds[0])
    guard result == 0 else { close(fds[1]); throw Failure("Cannot start the safety watchdog") }
    return fds[1]
}
/// Waits for the helper to exit, then makes sure no fan is left in manual mode.
func watchdog() {
    signal(SIGHUP, SIG_IGN); signal(SIGINT, SIG_IGN)
    var byte: UInt8 = 0
    while true {
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    // The helper's lock may close a moment after the pipe.
    for _ in 0..<20 {
        do { try restoreAutomatic(); return }
        catch let failure as Failure where failure.description == lockBusy { usleep(100_000) }
        catch { return }
    }
}
let lockBusy = "A cooling session is already running"
/// Returns fans left in manual mode (for example after a crash or by another app) to Auto.
func restoreAutomatic() throws {
    guard geteuid() == 0 else { throw Failure("Fan control requires administrator authorization") }
    let lock = try acquireLock()
    defer { close(lock) }
    let smc = try SMC()
    let manual = try smc.fans().filter { $0.mode == 1 }
    guard AutomaticRestoration.restore(keys: manual.map(\.modeKey),
        readMode: { Double(try smc.number($0)) },
        writeAutomatic: { try smc.write($0, expectedType: "ui8 ", bytes: [0]) },
        retryDelay: { usleep(100_000) }) else {
        throw Failure("Automatic control could not be verified. Restart your Mac.")
    }
}

enum FanMode: Hashable { case auto, manual, maximum }

final class CoolingModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var temperatures: Temperatures?
    @Published var sensorError = "Reading sensors…"
    @Published var minimumText = "1000" { didSet { limitsChanged() } }
    @Published var maximumText = "6000" { didSet { limitsChanged() } }
    @Published var selectedRPM = 6000.0 {
        didSet { if initializedLimits { defaults.set(Int(selectedRPM.rounded()), forKey: "manualRPM") } }
    }
    @Published private(set) var mode = FanMode.auto
    @Published private(set) var sessionRunning = false
    @Published private(set) var pending: String?
    @Published var message: String?
    /// Readings shown in the menu bar, in menu order. Never empty.
    @Published var menuBarReadings: [TemperatureReading] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "menuBarReadings") ?? [])
            .compactMap(TemperatureReading.init(rawValue:))
        return saved.isEmpty ? [.hottest] : saved
    }() {
        didSet { defaults.set(menuBarReadings.map(\.rawValue), forKey: "menuBarReadings"); onMenuBarLayoutChange?() }
    }
    var onMenuBarLayoutChange: (() -> Void)?
    func toggleMenuBar(_ reading: TemperatureReading) {
        if menuBarReadings.contains(reading) {
            guard menuBarReadings.count > 1 else { return }
            menuBarReadings.removeAll { $0 == reading }
        } else {
            menuBarReadings = TemperatureReading.allCases.filter { $0 == reading || menuBarReadings.contains($0) }
        }
    }
    @Published var colorsTemperatures = UserDefaults.standard.object(forKey: "colorsTemperatures") as? Bool ?? true {
        didSet { defaults.set(colorsTemperatures, forKey: "colorsTemperatures"); onUpdate?() }
    }
    /// Colour band for a reading, or nil when colours are off or the value is missing.
    func heatLevel(_ reading: TemperatureReading, _ value: Double?) -> HeatLevel? {
        guard colorsTemperatures, let value else { return nil }
        return reading.level(value).raised(by: thermalLevel())
    }
    /// Mirrors the login item's registration; System Settings can change it behind our back.
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status
    @Published private(set) var loginItemError: String?
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch { loginItemError = "Cannot change Launch at Login: \(error.localizedDescription)" }
        loginItemStatus = SMAppService.mainApp.status
    }
    func refreshLoginItemStatus() { loginItemStatus = SMAppService.mainApp.status }
    var bounds: HardwareBounds?
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "local.baadgir.sensors")
    private let defaults = UserDefaults.standard
    private var smc: SMC?
    private var reading = false
    private var initializedLimits = false
    private var helper: Process?
    private var directory: URL?

    var minimum: Double? { Double(minimumText) }
    var maximum: Double? { Double(maximumText) }
    var rangeIsValid: Bool {
        guard let bounds, let minimum, let maximum else { return false }
        return (try? CoolingPolicy.validateLimits(minimum: minimum, maximum: maximum, hardware: bounds)) != nil
    }
    var sliderRange: ClosedRange<Double> {
        if rangeIsValid, let minimum, let maximum { return minimum...maximum }
        return (bounds?.minimum ?? 1000)...(bounds?.maximum ?? 6000)
    }
    /// Fans held in manual mode by something other than this app's session.
    var externallyControlled: Bool {
        !sessionRunning && Date() > settlingUntil && fans.contains(where: { $0.mode == 1 })
    }
    private var settlingUntil = Date.distantPast
    var showsManualControls: Bool { sessionRunning && mode == .manual }
    var displayedMode: FanMode {
        if sessionRunning { return mode }
        return externallyControlled ? .manual : .auto
    }
    var status: String {
        if let pending { return pending }
        if externallyControlled { return "A fan is stuck in manual mode" }
        guard sessionRunning else { return "Automatic cooling" }
        if mode == .maximum { return "Maximum cooling" }
        return "Manual · \(Int(selectedRPM.rounded()).formatted()) RPM"
    }
    var thermalText: String {
        switch thermalLevel() {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "High"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
    private func limitsChanged() {
        if initializedLimits, rangeIsValid, let minimum, let maximum {
            defaults.set(Int(minimum), forKey: "minimumRPM")
            defaults.set(Int(maximum), forKey: "maximumRPM")
        }
        guard selectedRPM.isFinite else { selectedRPM = sliderRange.upperBound; return }
        selectedRPM = min(max(selectedRPM, sliderRange.lowerBound), sliderRange.upperBound)
    }
    private func loadLimits(_ bounds: HardwareBounds) {
        let lower = Int(ceil(bounds.minimum)), upper = Int(floor(bounds.maximum))
        let savedMinimum = defaults.object(forKey: "minimumRPM") as? Int
        let savedMaximum = defaults.object(forKey: "maximumRPM") as? Int
        if let savedMinimum, let savedMaximum, (try? CoolingPolicy.validateLimits(
            minimum: Double(savedMinimum), maximum: Double(savedMaximum), hardware: bounds)) != nil {
            minimumText = String(savedMinimum); maximumText = String(savedMaximum)
        } else {
            minimumText = String(lower); maximumText = String(upper)
        }
        selectedRPM = Double(defaults.object(forKey: "manualRPM") as? Int ?? upper)
        limitsChanged()
        initializedLimits = true
    }
    func refresh() {
        heartbeat()
        guard !reading else { return }
        reading = true
        queue.async { [weak self] in
            guard let self else { return }
            var fans: [Fan] = []
            var temperatures: Temperatures?
            var errorMessage = ""
            do {
                if self.smc == nil { self.smc = try SMC() }
                fans = try self.smc!.fans()
                do { temperatures = try self.smc!.temperatures() }
                catch { errorMessage = String(describing: error) }
            } catch {
                self.smc = nil
                errorMessage = String(describing: error)
            }
            DispatchQueue.main.async {
                self.reading = false
                self.fans = fans; self.temperatures = temperatures; self.sensorError = errorMessage
                self.bounds = try? HardwareBounds(ranges: fans.map { (Double($0.minimum), Double($0.maximum)) })
                if !self.initializedLimits, let bounds = self.bounds { self.loadLimits(bounds) }
                if self.sessionRunning, self.pending != nil, self.stopRequested == false,
                   fans.contains(where: { $0.mode == 1 }) { self.pending = nil }
                // The helper performs its own independent sensor checks as well.
                // Maximum cooling can run without temperatures; its RPM is never reduced.
                if self.sessionRunning && self.mode == .manual && temperatures == nil { self.endSession() }
                self.onUpdate?()
            }
        }
    }

    // MARK: Mode changes

    func select(_ newMode: FanMode) {
        message = nil
        switch newMode {
        case .auto:
            if sessionRunning { endSession() }
            else if externallyControlled { restoreAutomaticControl() }
        case .manual:
            if let reason = manualBlocker() { message = reason; break }
            if sessionRunning { mode = .manual; heartbeat() }
            else if externallyControlled { message = "Choose Auto to release the fans first." }
            else { startSession(.manual) }
        case .maximum:
            if sessionRunning { mode = .maximum; heartbeat() }
            else if externallyControlled { message = "Choose Auto to release the fans first." }
            else if fans.isEmpty { message = "No controllable fans were found." }
            else { startSession(.maximum) }
        }
        onUpdate?()
    }
    private func manualBlocker() -> String? {
        guard let bounds, let minimum, let maximum else { return "Fan limits are unavailable." }
        do {
            try CoolingPolicy.validateRange(rpm: selectedRPM.rounded(), minimum: minimum,
                                            maximum: maximum, hardware: bounds)
            // Already in manual: the helper enforces the running cutoff.
            if !(sessionRunning && mode == .manual) {
                try CoolingPolicy.validateTemperature(temperatures, thermal: thermalLevel(), starting: true)
            }
        } catch { return String(describing: error) }
        return nil
    }
    /// Writes the current target. Rewritten every second so the helper knows the app is alive.
    func heartbeat() {
        guard sessionRunning, !stopRequested, let directory else { return }
        let target = mode == .maximum ? CoolingTarget.maximum : .manual(rpm: selectedRPM.rounded())
        do { try target.encoded.write(to: directory.appendingPathComponent("control"), atomically: true, encoding: .utf8) }
        catch { message = "Cannot update fan speed: \(error.localizedDescription)" }
    }
    private var stopRequested = false
    private func startSession(_ newMode: FanMode) {
        guard helper == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("baadgir-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { message = "Cannot create cooling session: \(error)"; return }
        self.directory = directory
        mode = newMode; sessionRunning = true; stopRequested = false
        heartbeat()
        let started = runPrivileged(["--control", String(getpid()), directory.path]) { [weak self] success in
            guard let self else { return }
            self.directory = nil; self.sessionRunning = false
            self.mode = .auto; self.pending = nil; self.stopRequested = false
            try? FileManager.default.removeItem(at: directory)
            if success { self.message = nil }
        }
        if started { pending = "Waiting for administrator authorization…" }
        else {
            sessionRunning = false; mode = .auto; self.directory = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func endSession() {
        guard sessionRunning, let directory else { return }
        stopRequested = true
        if !FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: Data()) {
            // Without fresh heartbeats the helper still restores Auto within seconds.
            message = "Could not signal stop. Automatic cooling returns within \(Int(CoolingPolicy.heartbeatTimeout)) seconds."
        }
        pending = "Restoring automatic cooling…"; onUpdate?()
    }
    private func restoreAutomaticControl() {
        guard helper == nil else { return }
        if runPrivileged(["--restore"], completion: { [weak self] _ in self?.pending = nil }) {
            pending = "Restoring automatic cooling…"
        }
    }
    /// Runs this executable as root through an administrator prompt. Returns false if it could not launch.
    private func runPrivileged(_ arguments: [String], completion: @escaping (Bool) -> Void) -> Bool {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let errors = Pipe(); process.standardError = errors
        process.terminationHandler = { [weak self] completed in
            let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                let success = completed.terminationStatus == 0
                self.helper = nil
                // The last sensor read may predate restoration; don't report a stuck fan from it.
                self.settlingUntil = Date().addingTimeInterval(2)
                completion(success)
                if !success { self.message = Self.readableError(error) }
                self.refresh(); self.onUpdate?()
            }
        }
        do { try process.run() }
        catch { message = String(describing: error); return false }
        helper = process
        return true
    }
    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func readableError(_ text: String) -> String {
        if text.contains("(-128)") { return "Administrator authorization was cancelled." }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.isEmpty ? "Cooling session could not complete." : text
    }
}

struct ControlsView: View {
    @ObservedObject var model: CoolingModel
    let quit: () -> Void
    var openSettings: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let icon = NSImage(named: "app-icon") {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                } else { Image(systemName: "fan").font(.title2).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Baadgir").font(.headline)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                temperature(.cpu, value: model.temperatures?.cpu)
                temperature(.gpu, value: model.temperatures?.gpu)
                if let battery = model.temperatures?.battery { temperature(.battery, value: battery) }
                if let ssd = model.temperatures?.ssd { temperature(.ssd, value: ssd) }
            }
            HStack(spacing: 0) {
                Text("Thermal pressure: ").foregroundStyle(.secondary)
                Text(model.thermalText).foregroundStyle(thermalColor)
            }
            .font(.caption)
            ForEach(model.fans, id: \.index) { fan in
                HStack {
                    Text("Fan \(fan.index + 1)")
                    Spacer()
                    Text("\(Int(fan.rpm)) RPM").monospacedDigit()
                    Text(fan.mode == 1 ? "Manual" : "Auto").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if !model.sensorError.isEmpty {
                Text(model.sensorError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            Picker("Fan mode", selection: Binding(get: { model.displayedMode }, set: { model.select($0) })) {
                Text("Auto").tag(FanMode.auto)
                Text("Manual").tag(FanMode.manual)
                Text("Max").tag(FanMode.maximum)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(model.pending != nil || model.fans.isEmpty)
            if model.showsManualControls { manualControls }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettings).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Baadgir", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var manualControls: some View {
        HStack {
            Text("Manual speed").font(.headline)
            Spacer()
            Text("\(Int(model.selectedRPM.rounded())) RPM").monospacedDigit()
        }
        // No `step:` here: on macOS it draws one tick mark per step.
        Slider(value: $model.selectedRPM, in: model.sliderRange) { editing in
            if !editing { model.heartbeat() }
        }
        .disabled(model.bounds == nil || !model.rangeIsValid)
        .accessibilityLabel("Manual fan speed in RPM")
        if model.bounds != nil && !model.rangeIsValid {
            Text("Fix the speed limits in Settings.").font(.caption).foregroundStyle(.orange)
        } else {
            Text("Range \(Int(model.sliderRange.lowerBound).formatted())–\(Int(model.sliderRange.upperBound).formatted()) RPM · change limits in Settings")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var explanation: String {
        switch model.displayedMode {
        case .auto where model.externallyControlled:
            return "Choose Auto to hand the fans back to macOS."
        case .auto:
            return "macOS controls the fans. Manual and Max ask for your administrator password once and stay on until you choose Auto. Right-click the menu bar icon for quick switching."
        case .manual:
            return "Drag to change speed. Returns to Auto at 80°C, high thermal pressure, sleep, quit, or if monitoring fails."
        case .maximum:
            return "Fans run at full speed until you choose Auto, sleep, or quit."
        }
    }
    private var thermalColor: Color {
        guard model.colorsTemperatures else { return .secondary }
        switch HeatLevel.normal.raised(by: thermalLevel()) {
        case .normal: return .green
        case .warm: return .yellow
        case .hot: return .red
        }
    }
    private func temperature(_ reading: TemperatureReading, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reading == .battery ? "Battery" : reading.title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f°C", $0) } ?? "—°C")
                .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(model.heatLevel(reading, value).map(Color.init) ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @ObservedObject var model: CoolingModel
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { [.enabled, .requiresApproval].contains(model.loginItemStatus) },
                    set: { model.setLaunchAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Allow Baadgir in Login Items to finish.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("General")
            }
            Section {
                ForEach(TemperatureReading.allCases, id: \.self) { reading in
                    Toggle(reading.title, isOn: Binding(get: { model.menuBarReadings.contains(reading) },
                                                        set: { _ in model.toggleMenuBar(reading) }))
                        .disabled(model.menuBarReadings == [reading])  // At least one reading stays on.
                }
                Toggle("Color temperatures green, yellow and red", isOn: $model.colorsTemperatures)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Yellow and red start at 70°C and 85°C for CPU and GPU, 35°C and 40°C for battery, and 55°C and 70°C for SSD. High thermal pressure also turns readings yellow or red.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                TextField("Minimum RPM", text: $model.minimumText)
                TextField("Maximum RPM", text: $model.maximumText)
                if model.bounds != nil && !model.rangeIsValid {
                    Text("Enter a minimum below the maximum, within the hardware range.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Manual Speed Limits")
            } footer: {
                Text(model.bounds.map { "Sets the Manual slider's range. Your fan supports \(Int(ceil($0.minimum)).formatted())–\(Int(floor($0.maximum)).formatted()) RPM. Auto and Max ignore these limits." }
                     ?? "Reading fan limits…")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.bounds == nil)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { model.refreshLoginItemStatus() }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Color {
    init(_ level: HeatLevel) {
        switch level {
        case .normal: self = .green
        case .warm: self = .yellow
        case .hot: self = .red
        }
    }
}
extension NSColor {
    static func heat(_ level: HeatLevel) -> NSColor {
        switch level {
        case .normal: return .systemGreen
        case .warm: return .systemYellow
        case .hot: return .systemRed
        }
    }
}

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = CoolingModel()
    let popover = NSPopover()
    var timer: Timer?
    // Changing the status item while its menu is open can dismiss the menu, so updates wait until it closes.
    private var menuOpen = false
    private var layoutPending = false
    private var symbol = "fan"
    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Baadgir")
        item.button?.imagePosition = .imageLeading
        fixStatusItemWidth()
        item.button?.setAccessibilityLabel("Baadgir temperature and fan controls")
        item.button?.target = self; item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        let host = NSHostingController(rootView: ControlsView(model: model, quit: { [weak self] in self?.quitApp() },
                                                              openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.onMenuBarLayoutChange = { [weak self] in self?.layoutPending = true; self?.refreshStatusItem() }
        model.onUpdate = { [weak self] in self?.refreshStatusItem() }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stop), name: NSWorkspace.willSleepNotification, object: nil)
        removeStaleSessions()
        model.refresh()
    }
    /// Deletes session folders left by a crash, so no control files linger on disk.
    private func removeStaleSessions() {
        let temporary = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        where name.hasPrefix("baadgir-") {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
    private func refreshStatusItem() {
        guard !menuOpen else { return }
        if layoutPending { layoutPending = false; fixStatusItemWidth() } else { updateTitle() }
        let wanted = model.displayedMode == .auto ? "fan" : "fan.fill"
        if wanted != symbol {
            symbol = wanted
            item.button?.image = NSImage(systemSymbolName: wanted, accessibilityDescription: "Baadgir")
        }
        item.button?.toolTip = "Baadgir · " + model.status
    }
    private var titleFont: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
    /// One reading shows " 72°C"; several show " C 72°  G 64°" with letter prefixes.
    private func title(_ value: (TemperatureReading) -> Double?, colored: Bool) -> NSAttributedString {
        let readings = model.menuBarReadings
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping  // The default word wrap splits readings onto two lines.
        let base: [NSAttributedString.Key: Any] = [.font: titleFont, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        for (index, reading) in readings.enumerated() {
            if readings.count > 1 {
                var label = base; label[.foregroundColor] = NSColor.secondaryLabelColor
                text.append(NSAttributedString(string: (index == 0 ? " " : "  ") + reading.letter + " ", attributes: label))
            } else { text.append(NSAttributedString(string: " ", attributes: base)) }
            var attributes = base
            if colored, let level = model.heatLevel(reading, value(reading)) {
                attributes[.foregroundColor] = NSColor.heat(level)
            }
            let number = value(reading).map { String(Int($0.rounded())) } ?? "—"
            text.append(NSAttributedString(string: number + (readings.count > 1 ? "°" : "°C"), attributes: attributes))
        }
        return text
    }
    private func updateTitle() {
        item.button?.attributedTitle = title({ reading in self.model.temperatures.flatMap { reading.value(in: $0) } },
                                             colored: true)
    }
    /// Sizes the item for the widest readings so it (and the popover anchored to it) never shifts as numbers change.
    private func fixStatusItemWidth() {
        guard let button = item.button else { return }
        button.font = titleFont
        button.alignment = .center
        button.attributedTitle = title({ _ in 130 }, colored: false)
        // Measure without a width limit; `fittingSize` is constrained by the current length.
        let unbounded = NSRect(x: 0, y: 0, width: 10_000, height: NSStatusBar.system.thickness)
        item.length = ceil(button.cell?.cellSize(forBounds: unbounded).width ?? button.fittingSize.width) + 4
        updateTitle()
    }
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() }
        else { togglePopover() }
    }
    func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        func info(_ title: String) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.isEnabled = false
            menu.addItem(entry)
        }
        info(model.status)
        if let temperatures = model.temperatures {
            info(TemperatureReading.allCases.dropFirst().compactMap { reading in
                reading.value(in: temperatures).map { "\(reading.title) \(Int($0.rounded()))°C" }
            }.joined(separator: " · "))
        }
        for fan in model.fans { info("Fan \(fan.index + 1): \(Int(fan.rpm).formatted()) RPM") }
        menu.addItem(.separator())
        let busy = model.pending != nil || model.fans.isEmpty
        for (title, mode) in [("Auto", FanMode.auto),
                              ("Manual · \(Int(model.selectedRPM.rounded()).formatted()) RPM", .manual),
                              ("Max", .maximum)] {
            let entry = NSMenuItem(title: title, action: busy ? nil : #selector(selectMode(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = mode
            entry.state = model.displayedMode == mode ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Baadgir", action: #selector(togglePopover), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Baadgir", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        // Attach only while open so a left click still shows the popover.
        menu.delegate = self
        menuOpen = true
        item.menu = menu
        item.button?.performClick(nil)
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === item.menu else { return }
        item.menu = nil
        menuOpen = false
        refreshStatusItem()
    }
    @objc func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? FanMode else { return }
        model.select(mode)
        // Explain refusals (for example, too warm for Manual) where they are visible.
        if model.message != nil, !popover.isShown { togglePopover() }
    }
    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private var settingsWindow: NSWindow?
    @objc func openSettings() {
        popover.performClose(nil)
        model.refreshLoginItemStatus()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "Baadgir Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func stop() { model.endSession() }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.sessionRunning else { return .terminateNow }
        // Give the helper a moment to confirm Auto before exiting; it also restores Auto when this process ends.
        model.endSession()
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, self.model.sessionRunning, Date() < deadline else {
                timer.invalidate(); sender.reply(toApplicationShouldTerminate: true); return
            }
        }
        // Termination waits in a modal run loop mode, which `.common` includes.
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }
}

func diagnostic() -> String {
    do {
        let smc = try SMC()
        var lines = try smc.fans().map {
            "Fan \($0.index): \($0.rpm) RPM, range \($0.minimum)–\($0.maximum), mode \($0.mode) (\($0.modeKey))"
        }
        do {
            let temperatures = try smc.temperatures()
            lines.append("CPU \(temperatures.cpu)°C · GPU \(temperatures.gpu)°C")
        } catch { lines.append("Temperature readings unavailable: \(error)") }
        return lines.joined(separator: "\n")
    } catch { return "Read-only diagnostic failed: \(error)" }
}
let arguments = CommandLine.arguments
/// Carries preferences over once from the app's former name, Parvanak (bundle ID `local.parvanak`).
func migrateSettings() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "migratedFromParvanak") else { return }
    defaults.set(true, forKey: "migratedFromParvanak")
    guard let old = UserDefaults(suiteName: "local.parvanak") else { return }
    for key in ["minimumRPM", "maximumRPM", "manualRPM", "menuBarReadings", "colorsTemperatures"]
    where defaults.object(forKey: key) == nil {
        if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
    }
}
// No logs: nothing here writes readings to disk. `--probe` prints to the terminal only.
if arguments.contains("--probe") {
    print(diagnostic())
} else if arguments.count == 4 && arguments[1] == "--control" {
    do {
        guard let parent = Int32(arguments[2]), parent > 1 else { throw Failure("Invalid parent") }
        try coolingSession(parent: parent, directory: arguments[3])
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if arguments.count == 2 && arguments[1] == "--watchdog" {
    if geteuid() == 0 { watchdog() }
} else if arguments.count == 2 && arguments[1] == "--restore" {
    do { try restoreAutomatic() } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    migrateSettings()
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
