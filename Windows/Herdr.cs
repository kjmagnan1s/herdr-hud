using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace HerdrHUD;

public record Invocation(string Executable, string[] Arguments, bool Mutation = false, byte[]? Input = null, bool LocalPrompt = false);
public record Machine(string Id, string Label, string? Target, string Session);

public static class Json
{
    public static string Text(this JsonObject row, string key) => row[key]?.GetValueKind() == System.Text.Json.JsonValueKind.String ? row[key]!.GetValue<string>() : "";
    public static bool Flag(this JsonObject row, string key) => row[key]?.GetValueKind() == System.Text.Json.JsonValueKind.True;
    public static JsonObject Copy(this JsonObject row) => (JsonObject)row.DeepClone();
}

// The host runs roster checks, reads and sends on separate lanes. No terminal is
// prompted without fresh identity, configuration, and readiness checks. A
// submitted prompt is never retried.
public sealed class HerdrClient
{
    readonly Func<Invocation, Task<string>> execute;
    readonly string binary, sourceTarget, sourceSession;
    // Each machine's last result. Machines are checked concurrently, and one that
    // fails is retried on a widening interval, so an asleep remote never delays
    // the others.
    sealed record MachineResult(List<JsonObject> Agents, JsonObject State, Dictionary<string, (Machine Machine, JsonObject Agent)> Bindings);
    readonly Dictionary<string, MachineResult> results = new();
    readonly Dictionary<string, (int Count, DateTime RetryAt)> failures = new();
    static readonly int[] Backoff = [15, 30, 60];
    Dictionary<string, (Machine Machine, JsonObject Agent)> bindings = new();
    List<Machine> machines = [];
    string discoveryError = "";
    public IReadOnlyList<Machine> Machines => machines;
    const string Script = "unset HERDR_ENV HERDR_SOCKET_PATH HERDR_CONFIG_PATH HERDR_SESSION HERDR_SESSION_NAME HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_TERMINAL_ID; if [ -x \"$HOME/.local/bin/herdr\" ]; then exec \"$HOME/.local/bin/herdr\" \"$@\"; elif [ -x /opt/homebrew/bin/herdr ]; then exec /opt/homebrew/bin/herdr \"$@\"; else exec herdr \"$@\"; fi";
    public HerdrClient(string sourceTarget = "", string sourceSession = "default", string? binary = null, Func<Invocation, Task<string>>? execute = null)
    {
        this.sourceTarget = sourceTarget.Trim(); this.sourceSession = sourceSession;
        this.binary = binary ?? FindBinary(); this.execute = execute ?? new ProcessRunner().Run;
    }
    static string FindBinary()
    {
        string candidate = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Herdr", "bin", "herdr.exe");
        return File.Exists(candidate) ? candidate : "herdr.exe";
    }
    public static string Quote(string text) => "'" + text.Replace("'", "'\"'\"'") + "'";
    public static void ValidateTarget(string target)
    {
        if (string.IsNullOrWhiteSpace(target) || target.StartsWith('-') || target.Any(c => char.IsWhiteSpace(c) || char.IsControl(c))) throw new InvalidOperationException("Invalid saved SSH target.");
    }
    static string Command(IEnumerable<string> args) => string.Join(" ", args.Select(Quote));
    // Keepalives let a long-lived event link notice a dead connection in about 30 seconds.
    static string[] SshArgs(string target, string command, bool keepAlive = false) => keepAlive
        ? ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", target, command]
        : ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", target, command];
    static string SshPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe");
    /// The read-only event bridge for one machine, or null when it cannot run:
    /// a Herdr on this PC speaks a named pipe and is polled instead.
    public Invocation? WatchInvocation(Machine machine)
    {
        if (sourceTarget.Length == 0 && machine.Target is null) return null;
        var script = Command(["python3", "-c", File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Resources", "watch.py"))]);
        var input = Encoding.UTF8.GetBytes(new JsonObject { ["session"] = machine.Session }.ToJsonString() + "\n");
        if (machine.Target is not null) ValidateTarget(machine.Target);
        if (sourceTarget.Length == 0) return new Invocation(SshPath, SshArgs(machine.Target!, script, true), false, input);
        ValidateTarget(sourceTarget);
        var remote = machine.Target is null ? script : Command(["ssh", ..SshArgs(machine.Target, script, true)]);
        return new Invocation(SshPath, SshArgs(sourceTarget, remote, true), false, input);
    }
    public Invocation Invoke(Machine machine, string[] args, bool mutation = false, byte[]? input = null)
    {
        string[] scoped = ["--session", machine.Session, ..args];
        if (scoped.Any(s => s.Contains('\0'))) throw new InvalidOperationException("Invalid command argument.");
        var posix = mutation ? Command(["python3","-c",File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"Resources","prompt.py"))]) : Command(["sh", "-c", Script, "herdr-hud", ..scoped]);
        if (machine.Target is not null) ValidateTarget(machine.Target);
        var ssh = SshPath;
        if (sourceTarget.Length > 0)
        {
            ValidateTarget(sourceTarget);
            // The source host resolves its own saved SSH aliases and credentials.
            var remote = machine.Target is null ? posix : Command(["ssh", ..SshArgs(machine.Target, posix)]);
            return new Invocation(ssh, SshArgs(sourceTarget, remote), mutation,input);
        }
        return machine.Target is null ? new Invocation(binary, scoped, mutation,input,mutation) : new Invocation(ssh, SshArgs(machine.Target, posix), mutation,input);
    }
    Task<string> Call(Machine machine, string[] args, bool mutation = false) => execute(Invoke(machine, args, mutation));
    async Task<List<JsonObject>> Rows(Machine machine, string kind)
    {
        var raw = await Call(machine, [kind, "list"]);
        var node = JsonNode.Parse(raw)?["result"]?[kind switch { "agent" => "agents", "workspace" => "workspaces", "tab" => "tabs", _ => throw new InvalidOperationException() }] as JsonArray;
        if (node is null || node.Any(n => n is not JsonObject)) throw new InvalidOperationException("Herdr returned an unsupported roster format.");
        return node.OfType<JsonObject>().ToList();
    }
    Machine Root => new("local", sourceTarget.Length == 0 ? Environment.MachineName : "Herdr source", null, sourceSession);
    async Task<List<Machine>> Discover()
    {
        var saved = JsonNode.Parse(await Call(Root, ["machine", "list", "--json"])) as JsonArray ?? throw new InvalidOperationException("Cannot read Herdr's saved machines.");
        var found = new List<Machine> { Root }; var seen = new HashSet<string> { "local" };
        foreach (var row in saved.OfType<JsonObject>().Where(r => r.Flag("enabled")))
        {
            var id = row.Text("id"); var target = row.Text("target");
            if (id.Length == 0 || target.Length == 0 || !seen.Add(id)) continue;
            found.Add(new Machine(id, row.Text("label") is { Length: > 0 } label ? label : target, target, row.Text("session") is { Length: > 0 } session ? session : "default"));
        }
        return found;
    }
    public string Key(Machine machine, JsonObject row) => new JsonArray(sourceTarget, sourceSession, machine.Id, machine.Target ?? "", machine.Session, row.Text("pane_id"), row.Text("terminal_id"), row["agent_session"]?.DeepClone()).ToJsonString();
    async Task<MachineResult> Fetch(Machine machine)
    {
        var state = new JsonObject { ["id"] = machine.Id, ["label"] = machine.Label, ["session"] = machine.Session };
        try
        {
            var agents = await Rows(machine, "agent"); var spaces = await Rows(machine, "workspace"); var tabs = await Rows(machine, "tab");
            var enriched = new List<JsonObject>(); var bound = new Dictionary<string, (Machine, JsonObject)>();
            foreach (var agent in agents)
            {
                string key = Key(machine, agent); var row = agent.Copy();
                row["id"] = key; row["machine_label"] = machine.Label; row["machine_id"] = machine.Id; row["online"] = true;
                row["workspace_label"] = spaces.FirstOrDefault(s => s.Text("workspace_id") == agent.Text("workspace_id"))?.Text("label") ?? agent.Text("workspace_id");
                row["tab_label"] = tabs.FirstOrDefault(s => s.Text("tab_id") == agent.Text("tab_id"))?.Text("label") ?? agent.Text("tab_id");
                enriched.Add(row); bound[key] = (machine, agent);
            }
            state["online"] = true; state["count"] = enriched.Count;
            return new(enriched, state, bound);
        }
        catch (Exception e)
        {
            var cached = (results.GetValueOrDefault(machine.Id)?.Agents ?? []).Select(c => { var row = c.Copy(); row["online"] = false; return row; }).ToList();
            state["online"] = false; state["error"] = e.Message;
            return new(cached, state, new());
        }
    }
    /// only limits the check to those machine ids (an event named them); null
    /// re-reads Herdr's saved machines and checks every machine that is due.
    /// force ignores the failure backoff (manual refresh, or an event proved the
    /// machine is reachable again).
    public async Task<JsonObject> Snapshot(IReadOnlySet<string>? only = null, bool force = false)
    {
        if (only is null || machines.Count == 0)
        {
            try { machines = await Discover(); discoveryError = ""; } catch (Exception e) { discoveryError = e.Message; if (machines.Count == 0) machines = [Root]; }
        }
        var now = DateTime.UtcNow;
        var due = machines.Where(m => only is not null && !only.Contains(m.Id) ? !results.ContainsKey(m.Id)
            : force || !results.ContainsKey(m.Id) || !failures.TryGetValue(m.Id, out var f) || f.RetryAt <= now).ToList();
        var fresh = await Task.WhenAll(due.Select(Fetch));
        for (int i = 0; i < due.Count; i++)
        {
            var (machine, result) = (due[i], fresh[i]);
            if (result.State.Flag("online")) failures.Remove(machine.Id);
            else
            {
                int count = failures.TryGetValue(machine.Id, out var f) ? f.Count + 1 : 1, wait = Backoff[Math.Min(count, Backoff.Length) - 1];
                failures[machine.Id] = (count, DateTime.UtcNow.AddSeconds(wait)); result.State["retryIn"] = wait;
            }
            results[machine.Id] = result;
        }
        foreach (var id in results.Keys.Where(id => !machines.Any(m => m.Id == id)).ToArray()) { results.Remove(id); failures.Remove(id); }
        var all = new JsonArray(); var states = new JsonArray(); var next = new Dictionary<string, (Machine, JsonObject)>();
        foreach (var machine in machines)
        {
            if (!results.TryGetValue(machine.Id, out var result)) continue;
            foreach (var row in result.Agents) all.Add(row.Copy());
            states.Add(result.State.Copy());
            foreach (var pair in result.Bindings) next[pair.Key] = pair.Value;
        }
        bindings = next;
        return new JsonObject { ["agents"] = all, ["machines"] = states, ["discoveryError"] = discoveryError };
    }
    // Prompts re-read the saved machines and the agent's pane before sending, so
    // a replaced agent or changed machine is refused.
    async Task<(Machine Machine, JsonObject Agent)> Resolve(string id)
    {
        if (!bindings.TryGetValue(id, out var binding)) throw new InvalidOperationException("Agent is offline or changed. Refresh and select it again.");
        if (!(await Discover()).Contains(binding.Machine)) throw new InvalidOperationException("This machine's Herdr configuration changed. Refresh before sending.");
        var current = (await Rows(binding.Machine, "agent")).FirstOrDefault(r => r.Text("pane_id") == binding.Agent.Text("pane_id"));
        if (current is null || Key(binding.Machine, current) != id || current.Text("workspace_id") != binding.Agent.Text("workspace_id") || current.Text("agent") != binding.Agent.Text("agent")) throw new InvalidOperationException("The selected agent was replaced. Select its new session.");
        return (binding.Machine, current);
    }
    // Reads trust the last snapshot's binding instead of listing agents again;
    // events keep that snapshot current. Prompts still re-check identity.
    public async Task<JsonObject> Output(string id)
    {
        if (!bindings.TryGetValue(id, out var binding)) throw new InvalidOperationException("Agent is offline or changed. Refresh and select it again.");
        var (machine, agent) = binding;
        string text;
        try { text = await Call(machine, ["agent", "read", agent.Text("pane_id"), "--source", "recent-unwrapped", "--lines", "180"]); }
        // Herdr can't scroll a blocked agent's history, so show its visible screen,
        // which holds the question it is waiting on.
        catch (InvalidOperationException error) when (error.Message.Contains("agent_not_idle")) { text = await Call(machine, ["agent", "read", agent.Text("pane_id"), "--source", "visible"]); }
        return new JsonObject { ["id"] = id, ["provider"] = agent.Text("agent"), ["text"] = text };
    }
    // Picks one numbered option in a permission prompt or question by pressing
    // its number key once. The agent is re-checked and its visible screen must
    // still show the same question and option, so a stale card never answers a
    // newer dialog. Herdr can report an open question as idle, so the screen is
    // the proof, not the status. Never retried.
    public async Task<JsonObject> Answer(string id, int number, string question, string label)
    {
        if (number is < 1 or > 9 || label.Length == 0 || Encoding.UTF8.GetByteCount(label) > 2000 || Encoding.UTF8.GetByteCount(question) > 2000) throw new InvalidOperationException("That option can't be picked from the HUD. Answer in Herdr.");
        var (machine, agent) = await Resolve(id);
        if (agent.Text("agent_status") == "working" || agent.Text("pane_id").Length == 0) throw new InvalidOperationException("The agent moved on. Refresh and check its screen.");
        var screen = (await Call(machine, ["agent", "read", agent.Text("pane_id"), "--source", "visible"])).Replace('\u00a0', ' ').Replace("\r", "");
        var lines = screen.Split('\n').Select(l => l.Trim(' ', '│', '┃', '❯')).ToList();
        if ((question.Length > 0 && !lines.Contains(question)) || !lines.Any(l => l.StartsWith($"{number}. {label}", StringComparison.Ordinal))) throw new InvalidOperationException("This question is no longer on screen. Refresh and check the agent.");
        try { await Call(machine, ["agent", "send-keys", agent.Text("pane_id"), number.ToString()]); }
        catch { throw new InvalidOperationException("Answer uncertain. Check the agent in Herdr before answering again."); }
        return new JsonObject { ["ok"] = true, ["id"] = id };
    }
    public async Task<JsonObject> Prompt(string id, string message)
    {
        if (string.IsNullOrWhiteSpace(message) || Encoding.UTF8.GetByteCount(message) > 60000 || message.Contains('\0') || message.StartsWith('-')) throw new InvalidOperationException("Enter a prompt under 60 KB that does not start with a dash.");
        var (machine, agent) = await Resolve(id);
        if (agent.Text("agent_status") is not ("idle" or "done")) throw new InvalidOperationException("This agent is busy or needs input. Answer native questions in Herdr.");
        var input=Encoding.UTF8.GetBytes(new JsonObject{["session"]=machine.Session,["agent"]=agent.DeepClone(),["text"]=message}.ToJsonString()+"\n");
        string raw;
        try { raw = await execute(Invoke(machine, ["status","server"],true,input)); }
        catch { throw new InvalidOperationException("Delivery uncertain or refused. Inspect Herdr before sending again."); }
        JsonObject? response = null; try { response = JsonNode.Parse(raw) as JsonObject; } catch (System.Text.Json.JsonException) { }
        if (response?["result"]?["type"]?.GetValue<string>() != "agent_prompted" || response?["result"]?["agent"]?["terminal_id"]?.GetValue<string>() != agent.Text("terminal_id") || response?["error"] is not null) throw new InvalidOperationException("Delivery uncertain. Inspect Herdr before sending again.");
        return new JsonObject { ["ok"] = true, ["id"] = id };
    }
}
