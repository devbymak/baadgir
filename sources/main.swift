import AppKit
import SwiftUI
import IOKit
import Darwin

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
            guard !cpuKeys.isEmpty, !gpuKeys.isEmpty else {
                throw Failure("CPU and GPU temperature readings are unavailable")
            }
            discoveredTemperatures = true
        }
        // Once discovered, every sensor must stay readable. Never silently discard a failed sensor.
        return try Temperatures(cpu: cpuKeys.map { Double(try number($0)) },
                                gpu: gpuKeys.map { Double(try number($0)) },
                                battery: batteryKeys.map { Double(try number($0)) })
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

struct ManualRequest {
    let rpm: Double
    let minimum: Double
    let maximum: Double
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
func coolingSession(parent: pid_t, stopPath: String, manual: ManualRequest? = nil) throws {
    guard geteuid() == 0 else { throw Failure("Fan control requires administrator authorization") }
    let lock = open("/var/run/local.parvanak.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw Failure("Cannot create cooling session lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("A cooling session is already running") }
    guard kill(parent, 0) == 0, !FileManager.default.fileExists(atPath: stopPath) else {
        throw Failure("Cooling session was cancelled before it started")
    }
    let smc = try SMC()
    let fans = try smc.fans()
    guard fans.allSatisfy({ $0.rpm <= $0.maximum }) else {
        throw Failure("Actual RPM exceeds the reported limit; keeping system control")
    }
    guard fans.allSatisfy({ $0.mode != 1 }) else {
        throw Failure("Another app already controls a fan. Return it to Auto first.")
    }
    if let manual {
        let bounds = try HardwareBounds(ranges: fans.map { (Double($0.minimum), Double($0.maximum)) })
        try CoolingPolicy.validateRange(rpm: manual.rpm, minimum: manual.minimum,
                                        maximum: manual.maximum, hardware: bounds)
        try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: true)
    }
    signal(SIGTERM, handleSignal); signal(SIGINT, handleSignal); signal(SIGHUP, handleSignal)
    var touched: [Fan] = []
    func restore() -> Bool {
        AutomaticRestoration.restore(keys: touched.map(\.modeKey),
            readMode: { Double(try smc.number($0)) },
            writeAutomatic: { try smc.write($0, expectedType: "ui8 ", bytes: [0]) },
            retryDelay: { usleep(100_000) })
    }
    do {
        guard kill(parent, 0) == 0, !FileManager.default.fileExists(atPath: stopPath) else {
            throw Failure("Cooling session was cancelled")
        }
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
        if let manual {
            try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: true)
            for fan in fans { try smc.target(fan, rpm: Float(manual.rpm)) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(CoolingPolicy.sessionSeconds))
        var previous = start
        while clock.now < deadline && interrupted == 0 {
            let now = clock.now
            if previous.duration(to: now) > .seconds(3) || kill(parent, 0) != 0 ||
                FileManager.default.fileExists(atPath: stopPath) { break }
            previous = now
            if manual != nil {
                try CoolingPolicy.validateTemperature(smc.temperatures(), thermal: thermalLevel(), starting: false)
            }
            let live = try smc.fans()
            guard live.count == fans.count else { throw Failure("Fan configuration changed") }
            for (fan, original) in zip(live, fans) {
                let target = Float(manual?.rpm ?? Double(original.maximum))
                guard fan.minimum == original.minimum, fan.maximum == original.maximum,
                      fan.mode == 1, abs(try smc.number("F\(fan.index)Tg") - target) <= 1 else {
                    throw Failure("System reclaimed fan control; session ended")
                }
                if start.duration(to: now) > .seconds(5), fan.rpm < max(300, target * 0.35) {
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

final class CoolingModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var temperatures: Temperatures?
    @Published var sensorError = "Reading sensors…"
    @Published var status = "Automatic cooling"
    @Published var minimumText = "1000" { didSet { clampSelection() } }
    @Published var maximumText = "6000" { didSet { clampSelection() } }
    @Published var selectedRPM = 6000.0
    @Published var sessionRunning = false
    @Published var remainingSeconds: Int?
    @Published var message: String?
    var bounds: HardwareBounds?
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "local.parvanak.sensors")
    private var smc: SMC?
    private var reading = false
    private var initializedLimits = false
    private var helper: Process?
    private var stopPath: String?
    private var observedStart: Date?

    var minimum: Double? { Double(minimumText) }
    var maximum: Double? { Double(maximumText) }
    var rangeIsValid: Bool {
        guard let bounds, let minimum, let maximum else { return false }
        return (try? CoolingPolicy.validateRange(rpm: selectedRPM, minimum: minimum,
                                                 maximum: maximum, hardware: bounds)) != nil
    }
    var sliderRange: ClosedRange<Double> {
        if let bounds, let minimum, let maximum,
           minimum.isFinite, maximum.isFinite, minimum >= bounds.minimum,
           maximum <= bounds.maximum, minimum < maximum { return minimum...maximum }
        return (bounds?.minimum ?? 1000)...(bounds?.maximum ?? 6000)
    }
    var canApply: Bool {
        rangeIsValid && !sessionRunning && fans.allSatisfy({ $0.mode != 1 }) &&
        (try? CoolingPolicy.validateTemperature(temperatures, thermal: thermalLevel(), starting: true)) != nil
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
    func clampSelection() {
        guard selectedRPM.isFinite else { selectedRPM = sliderRange.upperBound; return }
        selectedRPM = min(max(selectedRPM, sliderRange.lowerBound), sliderRange.upperBound)
    }
    func refresh() {
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
                if !self.initializedLimits, let bounds = self.bounds {
                    self.minimumText = String(Int(ceil(bounds.minimum)))
                    self.maximumText = String(Int(floor(bounds.maximum)))
                    self.selectedRPM = floor(bounds.maximum)
                    self.initializedLimits = true
                }
                if self.sessionRunning && fans.contains(where: { $0.mode == 1 }) {
                    if self.observedStart == nil { self.observedStart = Date() }
                    self.remainingSeconds = max(0, CoolingPolicy.sessionSeconds - Int(Date().timeIntervalSince(self.observedStart!)))
                    self.status = "Manual cooling · \(self.remainingSeconds!)s remaining"
                }
                // The helper performs its own independent sensor checks as well.
                if self.sessionRunning && !errorMessage.isEmpty && temperatures == nil {
                    // A maximum-only boost can run without temperatures; its RPM is never reduced.
                    if self.manualSession { self.endSession() }
                }
                self.onUpdate?()
            }
        }
    }
    private var manualSession = false
    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    func applyManual() {
        guard canApply, let minimum, let maximum else { return }
        startSession(manual: ManualRequest(rpm: selectedRPM.rounded(), minimum: minimum, maximum: maximum))
    }
    func maximumBoost() {
        guard !sessionRunning, !fans.isEmpty, fans.allSatisfy({ $0.mode != 1 }) else { return }
        startSession(manual: nil)
    }
    private func startSession(manual: ManualRequest?) {
        guard helper == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parvanak-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { message = "Cannot create cooling session: \(error)"; return }
        let stopFile = directory.appendingPathComponent("stop").path
        stopPath = stopFile
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var args = [executable, manual == nil ? "--boost" : "--control", String(getpid()), stopFile]
        if let manual { args += [String(manual.rpm), String(manual.minimum), String(manual.maximum)] }
        let command = args.map(shellQuote).joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let errors = Pipe(); process.standardError = errors
        process.terminationHandler = { [weak self] completed in
            let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.helper = nil; self.stopPath = nil; self.sessionRunning = false
                self.observedStart = nil; self.remainingSeconds = nil
                self.status = completed.terminationStatus == 0 ? "Automatic cooling restored" : "Cooling session ended"
                try? FileManager.default.removeItem(at: directory)
                if completed.terminationStatus != 0 { self.message = error.isEmpty ? "Cooling session could not complete" : error }
                self.refresh(); self.onUpdate?()
            }
        }
        helper = process; manualSession = manual != nil
        status = "Waiting for administrator authorization…"
        sessionRunning = true; message = nil
        do { try process.run() }
        catch {
            helper = nil; stopPath = nil; sessionRunning = false
            status = "Automatic cooling"; message = String(describing: error)
            try? FileManager.default.removeItem(at: directory)
        }
        onUpdate?()
    }
    func endSession() {
        guard let path = stopPath else { return }
        if !FileManager.default.createFile(atPath: path, contents: Data()) {
            message = "Could not signal stop. The helper should finish at its 60-second deadline."
        }
        status = "Restoring automatic cooling…"; onUpdate?()
    }
}

struct ControlsView: View {
    @ObservedObject var model: CoolingModel
    let quit: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "app-icon") {
                        Image(nsImage: icon).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                    } else { Image(systemName: "fan").font(.title2).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Parvanak").font(.headline)
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 24) {
                    temperature("CPU", value: model.temperatures?.cpu)
                    temperature("GPU", value: model.temperatures?.gpu)
                    Spacer()
                }
                Text("Thermal pressure: \(model.thermalText)").font(.caption).foregroundStyle(.secondary)
                ForEach(model.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index + 1)")
                        Spacer()
                        Text("\(Int(fan.rpm)) RPM").monospacedDigit()
                        Text(fan.mode == 1 ? "Manual" : "Auto").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.sensorError.isEmpty {
                    Text(model.sensorError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text("Fan speed").font(.headline)
                    Spacer()
                    Text("\(Int(model.selectedRPM.rounded())) RPM").monospacedDigit()
                }
                Slider(value: $model.selectedRPM, in: model.sliderRange, step: 1)
                    .disabled(model.bounds == nil || model.sessionRunning)
                    .accessibilityLabel("Fan speed in RPM")
                HStack(spacing: 16) {
                    limitField("Minimum RPM", text: $model.minimumText)
                    limitField("Maximum RPM", text: $model.maximumText)
                }
                .disabled(model.bounds == nil || model.sessionRunning)
                if let bounds = model.bounds {
                    Text("Hardware range: \(Int(ceil(bounds.minimum)))–\(Int(floor(bounds.maximum))) RPM")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.bounds != nil && !model.rangeIsValid {
                    Text("Enter a minimum below the maximum, within the hardware range.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Apply speed for 60 seconds…") { model.applyManual() }
                    .buttonStyle(.borderedProminent).disabled(!model.canApply)
                Text("Manual control returns to Auto at 80°C or if monitoring fails. Start below 75°C. Your limits apply only to manual speed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Maximum cooling…") { model.maximumBoost() }
                        .disabled(model.sessionRunning || model.fans.isEmpty || model.fans.contains(where: { $0.mode == 1 }))
                    Spacer()
                    Button("Auto") { model.endSession() }.disabled(!model.sessionRunning)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Divider()
                HStack { Spacer(); Button("Quit Parvanak", action: quit).buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
        .frame(width: 360, height: 570)
    }
    private func temperature(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f°C", $0) } ?? "—°C")
                .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
    private func limitField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}

final class MenuApp: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = CoolingModel()
    let popover = NSPopover()
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Parvanak")
        item.button?.setAccessibilityLabel("Parvanak temperature and fan controls")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ControlsView(model: model, quit: { [weak self] in self?.quitApp() }))
        model.onUpdate = { [weak self] in
            guard let self else { return }
            self.item.button?.title = self.model.temperatures.map { " \(Int($0.highest.rounded()))°C" } ?? " —°C"
            self.item.button?.toolTip = "Parvanak · " + self.model.status
        }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stop), name: NSWorkspace.willSleepNotification, object: nil)
        model.refresh()
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
    @objc func stop() { model.endSession() }
    @objc func quitApp() { model.endSession(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.endSession() }
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
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--diagnose" {
    try? diagnostic().write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
} else if CommandLine.arguments.contains("--probe") {
    print(diagnostic())
} else if (CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--boost") ||
          (CommandLine.arguments.count == 7 && CommandLine.arguments[1] == "--control") {
    do {
        guard let parent = Int32(CommandLine.arguments[2]), parent > 1 else { throw Failure("Invalid parent") }
        var request: ManualRequest?
        if CommandLine.arguments[1] == "--control" {
            guard let rpm = Double(CommandLine.arguments[4]), let minimum = Double(CommandLine.arguments[5]),
                  let maximum = Double(CommandLine.arguments[6]) else { throw Failure("Invalid RPM limits") }
            request = ManualRequest(rpm: rpm, minimum: minimum, maximum: maximum)
        }
        try coolingSession(parent: parent, stopPath: CommandLine.arguments[3], manual: request)
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
