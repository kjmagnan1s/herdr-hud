using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace HerdrHUD;

static class Program
{
    public static readonly string Support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Herdr HUD");
    public static readonly string PipeName = "HerdrHUD-" + WindowsIdentity.GetCurrent().User!.Value;
    [STAThread] static int Main(string[] args)
    {
        Directory.CreateDirectory(Support);
        if (args.Length > 0)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
                pipe.Connect(3000);
                pipe.Write(System.Text.Encoding.UTF8.GetBytes(args[0].TrimStart('-') + "\n"));
                using var reader = new StreamReader(pipe, leaveOpen: true);
                string result = reader.ReadToEnd();
                File.WriteAllText(Path.Combine(Support, "last-control.json"), result);
                return result.Contains("\"error\"") ? 1 : 0;
            }
            catch (Exception e) { File.WriteAllText(Path.Combine(Support, "control-error.txt"), e.Message); return 1; }
        }
        using var mutex = new Mutex(true, "Local\\" + PipeName, out bool first);
        if (!first) return 0;
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => File.WriteAllText(Path.Combine(Support, "error.txt"), e.Exception.ToString());
        Application.Run(new HUDContext());
        return 0;
    }
}

sealed class Preferences
{
    public string SourceTarget { get; set; } = "";
    public string SourceSession { get; set; } = "default";
    public string SelectedAgent { get; set; } = "";
    public string Mode { get; set; } = "chat";
    public double RosterWidth { get; set; } = 220;
    public bool Visible { get; set; } = true;
    public bool AgentStrip { get; set; }
    public int ShortcutMode { get; set; }
    public int X { get; set; } = 32;
    public int Y { get; set; } = 180;
    public string Screen { get; set; } = "";
    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(Program.Support, "preferences.json"))) ?? new(); } catch { return new(); }
    }
    public void Save()
    {
        var path = Path.Combine(Program.Support, "preferences.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(this)); File.Move(path + ".tmp", path, true);
    }
}

static class Native
{
    public delegate void WinEvent(IntPtr hook, uint eventType, IntPtr hwnd, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [StructLayout(LayoutKind.Sequential)] struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] struct InputData { [FieldOffset(0)] public MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public InputData Data; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, Input[] inputs, int size);
    public static bool ClickOwn(Form form, Point point)
    {
        if (GetAncestor(WindowFromPoint(point),2) != form.Handle) return false;
        SetCursorPos(point.X,point.Y);
        Input[] inputs = [new() { Data = new() { Mouse = new() { Flags = 2 } } }, new() { Data = new() { Mouse = new() { Flags = 4 } } }];
        return SendInput(2,inputs,Marshal.SizeOf<Input>())==2;
    }
    public static void Raise(Form form) { if (form.Visible) SetWindowPos(form.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x13); }
}

sealed class Bubble : Form
{
    public Action? Toggle, MoveEnded;
    public Action<int>? Hotkey;
    // The badge counts only the most urgent state and takes its color: red needs
    // input, blue unread. An amber arc turns around the ring while agents work.
    public int Count; public string Tone = ""; public bool Working;
    float spin; readonly System.Windows.Forms.Timer spinner = new() { Interval = 50 };
    public static readonly Color Red = Color.FromArgb(255,107,114), Blue = Color.FromArgb(94,169,255), Amber = Color.FromArgb(245,181,68);
    // Claude's terracotta, matching the panel's accent.
    public static readonly Color Accent = Color.FromArgb(232,135,95), AccentHi = Color.FromArgb(245,169,134), BadgeRed = Color.FromArgb(255,77,87), BadgeBlue = Color.FromArgb(61,139,255);
    public Rectangle BadgeBounds
    {
        get { float scale = ClientSize.Width / 64f; return new Rectangle((int)Math.Round(41*scale), (int)Math.Round(3*scale), (int)Math.Round(20*scale), (int)Math.Round(20*scale)); }
    }
    public void SetBadge(int value, string tone, bool working)
    {
        value = Math.Max(0,value);
        if (value == Count && tone == Tone && working == Working) return;
        Count = value; Tone = tone; Working = working;
        // Only animate while something works; respect "show animations" being off.
        spinner.Enabled = working && SystemInformation.UIEffectsEnabled;
        UpdateShape(); Invalidate();
    }
    public static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath(); float d = radius*2;
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right-d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90); path.AddArc(r.X, r.Bottom-d, d, d, 90, 90);
        path.CloseFigure(); return path;
    }
    void UpdateShape()
    {
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
        // Winding fill unions the rounded tile and the badge instead of cutting a hole.
        float scale = ClientSize.Width / 64f;
        using var path = Rounded(new RectangleF(1*scale, 1*scale, 62*scale, 62*scale), 21*scale); path.FillMode = FillMode.Winding;
        if (Count > 0) path.AddEllipse(BadgeBounds);
        var old = Region; Region = new Region(path); old?.Dispose();
    }
    Point down, origin; bool dragging, pressed;
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
    public Bubble()
    {
        Text = "Herdr HUD H Button"; AccessibleName = "Herdr HUD. Click to open agents; drag to move.";
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        Size = new Size(64, 64); BackColor = Color.FromArgb(16, 18, 22); DoubleBuffered = true;
        Cursor = Cursors.Hand;
        spinner.Tick += (_, _) => { spin = (spin + 7.5f) % 360; Invalidate(); };
    }
    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e); UpdateShape();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = ClientSize.Width / 64f;
        // An app tile in Claude's terracotta, like the panel's brand mark, inside
        // a thin accent ring that turns red with a glow while an agent needs input.
        var tile = new RectangleF(7*scale, 7*scale, 50*scale, 50*scale);
        using (var shape = Rounded(tile, 14*scale))
        using (var fill = new LinearGradientBrush(tile, Color.FromArgb(242,153,112), Color.FromArgb(201,94,58), LinearGradientMode.Vertical)) g.FillPath(fill, shape);
        var outline = new RectangleF(4.25f*scale, 4.25f*scale, 55.5f*scale, 55.5f*scale);
        using var ring = Rounded(outline, 16.75f*scale);
        if (Tone == "blocked")
        {
            for (int i = 3; i >= 1; i--) { using var glow = new Pen(Color.FromArgb(40, Red), (2+i*2)*scale); g.DrawPath(glow, ring); }
            using var red = new Pen(Red, 2*scale); g.DrawPath(red, ring);
        }
        else { using var pen = new Pen(Color.FromArgb(140, AccentHi), 1.5f*scale); g.DrawPath(pen, ring); }
        if (Working)
        {
            // A short amber dash runs around the outline; the offset walks it along.
            using var dash = new Pen(Amber, 2.5f*scale) { DashCap = DashCap.Round, DashPattern = new[] { 13f, 65f }, DashOffset = spin / 360f * 78f };
            g.DrawPath(dash, ring);
        }
        using var font = new Font("Segoe UI Black", Height * .36f, FontStyle.Regular, GraphicsUnit.Pixel);
        TextRenderer.DrawText(g, "H", font, ClientRectangle, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        if (Count > 0)
        {
            var rect = BadgeBounds; bool red = Tone == "blocked";
            using var fill = new SolidBrush(red ? BadgeRed : BadgeBlue); g.FillEllipse(fill, rect);
            using var border = new Pen(BackColor, 2*scale); g.DrawEllipse(border, rect);
            using var badgeFont = new Font("Segoe UI", 10*scale, FontStyle.Bold, GraphicsUnit.Pixel);
            TextRenderer.DrawText(g, Math.Min(Count, 9).ToString(), badgeFont, rect, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button != MouseButtons.Left) return; pressed = true; dragging = false; down = Cursor.Position; origin = Location; Capture = true; }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e); if (!pressed) return; var delta = new Size(Cursor.Position.X - down.X, Cursor.Position.Y - down.Y);
        if (Math.Abs(delta.Width) + Math.Abs(delta.Height) > 4) dragging = true;
        if (dragging) Location = origin + delta;
    }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); if (!pressed) return; pressed = false; Capture = false; if (dragging) MoveEnded?.Invoke(); else Toggle?.Invoke(); }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; } // Click without stealing the game's focus.
        if (m.Msg == 0x312) { Hotkey?.Invoke(m.WParam.ToInt32()); return; }
        base.WndProc(ref m);
    }
}

