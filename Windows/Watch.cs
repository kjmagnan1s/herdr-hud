using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HerdrHUD;

// Keeps one read-only event bridge (watch.py over SSH) running for a machine
// and reports what it prints. Any exit restarts it with backoff. A link that
// stays silent past two missed heartbeats is treated as dead and restarted.
// The bridge runs in a kill-on-close job, so it never outlives the HUD.
public sealed class EventWatcher : IDisposable
{
    public enum Signal { Ready, Changed, Down }
    static readonly int[] Delays = [1, 2, 4, 8, 15, 30, 60];
    readonly Invocation invocation; readonly Action<Signal> handler; readonly TimeSpan silence;
    readonly CancellationTokenSource stop = new(); readonly Func<Invocation, IChildProcess> spawn;
    public Machine Machine { get; }
    public EventWatcher(Machine machine, Invocation invocation, Action<Signal> handler, double silenceSeconds = 50, Func<Invocation, IChildProcess>? spawn = null)
    {
        Machine = machine; this.invocation = invocation; this.handler = handler; silence = TimeSpan.FromSeconds(silenceSeconds);
        this.spawn = spawn ?? (i => new OwnedProcess(i));
    }
    public void Start() => _ = Task.Run(Run);
    async Task Run()
    {
        int attempt = 0;
        while (!stop.IsCancellationRequested)
        {
            bool healthy = false;
            try
            {
                using var child = spawn(invocation);
                // The request is the only input. Stdin then stays open: closing it
                // is how the bridge, across SSH, learns the HUD has gone.
                await child.Input.WriteAsync(invocation.Input ?? [], stop.Token); await child.Input.FlushAsync(stop.Token);
                _ = child.Error.CopyToAsync(Stream.Null);
                using var reader = new StreamReader(child.Output, Encoding.UTF8);
                while (true)
                {
                    // Pipe reads cannot be cancelled, so a silent or stopped link
                    // is ended by killing the bridge, which ends the read.
                    var read = reader.ReadLineAsync();
                    if (await Task.WhenAny(read, Task.Delay(silence, stop.Token)) != read) { child.Stop(); break; }
                    string? line = await read;
                    if (line is null) break;
                    JsonNode? value; try { value = JsonNode.Parse(line); } catch (JsonException) { continue; }
                    switch ((value as JsonObject)?.Text("type"))
                    {
                        case "ready": healthy = true; attempt = 0; handler(Signal.Ready); break;
                        case "changed": handler(Signal.Changed); break;
                    }
                }
            }
            catch (Exception) { }
            if (healthy) handler(Signal.Down);
            if (stop.IsCancellationRequested) return;
            try { await Task.Delay(TimeSpan.FromSeconds(Delays[Math.Min(attempt++, Delays.Length - 1)]), stop.Token); }
            catch (OperationCanceledException) { return; }
        }
    }
    public void Dispose() => stop.Cancel();
}
