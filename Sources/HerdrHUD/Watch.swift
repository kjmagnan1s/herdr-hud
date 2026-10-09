import Foundation

/// Keeps one read-only event bridge (watch.py) running for a machine and
/// reports what it prints. Any exit restarts it with backoff. A link that stays
/// silent past two missed heartbeats is treated as dead and restarted.
final class EventWatcher {
    enum Signal { case ready, changed, down }
    static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60]
    static let silence: TimeInterval = 50
    let machine: Machine
    private let invocation: Invocation
    private let handler: (Signal) -> Void
    private let queue = DispatchQueue(label: "herdr-hud.watch")
    private var process: Process?, input: FileHandle?, buffer = Data()
    private var lastLine = Date(), attempt = 0, stopped = false, healthy = false, generation = 0
    private var watchdog: DispatchSourceTimer?

    init(machine: Machine, invocation: Invocation, handler: @escaping (Signal) -> Void) {
        self.machine = machine; self.invocation = invocation; self.handler = handler
    }
    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                guard let self = self, self.process != nil, Date().timeIntervalSince(self.lastLine) > Self.silence else { return }
                self.process?.terminate()
            }
            timer.resume(); self.watchdog = timer
            self.launch()
        }
    }
    func stop() {
        queue.async { self.stopped = true; self.watchdog?.cancel(); self.watchdog = nil; self.process?.terminate(); try? self.input?.close() }
    }
    private func launch() {
        guard !stopped else { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        // Output and its end arrive in order on the serial queue, so the last
        // lines are always handled before the bridge counts as gone.
        generation += 1; let current = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { guard self?.generation == current else { return }; if data.isEmpty { self?.ended() } else { self?.receive(data) } }
        }
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { stdout.fileHandleForReading.readabilityHandler = nil; retry(); return }
        self.process = process; input = stdin.fileHandleForWriting; buffer = Data(); lastLine = Date()
        // The request is the only input. Stdin then stays open: closing it is
        // how the bridge, locally or across SSH, learns the HUD has gone.
        try? input?.write(contentsOf: invocation.input ?? Data())
    }
    private func receive(_ data: Data) {
        buffer.append(data); lastLine = Date()
        guard buffer.count <= 1_048_576 else { process?.terminate(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]; buffer.removeSubrange(buffer.startIndex...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? Row else { continue }
            switch value["type"] as? String {
            case "ready": healthy = true; attempt = 0; handler(.ready)
            case "changed": handler(.changed)
            default: break
            }
        }
    }
    private func ended() {
        guard let finished = process else { return }
        if finished.isRunning { finished.terminate() }
        process = nil; try? input?.close(); input = nil
        if healthy { healthy = false; handler(.down) }
        retry()
    }
    private func retry() {
        guard !stopped else { return }
        let delay = Self.delays[min(attempt, Self.delays.count - 1)]; attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }
}