// Off by default. Like a voice overlay's member row: one tile per agent beside
// the H while the panel is closed, so state reads at a glance during play.
sealed class AgentStrip : Form
{
    public Action<string>? Pick;
    public List<JsonObject> Agents = new(); public string Label = "";
    readonly List<(string id, RectangleF rect)> tiles = new();
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
    public AgentStrip()
    {
        Text = "Herdr HUD Agent Strip"; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.None; BackColor = Color.FromArgb(17,19,24); DoubleBuffered = true; Cursor = Cursors.Hand;
    }
    float Dpi => DeviceDpi / 96f;
    Font LabelFont() => new("Segoe UI Semibold", 12.5f*Dpi, FontStyle.Regular, GraphicsUnit.Pixel);
    static Font NameFont(float dpi) => new("Segoe UI Semibold", 13f*dpi, FontStyle.Regular, GraphicsUnit.Pixel);
    // Agents that need you or are working carry their name; ready ones stay a tile.
    static string? Name(JsonObject agent)
    {
        if (agent.Text("state") is not ("blocked" or "working" or "unread")) return null;
        var text = agent.Text("name"); return text.Length > 18 ? text[..17] + "…" : text;
    }
    static int Rank(string state) => state switch { "blocked" => 0, "unread" => 1, "working" => 2, _ => 3 };
    // Left to right: the "needs you" label, then tiles with a hairline between state groups.
    (float width, List<float> tiles, List<float> separators) Layout()
    {
        float s = Dpi, x = 10*s; var xs = new List<float>(); var seps = new List<float>(); int last = -1;
        if (Label.Length > 0) { using var font = LabelFont(); x += TextRenderer.MeasureText(Label, font).Width + 8*s; }
        foreach (var agent in Agents)
        {
            int rank = Rank(agent.Text("state"));
            if (last >= 0 && rank != last) { seps.Add(x); x += 9*s; }
            xs.Add(x); x += 36*s; last = rank;
            if (Name(agent) is string name) { using var font = NameFont(s); x += TextRenderer.MeasureText(name, font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Width + 11*s; }
        }
        return (x + 2*s, xs, seps);
    }
    public Size Measure() => new((int)Math.Ceiling(Layout().width), (int)Math.Round(44*Dpi));
    static Color Hsl(double h, double s, double l)
    {
        h = ((h % 360) + 360) % 360; double c = (1-Math.Abs(2*l-1))*s, x = c*(1-Math.Abs(h/60%2-1)), m = l-c/2;
        var (r, g, b) = h < 60 ? (c,x,0d) : h < 120 ? (x,c,0d) : h < 180 ? (0d,c,x) : h < 240 ? (0d,x,c) : h < 300 ? (x,0d,c) : (c,0d,x);
        return Color.FromArgb((int)Math.Round((r+m)*255), (int)Math.Round((g+m)*255), (int)Math.Round((b+m)*255));
    }
    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e); if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
        using var path = Bubble.Rounded(new RectangleF(0, 0, ClientSize.Width, ClientSize.Height), 14*Dpi); var old = Region; Region = new Region(path); old?.Dispose();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; float s = Dpi, mid = ClientSize.Height/2f;
        using (var edge = Bubble.Rounded(new RectangleF(0.5f, 0.5f, ClientSize.Width-1, ClientSize.Height-1), 14*s)) using (var pen = new Pen(Color.FromArgb(26,255,255,255))) g.DrawPath(pen, edge);
        var plan = Layout();
        if (Label.Length > 0) { using var font = LabelFont(); TextRenderer.DrawText(g, Label, font, new Rectangle((int)(10*s), 0, (int)(plan.tiles.FirstOrDefault(ClientSize.Width)-10*s), ClientSize.Height), Color.FromArgb(255,179,183), TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.Left); }
        using (var line = new SolidBrush(Color.FromArgb(31,255,255,255))) foreach (var x in plan.separators) g.FillRectangle(line, x, mid-11*s, 1*s, 22*s);
        tiles.Clear();
        using var initials = new Font("Segoe UI Black", 10.5f*s, FontStyle.Regular, GraphicsUnit.Pixel);
        for (int i = 0; i < Agents.Count && i < plan.tiles.Count; i++)
        {
            var agent = Agents[i]; string state = agent.Text("state"); double hue = agent["hue"]?.GetValue<double>() ?? 0;
            var rect = new RectangleF(plan.tiles[i], mid-14*s, 28*s, 28*s); var hit = rect;
            if (Name(agent) is string name)
            {
                using var font = NameFont(s); var size = TextRenderer.MeasureText(name, font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
                TextRenderer.DrawText(g, name, font, new Point((int)(rect.Right+7*s), (int)(mid-size.Height/2f)), Color.FromArgb(238,240,243), TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
                hit.Width += size.Width + 7*s;
            }
            tiles.Add((agent.Text("id"), hit));
            Color? ring = state switch { "blocked" => Bubble.Red, "working" => Color.FromArgb(217, Bubble.Amber), "unread" => Bubble.Blue, _ => null };
            if (ring is Color tone) { using var outer = Bubble.Rounded(RectangleF.Inflate(rect, 2.75f*s, 2.75f*s), 10*s); using var pen = new Pen(tone, 1.5f*s); g.DrawPath(pen, outer); }
            int alpha = state is "idle" or "done" or "offline" ? 209 : 255;
            Color top = state == "offline" ? Color.FromArgb(115,115,115) : Hsl(hue, .60, .56), bottom = state == "offline" ? Color.FromArgb(64,64,64) : Hsl(hue+24, .54, .36);
            using (var shape = Bubble.Rounded(rect, 8*s))
            using (var fill = new LinearGradientBrush(rect, Color.FromArgb(alpha, top), Color.FromArgb(alpha, bottom), 70f))
            using (var pen = new Pen(Color.FromArgb(alpha*16/100, 255,255,255))) { g.FillPath(fill, shape); g.DrawPath(pen, shape); }
            TextRenderer.DrawText(g, agent.Text("initials"), initials, Rectangle.Round(rect), Color.FromArgb(alpha, 255,255,255), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
        AccessibleName = (Label.Length > 0 ? Label + ". " : "") + "Agents: " + string.Join(", ", Agents.Select(a => a.Text("name") + " " + a.Text("state"))) + ". Click one to open it.";
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e); if (e.Button != MouseButtons.Left) return;
        string id = tiles.FirstOrDefault(t => RectangleF.Inflate(t.rect, 4*Dpi, 8*Dpi).Contains(e.Location)).id ?? tiles.FirstOrDefault().id ?? "";
        Pick?.Invoke(id);
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; } // Click without stealing the game's focus.
        base.WndProc(ref m);
    }
}

sealed class AgentPanel : Form
{
    public bool AllowQuit;
    public Action? CloseRequested;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x80; return p; } }
    public AgentPanel()
    {
        Text = "Herdr HUD Agents"; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        Size = new Size(960, 740); MinimumSize = new Size(640, 430); BackColor = Color.FromArgb(16, 18, 22); Padding = new Padding(5);
    }
    protected override void OnFormClosing(FormClosingEventArgs e) { if (!AllowQuit && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; CloseRequested?.Invoke(); } base.OnFormClosing(e); }
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg != 0x84) return;
        var point = PointToClient(new Point(unchecked((short)(long)m.LParam), unchecked((short)((long)m.LParam >> 16))));
        int edge = 6;
        if (point.X >= ClientSize.Width-edge && point.Y >= ClientSize.Height-edge) m.Result = new IntPtr(17);
        else if (point.X >= ClientSize.Width-edge) m.Result = new IntPtr(11);
        else if (point.Y >= ClientSize.Height-edge) m.Result = new IntPtr(15);
    }
}

