import AppKit
import IOKit
import Darwin

struct Fan {
    let index: Int
    let rpm: Float
    let maximum: Float
    let modeKey: String
    let mode: UInt8
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
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
        let value: Float
        if type == "flt ", data.count == 4 {
            value = data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        } else if type == "ui8 ", data.count == 1 { value = Float(data[0]) }
        else { throw Failure("Unsupported format for \(key): \(type)") }
        guard value.isFinite, value >= 0 else { throw Failure("Invalid value for \(key)") }
        return value
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
            return Fan(index: index, rpm: try number(prefix + "Ac"), maximum: maximum,
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
    func target(_ fan: Fan) throws {
        var value = fan.maximum
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        try write("F\(fan.index)Tg", expectedType: "flt ", bytes: bytes)
    }
    func mode(_ fan: Fan, _ value: UInt8) throws {
        guard value == 0 || value == 1 else { throw Failure("Mode blocked") }
        try write(fan.modeKey, expectedType: "ui8 ", bytes: [value])
    }
}

var interrupted: sig_atomic_t = 0
func handleSignal(_ signal: Int32) { interrupted = 1 }
func boost(parent: pid_t, stopPath: String) throws {
    guard geteuid() == 0 else { throw Failure("Cooling boost requires administrator authorization") }
    let lock = open("/var/run/local.parvanak.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw Failure("Cannot create cooling session lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("A cooling session is already running") }
    let smc = try SMC()
    let fans = try smc.fans()
    guard fans.allSatisfy({ $0.rpm <= $0.maximum }) else { throw Failure("Actual RPM exceeds the reported limit; keeping system control") }
    guard fans.allSatisfy({ $0.mode != 1 }) else { throw Failure("Another app already controls a fan. Return it to Auto first.") }
    signal(SIGTERM, handleSignal); signal(SIGINT, handleSignal); signal(SIGHUP, handleSignal)
    var touched: [Fan] = []
    var restoreFailed = false
    func restore() {
        for fan in touched {
            var restored = false
            for _ in 0..<3 {
                do {
                    try smc.mode(fan, 0)
                    let mode = try smc.number(fan.modeKey)
                    if mode == 0 || mode == 3 { restored = true; break }
                } catch { }
                usleep(100_000)
            }
            if !restored { restoreFailed = true }
        }
    }
    do {
        for fan in fans {
            // Set maximum first: never enter manual mode with a low target.
            touched.append(fan)
            try smc.target(fan)
            try smc.mode(fan, 1)
            guard try smc.number(fan.modeKey) == 1,
                  abs(try smc.number("F\(fan.index)Tg") - fan.maximum) <= 1 else {
                throw Failure("Fan controller did not confirm maximum cooling")
            }
        }
        let start = Date()
        var previous = start
        while Date().timeIntervalSince(start) < 60 && interrupted == 0 {
            let now = Date()
            if now.timeIntervalSince(previous) > 3 || kill(parent, 0) != 0 ||
                FileManager.default.fileExists(atPath: stopPath) { break }
            previous = now
            let live = try smc.fans()
            guard live.count == fans.count else { throw Failure("Fan configuration changed") }
            for fan in live {
                guard fan.mode == 1,
                      abs(try smc.number("F\(fan.index)Tg") - fan.maximum) <= 1 else {
                    throw Failure("System reclaimed fan control; boost ended")
                }
            }
            usleep(500_000)
        }
    } catch {
        restore()
        if restoreFailed { throw Failure("Automatic control could not be verified. Restart your Mac. Original error: \(error)") }
        throw error
    }
    restore()
    if restoreFailed { throw Failure("Automatic control could not be verified. Restart your Mac.") }
}

final class MenuApp: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var helper: Process?
    var stopPath: String?
    var status = "Automatic cooling"
    var boosting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Parvanak")
        item.button?.setAccessibilityLabel("Parvanak cooling controls")
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stop), name: NSWorkspace.willSleepNotification, object: nil)
        refresh()
    }
    func refresh() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Parvanak", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        var readable = false
        do {
            let fans = try SMC().fans()
            readable = true
            for fan in fans {
                menu.addItem(withTitle: "Fan \(fan.index + 1): \(Int(fan.rpm)) RPM · \(fan.mode == 1 ? "Manual" : "Automatic")", action: nil, keyEquivalent: "")
            }
            item.button?.title = fans.map { String(Int($0.rpm)) }.joined(separator: "/")
        } catch { menu.addItem(withTitle: "Fan readings unavailable", action: nil, keyEquivalent: "") }
        let thermal = [ProcessInfo.ThermalState.nominal: "Normal", .fair: "Warm", .serious: "High", .critical: "Critical"]
        menu.addItem(withTitle: "Thermal pressure: \(thermal[ProcessInfo.processInfo.thermalState] ?? "Unknown")", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let boostItem = menu.addItem(withTitle: "Maximum cooling for 60 seconds…", action: #selector(startBoost), keyEquivalent: "b")
        boostItem.target = self; boostItem.isEnabled = readable && helper == nil
        let auto = menu.addItem(withTitle: "End boost · Return to automatic", action: #selector(stop), keyEquivalent: "a")
        auto.target = self; auto.isEnabled = helper != nil
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Parvanak", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.autoenablesItems = false
        item.menu = menu
    }
    func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @objc func startBoost() {
        guard helper == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Parvanak-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { showError("Cannot create cooling session: \(error)"); return }
        let stopFile = directory.appendingPathComponent("stop").path
        stopPath = stopFile
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let command = shellQuote(executable) + " --boost " + String(getpid()) + " " + shellQuote(stopFile)
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let errors = Pipe(); process.standardError = errors
        process.terminationHandler = { [weak self] completed in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.helper = nil; self.stopPath = nil
                self.status = completed.terminationStatus == 0 ? "Automatic cooling restored" : "Boost did not complete"
                try? FileManager.default.removeItem(at: directory)
                self.refresh()
                if completed.terminationStatus != 0 { self.showError(message) }
            }
        }
        helper = process; status = "Cooling session · ends within 60 seconds"
        do { try process.run() } catch { helper = nil; status = "Automatic cooling"; showError(String(describing: error)) }
        refresh()
    }
    @objc func stop() {
        if let path = stopPath { FileManager.default.createFile(atPath: path, contents: Data()) }
        status = "Restoring automatic cooling…"; refresh()
    }
    @objc func quitApp() { stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if let path = stopPath { FileManager.default.createFile(atPath: path, contents: Data()) } }
    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Cooling session ended"; alert.informativeText = message
        alert.runModal()
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--diagnose" {
    let report: String
    do { report = try SMC().fans().map { "Fan \($0.index): \($0.rpm) RPM, maximum \($0.maximum), mode \($0.mode) (\($0.modeKey))" }.joined(separator: "\n") }
    catch { report = "Read-only diagnostic failed: \(error)" }
    try? report.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
} else if CommandLine.arguments.contains("--probe") {
    do {
        for fan in try SMC().fans() { print("Fan \(fan.index): \(fan.rpm) RPM, maximum \(fan.maximum), mode \(fan.mode) (\(fan.modeKey))") }
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--boost" {
    do {
        guard let parent = Int32(CommandLine.arguments[2]), parent > 1 else { throw Failure("Invalid parent") }
        try boost(parent: parent, stopPath: CommandLine.arguments[3])
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
