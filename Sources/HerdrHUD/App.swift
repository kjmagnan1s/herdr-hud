import AppKit
import WebKit
import Carbon
import ServiceManagement

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
// State colors shared by the H and its alerts: red needs input, amber working,
// blue new to read. They match the panel's palette; the accent is Claude's terracotta.
enum Tone {
    static let red = NSColor(srgbRed:1.00,green:0.42,blue:0.45,alpha:1), redInk = NSColor(srgbRed:1.00,green:0.82,blue:0.84,alpha:1)
    static let blue = NSColor(srgbRed:0.37,green:0.66,blue:1.00,alpha:1), blueInk = NSColor(srgbRed:0.84,green:0.91,blue:1.00,alpha:1)
    static let amber = NSColor(srgbRed:0.96,green:0.71,blue:0.27,alpha:1), green = NSColor(srgbRed:0.31,green:0.83,blue:0.58,alpha:1)
    static let accent = NSColor(srgbRed:0.91,green:0.53,blue:0.37,alpha:1), accentHi = NSColor(srgbRed:0.96,green:0.66,blue:0.53,alpha:1)
    static let badgeRed = NSColor(srgbRed:1.00,green:0.30,blue:0.34,alpha:1), badgeBlue = NSColor(srgbRed:0.24,green:0.55,blue:1.00,alpha:1)
    static let ink = NSColor(srgbRed:0.06,green:0.07,blue:0.09,alpha:1)
}
final class BubbleView: NSView {
    weak var app: HUDApp?
    var start = NSPoint.zero, origin = NSPoint.zero, dragged = false
    // The badge counts only the most urgent state and takes its color.
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    var tone = "" { didSet { if tone != oldValue { needsDisplay = true } } }
    var working = false { didSet { if working != oldValue { updateArc() } } }
    let arc = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        // A short amber dash runs around the tile's outline while any agent works.
        // Core Animation runs it on the GPU; it is removed when nothing is working.
        arc.frame = bounds; arc.path = CGPath(roundedRect: bounds.insetBy(dx:3.5, dy:3.5), cornerWidth:18, cornerHeight:18, transform: nil)
        arc.fillColor = nil; arc.strokeColor = Tone.amber.cgColor; arc.lineWidth = 2.5; arc.lineCap = .round
        arc.lineDashPattern = [NSNumber(value:BubbleView.dash), NSNumber(value:Double(BubbleView.perimeter)-BubbleView.dash)]; arc.isHidden = true
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }
    // Outline length of the arc's rounded square: straight sides plus one full circle of corners.
    static let perimeter = 4*(57.0-36)+2*Double.pi*18, dash = 34.0
    func updateArc() {
        arc.isHidden = !working; arc.removeAllAnimations()
        guard working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let run = CABasicAnimation(keyPath:"lineDashPhase")
        run.fromValue = 0; run.toValue = BubbleView.perimeter; run.duration = 2.4; run.repeatCount = .infinity
        arc.add(run, forKey:"run")
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // An app tile in Claude's terracotta, like the panel's brand mark, with a
    // thin accent ring, or red with a glow while an agent needs input. The count
    // sits in a pill.
    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx:7, dy:7), shape = NSBezierPath(roundedRect:tile,xRadius:14,yRadius:14)
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow(); drop.shadowColor = NSColor(white:0,alpha:0.55); drop.shadowBlurRadius = 8; drop.shadowOffset = NSSize(width:0,height:-3); drop.set()
        Tone.accent.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting:NSColor(srgbRed:0.79,green:0.37,blue:0.23,alpha:1),ending:NSColor(srgbRed:0.95,green:0.60,blue:0.44,alpha:1))?.draw(in:shape,angle:90)
        NSColor(white:1,alpha:0.14).setStroke(); let rim = NSBezierPath(roundedRect:tile.insetBy(dx:0.5,dy:0.5),xRadius:13.5,yRadius:13.5); rim.lineWidth = 1; rim.stroke()
        Tone.ink.withAlphaComponent(0.9).setStroke(); let gap = NSBezierPath(roundedRect:tile.insetBy(dx:-1,dy:-1),xRadius:15,yRadius:15); gap.lineWidth = 2; gap.stroke()
        let ring = NSBezierPath(roundedRect:tile.insetBy(dx:-2.75,dy:-2.75),xRadius:16.75,yRadius:16.75)
        NSGraphicsContext.saveGraphicsState()
        if tone == "blocked" {
            let glow = NSShadow(); glow.shadowColor = Tone.red.withAlphaComponent(0.75); glow.shadowBlurRadius = 8; glow.set()
            Tone.red.setStroke(); ring.lineWidth = 2
        } else { Tone.accentHi.withAlphaComponent(0.55).setStroke(); ring.lineWidth = 1.5 }
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let shade = NSShadow(); shade.shadowColor = NSColor(srgbRed:0.3,green:0.08,blue:0,alpha:0.45); shade.shadowBlurRadius = 2; shade.shadowOffset = NSSize(width:0,height:-1)
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:24, weight:.heavy), .foregroundColor:NSColor.white, .shadow:shade]
        let glyph = "H" as NSString, size = glyph.size(withAttributes:attrs)
        glyph.draw(at:NSPoint(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2), withAttributes:attrs)
        if count > 0 {
            let red = tone == "blocked", text = String(min(count,9)) as NSString
            let font = NSFont.systemFont(ofSize:11,weight:.heavy), label = text.size(withAttributes:[.font:font])
            let width = max(20, label.width+10), badge = NSRect(x:bounds.maxX-width-1,y:bounds.maxY-22,width:width,height:20)
            Tone.ink.setFill(); NSBezierPath(roundedRect:badge.insetBy(dx:-2,dy:-2),xRadius:12,yRadius:12).fill()
            (red ? Tone.badgeRed : Tone.badgeBlue).setFill(); NSBezierPath(roundedRect:badge,xRadius:10,yRadius:10).fill()
            text.draw(at:NSPoint(x:badge.midX-label.width/2,y:badge.midY-label.height/2),withAttributes:[.font:font,.foregroundColor:NSColor.white])
        }
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x-start.x,point.y-start.y) > 4 { dragged = true }
        guard dragged else { return }
        window?.setFrameOrigin(NSPoint(x:origin.x+point.x-start.x,y:origin.y+point.y-start.y))
        app?.positionPanel()
    }
    override func mouseUp(with event: NSEvent) { if dragged { app?.savePosition() } else { app?.togglePanel() } }
    override func rightMouseDown(with event: NSEvent) { if let menu = app?.status.menu { NSMenu.popUpContextMenu(menu,with:event,for:self) } }
}
final class HUDApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    // Roster checks, output reads and sends each get their own queue, so a
    // slow or offline machine never delays opening an agent or a send.
    let client = HerdrClient(), work = DispatchQueue(label:"herdr-hud.transport",qos:.userInitiated)
    let reads = DispatchQueue(label:"herdr-hud.reads",qos:.userInitiated)
    let sends = DispatchQueue(label:"herdr-hud.sends",qos:.userInitiated)
    // One event bridge per machine. A machine whose bridge is live refreshes on
    // its events; the others are polled. Everything is reconciled every 30 s.
    var watchers: [String: EventWatcher] = [:], live = Set<String>(), knownMachines: [Machine] = []
    var queuedAll = false, queuedMachines = Set<String>(), queuedForce = false, eventMachines = Set<String>()
    var lastFull = Date.distantPast, lastEmitted = ""
    let defaults = UserDefaults.standard
    var bubble: NSPanel!, panel: OverlayPanel!, bubbleView: BubbleView!, web: WKWebView!, status: NSStatusItem!
    var timer: Timer?, hotkeys: [EventHotKeyRef] = [], handler: EventHandlerRef?
    var visible = true, panelOpen = false, ready = false, polling = false
    var lastSnapshot: Row = [:], readBusy = false, selected = ""
    var promptIDs = Set<String>(), hotkeyWarning = ""
    var toast: NSPanel?, toastTimer: Timer?, toastHover = false
    var strip: NSPanel?, stripView: StripView?, stripAgents: [Row] = [], stripLabel = ""
    var shortcuts: [NSMenuItem] = []
    static let channel = Notification.Name("org.herdr.community.hud.control")
    var support: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        visible = defaults.object(forKey:"visible") == nil || defaults.bool(forKey:"visible")
        panel = OverlayPanel(contentRect:NSRect(x:100,y:100,width:960,height:740), styleMask:[.borderless,.nonactivatingPanel,.resizable], backing:.buffered,defer:false)
        configure(panel); panel.title = "Herdr HUD Agents"; panel.minSize = NSSize(width:640,height:430)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self,name:"hud")
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame:panel.contentView!.bounds,configuration:config)
        web.autoresizingMask = [.width,.height]; web.navigationDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        // Native blur behind the transparent page; the CSS only tints it.
        let glass = NSVisualEffectView(frame:panel.contentView!.bounds)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named:.darkAqua); glass.autoresizingMask = [.width,.height]
        let radius: CGFloat = 16, mask = NSImage(size:NSSize(width:radius*2+1,height:radius*2+1),flipped:false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top:radius,left:radius,bottom:radius,right:radius); mask.resizingMode = .stretch
        glass.maskImage = mask
        web.frame = glass.bounds; glass.addSubview(web)
        panel.contentView = glass
        web.loadFileURL(HUDResources.root.appendingPathComponent("index.html"),allowingReadAccessTo:HUDResources.root)
        bubble = NSPanel(contentRect:NSRect(x:32,y:180,width:64,height:64),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(bubble); bubble.title = "Herdr HUD H Button"; bubble.level = NSWindow.Level(rawValue:panel.level.rawValue+1)
        bubbleView = BubbleView(frame:NSRect(x:0,y:0,width:64,height:64)); bubbleView.app = self
        bubbleView.setAccessibilityRole(.button); bubbleView.setAccessibilityLabel("Herdr HUD. Click to open agents; drag to move.")
        bubble.contentView = bubbleView
        restorePosition()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.title = "H"; status.button?.toolTip = "Herdr HUD"
        buildMenu(); registerHotkeys()
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(control(_:)),name:Self.channel,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(spaceChanged),name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 && self.panelOpen { self.closePanel(); return nil }
            return event
        }
        if visible { bubble.orderFrontRegardless() }
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.tick() }
        refresh(); diagnostics()
    }
    func configure(_ window: NSPanel) {
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false; window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        if #available(macOS 13.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
    }
    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; return item }
    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("Open / close agents",#selector(togglePanel)))
        menu.addItem(menuItem("Show / hide H button",#selector(toggleVisibility)))
        let stripItem = menuItem("Show agent strip beside H",#selector(toggleStrip(_:))); stripItem.state = defaults.bool(forKey:"agentStrip") ? .on : .off; menu.addItem(stripItem)
        menu.addItem(.separator())
        let root = NSMenuItem(title:"Keyboard shortcuts",action:nil,keyEquivalent:""), submenu = NSMenu()
        for (index,title) in ["⌘⌥H panel · ⌘⌥⇧H hide", "⌃⌥H panel · ⌃⌥⇧H hide", "Shortcuts off"].enumerated() {
            let item = menuItem(title,#selector(changeShortcut(_:))); item.tag = index; shortcuts.append(item); submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
        let login = menuItem("Launch at login",#selector(toggleLogin(_:))); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(menuItem("Refresh agents",#selector(refresh)))
        menu.addItem(menuItem("About Herdr HUD",#selector(about)))
        menu.addItem(.separator()); menu.addItem(menuItem("Quit Herdr HUD",#selector(quit)))
        status.menu = menu
    }
    @objc func toggleStrip(_ item: NSMenuItem) {
        defaults.set(!defaults.bool(forKey:"agentStrip"),forKey:"agentStrip"); item.state = defaults.bool(forKey:"agentStrip") ? .on : .off; updateStrip()
    }
    // Off by default. Like a voice overlay's member row: one tile per agent beside
    // the H while the panel is closed, so state reads at a glance during play.
    func updateStrip() {
        guard defaults.bool(forKey:"agentStrip"), visible, !panelOpen, !stripAgents.isEmpty, bubble != nil else { strip?.orderOut(nil); return }
        if strip == nil {
            let window = NSPanel(contentRect:NSRect(x:0,y:0,width:120,height:44),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            configure(window); window.title = "Herdr HUD Agent Strip"; window.level = bubble.level
            let view = StripView(frame:window.contentView!.bounds); view.app = self; view.autoresizingMask = [.width,.height]
            window.contentView = view; strip = window; stripView = view
        }
        stripView?.agents = stripAgents; stripView?.label = stripLabel
        positionStrip(); strip?.orderFrontRegardless(); stripView?.needsDisplay = true
    }
    func positionStrip() {
        guard let strip = strip, let view = stripView, bubble != nil, !NSScreen.screens.isEmpty else { return }
        strip.setFrame(stripFrame(bubble:bubble.frame,size:NSSize(width:view.plan().width,height:44),visibleFrame:screenForBubble().visibleFrame),display:true)
    }
    @objc func changeShortcut(_ item: NSMenuItem) { defaults.set(item.tag,forKey:"shortcutMode"); registerHotkeys() }
    func registerHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }; hotkeys = []
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let event = event, let pointer = pointer else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
                let app = Unmanaged<HUDApp>.fromOpaque(pointer).takeUnretainedValue()
                if id.id == 1 { app.togglePanel() } else { app.toggleVisibility() }
                return noErr
            },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        }
        let mode = defaults.integer(forKey:"shortcutMode")
        for item in shortcuts { item.state = item.tag == mode ? .on : .off }
        guard mode != 2 else { hotkeyWarning = ""; return }
        let modifiers = UInt32(optionKey | (mode == 0 ? cmdKey : controlKey))
        hotkeyWarning = ""
        for id in 1...2 {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_H),modifiers | (id == 2 ? UInt32(shiftKey) : 0),EventHotKeyID(signature:0x48484431,id:UInt32(id)),GetApplicationEventTarget(),0,&ref)
            if result == noErr, let ref = ref { hotkeys.append(ref) } else { hotkeyWarning = "Shortcut already in use. Choose another combination in the H menu." }
        }
        if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
    }
    @objc func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { emit("notice",["message":"Login startup could not be enabled: " + error.localizedDescription]); openPanel() }
    }
    @objc func about() { openPanel(); emit("notice",["message":"Herdr HUD · Mac preview 0.1.0 · MIT · Community project, not affiliated with Herdr or Basecamp. Configure machines in Herdr; they appear here automatically."]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleVisibility() {
        visible.toggle(); defaults.set(visible,forKey:"visible")
        if visible { bubble.orderFrontRegardless(); refresh() } else { closePanel(); bubble.orderOut(nil); hideToast(); lastEmitted = ""; emit("resetBaseline",[:]) }
        updateStrip(); diagnostics()
    }
    @objc func togglePanel() { if panelOpen { closePanel() } else { openPanel() } }
    func openPanel() {
        visible = true; defaults.set(true,forKey:"visible"); panelOpen = true
        positionPanel(); bubble.orderFrontRegardless(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web); hideToast(); updateStrip(); emit("visibility",["open":true]); refresh(); diagnostics()
    }
    func closePanel() { panelOpen = false; panel.orderOut(nil); updateStrip(); emit("visibility",["open":false]); diagnostics() }
    func screenForBubble() -> NSScreen { NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x:bubble.frame.midX,y:bubble.frame.midY)) }) ?? NSScreen.screens.first! }
    func screenKey(_ screen: NSScreen) -> String { String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
    func restorePosition() {
        guard let screen = NSScreen.screens.first(where: { screenKey($0) == defaults.string(forKey:"lastScreen") }) ?? NSScreen.screens.first else { return }
        let point = defaults.string(forKey:"position." + screenKey(screen)).map(NSPointFromString) ?? NSPoint(x:32,y:180)
        bubble.setFrameOrigin(NSPoint(x:screen.frame.minX+min(max(point.x,4),screen.frame.width-68),y:screen.frame.minY+min(max(point.y,4),screen.frame.height-68)))
    }
    func savePosition() {
        let screen = screenForBubble(); let frame = screen.frame
        let point = NSPoint(x:min(max(bubble.frame.minX-frame.minX,4),frame.width-68),y:min(max(bubble.frame.minY-frame.minY,4),frame.height-68))
        defaults.set(NSStringFromPoint(point),forKey:"position." + screenKey(screen)); defaults.set(screenKey(screen),forKey:"lastScreen")
        bubble.setFrameOrigin(NSPoint(x:frame.minX+point.x,y:frame.minY+point.y)); positionPanel(); diagnostics()
    }
    func positionPanel() {
        defer { positionToast(); positionStrip() }
        guard bubble != nil, panel != nil, !NSScreen.screens.isEmpty else { return }
        let frame = screenForBubble().visibleFrame
        let size = NSSize(width:min(panel.frame.width,frame.width-24),height:min(panel.frame.height,frame.height-24))
        let right = bubble.frame.maxX+12
        let x = right+size.width <= frame.maxX ? right : bubble.frame.minX-size.width-12
        let y = bubble.frame.maxY-size.height
        panel.setFrame(NSRect(x:min(max(x,frame.minX+12),frame.maxX-size.width-12),y:min(max(y,frame.minY+12),frame.maxY-size.height-12),width:size.width,height:size.height),display:true)
    }
    @objc func screensChanged() { restorePosition(); positionPanel() }
    @objc func spaceChanged() { if visible { bubble.orderFrontRegardless(); if panelOpen { panel.orderFrontRegardless() } else if strip?.isVisible == true { strip?.orderFrontRegardless() }; toast?.orderFrontRegardless() } }
    // Manual refresh: every machine, ignoring the offline backoff.
    @objc func refresh() { check(nil, force: true) }
    func tick() {
        guard visible else { return }
        if knownMachines.isEmpty || Date().timeIntervalSince(lastFull) >= 30 { check(nil, force: false); return }
        let polled = Set(knownMachines.map(\.id)).subtracting(live)
        if !polled.isEmpty { check(polled, force: false) }
    }
    /// Checks the named machines (nil: rediscover and check all). Requests that
    /// arrive during a check are merged and run right after it.
    func check(_ only: Set<String>?, force: Bool) {
        guard visible else { return }
        if polling {
            if let only = only { queuedMachines.formUnion(only) } else { queuedAll = true }
            queuedForce = queuedForce || force; return
        }
        polling = true; if only == nil { lastFull = Date() }
        work.async { let data = self.client.snapshot(only: only, force: force), machines = self.client.machines
            DispatchQueue.main.async {
                self.polling = false; self.knownMachines = machines; self.publish(data); self.reconcileWatchers()
                if self.queuedAll || !self.queuedMachines.isEmpty {
                    let next: Set<String>? = self.queuedAll ? nil : self.queuedMachines, force = self.queuedForce
                    self.queuedAll = false; self.queuedMachines = []; self.queuedForce = false; self.check(next, force: force)
                }
            }
        }
    }
    // The page only hears about the roster when it actually changed, so the
    // list is not rebuilt (and hover or focus does not flicker) every poll.
    func publish(_ data: Row) {
        lastSnapshot = data
        let text = encode(["type":"roster","data":data])
        if visible && ready && text != lastEmitted { lastEmitted = text; web.evaluateJavaScript("window.receive(" + text + ")",completionHandler:nil) }
        diagnostics()
    }
    func reconcileWatchers() {
        for (id, watcher) in watchers where !knownMachines.contains(watcher.machine) { watcher.stop(); watchers[id] = nil; live.remove(id) }
        for machine in knownMachines where watchers[machine.id] == nil {
            guard let invocation = try? client.watchInvocation(machine) else { continue }
            let watcher = EventWatcher(machine: machine, invocation: invocation) { [weak self] signal in
                DispatchQueue.main.async { self?.watcherSignal(machine.id, signal) }
            }
            watchers[machine.id] = watcher; watcher.start()
        }
    }
    func watcherSignal(_ id: String, _ signal: EventWatcher.Signal) {
        guard watchers[id] != nil else { return }
        switch signal {
        case .down: live.remove(id)
        case .ready: live.insert(id); check([id], force: true)
        case .changed:
            // Events arrive in bursts (a new tab is three of them); gather them briefly.
            if eventMachines.isEmpty { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { let ids = self.eventMachines; self.eventMachines = []; self.check(ids, force: true) } }
            eventMachines.insert(id)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { for watcher in watchers.values { watcher.stop() } }
    func emit(_ type: String, _ data: Row) { guard ready else { return }; web.evaluateJavaScript("window.receive(" + encode(["type":type,"data":data]) + ")",completionHandler:nil) }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? Row, let operation = data["op"] as? String else { return }
        let requestID = data["requestID"] as? String ?? ""
        switch operation {
        case "ready": ready = true; lastEmitted = ""; emit("preferences",["selectedAgent":defaults.string(forKey:"selectedAgent") ?? "","rosterWidth":defaults.double(forKey:"rosterWidth"),"mode":defaults.string(forKey:"viewMode") ?? "chat"]); emit("visibility",["open":panelOpen]); if !lastSnapshot.isEmpty { publish(lastSnapshot) }; if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
        case "close": closePanel()
        case "hide": if visible { toggleVisibility() }
        case "refresh": refresh()
        case "preferences":
            if let id = data["selectedAgent"] as? String, id.utf8.count <= 8192 { defaults.set(id,forKey:"selectedAgent") }
            if let width = data["rosterWidth"] as? Double, width >= 56 && width <= 600 { defaults.set(width,forKey:"rosterWidth") }
            if let mode = data["mode"] as? String, ["chat","terminal"].contains(mode) { defaults.set(mode,forKey:"viewMode") }
        case "badge": bubbleView.count = data["count"] as? Int ?? 0; bubbleView.tone = data["tone"] as? String ?? ""; bubbleView.working = (data["working"] as? Int ?? 0) > 0
        case "strip": stripAgents = Array((data["agents"] as? [Row] ?? []).prefix(8)); stripLabel = String((data["label"] as? String ?? "").prefix(40)); updateStrip()
        case "alertPreview":
            if !panelOpen && visible, let id = data["id"] as? String {
                reads.async {
                    let output = (try? self.client.output(id)) ?? ["id":id,"text":"","provider":""]
                    DispatchQueue.main.async { self.emit("alertPreview",output.merging(["title":data["title"] ?? "Agent update","tone":data["tone"] ?? ""],uniquingKeysWith:{_,b in b})) }
                }
            }
        case "alert": if !panelOpen && visible { showToast(data) }
        case "alertClear": hideToast()
        case "output", "prompt":
            guard let id = data["id"] as? String, !requestID.isEmpty, panelOpen else { return }
            if operation == "output" { if readBusy { return }; readBusy = true; selected = id }
            if operation == "prompt" { guard !promptIDs.contains(requestID) else { return }; promptIDs.insert(requestID) }
            (operation == "output" ? reads : sends).async {
                var result: Row
                do { result = operation == "output" ? try self.client.output(id) : try self.client.prompt(id,data["message"] as? String ?? "") }
                catch { result = ["error":error.localizedDescription, "id":id] }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { if operation == "output" { self.readBusy = false }; self.emit(operation,value) }
            }
        case "answer":
            guard let id = data["id"] as? String, let number = data["n"] as? Int, !requestID.isEmpty, panelOpen, !promptIDs.contains(requestID) else { return }
            promptIDs.insert(requestID)
            sends.async {
                var result: Row
                do { result = try self.client.answer(id,number,question:data["question"] as? String ?? "",label:data["label"] as? String ?? "") }
                catch { result = ["error":error.localizedDescription, "id":id] }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { self.emit("answer",value) }
            }
        default: break
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
    // One toast at a time. A newer alert updates it in place instead of
    // replacing it; `update` only refreshes a toast that is already showing.
    // Needs-input toasts stay until opened or dismissed; others fade after 6 s.
    func showToast(_ data: Row) {
        if toast == nil && data["update"] as? Bool == true { return }
        let view: ToastView
        if let current = toast?.contentView as? ToastView { view = current } else {
            let window = NSPanel(contentRect:NSRect(x:0,y:0,width:380,height:124),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            configure(window); window.title = "Herdr HUD Alert"; window.hasShadow = true
            window.level = NSWindow.Level(rawValue:bubble.level.rawValue+1)
            view = ToastView(frame:NSRect(x:0,y:0,width:380,height:124)); view.app = self; window.contentView = view
            toast = window; positionToast(); window.orderFrontRegardless()
        }
        view.agentID = data["id"] as? String ?? ""; view.sticky = data["tone"] as? String == "blocked"
        view.title = data["title"] as? String ?? "Agent update"; view.detail = data["preview"] as? String ?? "Click to read the response"; view.answers = data["answers"] as? String ?? ""; view.waiting = data["waiting"] as? Int ?? 0; view.danger = data["danger"] as? Bool ?? false
        view.needsDisplay = true; armToastTimer()
    }
    func armToastTimer() {
        toastTimer?.invalidate(); toastTimer = nil
        guard let view = toast?.contentView as? ToastView, !view.sticky else { return }
        toastTimer = Timer.scheduledTimer(withTimeInterval:6,repeats:false) { [weak self] _ in if self?.toastHover != true { self?.hideToast() } }
    }
    func positionToast() {
        guard let toast = toast, bubble != nil, !NSScreen.screens.isEmpty else { return }
        toast.setFrame(notificationFrame(bubble:bubble.frame,size:toast.frame.size,visibleFrame:screenForBubble().visibleFrame),display:true)
    }
    func hideToast() { toastTimer?.invalidate(); toast?.orderOut(nil); toast = nil; toastHover = false }
    func diagnostics() {
        guard bubble != nil else { return }
        let data: Row = ["pid":ProcessInfo.processInfo.processIdentifier,"visible":visible,"panelOpen":panelOpen,"screens":NSScreen.screens.count,"panelKey":panel.isKeyWindow,"resourceRoot":HUDResources.root.path,"bubbleFrame":NSStringFromRect(bubble.frame),"panelFrame":NSStringFromRect(panel.frame),"machines":lastSnapshot["machines"] ?? [],"agentCount":(lastSnapshot["agents"] as? [Row])?.count ?? 0,"eventStreams":live.sorted(),"shortcutWarning":hotkeyWarning]
        try? encode(data).write(to:support.appendingPathComponent("diagnostics.json"),atomically:true,encoding:.utf8)
    }
    @objc func control(_ notification: Notification) {
        switch notification.object as? String {
        case "open": openPanel()
        case "close": closePanel()
        case "toggle": togglePanel()
        case "hide": if visible { toggleVisibility() }
        case "show": if !visible { toggleVisibility() }
        case "preview-alert":
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            showToast(["id":defaults.string(forKey:"selectedAgent") ?? "","title":"Notification preview","preview":"Notifications follow H and stay clear of the button."])
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                guard let toast = self.toast else { return }
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Row] ?? []
                let toastIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == toast.windowNumber }
                let bubbleIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == self.bubble.windowNumber }
                let evidence: Row = ["bubbleFrame":NSStringFromRect(self.bubble.frame),"toastFrame":NSStringFromRect(toast.frame),"onScreen":self.screenForBubble().visibleFrame.contains(toast.frame),"overlapsButton":toast.frame.intersects(self.bubble.frame),"focusUnchanged":NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,"toastAboveButton":toastIndex != nil && bubbleIndex != nil && toastIndex! < bubbleIndex!,"visible":toast.isVisible]
                try? encode(evidence).write(to:self.support.appendingPathComponent("notification-preview.json"),atomically:true,encoding:.utf8)
                if let view = toast.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:rep)
                    if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("notification-preview.png")) }
                }
            }
        case "verify-ui":
            openPanel()
            web.callAsyncJavaScript("return await window.verifyControls()",arguments:[:],in:nil,in:.page) { result in
                let value: Any
                switch result { case .success(let data): value=data; case .failure(let error): value=["error":error.localizedDescription] }
                try? encode(value).write(to:self.support.appendingPathComponent("ui-verification.json"),atomically:true,encoding:.utf8)
            }
        case "inspect":
            web.evaluateJavaScript("JSON.stringify({title:document.title,agents:document.querySelectorAll('.agent').length,selected:document.getElementById('title').textContent,outputLength:document.getElementById('output').textContent.length,draftLength:document.getElementById('prompt').value.length,sendDisabled:document.getElementById('send').disabled,notice:document.getElementById('notice').textContent})") { value,error in
                let text = (value as? String) ?? (error?.localizedDescription ?? "unknown")
                try? text.write(to:self.support.appendingPathComponent("ui-check.json"),atomically:true,encoding:.utf8)
            }
        case "snapshot":
            web.takeSnapshot(with:nil) { image,error in
                if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("panel-preview.png")) }
            }
        default: break
        }
    }
}
final class ToastView: NSView {
    weak var app: HUDApp?
    var agentID = "", title = "", detail = "", answers = "", sticky = false, danger = false, waiting = 0
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways],owner:self)) }
    override func mouseEntered(with event:NSEvent) { app?.toastHover = true }
    override func mouseExited(with event:NSEvent) { app?.toastHover = false; app?.armToastTimer() }
    override func mouseUp(with event:NSEvent) { if convert(event.locationInWindow,from:nil).x > bounds.width-35 { app?.hideToast() } else { let id = agentID; app?.openPanel(); app?.emit("select",["id":id]) } }
    // Like a game overlay's message toast: a dark sheet, a state-tinted icon, a
    // small kicker, the title, one line of preview and the shortcut that opens it.
    override func draw(_ dirtyRect:NSRect) {
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12)
        NSColor(srgbRed:0.067,green:0.075,blue:0.094,alpha:0.97).setFill(); shape.fill()
        NSColor(white:1,alpha:0.12).setStroke(); shape.lineWidth = 1; shape.stroke()
        let tone = danger ? Tone.amber : sticky ? Tone.red : Tone.blue, top = bounds.height
        let icon = NSRect(x:14,y:top-52,width:38,height:38), plate = NSBezierPath(roundedRect:icon,xRadius:10,yRadius:10)
        tone.withAlphaComponent(0.2).setFill(); plate.fill(); tone.withAlphaComponent(0.5).setStroke(); plate.lineWidth = 1; plate.stroke()
        let mark = (danger ? "⚠" : sticky ? "!" : "✓") as NSString, markAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:14,weight:.bold),.foregroundColor:danger ? NSColor(srgbRed:1,green:0.80,blue:0.55,alpha:1) : sticky ? Tone.redInk : Tone.blueInk]
        let markSize = mark.size(withAttributes:markAttrs); mark.draw(at:NSPoint(x:icon.midX-markSize.width/2,y:icon.midY-markSize.height/2),withAttributes:markAttrs)
        let line = NSMutableParagraphStyle(); line.lineBreakMode = .byTruncatingTail
        let kicker = (sticky ? (danger ? "DESTRUCTIVE" : "NEEDS YOU") + (waiting > 1 ? " · \(waiting) WAITING" : "") : "FINISHED") as NSString
        kicker.draw(in:NSRect(x:64,y:top-27,width:220,height:14),withAttributes:[.font:NSFont.systemFont(ofSize:10.5,weight:.bold),.kern:0.8,.foregroundColor:danger ? NSColor(srgbRed:1,green:0.80,blue:0.55,alpha:1) : sticky ? NSColor(srgbRed:1,green:0.61,blue:0.63,alpha:1) : NSColor(srgbRed:0.61,green:0.78,blue:1,alpha:1),.paragraphStyle:line])
        (title as NSString).draw(in:NSRect(x:64,y:top-49,width:280,height:20),withAttributes:[.font:NSFont.systemFont(ofSize:15,weight:.semibold),.foregroundColor:NSColor(white:0.95,alpha:1),.paragraphStyle:line])
        // A destructive command reads in amber, and Yes is no longer the highlighted key.
        (detail as NSString).draw(in:NSRect(x:64,y:top-71,width:300,height:19),withAttributes:[.font:NSFont.systemFont(ofSize:13.5,weight:danger ? .medium : .regular),.foregroundColor:danger ? NSColor(srgbRed:1,green:0.80,blue:0.55,alpha:1) : NSColor(srgbRed:0.86,green:0.87,blue:0.89,alpha:1),.paragraphStyle:line])
        let mode = UserDefaults.standard.integer(forKey:"shortcutMode"), keys = mode == 0 ? "⌘⌥H" : mode == 1 ? "⌃⌥H" : ""
        let hintFont = NSFont.systemFont(ofSize:13,weight:.medium), hintColor = NSColor(srgbRed:0.76,green:0.79,blue:0.83,alpha:1)
        // A hairline splits the message from the keys that act on it.
        NSColor(white:1,alpha:0.08).setFill(); NSRect(x:14,y:42,width:bounds.width-28,height:1).fill()
        // Keycaps for the shortcut and each answer number: "⌘⌥H then 1 Yes 2 Always 3 No".
        var x: CGFloat = 14
        func cap(_ text: String, primary: Bool = false) {
            let keyAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:12,weight:.bold),.foregroundColor:primary ? NSColor(srgbRed:0.02,green:0.08,blue:0.05,alpha:1) : NSColor(white:0.95,alpha:1)]
            let size = (text as NSString).size(withAttributes:keyAttrs), rect = NSRect(x:x,y:11,width:max(22,size.width+12),height:22)
            (primary ? Tone.green : NSColor(white:1,alpha:0.1)).setFill(); let path = NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6); path.fill()
            NSColor(white:1,alpha:primary ? 0 : 0.24).setStroke(); path.lineWidth = 1; path.stroke()
            (text as NSString).draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:keyAttrs); x = rect.maxX+6
        }
        func word(_ text: String, _ color: NSColor) {
            let attrs: [NSAttributedString.Key:Any] = [.font:hintFont,.foregroundColor:color]
            guard x < bounds.width-20 else { return }
            (text as NSString).draw(at:NSPoint(x:x,y:13),withAttributes:attrs); x += (text as NSString).size(withAttributes:attrs).width+12
        }
        if keys.isEmpty { word("Click to open",hintColor) }
        else {
            cap(keys)
            if answers.isEmpty { word("open",hintColor) }
            else {
                word("then",hintColor)
                for (i, answer) in answers.components(separatedBy:" · ").enumerated() {
                    let parts = answer.split(separator:" ",maxSplits:1).map(String.init)
                    guard let number = parts.first else { continue }
                    cap(number, primary: i == 0 && !danger); word(parts.count > 1 ? parts[1] : "",NSColor(white:0.95,alpha:1))
                }
            }
        }
        ("×" as NSString).draw(at:NSPoint(x:bounds.width-24,y:top-28),withAttributes:[.font:NSFont.systemFont(ofSize:17),.foregroundColor:hintColor])
    }
}
final class StripView: NSView {
    weak var app: HUDApp?
    var agents: [Row] = [], label = ""
    var tiles: [(id: String, rect: NSRect)] = []
    static let labelAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:12.5,weight:.semibold),.foregroundColor:NSColor(srgbRed:1,green:0.70,blue:0.72,alpha:1)]
    static let nameAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:13,weight:.semibold),.foregroundColor:NSColor(srgbRed:0.93,green:0.94,blue:0.95,alpha:1)]
    // Agents that need you or are working carry their name; ready ones stay a tile.
    static func name(_ agent: Row) -> String? {
        guard ["blocked","working","unread"].contains(agent["state"] as? String ?? "") else { return nil }
        let text = agent["name"] as? String ?? ""; return text.count > 18 ? String(text.prefix(17)) + "…" : text
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    static func rank(_ state: String) -> Int { ["blocked":0,"unread":1,"working":2][state] ?? 3 }
    // Left to right: the "needs you" label, then tiles with a hairline between state groups.
    func plan() -> (width: CGFloat, label: CGFloat, tiles: [CGFloat], separators: [CGFloat]) {
        var x: CGFloat = 10, labelX: CGFloat = -1, xs: [CGFloat] = [], seps: [CGFloat] = [], last = -1
        if !label.isEmpty { labelX = x; x += ceil((label as NSString).size(withAttributes:Self.labelAttrs).width)+10 }
        for agent in agents {
            let rank = Self.rank(agent["state"] as? String ?? "")
            if last >= 0 && rank != last { seps.append(x); x += 9 }
            xs.append(x); x += 36; last = rank
            if let name = Self.name(agent) { x += ceil((name as NSString).size(withAttributes:Self.nameAttrs).width)+11 }
        }
        return (x-8+10, labelX, xs, seps)
    }
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> NSColor {
        let v = l+s*min(l,1-l), sv = v == 0 ? 0 : 2*(1-l/v)
        return NSColor(hue:CGFloat(h.truncatingRemainder(dividingBy:360)/360),saturation:CGFloat(sv),brightness:CGFloat(v),alpha:1)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:14,yRadius:14)
        NSColor(srgbRed:0.067,green:0.075,blue:0.094,alpha:0.9).setFill(); shape.fill()
        NSColor(white:1,alpha:0.1).setStroke(); shape.lineWidth = 1; shape.stroke()
        let spots = plan(), mid = bounds.midY
        if spots.label >= 0 {
            let size = (label as NSString).size(withAttributes:Self.labelAttrs)
            (label as NSString).draw(at:NSPoint(x:spots.label,y:mid-size.height/2),withAttributes:Self.labelAttrs)
        }
        for x in spots.separators { NSColor(white:1,alpha:0.12).setFill(); NSRect(x:x,y:mid-11,width:1,height:22).fill() }
        tiles = []
        for (agent, x) in zip(agents, spots.tiles) {
            let state = agent["state"] as? String ?? "", rect = NSRect(x:x,y:mid-14,width:28,height:28), hue = agent["hue"] as? Double ?? 0
            var hit = rect
            if let name = Self.name(agent) {
                let size = (name as NSString).size(withAttributes:Self.nameAttrs)
                (name as NSString).draw(at:NSPoint(x:rect.maxX+7,y:mid-size.height/2),withAttributes:Self.nameAttrs); hit.size.width += ceil(size.width)+7
            }
            tiles.append((agent["id"] as? String ?? "", hit))
            let ring: NSColor? = state == "blocked" ? Tone.red : state == "working" ? Tone.amber.withAlphaComponent(0.85) : state == "unread" ? Tone.blue : nil
            if let ring = ring { ring.setStroke(); let outer = NSBezierPath(roundedRect:rect.insetBy(dx:-2.75,dy:-2.75),xRadius:10,yRadius:10); outer.lineWidth = 1.5; outer.stroke() }
            let quiet = ["idle","done","offline"].contains(state), path = NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8)
            let top = state == "offline" ? NSColor(white:0.45,alpha:1) : Self.hsl(hue,0.60,0.56), bottom = state == "offline" ? NSColor(white:0.25,alpha:1) : Self.hsl(hue+24,0.54,0.36)
            NSGraphicsContext.saveGraphicsState(); if quiet { NSGraphicsContext.current?.cgContext.setAlpha(0.82) }
            NSGradient(starting:top,ending:bottom)?.draw(in:path,angle:-70)
            NSColor(white:1,alpha:0.16).setStroke(); path.lineWidth = 1; path.stroke()
            let text = (agent["initials"] as? String ?? "?") as NSString, attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10.5,weight:.heavy),.foregroundColor:NSColor.white]
            let size = text.size(withAttributes:attrs); text.draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        let names = agents.map { "\($0["name"] as? String ?? "agent") \($0["state"] as? String ?? "")" }.joined(separator:", ")
        setAccessibilityRole(.group); setAccessibilityLabel((label.isEmpty ? "" : label + ". ") + "Agents: " + names + ". Click one to open it.")
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        let id = tiles.first(where:{ $0.rect.insetBy(dx:-4,dy:-8).contains(point) })?.id ?? tiles.first?.id ?? ""
        app?.openPanel(); if !id.isEmpty { app?.emit("select",["id":id]) }
    }
}