sealed class SilentToast : Form
{
    public SilentToast() { StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.None; }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
}

sealed class HUDContext : ApplicationContext
{
    readonly Preferences prefs = Preferences.Load();
    readonly Bubble bubble = new(); readonly AgentPanel panel = new(); readonly WebView2 web = new(); readonly AgentStrip strip = new();
    // Roster checks, output reads and sends each get their own lane, so a slow or
    // offline machine never delays opening an agent or a send.
    readonly NotifyIcon tray = new(); readonly SemaphoreSlim transport = new(1), reads = new(1), sends = new(1);
    readonly System.Windows.Forms.Timer timer = new() { Interval = 3000 };
    // One event bridge per machine. A machine whose bridge is live refreshes on
    // its events; the others are polled. Everything is reconciled every 30 s.
    readonly Dictionary<string, EventWatcher> watchers = new(); readonly HashSet<string> live = new(), eventMachines = new(), queuedMachines = new();
    bool queuedAll, queuedForce; DateTime lastFull = DateTime.MinValue; string lastEmitted = "";
    readonly HashSet<string> promptIDs = new();
    readonly CancellationTokenSource lifetime = new();
    HerdrClient client; JsonObject snapshot = new();
    bool ready, polling, quitting; IntPtr previousForeground;
    SilentToast? toast; System.Windows.Forms.Timer? toastTimer;
    string hotkeyWarning = "";
    Native.WinEvent? foregroundCallback; IntPtr foregroundHook;
    public HUDContext()
    {
        client = new HerdrClient(prefs.SourceTarget, prefs.SourceSession);
        _ = bubble.Handle;
        bubble.Toggle = TogglePanel; bubble.MoveEnded = SavePosition; bubble.Hotkey = id => { if (id == 1) TogglePanel(); else ToggleVisibility(); };
        panel.CloseRequested = ClosePanel;
        web.Dock = DockStyle.Fill; web.DefaultBackgroundColor = Color.FromArgb(19, 22, 29); panel.Controls.Add(web);
        _ = panel.Handle;
        // Sizes are design units; WebView2 renders CSS using the monitor DPI.
        float scale = panel.DeviceDpi / 96f;
        panel.MinimumSize = new Size((int)(640*scale), (int)(430*scale));
        panel.Size = new Size((int)(960*scale), (int)(740*scale));
        bubble.Size = new Size((int)(64*scale), (int)(64*scale));
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap)) { g.Clear(Color.FromArgb(24,27,34)); using var font = new Font("Segoe UI", 23, FontStyle.Bold, GraphicsUnit.Pixel); g.DrawString("H", font, Brushes.Goldenrod, 2, 0); }
        var handle = bitmap.GetHicon(); using var original = Icon.FromHandle(handle); tray.Icon = (Icon)original.Clone(); Native.DestroyIcon(handle);
        tray.Text = "Herdr HUD"; tray.Visible = true; tray.DoubleClick += (_, _) => TogglePanel();
        bubble.LocationChanged += (_, _) => { PositionToast(); PositionStrip(); };
        strip.Pick = id => { OpenPanel(); if (id.Length > 0) Emit("select", new() { ["id"] = id }); };
        BuildMenu(); RestorePosition(); RegisterHotkeys();
        foregroundCallback = (_, _, _, _, _, _, _) => { if (!quitting && prefs.Visible) bubble.BeginInvoke(() => { Native.Raise(panel); Native.Raise(strip); if (toast is not null) Native.Raise(toast); Native.Raise(bubble); }); };
        foregroundHook = Native.SetWinEventHook(3,3,IntPtr.Zero,foregroundCallback,0,0,0);
        if (prefs.Visible) bubble.Show();
        timer.Tick += async (_, _) => await Tick(); timer.Start();
        SystemEvents.DisplaySettingsChanged += DisplaysChanged;
        _ = Listen(); _ = InitializeWeb();
    }
    async Task InitializeWeb()
    {
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Program.Support, "WebView2"));
            await web.EnsureCoreWebView2Async(environment);
            var core = web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false; core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreHostObjectsAllowed = false; core.Settings.IsStatusBarEnabled = false; core.Settings.IsZoomControlEnabled = false;
            core.SetVirtualHostNameToFolderMapping("hud.local", Path.Combine(AppContext.BaseDirectory, "Resources"), CoreWebView2HostResourceAccessKind.DenyCors);
            core.NavigationStarting += (_, e) => { if (e.Uri != "https://hud.local/index.html") e.Cancel = true; };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, e) => e.Cancel = true;
            core.WebMessageReceived += async (_, e) =>
            {
                if (e.Source != "https://hud.local/index.html" || e.WebMessageAsJson.Length > 100000) return;
                try { if (JsonNode.Parse(e.WebMessageAsJson) is JsonObject data) await Message(data); }
                catch (Exception error) { Emit("notice", new() { ["message"] = error.Message }); }
            };
            web.KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) { e.Handled = true; e.SuppressKeyPress = true; panel.BeginInvoke(ClosePanel); } };
            core.Navigate("https://hud.local/index.html");
        }
        catch (Exception e) { File.WriteAllText(Path.Combine(Program.Support, "startup-error.txt"), e.ToString()); tray.ShowBalloonTip(8000, "Herdr HUD could not start", "Check that Microsoft Edge WebView2 Runtime is installed. " + e.Message, ToolTipIcon.Error); }
    }
    void Emit(string type, JsonObject data) { if (ready && !quitting) web.CoreWebView2.PostWebMessageAsJson(new JsonObject { ["type"] = type, ["data"] = data.DeepClone() }.ToJsonString()); }
    static async Task<T> Serialized<T>(SemaphoreSlim lane, Func<Task<T>> action) { await lane.WaitAsync(); try { return await action(); } finally { lane.Release(); } }
    // Manual refresh: every machine, ignoring the offline backoff.
    Task Refresh() => Check(null, true);
    async Task Tick()
    {
        if (!prefs.Visible || quitting) return;
        if (client.Machines.Count == 0 || DateTime.UtcNow - lastFull >= TimeSpan.FromSeconds(30)) { await Check(null, false); return; }
        var polled = client.Machines.Select(m => m.Id).Where(id => !live.Contains(id)).ToHashSet();
        if (polled.Count > 0) await Check(polled, false);
    }
    // Checks the named machines (null: rediscover and check all). Requests that
    // arrive during a check are merged and run right after it.
    async Task Check(IReadOnlySet<string>? only, bool force)
    {
        if (!prefs.Visible || quitting) return;
        if (polling) { if (only is null) queuedAll = true; else queuedMachines.UnionWith(only); queuedForce |= force; return; }
        polling = true; if (only is null) lastFull = DateTime.UtcNow; var current = client;
        try { var data = await Serialized(transport, () => current.Snapshot(only, force)); if (current == client) { Publish(data); ReconcileWatchers(); } }
        finally { polling = false; }
        if (queuedAll || queuedMachines.Count > 0)
        {
            IReadOnlySet<string>? next = queuedAll ? null : queuedMachines.ToHashSet(); bool nextForce = queuedForce;
            queuedAll = false; queuedMachines.Clear(); queuedForce = false; await Check(next, nextForce);
        }
    }
    // The page only hears about the roster when it changed, so the list is not
    // rebuilt (and hover or focus does not flicker) every poll.
    void Publish(JsonObject data)
    {
        snapshot = data; string text = data.ToJsonString();
        if (prefs.Visible && ready && text != lastEmitted) { lastEmitted = text; Emit("roster", data); }
        Diagnostics();
    }
    void ReconcileWatchers()
    {
        foreach (var (id, watcher) in watchers.ToArray()) if (!client.Machines.Contains(watcher.Machine)) { watcher.Dispose(); watchers.Remove(id); live.Remove(id); }
        foreach (var machine in client.Machines)
        {
            if (watchers.ContainsKey(machine.Id)) continue;
            Invocation? invocation; try { invocation = client.WatchInvocation(machine); } catch { continue; }
            if (invocation is null) continue;
            var watcher = new EventWatcher(machine, invocation, signal => { if (!quitting) bubble.BeginInvoke(() => WatcherSignal(machine.Id, signal)); });
            watchers[machine.Id] = watcher; watcher.Start();
        }
    }
    void StopWatchers() { foreach (var watcher in watchers.Values) watcher.Dispose(); watchers.Clear(); live.Clear(); }
    void WatcherSignal(string id, EventWatcher.Signal signal)
    {
        if (!watchers.ContainsKey(id)) return;
        switch (signal)
        {
            case EventWatcher.Signal.Down: live.Remove(id); break;
            case EventWatcher.Signal.Ready: live.Add(id); _ = Check(new HashSet<string> { id }, true); break;
            case EventWatcher.Signal.Changed:
                // Events arrive in bursts (a new tab is three of them); gather them briefly.
                if (eventMachines.Count == 0) _ = Task.Delay(150).ContinueWith(_ => bubble.BeginInvoke(async () => { var ids = eventMachines.ToHashSet(); eventMachines.Clear(); await Check(ids, true); }));
                eventMachines.Add(id); break;
        }
    }
    async Task Message(JsonObject data)
    {
        string op = data.Text("op"), requestID = data.Text("requestID"), id = data.Text("id");
        switch (op)
        {
            case "ready": ready = true; lastEmitted = ""; Emit("preferences", new() { ["selectedAgent"] = prefs.SelectedAgent, ["rosterWidth"] = prefs.RosterWidth, ["mode"] = prefs.Mode }); Emit("visibility", new() { ["open"] = panel.Visible }); if (snapshot.Count > 0) Publish(snapshot); await Refresh(); if (hotkeyWarning.Length > 0) Emit("notice", new() { ["message"] = hotkeyWarning }); break;
            case "close": ClosePanel(); break;
            case "hide": if (prefs.Visible) ToggleVisibility(); break;
            case "refresh": await Refresh(); break;
            case "preferences":
                if (data["selectedAgent"] is JsonValue && data.Text("selectedAgent").Length <= 8192) prefs.SelectedAgent = data.Text("selectedAgent");
                if (data["rosterWidth"] is JsonValue value && value.TryGetValue<double>(out var width) && width is >=56 and <=600) prefs.RosterWidth = width;
                if (data.Text("mode") is "chat" or "terminal") prefs.Mode = data.Text("mode"); prefs.Save(); break;
            case "strip":
                strip.Agents = (data["agents"] as JsonArray ?? new()).OfType<JsonObject>().Take(8).Select(a => (JsonObject)a.DeepClone()).ToList();
                strip.Label = data.Text("label"); if (strip.Label.Length > 40) strip.Label = strip.Label[..40]; UpdateStrip(); break;
            case "badge": bubble.SetBadge(data["count"]?.GetValue<int>() ?? 0, data.Text("tone"), (data["working"]?.GetValue<int>() ?? 0) > 0); break;
            case "alertPreview":
                if (panel.Visible || !prefs.Visible) break;
                JsonObject output; try { output = await Serialized(reads, () => client.Output(id)); } catch { output = new() { ["id"] = id, ["text"] = "", ["provider"] = "" }; }
                output["title"] = data.Text("title"); output["tone"] = data.Text("tone"); Emit("alertPreview", output); break;
            case "alert": if (!panel.Visible && prefs.Visible) ShowToast(data); break;
            case "alertClear": HideToast(); break;
            case "output": case "prompt":
                if (id.Length == 0 || requestID.Length == 0 || requestID.Length > 100 || !panel.Visible) break;
                if (op == "prompt" && !promptIDs.Add(requestID)) break;
                var current = client; JsonObject result;
                try { result = await Serialized(op == "output" ? reads : sends, () => current != client ? throw new InvalidOperationException("Herdr source changed. Refresh and select an agent.") : op == "output" ? current.Output(id) : current.Prompt(id, data.Text("message"))); }
                catch (Exception e) { result = new() { ["id"] = id, ["error"] = e.Message }; }
                result["requestID"] = requestID; Emit(op, result); break;
            case "answer":
                if (id.Length == 0 || requestID.Length == 0 || requestID.Length > 100 || !panel.Visible || !promptIDs.Add(requestID)) break;
                if (data["n"] is not JsonValue n || !n.TryGetValue<int>(out var number)) number = 0;
                var answerClient = client; JsonObject answer;
                try { answer = await Serialized(sends, () => answerClient != client ? throw new InvalidOperationException("Herdr source changed. Refresh and select an agent.") : answerClient.Answer(id, number, data.Text("question"), data.Text("label"))); }
                catch (Exception e) { answer = new() { ["id"] = id, ["error"] = e.Message }; }
                answer["requestID"] = requestID; Emit("answer", answer); break;
        }
    }
    void BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open / close agents", null, (_, _) => TogglePanel());
        menu.Items.Add("Show / hide HUD", null, (_, _) => ToggleVisibility());
        var stripItem = new ToolStripMenuItem("Show agent strip beside H") { Checked = prefs.AgentStrip };
        stripItem.Click += (_, _) => { prefs.AgentStrip = !prefs.AgentStrip; prefs.Save(); UpdateStrip(); BuildMenu(); };
        menu.Items.Add(stripItem);
        menu.Items.Add("Refresh", null, async (_, _) => await Refresh());
        menu.Items.Add("Herdr connection…", null, (_, _) => Connection());
        var shortcuts = new ToolStripMenuItem("Shortcuts");
        string[] names = ["Ctrl+Alt+H / Ctrl+Alt+Shift+H", "Ctrl+Win+H / Ctrl+Win+Shift+H", "Off"];
        for (int i = 0; i < names.Length; i++) { int mode = i; var item = new ToolStripMenuItem(names[i]) { Checked = prefs.ShortcutMode == i }; item.Click += (_, _) => { prefs.ShortcutMode = mode; prefs.Save(); RegisterHotkeys(); BuildMenu(); }; shortcuts.DropDownItems.Add(item); }
        menu.Items.Add(shortcuts);
        using var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        var login = new ToolStripMenuItem("Launch at login") { Checked = run?.GetValue("HerdrHUD") is not null };
        login.Click += (_, _) => { using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (login.Checked) key.DeleteValue("HerdrHUD", false); else key.SetValue("HerdrHUD", "\""+Environment.ProcessPath+"\""); BuildMenu(); };
        menu.Items.Add(login); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("About Herdr HUD", null, (_, _) => { OpenPanel(); Emit("notice", new() { ["message"] = "Herdr HUD · Windows alpha 0.1.0 · MIT · Community project. Fullscreen game compatibility is still being tested." }); });
        menu.Items.Add("Quit", null, (_, _) => Quit());
        var old = tray.ContextMenuStrip; tray.ContextMenuStrip = menu; bubble.ContextMenuStrip = menu; old?.Dispose();
    }
    void RegisterHotkeys()
    {
        Native.UnregisterHotKey(bubble.Handle, 1); Native.UnregisterHotKey(bubble.Handle, 2); hotkeyWarning = "";
        if (prefs.ShortcutMode == 2) return;
        uint modifiers = 0x4000u | 0x2u | (prefs.ShortcutMode == 1 ? 0x8u : 0x1u);
        bool panelKey = Native.RegisterHotKey(bubble.Handle, 1, modifiers, 0x48), visibilityKey = Native.RegisterHotKey(bubble.Handle, 2, modifiers | 0x4u, 0x48);
        if (!panelKey || !visibilityKey) { hotkeyWarning = "A HUD shortcut is already in use. Choose another preset from the H tray menu."; Emit("notice", new() { ["message"] = hotkeyWarning }); }
    }
    void TogglePanel() { if (panel.Visible) ClosePanel(); else OpenPanel(); }
    void OpenPanel()
    {
        if (!panel.Visible) previousForeground = Native.GetForegroundWindow();
        prefs.Visible = true; prefs.Save(); bubble.Show(); PositionPanel(); HideToast(); strip.Hide();
        panel.Show(); panel.Activate(); web.Focus(); Native.Raise(bubble); Emit("visibility", new() { ["open"] = true }); _ = Refresh(); Diagnostics();
    }
    void ClosePanel()
    {
        bool restore = Native.GetAncestor(Native.GetForegroundWindow(), 2) == panel.Handle;
        panel.Hide(); UpdateStrip(); Emit("visibility", new() { ["open"] = false });
        if (restore && Native.IsWindow(previousForeground)) Native.SetForegroundWindow(previousForeground);
        Diagnostics();
    }
    void ToggleVisibility()
    {
        prefs.Visible = !prefs.Visible; prefs.Save();
        if (prefs.Visible) { bubble.Show(); _ = Refresh(); } else { ClosePanel(); bubble.Hide(); HideToast(); lastEmitted = ""; Emit("resetBaseline", new()); }
        UpdateStrip(); Diagnostics();
    }
    void RestorePosition()
    {
        var screen = Screen.AllScreens.FirstOrDefault(s => s.DeviceName == prefs.Screen) ?? Screen.PrimaryScreen!;
        bubble.Location = new Point(screen.WorkingArea.Left+prefs.X, screen.WorkingArea.Top+prefs.Y); ClampBubble();
    }
    void ClampBubble()
    {
        var r = Screen.FromRectangle(bubble.Bounds).WorkingArea;
        bubble.Location = new Point(Math.Clamp(bubble.Left, r.Left, Math.Max(r.Left, r.Right-bubble.Width)), Math.Clamp(bubble.Top, r.Top, Math.Max(r.Top, r.Bottom-bubble.Height)));
    }
    void SavePosition()
    {
        ClampBubble(); var screen = Screen.FromControl(bubble); prefs.Screen = screen.DeviceName;
        prefs.X = bubble.Left-screen.WorkingArea.Left; prefs.Y = bubble.Top-screen.WorkingArea.Top; prefs.Save(); PositionPanel(); Diagnostics();
    }
    void PositionPanel()
    {
        var r = Screen.FromControl(bubble).WorkingArea;
        panel.Size = new Size(Math.Min(panel.Width, r.Width-16), Math.Min(panel.Height, r.Height-16));
        int x = bubble.Right+12; if (x+panel.Width > r.Right) x = bubble.Left-panel.Width-12;
        panel.Location = new Point(Math.Clamp(x, r.Left+8, Math.Max(r.Left+8, r.Right-panel.Width-8)), Math.Clamp(bubble.Top, r.Top+8, Math.Max(r.Top+8, r.Bottom-panel.Height-8)));
    }
    void DisplaysChanged(object? sender, EventArgs e) { if (!quitting) bubble.BeginInvoke(() => { RestorePosition(); PositionPanel(); PositionToast(); PositionStrip(); }); }
    void UpdateStrip()
    {
        if (!prefs.AgentStrip || !prefs.Visible || panel.Visible || strip.Agents.Count == 0) { strip.Hide(); return; }
        strip.Size = strip.Measure(); PositionStrip(); strip.Invalidate();
        if (!strip.Visible) { strip.Show(); Native.Raise(strip); Native.Raise(bubble); }
    }
    // Beside the H on the side facing the screen's center, vertically centered on it.
    void PositionStrip()
    {
        if (!strip.Visible && strip.Agents.Count == 0) return;
        var area = Screen.FromRectangle(bubble.Bounds).WorkingArea; int gap = (int)Math.Round(8*bubble.DeviceDpi/96f);
        int x = bubble.Left + bubble.Width/2 > area.Left + area.Width/2 ? bubble.Left-gap-strip.Width : bubble.Right+gap;
        int y = bubble.Top + (bubble.Height-strip.Height)/2;
        strip.Location = new Point(Math.Clamp(x,area.Left,Math.Max(area.Left,area.Right-strip.Width)), Math.Clamp(y,area.Top,Math.Max(area.Top,area.Bottom-strip.Height)));
    }
    // One toast at a time. A newer alert updates it in place instead of replacing
    // it; "update" only refreshes a toast that is already showing. Needs-input
    // toasts stay until opened or dismissed; others fade after 6 s unless hovered.
    Label? toastText; Panel? toastStripe; string toastAgent = ""; bool toastSticky;
    void ShowToast(JsonObject data)
    {
        if (toast is null && data["update"]?.GetValueKind() == JsonValueKind.True) return;
        float scale = bubble.DeviceDpi / 96f;
        int Px(int value) => (int)Math.Round(value*scale);
        if (toast is null)
        {
            toast = new SilentToast { Text = "Herdr HUD Agent Update", FormBorderStyle = FormBorderStyle.None, ShowInTaskbar = false, TopMost = true, BackColor = Color.FromArgb(17,19,24), Size = new Size(Px(380), Px(124)) };
            toastStripe = new Panel { Dock = DockStyle.Left, Width = Px(4) };
            toastText = new Label { ForeColor = Color.FromArgb(220,223,228), Padding = new Padding(Px(12),Px(12),Px(38),Px(12)), Dock = DockStyle.Fill, Cursor = Cursors.Hand, UseMnemonic = false };
            toastText.Paint += PaintToastTitle;
            toastText.Click += (_, _) => { string id = toastAgent; OpenPanel(); Emit("select", new() { ["id"] = id }); };
            var close = new Button { Text = "×", Width = Px(28), Height = Px(28), Left = toast.ClientSize.Width-Px(30), Top = Px(2), Anchor = AnchorStyles.Top | AnchorStyles.Right, FlatStyle = FlatStyle.Flat, ForeColor = Color.WhiteSmoke }; close.FlatAppearance.BorderSize = 0; close.Click += (_, _) => HideToast();
            toast.Controls.Add(toastText); toast.Controls.Add(toastStripe); toast.Controls.Add(close); close.BringToFront();
            toast.Shown += (_, _) => PositionToast();
            toast.DpiChanged += (_, _) => PositionToast();
            PositionToast(); toast.Show(); Native.Raise(toast); Native.Raise(bubble);
        }
        toastAgent = data.Text("id"); toastSticky = data.Text("tone") == "blocked";
        toastStripe!.BackColor = toastSticky ? Bubble.Red : Bubble.Blue;
        // The title line is painted in the state color; the label holds the preview below it.
        toastText!.Tag = data.Text("title"); toastText.Text = "\n\n" + data.Text("preview") + (data.Text("answers").Length > 0 ? "\nOpen with the shortcut, then press " + data.Text("answers") : ""); toastText.Invalidate();
        toastTimer?.Dispose(); toastTimer = null;
        if (!toastSticky)
        {
            toastTimer = new() { Interval = 6000 };
            toastTimer.Tick += (_, _) => { if (toast is not null && !toast.Bounds.Contains(Cursor.Position)) HideToast(); }; toastTimer.Start();
        }
    }
    void PaintToastTitle(object? sender, PaintEventArgs e)
    {
        if (sender is not Label label) return;
        using var font = new Font(label.Font.FontFamily, label.Font.Size * 1.08f, FontStyle.Bold);
        var color = toastSticky ? Color.FromArgb(255,154,154) : Color.FromArgb(169,203,255);
        e.Graphics.FillRectangle(new SolidBrush(label.BackColor), label.Padding.Left, label.Padding.Top, label.Width - label.Padding.Horizontal, font.Height + 2);
        TextRenderer.DrawText(e.Graphics, label.Tag as string ?? "", font, new Rectangle(label.Padding.Left, label.Padding.Top, label.Width - label.Padding.Horizontal, font.Height + 2), color, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.Left);
    }
    void PositionToast()
    {
        if (toast is null || toast.IsDisposed) return;
        var area = Screen.FromRectangle(bubble.Bounds).WorkingArea;
        int gap = (int)Math.Round(10*bubble.DeviceDpi/96f);
        int x = bubble.Left + (bubble.Width-toast.Width)/2;
        int y = bubble.Top-toast.Height-gap;
        if (y < area.Top) y = bubble.Bottom+gap;
        toast.Location = new Point(Math.Clamp(x,area.Left,Math.Max(area.Left,area.Right-toast.Width)), Math.Clamp(y,area.Top,Math.Max(area.Top,area.Bottom-toast.Height)));
    }
    void HideToast() { toastTimer?.Dispose(); toastTimer = null; toast?.Dispose(); toast = null; toastText = null; toastStripe = null; }
    void Connection()
    {
        using var form = new Form { Text = "Herdr connection", Size = new Size(500,280), StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        var info = new Label { Text = "Use this PC's Herdr installation, or connect to the Mac/Linux machine that already has your Herdr setup.", Left = 20, Top = 16, Width = 450, Height = 45 };
        var label = new Label { Text = "SSH target (leave blank for this PC)", Left = 20, Top = 70, Width = 430 };
        var target = new TextBox { Text = prefs.SourceTarget, Left = 20, Top = 96, Width = 440, PlaceholderText = "username@hostname or an SSH alias" };
        var sessionLabel = new Label { Text = "Session", Left = 20, Top = 134 };
        var session = new TextBox { Text = prefs.SourceSession, Left = 120, Top = 130, Width = 340 };
        var save = new Button { Text = "Connect", Left = 350, Top = 180, Width = 110 };
        save.Click += (_, _) =>
        {
            try { if (target.Text.Trim().Length > 0) HerdrClient.ValidateTarget(target.Text.Trim()); if (string.IsNullOrWhiteSpace(session.Text) || session.Text.Any(char.IsControl)) throw new InvalidOperationException("Enter a valid session name."); }
            catch (Exception e) { MessageBox.Show(form, e.Message); return; }
            prefs.SourceTarget = target.Text.Trim(); prefs.SourceSession = session.Text.Trim(); prefs.SelectedAgent = ""; prefs.Save();
            StopWatchers(); client = new HerdrClient(prefs.SourceTarget, prefs.SourceSession); snapshot = new(); lastEmitted = ""; Emit("resetBaseline", new()); form.DialogResult = DialogResult.OK;
        };
        form.Controls.AddRange([info,label,target,sessionLabel,session,save]); form.AcceptButton = save;
        if (form.ShowDialog() == DialogResult.OK) { OpenPanel(); _ = Refresh(); }
    }
    JsonObject Diagnostics()
    {
        var data = new JsonObject { ["ready"] = ready, ["visible"] = bubble.Visible, ["panelOpen"] = panel.Visible, ["pid"] = Environment.ProcessId, ["sessionId"] = Process.GetCurrentProcess().SessionId, ["agents"] = snapshot["agents"]?.AsArray().Count ?? 0, ["eventStreams"] = new JsonArray(live.Order().Select(id => (JsonNode?)id).ToArray()), ["resources"] = Path.Combine(AppContext.BaseDirectory, "Resources"), ["shortcutWarning"] = hotkeyWarning, ["badgeCount"] = bubble.Count, ["badgeBounds"] = JsonSerializer.SerializeToNode(bubble.BadgeBounds), ["toastBounds"] = toast is not null ? JsonSerializer.SerializeToNode(toast.Bounds) : null, ["bubbleBounds"] = JsonSerializer.SerializeToNode(bubble.Bounds), ["panelBounds"] = JsonSerializer.SerializeToNode(panel.Bounds) };
        File.WriteAllText(Path.Combine(Program.Support, "diagnostics.json"), data.ToJsonString()); return data;
    }
    async Task Listen()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(Program.PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(lifetime.Token);
                using var reader = new StreamReader(pipe, leaveOpen: true);
                // A small fixed control vocabulary, never arbitrary JavaScript or shell.
                char[] buffer = new char[64]; int n = await reader.ReadAsync(buffer.AsMemory(), lifetime.Token).AsTask().WaitAsync(TimeSpan.FromSeconds(3));
                string command = new string(buffer, 0, n).Trim(); var result = await Control(command);
                using var writer = new StreamWriter(pipe, leaveOpen: true) { AutoFlush = true }; await writer.WriteAsync(result.ToJsonString());
            }
            catch (OperationCanceledException) { break; }
            catch (Exception e) { if (!quitting) File.WriteAllText(Path.Combine(Program.Support, "pipe-error.txt"), e.Message); }
        }
    }
    async Task<JsonObject> Control(string command)
    {
        switch (command)
        {
            case "open": OpenPanel(); break; case "close": ClosePanel(); break;
            case "hide": if (prefs.Visible) ToggleVisibility(); break; case "show": if (!prefs.Visible) ToggleVisibility(); break;
            case "toggle": TogglePanel(); break;
            case "roster": await Refresh(); return snapshot.Copy();
            case "inspect":
                if (!ready) return new() { ["error"] = "UI is still loading." };
                var inspected = await web.CoreWebView2.ExecuteScriptAsync("({agents:agents.length,selected:document.getElementById('title').textContent,outputLength:document.getElementById('output').textContent.length,draftLength:document.getElementById('prompt').value.length,sendDisabled:document.getElementById('send').disabled,notice:document.getElementById('notice').textContent})");
                File.WriteAllText(Path.Combine(Program.Support, "ui-check.json"), inspected); return JsonNode.Parse(inspected) as JsonObject ?? new();
            case "snapshot":
                if (!ready) return new() { ["error"] = "UI is still loading." };
                using (var file = File.Create(Path.Combine(Program.Support, "panel-preview.png"))) await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, file); break;
            case "verify-ui":
                if (!ready) return new() { ["error"] = "UI is still loading." };
                OpenPanel();
                // CDP awaits the promise; the bundled test never sends a prompt.
                var checkedUI = await web.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate", "{\"expression\":\"window.verifyControls()\",\"awaitPromise\":true,\"returnByValue\":true}");
                File.WriteAllText(Path.Combine(Program.Support, "ui-verification.json"), checkedUI); return JsonNode.Parse(checkedUI) as JsonObject ?? new();
            case "preview-alert":
                var foreground = Native.GetForegroundWindow();
                ShowToast(new() { ["id"] = prefs.SelectedAgent, ["title"] = "Notification preview", ["preview"] = "This notification stays beside H, wherever you move it." });
                await Task.Delay(250);
                var preview = Diagnostics();
                preview["focusUnchanged"] = Native.GetForegroundWindow() == foreground;
                preview["onSameScreen"] = toast is not null && Screen.FromControl(toast).DeviceName == Screen.FromControl(bubble).DeviceName;
                preview["onScreen"] = toast is not null && Screen.FromControl(bubble).WorkingArea.Contains(toast.Bounds);
                File.WriteAllText(Path.Combine(Program.Support,"notification-preview.json"),preview.ToJsonString());
                return preview;
            case "fixture": return await Fixture();
            default: return new() { ["error"] = "Unknown control command." };
        }
        return Diagnostics();
    }
    async Task<JsonObject> Fixture()
    {
        bool wasOpen = panel.Visible, wasVisible = prefs.Visible; var before = Native.GetForegroundWindow(); var pointer = Cursor.Position;
        using var fixture = new Form { Text = "Herdr HUD Fullscreen Test", FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = Screen.FromControl(bubble).Bounds, BackColor = Color.FromArgb(38,59,83) };
        fixture.Controls.Add(new Label { Text = "HERDR HUD\nFullscreen window test\n\nThis is a test fixture, not a game.", ForeColor = Color.White, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 28) });
        try
        {
            ClosePanel(); fixture.Show(); fixture.Activate(); await Task.Delay(400);
            bool fixtureClick = Native.ClickOwn(fixture, new Point(fixture.Right-100,fixture.Top+fixture.Height/2));
            await Task.Delay(200);
            bool fixtureFocused = Native.GetForegroundWindow()==fixture.Handle;
            long bubbleHit = Native.GetAncestor(Native.WindowFromPoint(new Point(bubble.Left+bubble.Width/2,bubble.Top+bubble.Height/2)),2).ToInt64();
            bool bubbleClick = Native.ClickOwn(bubble,new Point(bubble.Left+bubble.Width/2,bubble.Top+bubble.Height/2));
            await Task.Delay(300);
            bool panelFocused = panel.Visible && Native.GetAncestor(Native.GetForegroundWindow(),2)==panel.Handle;
            ClosePanel(); await Task.Delay(200);
            bool focusReturned = Native.GetForegroundWindow()==fixture.Handle;
            OpenPanel(); fixture.Activate(); Native.Raise(panel); Native.Raise(bubble); await Task.Delay(300);
            var order = new List<long>(); IntPtr hwnd = Native.GetWindow(fixture.Handle, 0);
            for (int i = 0; hwnd != IntPtr.Zero && i < 4000; i++, hwnd = Native.GetWindow(hwnd, 2)) order.Add(hwnd.ToInt64());
            bool above = order.IndexOf(panel.Handle.ToInt64()) >= 0 && order.IndexOf(bubble.Handle.ToInt64()) >= 0 && order.IndexOf(panel.Handle.ToInt64()) < order.IndexOf(fixture.Handle.ToInt64()) && order.IndexOf(bubble.Handle.ToInt64()) < order.IndexOf(fixture.Handle.ToInt64());
            using var screen = new Bitmap(fixture.Width, fixture.Height);
            using (var graphics = Graphics.FromImage(screen)) graphics.CopyFromScreen(fixture.Location, Point.Empty, fixture.Size);
            screen.Save(Path.Combine(Program.Support, "fullscreen-fixture.png"));
            var data = new JsonObject { ["fixtureClick"] = fixtureClick, ["fixtureFocused"] = fixtureFocused, ["bubbleClick"] = bubbleClick, ["bubbleHit"] = bubbleHit, ["bubbleHandle"] = bubble.Handle.ToInt64(), ["panelFocusedOnClick"] = panelFocused, ["focusReturnedOnClose"] = focusReturned, ["hudAboveFixture"] = above, ["fixtureRemainsForeground"] = Native.GetForegroundWindow() == fixture.Handle, ["panelOverlaps"] = fixture.Bounds.IntersectsWith(panel.Bounds), ["bubbleOverlaps"] = fixture.Bounds.IntersectsWith(bubble.Bounds), ["fixtureBounds"] = JsonSerializer.SerializeToNode(fixture.Bounds), ["exclusiveFullscreenTested"] = false };
            File.WriteAllText(Path.Combine(Program.Support, "fullscreen-fixture.json"), data.ToJsonString()); return data;
        }
        finally { Native.SetCursorPos(pointer.X,pointer.Y); fixture.Close(); if (!wasOpen) ClosePanel(); if (!wasVisible && prefs.Visible) ToggleVisibility(); if (Native.IsWindow(before)) Native.SetForegroundWindow(before); }
    }
    void Quit()
    {
        quitting = true; lifetime.Cancel(); timer.Stop(); HideToast(); StopWatchers();
        if (foregroundHook != IntPtr.Zero) Native.UnhookWinEvent(foregroundHook);
        SystemEvents.DisplaySettingsChanged -= DisplaysChanged;
        Native.UnregisterHotKey(bubble.Handle, 1); Native.UnregisterHotKey(bubble.Handle, 2);
        tray.Visible = false; tray.Dispose(); panel.AllowQuit = true; web.Dispose(); panel.Close(); bubble.Close(); ExitThread();
    }
}
