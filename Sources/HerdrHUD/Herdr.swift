import Foundation
import Darwin

typealias Row = [String: Any]
struct HUDError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func encode(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
struct Machine: Equatable {
    let id: String, label: String, target: String?, session: String
    var json: Row { ["id": id, "label": label, "session": session] }
}
struct Invocation {
    let executable: String
    let arguments: [String]
    let mutation: Bool
    var input: Data? = nil
    var localPrompt: Bool = false
}
final class HerdrClient {
    let execute: (Invocation) throws -> String
    let binary: String
    // Snapshots write bindings on the transport queue while reads and sends use
    // their own queues, so access goes through a lock.
    private let bindingLock = NSLock()
    private var boundAgents: [String: (Machine, Row)] = [:]
    var bindings: [String: (Machine, Row)] {
        get { bindingLock.lock(); defer { bindingLock.unlock() }; return boundAgents }
        set { bindingLock.lock(); boundAgents = newValue; bindingLock.unlock() }
    }
    var machines: [Machine] = []
    var discoveryError = ""
    init(binary: String? = nil, execute: ((Invocation) throws -> String)? = nil) {
        let candidates = [NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        self.binary = binary ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/env"
        let runner = ProcessRunner()
        self.execute = execute ?? { try runner.run($0) }
    }
    func invocation(_ machine: Machine, _ args: [String], mutation: Bool = false, input: Data? = nil) throws -> Invocation {
        let scoped = ["--session", machine.session] + args
        guard !scoped.contains(where: { $0.contains("\0") }) else { throw HUDError("Invalid command argument.") }
        if let target = machine.target {
            guard !target.isEmpty, !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace || $0.isNewline }), !target.contains("\0") else { throw HUDError("Invalid saved SSH target.") }
            // The remote login shell may be fish. Run our fixed POSIX script explicitly.
            // Herdr's standard user install is checked first, then normal PATH lookup.
            let script = "unset HERDR_ENV HERDR_SOCKET_PATH HERDR_CONFIG_PATH HERDR_SESSION HERDR_SESSION_NAME HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_TERMINAL_ID; if [ -x \"$HOME/.local/bin/herdr\" ]; then exec \"$HOME/.local/bin/herdr\" \"$@\"; elif [ -x /opt/homebrew/bin/herdr ]; then exec /opt/homebrew/bin/herdr \"$@\"; else exec herdr \"$@\"; fi"
            let remote = mutation ? ["python3", "-c", try String(contentsOf:HUDResources.root.appendingPathComponent("prompt.py"),encoding:.utf8)].map(shellQuote).joined(separator:" ") : (["sh", "-c", script, "herdr-hud"] + scoped).map(shellQuote).joined(separator: " ")
            return Invocation(executable: "/usr/bin/ssh", arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", target, remote], mutation: mutation, input: input)
        }
        return Invocation(executable: binary, arguments: (binary == "/usr/bin/env" ? ["herdr"] : []) + scoped, mutation: mutation, input:input, localPrompt:mutation)
    }
    // Python that is really installed. The /usr/bin/python3 stub would pop a
    // Command Line Tools install dialog over the game, so it is never used.
    static let localPython = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    /// The read-only event bridge for one machine, or nil when it cannot run
    /// there (no usable Python on this Mac); that machine is then polled.
    func watchInvocation(_ machine: Machine, python: String? = HerdrClient.localPython) throws -> Invocation? {
        let script = try String(contentsOf: HUDResources.root.appendingPathComponent("watch.py"), encoding: .utf8)
        let input = Data((encode(["session": machine.session]) + "\n").utf8)
        if let target = machine.target {
            guard !target.isEmpty, !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace || $0.isNewline }), !target.contains("\0") else { throw HUDError("Invalid saved SSH target.") }
            // Keepalives detect a dead link in about 30 seconds instead of minutes.
            return Invocation(executable: "/usr/bin/ssh", arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", target, ["python3", "-c", script].map(shellQuote).joined(separator: " ")], mutation: false, input: input)
        }
        guard let python = python else { return nil }
        return Invocation(executable: python, arguments: ["-c", script], mutation: false, input: input)
    }
    func call(_ machine: Machine, _ args: [String], mutation: Bool = false) throws -> String {
        try execute(invocation(machine, args, mutation: mutation))
    }
    func rows(_ machine: Machine, _ group: String) throws -> [Row] {
        let raw = try call(machine, [group, "list"])
        guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? Row,
              let result = object["result"] as? Row,
              let rows = result[["agent":"agents", "workspace":"workspaces", "tab":"tabs"][group]!] as? [Row] else { throw HUDError("Herdr returned an unsupported roster format.") }
        return rows
    }
    func discover() throws -> [Machine] {
        let local = Machine(id: "local", label: Host.current().localizedName ?? "This Mac", target: nil, session: "default")
        let raw = try call(local, ["machine", "list", "--json"])
        guard let data = raw.data(using: .utf8), let saved = try JSONSerialization.jsonObject(with: data) as? [Row] else { throw HUDError("Cannot read Herdr's saved machines.") }
        var found = [local], seen = Set(["local"])
        for row in saved where row["enabled"] as? Bool == true {
            guard let id = row["id"] as? String, let target = row["target"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            found.append(Machine(id: id, label: row["label"] as? String ?? target, target: target, session: row["session"] as? String ?? "default"))
        }
        return found
    }
    static func key(_ machine: Machine, _ row: Row) -> String {
        encode([machine.id, machine.target ?? "", machine.session, row["pane_id"] ?? "", row["terminal_id"] ?? "", row["agent_session"] ?? NSNull()])
    }
    // Each machine's last result. Machines are checked concurrently, and one
    // that fails is retried on a widening interval instead of every poll, so an
    // asleep remote never delays the others.
    struct MachineResult { var agents: [Row]; var state: Row; var bindings: [String: (Machine, Row)] }
    private(set) var results: [String: MachineResult] = [:]
    private(set) var failures: [String: (count: Int, retryAt: Date)] = [:]
    static let backoff: [TimeInterval] = [15, 30, 60]
    func fetch(_ machine: Machine) -> MachineResult {
        do {
            let agents = try rows(machine, "agent"), spaces = try rows(machine, "workspace"), tabs = try rows(machine, "tab")
            var bound: [String: (Machine, Row)] = [:]
            let enriched = agents.map { original -> Row in
                var row = original
                row["id"] = Self.key(machine, row)
                row["machine_label"] = machine.label; row["machine_id"] = machine.id; row["online"] = true
                row["workspace_label"] = spaces.first(where: { ($0["workspace_id"] as? String) == (row["workspace_id"] as? String) })?["label"] ?? row["workspace_id"]
                row["tab_label"] = tabs.first(where: { ($0["tab_id"] as? String) == (row["tab_id"] as? String) })?["label"] ?? row["tab_id"]
                bound[row["id"] as! String] = (machine, original)
                return row
            }
            return MachineResult(agents: enriched, state: machine.json.merging(["online": true, "count": enriched.count], uniquingKeysWith: { _, b in b }), bindings: bound)
        } catch {
            let cached = (results[machine.id]?.agents ?? []).map { $0.merging(["online": false], uniquingKeysWith: { _, b in b }) }
            return MachineResult(agents: cached, state: machine.json.merging(["online": false, "error": error.localizedDescription], uniquingKeysWith: { _, b in b }), bindings: [:])
        }
    }
    /// `only` limits the check to those machine ids (an event named them); nil
    /// re-reads Herdr's saved machines and checks every machine that is due.
    /// `force` ignores the failure backoff (manual refresh, or an event proved
    /// the machine is reachable again).
    func snapshot(only: Set<String>? = nil, force: Bool = false) -> Row {
        if only == nil || machines.isEmpty {
            do { machines = try discover(); discoveryError = "" }
            catch { discoveryError = error.localizedDescription; if machines.isEmpty { machines = [Machine(id:"local", label:"This Mac", target:nil, session:"default")] } }
        }
        let now = Date()
        let due = machines.filter { machine in
            if let only = only, !only.contains(machine.id) { return results[machine.id] == nil }
            return force || results[machine.id] == nil || (failures[machine.id].map { $0.retryAt <= now } ?? true)
        }
        var fresh = [MachineResult?](repeating: nil, count: due.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: due.count) { index in
            let result = fetch(due[index])
            lock.lock(); fresh[index] = result; lock.unlock()
        }
        for (machine, result) in zip(due, fresh) {
            guard var result = result else { continue }
            if result.state["online"] as? Bool == true { failures[machine.id] = nil }
            else {
                let count = (failures[machine.id]?.count ?? 0) + 1, wait = Self.backoff[min(count, Self.backoff.count) - 1]
                failures[machine.id] = (count, Date().addingTimeInterval(wait))
                result.state["retryIn"] = Int(wait)
            }
            results[machine.id] = result
        }
        results = results.filter { id, _ in machines.contains(where: { $0.id == id }) }
        failures = failures.filter { id, _ in machines.contains(where: { $0.id == id }) }
        var all: [Row] = [], states: [Row] = [], nextBindings: [String: (Machine, Row)] = [:]
        for machine in machines {
            guard let result = results[machine.id] else { continue }
            all += result.agents; states.append(result.state)
            nextBindings.merge(result.bindings, uniquingKeysWith: { _, b in b })
        }
        bindings = nextBindings
        return ["agents":all, "machines":states, "discoveryError":discoveryError]
    }
    // Prompts re-read the saved machines and the agent's pane before sending,
    // so a replaced agent or changed machine is refused.
    func resolve(_ id: String) throws -> (Machine, Row) {
        guard let (machine, expected) = bindings[id] else { throw HUDError("Agent is offline or changed. Refresh and select it again.") }
        guard try discover().contains(machine) else { throw HUDError("This machine's Herdr configuration changed. Refresh before sending.") }
        guard let current = try rows(machine, "agent").first(where: { ($0["pane_id"] as? String) == (expected["pane_id"] as? String) }),
              Self.key(machine, current) == id,
              (current["workspace_id"] as? String) == (expected["workspace_id"] as? String),
              (current["agent"] as? String) == (expected["agent"] as? String) else { throw HUDError("The selected agent was replaced. Select its new session.") }
        return (machine, current)
    }
    // Reads trust the last snapshot's binding instead of listing agents again;
    // events keep that snapshot current. Prompts still re-check identity.
    func output(_ id: String) throws -> Row {
        guard let (machine, row) = bindings[id] else { throw HUDError("Agent is offline or changed. Refresh and select it again.") }
        let pane = row["pane_id"] as! String
        let text: String
        do { text = try call(machine, ["agent", "read", pane, "--source", "recent-unwrapped", "--lines", "180"]) }
        // Herdr can't scroll a blocked agent's history, so show its visible screen,
        // which holds the question it is waiting on.
        catch let error as HUDError where error.message.contains("agent_not_idle") { text = try call(machine, ["agent", "read", pane, "--source", "visible"]) }
        return ["id":id, "provider":row["agent"] ?? "", "text":text]
    }
    // Picks one numbered option in a permission prompt or question by pressing
    // its number key once. The agent is re-checked and its visible screen must
    // still show the same question and option, so a stale card never answers a
    // newer dialog. Herdr can report an open question as idle, so the screen is
    // the proof, not the status. Never retried.
    func answer(_ id: String, _ number: Int, question: String, label: String) throws -> Row {
        guard (1...9).contains(number), !label.isEmpty, label.utf8.count <= 2000, question.utf8.count <= 2000 else { throw HUDError("That option can't be picked from the HUD. Answer in Herdr.") }
        let (machine, row) = try resolve(id)
        guard (row["agent_status"] as? String) != "working", let pane = row["pane_id"] as? String else { throw HUDError("The agent moved on. Refresh and check its screen.") }
        let screen = try call(machine, ["agent", "read", pane, "--source", "visible"]).replacingOccurrences(of: "\u{00a0}", with: " ")
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " │┃❯")) }
        guard question.isEmpty || lines.contains(question), lines.contains(where: { $0.hasPrefix("\(number). \(label)") }) else { throw HUDError("This question is no longer on screen. Refresh and check the agent.") }
        do { _ = try call(machine, ["agent", "send-keys", pane, String(number)]) }
        catch { throw HUDError("Answer uncertain. Check the agent in Herdr before answering again.") }
        return ["ok":true, "id":id]
    }
    func prompt(_ id: String, _ message: String) throws -> Row {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 60000, !message.contains("\0"), !message.hasPrefix("-") else { throw HUDError("Enter a prompt under 60 KB that does not start with a dash.") }
        let (machine, row) = try resolve(id)
        guard ["idle", "done"].contains(row["agent_status"] as? String ?? "") else { throw HUDError("This agent is busy or needs input. Answer native questions in Herdr.") }
        let input=Data((encode(["session":machine.session,"agent":row,"text":message])+"\n").utf8)
        let raw: String
        do { raw = try execute(invocation(machine, ["status","server"], mutation:true, input:input)) }
        catch { throw HUDError("Delivery uncertain or refused. Inspect Herdr before sending again.") }
        guard let data = raw.data(using: .utf8), let response = try? JSONSerialization.jsonObject(with:data) as? Row, (response["result"] as? Row)?["type"] as? String == "agent_prompted", ((response["result"] as? Row)?["agent"] as? Row)?["terminal_id"] as? String == row["terminal_id"] as? String, response["error"] == nil else { throw HUDError("Delivery uncertain. Inspect Herdr before sending again.") }
        return ["ok":true, "id":id]
    }
}
