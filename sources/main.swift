import AppKit
import SwiftUI
import IOKit
import Darwin
import ServiceManagement
import UserNotifications
import Carbon.HIToolbox
import IOKit.ps

struct Fan {
    let index: Int
    let rpm: Float
    let minimum: Float
    let maximum: Float
    let modeKey: String
    let mode: UInt8
}
struct SMCFailure: Error, CustomStringConvertible {
    let key: String, command: UInt8, kernel: kern_return_t, smc: UInt8
    var description: String { "SMC \(key) command \(command) rejected (IOKit \(kernel), SMC \(smc))" }
    /// kSMCKeyNotFound: this Mac doesn't have the key, as opposed to a failed read.
    var keyNotFound: Bool { kernel == KERN_SUCCESS && smc == 0x84 }
}
/// The chip's marketing name, such as "Apple M3 Pro".
func chipName() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(cString: bytes)
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
            throw SMCFailure(key: key, command: command, kernel: result, smc: output[40])
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
    private(set) var cpuKeys: [String] = []
    private(set) var gpuKeys: [String] = []
    private var batteryKeys: [String] = []
    private var ssdKeys: [String] = []
    private var discoveredTemperatures = false
    func temperatures() throws -> Temperatures {
        if !discoveredTemperatures {
            let generation = SensorKeys.generation(brand: chipName())
            func available(_ keys: [String]) -> [String] {
                keys.filter { key in
                    guard let value = try? number(key) else { return false }
                    return value > 0 && value <= 130
                }
            }
            cpuKeys = available(SensorKeys.cpu(generation))
            gpuKeys = available(SensorKeys.gpu(generation))
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
    /// System and adapter power from the SMC (`PSTR`, `PDTR`). Display only; never used for control.
    func power() throws -> PowerReadings {
        let system = Double(try number("PSTR"))
        return try PowerReadings(system: system, adapter: (try? number("PDTR")).map(Double.init))
    }
    /// Empty on a fanless Mac, such as a MacBook Air, which has no fan count or a count of zero.
    func fans() throws -> [Fan] {
        let count: Float
        do { count = try number("FNum") }
        catch let error as SMCFailure where error.keyNotFound { return [] }
        guard count <= 8, count.rounded() == count else { throw Failure("Unexpected fan count") }
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

func currentPowerSource() -> PowerSource {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
    switch type {
    case kIOPMACPowerKey: return .adapter
    case kIOPMBatteryPowerKey: return .battery
    default: return .unknown
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
/// Root-owned copy of the executable, installed by `build.sh --install`. Root never runs the app bundle's copy,
/// which any app running as the user could replace.
let helperPath = "/Library/PrivilegedHelperTools/local.baadgir.helper"
/// Refuses fan control unless this process is root running the root-owned helper.
func requireRootHelper() throws {
    guard geteuid() == 0 else { throw Failure("Fan control requires administrator authorization") }
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else {
        throw Failure("Cannot locate the fan-control helper")
    }
    defer { free(resolved) }
    guard String(cString: resolved) == helperPath, isRootOwned(helperPath) else {
        throw Failure("Fan control runs only from the installed helper. Run ./build.sh --install.")
    }
}
/// The user a process runs as.
func processOwner(_ pid: pid_t) throws -> uid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&request, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else {
        throw Failure("Cannot identify Baadgir's user")
    }
    return info.kp_eproc.e_ucred.cr_uid
}
/// Opens the app's session folder without following links, and checks that the app's user owns it and no one else
/// can enter it. Root then reaches the session files only through this folder, never through a swapped path.
func openSessionDirectory(_ path: String, owner: uid_t) throws -> Int32 {
    let folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard folder >= 0 else { throw Failure("Cooling session folder is unavailable") }
    var info = stat()
    guard fstat(folder, &info) == 0, info.st_uid == owner, info.st_mode & 0o077 == 0 else {
        close(folder)
        throw Failure("Cooling session folder is not private to Baadgir's user")
    }
    return folder
}
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
func readControl(in folder: Int32, owner: uid_t) throws -> (target: CoolingTarget, modified: Double) {
    // Non-blocking so a FIFO in place of the file cannot stall the helper while fans are manual.
    let file = openat(folder, "control", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard file >= 0 else { throw Failure("Cooling controls are unavailable; returning to automatic cooling") }
    defer { close(file) }
    var info = stat()
    // The app's own single-link file only: a hard link could otherwise point root at a file the user cannot read.
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64,
          info.st_uid == owner, info.st_nlink == 1 else {
        throw Failure("Cooling controls are invalid")
    }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(file, &buffer, buffer.count)
    guard count > 0 else { throw Failure("Cooling controls are empty") }
    let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return (try CoolingTarget(encoded: String(decoding: buffer[0..<count], as: UTF8.self)), modified)
}
func coolingSession(parent: pid_t, directory: String) throws {
    try requireRootHelper()
    let lock = try acquireLock()
    defer { close(lock) }
    let owner = try processOwner(parent)
    let folder = try openSessionDirectory(directory, owner: owner)
    defer { close(folder) }
    func cancelled() -> Bool {
        var info = stat()
        return kill(parent, 0) != 0 || fstatat(folder, "stop", &info, AT_SYMLINK_NOFOLLOW) == 0
    }
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
        let (target, modified) = try readControl(in: folder, owner: owner)
        guard heartbeat.isFresh(stamp: modified, now: ProcessInfo.processInfo.systemUptime) else {
            throw Failure("Baadgir stopped responding; returning to automatic cooling")
        }
        switch target {
        case .manual(let rpm):
            try CoolingPolicy.validateRange(rpm: rpm, minimum: bounds.minimum, maximum: bounds.maximum, hardware: bounds)
        case .curve(let curve): try curve.validate(hardware: bounds)
        case .maximum: break
        }
        return target
    }
    // The first target must also be recent by wall clock; later checks use the monotonic heartbeat.
    guard abs(Date().timeIntervalSince1970 - (try readControl(in: folder, owner: owner)).modified) <= CoolingPolicy.heartbeatTimeout else {
        throw Failure("Cooling controls are stale")
    }
    var previousTarget = try requestedTarget()
    switch previousTarget {
    case .manual: try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: true)
    case .curve: _ = try smc.temperatures()
    case .maximum: break
    }
    signal(SIGTERM, handleSignal); signal(SIGINT, handleSignal); signal(SIGHUP, handleSignal)
    // Started before any fan is touched; it restores Auto even if this process is force-killed.
    let watchdog = try startWatchdog(executable: helperPath)
    defer { close(watchdog) }
    // A gone watchdog shows up as a write error rather than a signal; a full pipe never blocks the loop.
    signal(SIGPIPE, SIG_IGN)
    _ = fcntl(watchdog, F_SETFL, O_NONBLOCK)
    /// Tells the watchdog the loop is still running; it takes over if these stop.
    func pulse() throws {
        var byte: UInt8 = 1
        guard write(watchdog, &byte, 1) == 1 || errno == EAGAIN else {
            throw Failure("The safety watchdog stopped; returning to automatic cooling")
        }
    }
    // Tells the app the session is live; in Curve mode the fans may stay automatic for a long time.
    let marker = openat(folder, "running", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
    if marker >= 0 { close(marker) }
    var touched: [Fan] = []
    func restore() -> Bool {
        AutomaticRestoration.restore(keys: touched.map(\.modeKey),
            readMode: { Double(try smc.number($0)) },
            writeAutomatic: { try smc.write($0, expectedType: "ui8 ", bytes: [0]) },
            retryDelay: { usleep(100_000) })
    }
    /// Per-fan targets while Baadgir holds the fans; nil while macOS controls them (Curve mode only).
    var applied: [Float]?
    /// Puts every fan in manual mode, writing the target first so no fan runs a stale value.
    func engage(_ targets: [Float]) throws {
        for (fan, rpm) in zip(fans, targets) {
            if !touched.contains(where: { $0.index == fan.index }) { touched.append(fan) }
            try smc.target(fan, rpm: rpm)
            try smc.mode(fan, 1)
            guard try smc.number(fan.modeKey) == 1, abs(try smc.number("F\(fan.index)Tg") - rpm) <= 1 else {
                throw Failure("Fan controller did not confirm the requested speed")
            }
        }
        applied = targets
    }
    var curveController = CurveController()
    do {
        guard !cancelled() else { throw Failure("Cooling session was cancelled") }
        let clock = ContinuousClock()
        var previous = clock.now
        var changed = previous
        // Runs until the app chooses Auto, quits, stops responding, or a safety check fails.
        while interrupted == 0 {
            let now = clock.now
            if previous.duration(to: now) > .seconds(3) || cancelled() { break }
            previous = now
            try pulse()
            let target = try requestedTarget()
            let wasManual = previousTarget.isManual
            previousTarget = target
            let wanted: [Float]?
            switch target {
            case .maximum:
                wanted = fans.map(\.maximum)
            case .manual(let rpm):
                // Switching into Manual from Max or Curve must meet the same start limit as a new session.
                try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(),
                                                      starting: !wasManual)
                wanted = fans.map { _ in Float(rpm) }
            case .curve(let curve):
                if !curveController.engaged, applied != nil {
                    // Coming from Manual or Max: hand the fans back so the curve starts from macOS's own speed.
                    guard restore() else { throw Failure("Automatic control could not be verified. Restart your Mac.") }
                    applied = nil
                    usleep(500_000); continue
                }
                let desired = CoolingPolicy.curveSpeed(curve, try smc.temperatures(), thermal: thermalLevel())
                wanted = curveController.targets(desired: desired, actual: try smc.fans().map { Double($0.rpm) },
                    maximums: fans.map { Double($0.maximum) }, now: ProcessInfo.processInfo.systemUptime)?.map(Float.init)
            }
            if case .curve = target {} else { curveController = CurveController() }
            if let wanted {
                if applied == nil {
                    // Manual and Max start at maximum, never a stale low target; Curve starts above macOS's speed.
                    if case .curve = target { try engage(wanted) } else { try engage(fans.map(\.maximum)) }
                    changed = now
                }
                if wanted != applied {
                    for (fan, rpm) in zip(fans, wanted) { try smc.target(fan, rpm: rpm) }
                    applied = wanted; changed = now
                }
            } else if applied != nil {
                guard restore() else { throw Failure("Automatic control could not be verified. Restart your Mac.") }
                applied = nil
            }
            let live = try smc.fans()
            guard live.count == fans.count else { throw Failure("Fan configuration changed") }
            for (index, (fan, original)) in zip(live, fans).enumerated() {
                guard fan.minimum == original.minimum, fan.maximum == original.maximum else {
                    throw Failure("Fan configuration changed")
                }
                guard let applied else {
                    guard fan.mode != 1 else { throw Failure("Another app took control of a fan; session ended") }
                    continue
                }
                let expected = applied[index]
                guard fan.mode == 1, abs(try smc.number("F\(fan.index)Tg") - expected) <= 1 else {
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
/// Waits for the helper to exit or stall, then makes sure no fan is left in manual mode.
func watchdog() {
    signal(SIGHUP, SIG_IGN); signal(SIGINT, SIG_IGN)
    // The helper spawned this process; read now, before a helper exit hands it to launchd.
    let helper = getppid()
    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    var byte: UInt8 = 0
    var stalled = false
    while true {
        let ready = poll(&input, 1, Int32(CoolingPolicy.helperStallTimeout * 1000))
        if ready == 0 { stalled = true; break }
        if ready < 0 { if errno == EINTR { continue } else { break } }
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    // The pipe is still open, so the helper is alive but stuck, possibly holding fans at a stale speed.
    if stalled, helper > 1 { kill(helper, SIGKILL) }
    // The helper's lock may close a moment after the pipe, and the SMC can fail briefly; keep trying for a few seconds.
    for _ in 0..<30 {
        do { try restoreAutomatic(); return } catch { usleep(100_000) }
    }
    // A helper stuck inside the kernel can't exit and keeps its lock; restore without it rather than leave fans manual.
    if stalled { try? restoreAutomatic(locking: false) }
}
let lockBusy = "A cooling session is already running"
/// Returns fans left in manual mode (for example after a crash or by another app) to Auto.
func restoreAutomatic(locking: Bool = true) throws {
    try requireRootHelper()
    let lock = locking ? try acquireLock() : -1
    defer { if lock >= 0 { close(lock) } }
    let smc = try SMC()
    let manual = try smc.fans().filter { $0.mode == 1 }
    guard AutomaticRestoration.restore(keys: manual.map(\.modeKey),
        readMode: { Double(try smc.number($0)) },
        writeAutomatic: { try smc.write($0, expectedType: "ui8 ", bytes: [0]) },
        retryDelay: { usleep(100_000) }) else {
        throw Failure("Automatic control could not be verified. Restart your Mac.")
    }
}

final class CoolingModel: ObservableObject {
    @Published var fans: [Fan] = []
    /// No fans at all, such as a MacBook Air: Baadgir only shows temperatures. False until the first fan read.
    @Published private(set) var fanless = false {
        didSet { if fanless != oldValue { onMenuBarLayoutChange?(); onHotKeyChange?() } }
    }
    @Published var temperatures: Temperatures?
    @Published var power: PowerReadings?
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
    /// Readings two to a column in a smaller font, instead of one row.
    @Published var stacksMenuBarReadings = UserDefaults.standard.bool(forKey: "stacksMenuBarReadings") {
        didSet { defaults.set(stacksMenuBarReadings, forKey: "stacksMenuBarReadings"); onMenuBarLayoutChange?() }
    }
    /// The fan symbol before the readings; filled while Baadgir controls the fans.
    @Published var showsMenuBarIcon = UserDefaults.standard.object(forKey: "showsMenuBarIcon") as? Bool ?? true {
        didSet { defaults.set(showsMenuBarIcon, forKey: "showsMenuBarIcon"); onMenuBarLayoutChange?() }
    }
    /// The chosen readings this Mac can show.
    var shownMenuBarReadings: [TemperatureReading] { TemperatureReading.shown(menuBarReadings, fanless: fanless) }
    var onMenuBarLayoutChange: (() -> Void)?
    func toggleMenuBar(_ reading: TemperatureReading) {
        if menuBarReadings.contains(reading) {
            guard shownMenuBarReadings.contains(where: { $0 != reading }) else { return }
            menuBarReadings.removeAll { $0 == reading }
        } else {
            menuBarReadings = TemperatureReading.allCases.filter { $0 == reading || menuBarReadings.contains($0) }
        }
    }
    @Published var notifiesOnReturn = UserDefaults.standard.object(forKey: "notifiesOnReturn") as? Bool ?? true {
        didSet {
            defaults.set(notifiesOnReturn, forKey: "notifiesOnReturn")
            if notifiesOnReturn { requestNotificationPermission() }
        }
    }
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Tells the user when fans went back to Auto without being asked, for example after a safety cutoff.
    private func notifyReturn(_ reason: String) {
        guard notifiesOnReturn else { return }
        let content = UNMutableNotificationContent()
        content.title = "Fans are back on Auto"
        content.body = reason
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    /// The last ten minutes of readings, one per second. Memory only.
    @Published private(set) var history = RingBuffer<HistorySample>(capacity: 600)
    @Published var showsHistory = UserDefaults.standard.object(forKey: "showsHistory") as? Bool ?? true {
        didSet { defaults.set(showsHistory, forKey: "showsHistory") }
    }
    /// ⌃⌥M switches between Max and Auto from anywhere.
    @Published var usesMaxHotKey = UserDefaults.standard.object(forKey: "usesMaxHotKey") as? Bool ?? true {
        didSet { defaults.set(usesMaxHotKey, forKey: "usesMaxHotKey"); onHotKeyChange?() }
    }
    @Published var hotKeyError: String?
    var onHotKeyChange: (() -> Void)?
    /// Whether baadgir:// links (and so Shortcuts and the command line) may change the fan mode.
    /// Off until turned on: any web page or app can open a link, and starting a session asks for the administrator password.
    @Published var allowsLinks = UserDefaults.standard.object(forKey: "allowsLinks") as? Bool ?? false {
        didSet { defaults.set(allowsLinks, forKey: "allowsLinks") }
    }
    /// Asks in Baadgir before a request from outside starts cooling. Nil or false declines.
    var confirmRemoteStart: ((FanMode) -> Bool)?
    /// Runs a request from a link, Shortcuts, or the command line, with the same checks as the popover.
    func perform(_ command: RemoteCommand) {
        guard allowsLinks else {
            message = "Links, Shortcuts and the command line are turned off in Settings."; onUpdate?(); return
        }
        let wanted: FanMode
        switch command {
        case .auto: wanted = .auto
        case .curve: wanted = .curve
        case .maximum: wanted = .maximum
        case .manual(let rpm):
            if let rpm, !sliderRange.contains(rpm) {
                message = "Choose a speed within \(Int(sliderRange.lowerBound))–\(Int(sliderRange.upperBound)) RPM."
                onUpdate?(); return
            }
            wanted = .manual
        }
        // Any web page can open a link. Starting cooling raises the administrator prompt, so it needs a click here first;
        // switching modes inside a running session and returning to Auto don't.
        if wanted != .auto, !sessionRunning, confirmRemoteStart?(wanted) != true { return }
        if case .manual(let rpm?) = command { selectedRPM = rpm }
        select(wanted)
    }
    @Published var rules = PowerRules(
        autoOnBattery: UserDefaults.standard.bool(forKey: "autoOnBattery"),
        onAdapter: UserDefaults.standard.string(forKey: "onAdapterMode").flatMap(FanMode.init(rawValue:))) {
        didSet {
            defaults.set(rules.autoOnBattery, forKey: "autoOnBattery")
            defaults.set(rules.onAdapter?.rawValue, forKey: "onAdapterMode")
            // Apply a newly enabled battery rule right away.
            if rules.autoOnBattery, !oldValue.autoOnBattery, sessionRunning, currentPowerSource() == .battery { select(.auto) }
        }
    }
    private var lastPowerSource: PowerSource?
    /// Switches mode when the power source changes, as the rules ask.
    private func applyRules() {
        let source = currentPowerSource()
        defer { lastPowerSource = source }
        guard !fanless, pending == nil, let mode = rules.mode(from: lastPowerSource, to: source, current: sessionRunning ? mode : .auto)
        else { return }
        select(mode)
    }
    /// True once the first sensor read has finished, so queued link requests see real readings.
    @Published private(set) var hasRead = false
    @Published var colorsTemperatures = UserDefaults.standard.object(forKey: "colorsTemperatures") as? Bool ?? true {
        didSet { defaults.set(colorsTemperatures, forKey: "colorsTemperatures"); onUpdate?() }
    }
    /// Colour band for a reading, or nil when colours are off or the value is missing.
    func heatLevel(_ reading: TemperatureReading, _ value: Double?) -> HeatLevel? {
        guard colorsTemperatures, let value, let level = reading.level(value) else { return nil }
        return level.raised(by: thermalLevel())
    }
    /// Average speed of all fans, as in the history graph; nil before the first read.
    var fanSpeed: Double? { fans.isEmpty ? nil : fans.map { Double($0.rpm) }.reduce(0, +) / Double(fans.count) }
    /// The current value of a menu bar reading.
    func value(of reading: TemperatureReading) -> Double? {
        reading == .fan ? fanSpeed : temperatures.flatMap { reading.value(in: $0) }
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
    /// Curve points as typed in Settings; `curve` is the last valid version, which is what runs.
    @Published var curveTemperatureTexts = [String](repeating: "", count: FanCurve.pointCount) { didSet { curveChanged() } }
    @Published var curveRPMTexts = [String](repeating: "", count: FanCurve.pointCount) { didSet { curveChanged() } }
    @Published private(set) var curve: FanCurve?
    @Published private(set) var curveError: String?
    private var fillingCurve = false
    private func curveChanged() {
        guard initializedLimits, !fillingCurve, let bounds else { return }
        do {
            // Whole numbers only: the helper receives the curve as whole numbers, so it checks exactly what is shown here.
            let whole = { (text: String) in Int(text.trimmingCharacters(in: .whitespaces)) }
            let temperatures = curveTemperatureTexts.map(whole), speeds = curveRPMTexts.map(whole)
            guard !temperatures.contains(nil), !speeds.contains(nil) else { throw Failure("Enter a whole number in every field") }
            let edited = try FanCurve(zip(temperatures, speeds).map { FanCurve.Point(temperature: Double($0!), rpm: Double($1!)) })
            try edited.validate(hardware: bounds)
            curve = edited; curveError = nil
            defaults.set(edited.points.flatMap { [Int($0.temperature), Int($0.rpm)] }, forKey: "curvePoints")
        } catch { curveError = String(describing: error) }
    }
    private func showCurve(_ curve: FanCurve) {
        fillingCurve = true  // Fill every field before validating.
        curveTemperatureTexts = curve.points.map { String(Int($0.temperature)) }
        curveRPMTexts = curve.points.map { String(Int($0.rpm)) }
        fillingCurve = false
        curveChanged()
    }
    func resetCurve() { if let bounds { showCurve(.standard(for: bounds)) } }
    /// What the curve asks for right now; infinity means maximum.
    var curveSpeedNow: Double? {
        guard let curve, let temperatures else { return nil }
        return CoolingPolicy.curveSpeed(curve, temperatures, thermal: thermalLevel())
    }
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
        if fanless { return "No fans · temperatures only" }
        if externallyControlled { return "A fan is stuck in manual mode" }
        guard sessionRunning else { return "Automatic cooling" }
        if mode == .maximum { return "Maximum cooling" }
        if mode == .curve {
            guard let fan = fans.first(where: { $0.mode == 1 }) else { return "Curve · following macOS" }
            return "Curve · \(Int(fan.rpm.rounded()).formatted()) RPM"
        }
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
        let saved = (defaults.array(forKey: "curvePoints") as? [Int]) ?? []
        let points = stride(from: 0, to: saved.count - 1, by: 2).map {
            FanCurve.Point(temperature: Double(saved[$0]), rpm: Double(saved[$0 + 1]))
        }
        if let stored = try? FanCurve(points), (try? stored.validate(hardware: bounds)) != nil { showCurve(stored) }
        else { showCurve(.standard(for: bounds)) }
    }
    func refresh() {
        heartbeat()
        guard !reading else { return }
        reading = true
        queue.async { [weak self] in
            guard let self else { return }
            var fans: [Fan] = []
            var fanless: Bool?  // Nil when the fans could not be read.
            var temperatures: Temperatures?
            var power: PowerReadings?
            var errors: [String] = []
            do {
                if self.smc == nil { self.smc = try SMC() }
                let smc = self.smc!
                // Fans and temperatures are read separately, so a Mac without fans still shows temperatures.
                do { fans = try smc.fans(); fanless = fans.isEmpty }
                catch { errors.append(String(describing: error)) }
                do { temperatures = try smc.temperatures() }
                catch { errors.append(String(describing: error)) }
                power = try? smc.power()
                if fanless == nil && temperatures == nil { self.smc = nil }  // Reconnect on the next read.
            } catch {
                errors.append(String(describing: error))
            }
            let errorMessage = errors.joined(separator: "\n")
            DispatchQueue.main.async {
                self.reading = false
                self.fans = fans; self.temperatures = temperatures; self.power = power; self.sensorError = errorMessage
                if let fanless { self.fanless = fanless }
                self.hasRead = true
                self.history.append(HistorySample(cpu: temperatures?.cpu, gpu: temperatures?.gpu, fan: self.fanSpeed))
                self.bounds = try? HardwareBounds(ranges: fans.map { (Double($0.minimum), Double($0.maximum)) })
                if !self.initializedLimits, let bounds = self.bounds { self.loadLimits(bounds) }
                if self.sessionRunning, self.pending != nil, self.stopRequested == false, let directory = self.directory,
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent("running").path) {
                    self.pending = nil; self.sessionStarted = true
                }
                // The helper performs its own independent sensor checks as well.
                // Maximum cooling can run without temperatures; its RPM is never reduced.
                if self.sessionRunning && [.manual, .curve].contains(self.mode) && temperatures == nil {
                    self.endSession(reason: "Temperature readings stopped: \(errorMessage)")
                }
                // After limits and the curve are loaded, so a rule can start Curve at launch.
                self.applyRules()
                self.onUpdate?()
            }
        }
    }

    // MARK: Mode changes

    func select(_ newMode: FanMode) {
        message = nil
        if fanless, newMode != .auto {
            message = "This Mac has no fans, so Baadgir only shows temperatures."; onUpdate?(); return
        }
        if let reason = rules.blocker(for: newMode, on: currentPowerSource()) { message = reason; onUpdate?(); return }
        switch newMode {
        case .auto:
            if sessionRunning { endSession() }
            else if externallyControlled { restoreAutomaticControl() }
        case .curve:
            if let reason = curveBlocker() { message = reason; break }
            if sessionRunning { mode = .curve; heartbeat() }
            else if externallyControlled { message = "Choose Auto to release the fans first." }
            else { startSession(.curve) }
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
    private func curveBlocker() -> String? {
        guard curve != nil else { return curveError ?? "Set up a fan curve in Settings first." }
        guard temperatures != nil else { return "Temperature readings are unavailable; keeping automatic cooling" }
        return nil
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
        let target: CoolingTarget
        switch mode {
        case .maximum, .auto: target = .maximum
        case .manual: target = .manual(rpm: selectedRPM.rounded())
        case .curve:
            guard let curve else { return }
            target = .curve(curve)
        }
        do { try target.encoded.write(to: directory.appendingPathComponent("control"), atomically: true, encoding: .utf8) }
        catch { message = "Cannot update fan speed: \(error.localizedDescription)" }
    }
    private var stopRequested = false
    /// Set once the helper reports it is running, so failures before that aren't reported as a return to Auto.
    private var sessionStarted = false
    /// Why the app itself ended the session, when the user didn't ask.
    private var forcedReason: String?
    private func startSession(_ newMode: FanMode) {
        guard helper == nil else { return }
        if notifiesOnReturn { requestNotificationPermission() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("baadgir-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { message = "Cannot create cooling session: \(error)"; return }
        self.directory = directory
        mode = newMode; sessionRunning = true; stopRequested = false; sessionStarted = false; forcedReason = nil
        heartbeat()
        let started = runPrivileged(["--control", String(getpid()), directory.path]) { [weak self] success, error in
            guard let self else { return }
            if let reason = self.forcedReason { self.notifyReturn(reason) }
            else if self.sessionStarted && !self.stopRequested {
                self.notifyReturn(success ? "The cooling session ended." : error)
            }
            self.directory = nil; self.sessionRunning = false; self.sessionStarted = false; self.forcedReason = nil
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
    /// Pass a reason when the app, not the user, decided to stop; it is shown as a notification.
    func endSession(reason: String? = nil) {
        guard sessionRunning, let directory else { return }
        if let reason, forcedReason == nil { forcedReason = reason }
        stopRequested = true
        if !FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: Data()) {
            // Without fresh heartbeats the helper still restores Auto within seconds.
            message = "Could not signal stop. Automatic cooling returns within \(Int(CoolingPolicy.heartbeatTimeout)) seconds."
        }
        pending = "Restoring automatic cooling…"; onUpdate?()
    }
    private func restoreAutomaticControl() {
        guard helper == nil else { return }
        if runPrivileged(["--restore"], completion: { [weak self] _, _ in self?.pending = nil }) {
            pending = "Restoring automatic cooling…"
        }
    }
    /// Runs the root-owned helper as root through an administrator prompt. Returns false if it could not launch.
    private func runPrivileged(_ arguments: [String], completion: @escaping (Bool, String) -> Void) -> Bool {
        // Never hand the administrator password to a file that another app running as this user could replace.
        guard isRootOwned(helperPath) else {
            message = "The fan-control helper is not installed. Run ./build.sh --install."; return false
        }
        guard let executable = Bundle.main.executablePath,
              FileManager.default.contentsEqual(atPath: executable, andPath: helperPath) else {
            message = "The fan-control helper doesn't match this Baadgir. Run ./build.sh --install."; return false
        }
        // An empty environment: nothing set for this user's apps (such as via `launchctl setenv`) reaches root.
        let command = (["/usr/bin/env", "-i", helperPath] + arguments).map(shellQuote).joined(separator: " ")
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
                let readable = Self.readableError(error)
                completion(success, readable)
                if !success { self.message = readable }
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
                Spacer()
                if let power = model.power {
                    Text("Power: ").foregroundStyle(.secondary)
                    Text(power.text).monospacedDigit()
                }
            }
            .font(.caption)
            if model.showsHistory {
                HistoryView(samples: model.history.elements, fanMaximum: model.bounds?.maximum, showsFan: !model.fanless)
            }
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
            if model.fanless {
                Text("This Mac has no fans. macOS cools it by slowing the chip down when it gets hot.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Fan mode", selection: Binding(get: { model.displayedMode }, set: { model.select($0) })) {
                    Text("Auto").tag(FanMode.auto)
                    Text("Curve").tag(FanMode.curve)
                    Text("Manual").tag(FanMode.manual)
                    Text("Max").tag(FanMode.maximum)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.pending != nil || model.fans.isEmpty)
                if model.showsManualControls { manualControls }
                if model.sessionRunning && model.mode == .curve, let speed = model.curveSpeedNow {
                    Text(speed.isInfinite ? "Curve wants maximum cooling"
                                          : "Curve wants \(Int(speed).formatted()) RPM at \(Int(model.temperatures?.highest ?? 0))°C")
                        .font(.caption).monospacedDigit()
                }
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
            return "macOS controls the fans. Curve, Manual and Max ask for your administrator password once and stay on until you choose Auto. Right-click the menu bar icon for quick switching."
        case .curve:
            return "Follows your curve from Settings when it asks for more than macOS, never less. Maximum at 80°C or high thermal pressure. Returns to Auto on sleep, quit, or if monitoring fails."
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
                if !model.fanless {
                    Toggle("Notify when fans return to Auto on their own", isOn: $model.notifiesOnReturn)
                    Toggle("⌃⌥M switches between Max and Auto", isOn: $model.usesMaxHotKey)
                    Toggle("Allow Shortcuts, baadgir:// links and the command line to change fan mode", isOn: $model.allowsLinks)
                }
                if let error = model.hotKeyError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("General")
            }
            Section {
                Picker("Layout", selection: $model.stacksMenuBarReadings) {
                    Text("Side by side").tag(false)
                    Text("Stacked").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(model.shownMenuBarReadings.count < 2)  // One reading has nothing to stack.
                Toggle(model.fanless ? "Show the thermometer icon" : "Show the fan icon", isOn: $model.showsMenuBarIcon)
                ForEach(TemperatureReading.available(fanless: model.fanless), id: \.self) { reading in
                    Toggle(reading.title, isOn: Binding(get: { model.shownMenuBarReadings.contains(reading) },
                                                        set: { _ in model.toggleMenuBar(reading) }))
                        .disabled(model.shownMenuBarReadings == [reading])  // At least one reading stays on.
                }
                Toggle("Color temperatures green, yellow and red", isOn: $model.colorsTemperatures)
                Toggle("Show the last 10 minutes in the popover", isOn: $model.showsHistory)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Yellow and red start at 70°C and 85°C for CPU and GPU, 35°C and 40°C for battery, and 55°C and 70°C for SSD. High thermal pressure also turns readings yellow or red.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.fanless { fanSections }
        }
        .formStyle(.grouped)
        // Fixed height so the window fits small screens; the form scrolls.
        .frame(width: 440, height: model.fanless ? 420 : 680)
        .onAppear { model.refreshLoginItemStatus() }
    }
    @ViewBuilder private var fanSections: some View {
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
            Text(model.bounds.map { "Sets the Manual slider's range. \(model.fans.count > 1 ? "Your fans share" : "Your fan supports") \(Int(ceil($0.minimum)).formatted())–\(Int(floor($0.maximum)).formatted()) RPM. Auto and Max ignore these limits." }
                 ?? "Reading fan limits…")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.bounds == nil)
        Section {
            ForEach(0..<FanCurve.pointCount, id: \.self) { index in
                HStack {
                    Text("Point \(index + 1)")
                    Spacer()
                    TextField("°C", text: $model.curveTemperatureTexts[index]).frame(width: 50)
                    Text("°C").foregroundStyle(.secondary)
                    TextField("RPM", text: $model.curveRPMTexts[index]).frame(width: 64)
                    Text("RPM").foregroundStyle(.secondary)
                }
                .labelsHidden().multilineTextAlignment(.trailing)
            }
            if let error = model.curveError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let curve = model.curve, let bounds = model.bounds { CurvePreview(curve: curve, bounds: bounds) }
            HStack { Spacer(); Button("Reset to Default") { model.resetCurve() } }
        } header: {
            Text("Fan Curve")
        } footer: {
            Text("Uses the hottest CPU or GPU reading. Curve mode only takes over when the curve wants more than macOS is running, and never goes below macOS's speed. At 80°C, a 45°C battery or high thermal pressure, fans run at maximum.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.bounds == nil)
        Section {
            Toggle("On battery, return to Auto and stay there", isOn: $model.rules.autoOnBattery)
            Picker("When plugged in", selection: $model.rules.onAdapter) {
                Text("Do nothing").tag(FanMode?.none)
                Text("Switch to Curve").tag(FanMode?.some(.curve))
                Text("Switch to Max").tag(FanMode?.some(.maximum))
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("The plugged-in rule runs when you connect power and when Baadgir starts while plugged in, only if fans are on Auto. Starting a mode may ask for your administrator password.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.bounds == nil)
    }
}

/// Line through the values scaled to `range`; nil values leave gaps.
struct Sparkline: Shape {
    let values: [Double?]
    let range: ClosedRange<Double>
    let capacity: Int
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var drawing = false
        let span = max(range.upperBound - range.lowerBound, 1)
        // Newest sample at the right edge, so a fresh history grows in from the right.
        let offset = capacity - values.count
        for (index, value) in values.enumerated() {
            guard let value else { drawing = false; continue }
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(index + offset) / CGFloat(max(capacity - 1, 1)),
                                y: rect.maxY - rect.height * CGFloat((clamped - range.lowerBound) / span))
            if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
        }
        return path
    }
}

/// Ten-minute CPU/GPU temperature and fan speed graphs.
struct HistoryView: View {
    let samples: [HistorySample]
    let fanMaximum: Double?
    var showsFan = true
    private let capacity = 600
    var body: some View {
        let temperatures = samples.flatMap { [$0.cpu, $0.gpu] }.compactMap { $0 }
        let temperatureRange = 30...max(90, (temperatures.max() ?? 0) + 5)
        let fanPeak = samples.compactMap(\.fan).max()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 10 minutes").foregroundStyle(.secondary)
                Spacer()
                legend("CPU", .orange); legend("GPU", .purple)
                if let peak = temperatures.max() { Text("peak \(Int(peak.rounded()))°C").foregroundStyle(.secondary) }
            }
            .font(.caption)
            ZStack {
                Sparkline(values: samples.map(\.cpu), range: temperatureRange, capacity: capacity).stroke(.orange, lineWidth: 1.5)
                Sparkline(values: samples.map(\.gpu), range: temperatureRange, capacity: capacity).stroke(.purple, lineWidth: 1.5)
            }
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
            if showsFan {
                HStack {
                    legend("Fan", .teal)
                    Spacer()
                    if let fanPeak { Text("peak \(Int(fanPeak.rounded()).formatted()) RPM").foregroundStyle(.secondary) }
                }
                .font(.caption)
                Sparkline(values: samples.map(\.fan), range: 0...(fanMaximum ?? max(fanPeak ?? 1, 1)), capacity: capacity)
                    .stroke(.teal, lineWidth: 1.5)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsFan ? "Temperature and fan history for the last 10 minutes" : "Temperature history for the last 10 minutes")
    }
    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// Small line drawing of the curve from 30°C to 80°C, where maximum takes over.
struct CurvePreview: View {
    let curve: FanCurve
    let bounds: HardwareBounds
    private let low = FanCurve.lowestTemperature, high = CoolingPolicy.stopLimit
    private func point(_ temperature: Double, _ rpm: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: (temperature - low) / (high - low) * size.width,
                y: (1 - (rpm - bounds.minimum) / (bounds.maximum - bounds.minimum)) * size.height)
    }
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: point(low, curve.rpm(at: low), in: geometry.size))
                for item in curve.points { path.addLine(to: point(item.temperature, item.rpm, in: geometry.size)) }
                path.addLine(to: point(high - 0.001, curve.points.last!.rpm, in: geometry.size))
                path.addLine(to: point(high, bounds.maximum, in: geometry.size))
            }
            .stroke(Color.accentColor, lineWidth: 2)
            ForEach(curve.points, id: \.temperature) { item in
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .position(point(item.temperature, item.rpm, in: geometry.size))
            }
        }
        .frame(height: 70)
        .padding(.vertical, 4)
        .accessibilityLabel("Fan curve preview")
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

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = CoolingModel()
    let popover = NSPopover()
    var timer: Timer?
    // Changing the status item while its menu is open can dismiss the menu, so updates wait until it closes.
    private var menuOpen = false
    private var layoutPending = false
    private var symbol = "fan"
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        model.onUpdate = { [weak self] in self?.refreshStatusItem(); self?.runQueuedCommands() }
        model.confirmRemoteStart = { [weak self] mode in self?.confirmStart(mode) ?? false }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stop), name: NSWorkspace.willSleepNotification, object: nil)
        removeStaleSessions()
        UNUserNotificationCenter.current().delegate = self
        model.onHotKeyChange = { [weak self] in self?.updateHotKey() }
        updateHotKey()
        model.refresh()
    }
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// Registers or removes ⌃⌥M. Carbon hot keys need no Accessibility permission.
    private func updateHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        model.hotKeyError = nil
        guard model.usesMaxHotKey, !model.fanless else { return }
        if hotKeyHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                Unmanaged<MenuApp>.fromOpaque(context).takeUnretainedValue().toggleMaximum()
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: 0x42414447 /* "BADG" */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { model.hotKeyError = "⌃⌥M is already used by another app." }
    }
    private var queuedCommands: [RemoteCommand] = []
    /// Handles baadgir:// links from Shortcuts, the command line, or other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do { queuedCommands.append(try RemoteCommand(url: url)) }
            catch { model.message = String(describing: error); showMessage() }
        }
        runQueuedCommands()
    }
    private var confirming = false
    /// Asks before a link, Shortcut or command starts cooling, so a web page can't raise the password prompt on its own.
    private func confirmStart(_ mode: FanMode) -> Bool {
        // One question at a time; requests that arrive meanwhile are declined.
        guard !confirming else { return false }
        let name: String
        switch mode {
        case .curve: name = "Curve"
        case .manual: name = "Manual"
        case .maximum: name = "Max"
        case .auto: return true
        }
        confirming = true
        defer { confirming = false }
        let alert = NSAlert()
        alert.messageText = "Start \(name) cooling?"
        alert.informativeText = "A link, Shortcut or command asked Baadgir to take over the fans. If you continue, macOS asks for your administrator password."
        alert.addButton(withTitle: "Start \(name)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Waits for the first sensor read so a link that launched the app isn't refused for missing readings.
    private func runQueuedCommands() {
        guard model.hasRead, !queuedCommands.isEmpty else { return }
        let commands = queuedCommands
        queuedCommands = []
        for command in commands { model.perform(command) }
        showMessage()
    }
    /// Opens the popover when a request from outside it was refused, so the reason is visible.
    private func showMessage() {
        if model.message != nil, !popover.isShown { togglePopover() }
    }
    private func toggleMaximum() {
        model.select(model.displayedMode == .maximum ? .auto : .maximum)
        showMessage()
    }
    // Menu bar apps count as active while their popover is open; show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
        let wanted = model.fanless ? "thermometer.medium" : model.displayedMode == .auto ? "fan" : "fan.fill"
        let symbolChanged = wanted != symbol
        symbol = wanted
        if layoutPending { layoutPending = false; fixStatusItemWidth() }
        else if stacked { updateStackedImage() }
        else {
            updateTitle()
            if symbolChanged { item.button?.image = statusSymbol }
        }
        item.button?.toolTip = "Baadgir · " + model.status
    }
    private var stacked: Bool { model.stacksMenuBarReadings && model.shownMenuBarReadings.count > 1 }
    private var statusSymbol: NSImage? {
        model.showsMenuBarIcon ? NSImage(systemSymbolName: symbol, accessibilityDescription: "Baadgir") : nil
    }
    private func currentValue(_ reading: TemperatureReading) -> Double? { model.value(of: reading) }
    private var titleFont: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
    /// One reading shows " 72°C"; several show " C 72°  G 64°" with letter prefixes. No leading space without the icon.
    private func title(_ value: (TemperatureReading) -> Double?, colored: Bool) -> NSAttributedString {
        let readings = model.shownMenuBarReadings
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping  // The default word wrap splits readings onto two lines.
        let base: [NSAttributedString.Key: Any] = [.font: titleFont, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        for (index, reading) in readings.enumerated() {
            if readings.count > 1 {
                var label = base; label[.foregroundColor] = NSColor.secondaryLabelColor
                let lead = index > 0 ? "  " : model.showsMenuBarIcon ? " " : ""
                text.append(NSAttributedString(string: lead + reading.letter + " ", attributes: label))
            } else if model.showsMenuBarIcon { text.append(NSAttributedString(string: " ", attributes: base)) }
            var attributes = base
            if colored, let level = model.heatLevel(reading, value(reading)) {
                attributes[.foregroundColor] = NSColor.heat(level)
            }
            text.append(NSAttributedString(string: reading.text(value(reading), compact: readings.count > 1), attributes: attributes))
        }
        return text
    }
    private func updateTitle() {
        item.button?.attributedTitle = title(currentValue, colored: true)
    }
    /// SF Mono, like other apps' stacked menu bar readings (Stats, for one), so the two sit together evenly.
    private var stackedFont: NSFont { .monospacedSystemFont(ofSize: 10, weight: .medium) }
    /// The fan symbol (unless hidden), then readings two to a column: "C 72°" over "G 64°". Not a template image, so the heat colours
    /// show; label colours resolve when the menu bar draws it, so it follows the menu bar's light or dark appearance.
    private func stackedImage(_ value: (TemperatureReading) -> Double?, colored: Bool) -> NSImage {
        let font = stackedFont, height = NSStatusBar.system.thickness
        let lineHeight = ceil(font.ascender - font.descender)
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let letterWidth = TemperatureReading.allCases.map { width($0.letter) }.max() ?? 0
        let gap: CGFloat = 3, spacing: CGFloat = 7
        // Sized for the widest value so the item never shifts.
        let column = letterWidth + gap + (model.shownMenuBarReadings.map { width($0.text($0.widest, compact: true)) }.max() ?? 0)
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        let fan = model.showsMenuBarIcon
            ? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) : nil
        let fanWidth = fan.map { ceil($0.size.width) + 5 } ?? 0
        let columns = MenuBarLayout.columns(model.shownMenuBarReadings).map { column in
            column.map { reading -> (letter: String, number: String, color: NSColor) in
                let level = colored ? model.heatLevel(reading, value(reading)) : nil
                return (reading.letter, reading.text(value(reading), compact: true), level.map(NSColor.heat) ?? .labelColor)
            }
        }
        let size = NSSize(width: fanWidth + CGFloat(columns.count) * column + CGFloat(max(columns.count - 1, 0)) * spacing,
                          height: height)
        return NSImage(size: size, flipped: true) { _ in
            if let fan {
                fan.draw(in: NSRect(x: 0, y: (height - fan.size.height) / 2, width: fan.size.width, height: fan.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            for (index, lines) in columns.enumerated() {
                let x = fanWidth + CGFloat(index) * (column + spacing)
                for (line, entry) in lines.enumerated() {
                    // A column with one reading is centred vertically.
                    let y = (height - CGFloat(lines.count) * lineHeight) / 2 + CGFloat(line) * lineHeight
                    NSAttributedString(string: entry.letter, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                        .draw(at: CGPoint(x: x, y: y))
                    let number = NSAttributedString(string: entry.number, attributes: [.font: font, .foregroundColor: entry.color])
                    number.draw(at: CGPoint(x: x + column - number.size().width, y: y))  // Right-aligned so digits stay put.
                }
            }
            return true
        }
    }
    private func updateStackedImage() {
        item.button?.image = stackedImage(currentValue, colored: true)
        item.button?.setAccessibilityValue(model.shownMenuBarReadings.map { reading in
            "\(reading.title) " + (currentValue(reading).map { reading.text($0, compact: false) } ?? "unavailable")
        }.joined(separator: ", "))
    }
    /// Sizes the item for the widest readings so it (and the popover anchored to it) never shifts as numbers change.
    private func fixStatusItemWidth() {
        guard let button = item.button else { return }
        if stacked {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            item.length = stackedImage(\.widest, colored: false).size.width + 8
            updateStackedImage()
            return
        }
        button.setAccessibilityValue(nil)
        button.image = statusSymbol
        button.imagePosition = model.showsMenuBarIcon ? .imageLeading : .noImage
        button.font = titleFont
        button.alignment = .center
        button.attributedTitle = title(\.widest, colored: false)
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
        if let power = model.power { info("Power: " + power.text) }
        menu.addItem(.separator())
        let busy = model.pending != nil || model.fans.isEmpty
        for (title, mode) in model.fanless ? [] : [("Auto", FanMode.auto),
                              ("Curve", .curve),
                              ("Manual · \(Int(model.selectedRPM.rounded()).formatted()) RPM", .manual),
                              ("Max", .maximum)] {
            let entry = NSMenuItem(title: title, action: busy ? nil : #selector(selectMode(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = mode
            entry.state = model.displayedMode == mode ? .on : .off
            if mode == .maximum, model.usesMaxHotKey, model.hotKeyError == nil {
                entry.keyEquivalent = "m"; entry.keyEquivalentModifierMask = [.control, .option]
            }
            menu.addItem(entry)
        }
        if !model.fanless { menu.addItem(.separator()) }
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
            // Size to the SwiftUI content first; centering the default-sized window leaves it off-center once it grows.
            window.setContentSize(host.view.fittingSize)
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
        let chip = chipName()
        var lines = ["Chip: \(chip.isEmpty ? "unknown" : chip)"
                     + (SensorKeys.generation(brand: chip) == nil ? " (not in the sensor table; probing every known key)" : "")]
        do {
            let fans = try smc.fans()
            lines += fans.isEmpty ? ["No fans: temperatures only"] : fans.map {
                "Fan \($0.index): \($0.rpm) RPM, range \($0.minimum)–\($0.maximum), mode \($0.mode) (\($0.modeKey))"
            }
        } catch { lines.append("Fan readings unavailable: \(error)") }
        do {
            let temperatures = try smc.temperatures()
            lines.append("CPU \(temperatures.cpu)°C · GPU \(temperatures.gpu)°C")
            lines.append("Sensors: CPU \(smc.cpuKeys.joined(separator: " ")) · GPU \(smc.gpuKeys.joined(separator: " "))")
        } catch { lines.append("Temperature readings unavailable: \(error)") }
        do { lines.append("Power: " + (try smc.power()).text) }
        catch { lines.append("Power readings unavailable: \(error)") }
        return lines.joined(separator: "\n")
    } catch { return "Read-only diagnostic failed: \(error)" }
}
let arguments = CommandLine.arguments
let usage = """
Usage: baadgir status | auto | curve | max | manual [RPM]
  status        Print fan and sensor readings (read-only).
  auto … max    Ask the running Baadgir app to change fan mode, with the same checks as the app.
"""
let bundleIdentifier = "local.baadgir"
/// Sends a request to the running Baadgir (launching the installed copy if needed) through its baadgir:// link.
func send(_ command: RemoteCommand) -> Int32 {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // By bundle ID, so the request reaches the copy that is already running rather than starting another.
    open.arguments = ["-g", "-b", bundleIdentifier, command.url.absoluteString]
    do { try open.run(); open.waitUntilExit() } catch { fputs("\(error)\n", stderr); return 1 }
    return open.terminationStatus
}
// No logs: nothing here writes readings to disk. `--probe` and `status` print to the terminal only.
if arguments.contains("--probe") || arguments.dropFirst() == ["status"] {
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
} else if arguments.count >= 2, !arguments[1].hasPrefix("-") {
    // Plain words are commands; anything starting with "-" may come from macOS when it launches the app.
    do { exit(send(try RemoteCommand(arguments: Array(arguments.dropFirst())))) }
    catch {
        if arguments[1].lowercased() == "manual" { fputs("\(error)\n", stderr) }
        fputs(usage + "\n", stderr); exit(arguments[1] == "help" ? 0 : 2)
    }
} else if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains(where: { $0.processIdentifier != getpid() }) {
    // Two copies would delete each other's session folders and fight over the fans.
    fputs("Baadgir is already running.\n", stderr)
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
