import AppKit
import WebKit
import Carbon
import ServiceManagement

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
// State colors shared by the H and its alerts: red needs input, amber working,
// blue new to read. They match the panel's palette.
enum Tone {
    static let red = NSColor(srgbRed:1.00,green:0.42,blue:0.42,alpha:1), redInk = NSColor(srgbRed:0.16,green:0.04,blue:0.04,alpha:1)
    static let blue = NSColor(srgbRed:0.42,green:0.66,blue:1.00,alpha:1), blueInk = NSColor(srgbRed:0.04,green:0.10,blue:0.18,alpha:1)
    static let amber = NSColor(srgbRed:0.95,green:0.72,blue:0.29,alpha:1)
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
        // A short amber arc turns around the ring while any agent works. Core
        // Animation runs it on the GPU; it is removed when nothing is working.
        arc.frame = bounds; arc.path = CGPath(ellipseIn: bounds.insetBy(dx:2, dy:2), transform: nil)
        arc.fillColor = nil; arc.strokeColor = Tone.amber.cgColor; arc.lineWidth = 3; arc.lineCap = .round
        arc.strokeStart = 0; arc.strokeEnd = 0.28; arc.isHidden = true
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateArc() {
        arc.isHidden = !working; arc.removeAllAnimations()
        guard working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath:"transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 2.4; spin.repeatCount = .infinity
        arc.anchorPoint = CGPoint(x:0.5, y:0.5); arc.position = CGPoint(x:bounds.midX, y:bounds.midY)
        arc.add(spin, forKey:"spin")
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.09, green:0.10, blue:0.13, alpha:0.97).setFill()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx:4, dy:4)); circle.fill()
        NSGraphicsContext.saveGraphicsState()
        if tone == "blocked" {
            // Needs input wins: a red ring with a soft glow, like a debuff highlight.
            let glow = NSShadow(); glow.shadowColor = Tone.red.withAlphaComponent(0.8); glow.shadowBlurRadius = 5; glow.set()
            Tone.red.setStroke()
        } else { NSColor(calibratedRed:0.91, green:0.72, blue:0.36, alpha:1).setStroke() }
        circle.lineWidth = 2; circle.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:28, weight:.bold), .foregroundColor:NSColor(calibratedRed:0.97,green:0.79,blue:0.43,alpha:1)]
        ("H" as NSString).draw(at:NSPoint(x:20,y:16), withAttributes:attrs)
        if count > 0 {
            let red = tone == "blocked", text = String(min(count,9)) as NSString
            let font = NSFont.systemFont(ofSize:10,weight:.bold), size = text.size(withAttributes:[.font:font])
            let badge = NSRect(x:42,y:42,width:19,height:19)
            NSColor(calibratedRed:0.09, green:0.10, blue:0.13, alpha:1).setFill(); NSBezierPath(ovalIn:badge.insetBy(dx:-1.5,dy:-1.5)).fill()
            (red ? Tone.red : Tone.blue).setFill(); NSBezierPath(ovalIn:badge).fill()
            text.draw(at:NSPoint(x:badge.midX-size.width/2,y:badge.midY-size.height/2),withAttributes:[.font:font,.foregroundColor:red ? Tone.redInk : Tone.blueInk])
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
    var shortcuts: [NSMenuItem] = []
    static let channel = Notification.Name("org.herdr.community.hud.control")
    var support: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        visible = defaults.object(forKey:"visible") == nil || defaults.bool(forKey:"visible")
        panel = OverlayPanel(contentRect:NSRect(x:100,y:100,width:940,height:650), styleMask:[.borderless,.nonactivatingPanel,.resizable], backing:.buffered,defer:false)
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
        diagnostics()
    }
    @objc func togglePanel() { if panelOpen { closePanel() } else { openPanel() } }
    func openPanel() {
        visible = true; defaults.set(true,forKey:"visible"); panelOpen = true
        positionPanel(); bubble.orderFrontRegardless(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web); hideToast(); emit("visibility",["open":true]); refresh(); diagnostics()
    }
    func closePanel() { panelOpen = false; panel.orderOut(nil); emit("visibility",["open":false]); diagnostics() }
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
        defer { positionToast() }
        guard bubble != nil, panel != nil, !NSScreen.screens.isEmpty else { return }
        let frame = screenForBubble().visibleFrame
        let size = NSSize(width:min(panel.frame.width,frame.width-24),height:min(panel.frame.height,frame.height-24))
        let right = bubble.frame.maxX+12
        let x = right+size.width <= frame.maxX ? right : bubble.frame.minX-size.width-12
        let y = bubble.frame.maxY-size.height
        panel.setFrame(NSRect(x:min(max(x,frame.minX+12),frame.maxX-size.width-12),y:min(max(y,frame.minY+12),frame.maxY-size.height-12),width:size.width,height:size.height),display:true)
    }
    @objc func screensChanged() { restorePosition(); positionPanel() }
    @objc func spaceChanged() { if visible { bubble.orderFrontRegardless(); if panelOpen { panel.orderFrontRegardless() }; toast?.orderFrontRegardless() } }
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
            let window = NSPanel(contentRect:NSRect(x:0,y:0,width:320,height:92),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            configure(window); window.title = "Herdr HUD Alert"; window.hasShadow = true
            window.level = NSWindow.Level(rawValue:bubble.level.rawValue+1)
            view = ToastView(frame:NSRect(x:0,y:0,width:320,height:92)); view.app = self; window.contentView = view
            toast = window; positionToast(); window.orderFrontRegardless()
        }
        view.agentID = data["id"] as? String ?? ""; view.sticky = data["tone"] as? String == "blocked"
        view.title = data["title"] as? String ?? "Agent update"; view.detail = data["preview"] as? String ?? "Click to read the response"
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
    var agentID = "", title = "", detail = "", sticky = false
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways],owner:self)) }
    override func mouseEntered(with event:NSEvent) { app?.toastHover = true }
    override func mouseExited(with event:NSEvent) { app?.toastHover = false; app?.armToastTimer() }
    override func mouseUp(with event:NSEvent) { if convert(event.locationInWindow,from:nil).x > bounds.width-35 { app?.hideToast() } else { let id = agentID; app?.openPanel(); app?.emit("select",["id":id]) } }
    // A WoW-style tooltip: deep navy, thin light border, a stripe and title in
    // the state color (red needs input, blue finished).
    override func draw(_ dirtyRect:NSRect) {
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10)
        NSColor(srgbRed:0.03,green:0.04,blue:0.08,alpha:0.94).setFill(); shape.fill()
        NSColor(white:1,alpha:0.16).setStroke(); shape.lineWidth = 1; shape.stroke()
        (sticky ? Tone.red : Tone.blue).setFill(); NSBezierPath(roundedRect:NSRect(x:0,y:10,width:3,height:bounds.height-20),xRadius:1.5,yRadius:1.5).fill()
        let titleColor = sticky ? NSColor(srgbRed:1,green:0.60,blue:0.60,alpha:1) : NSColor(srgbRed:0.66,green:0.80,blue:1,alpha:1)
        (title as NSString).draw(in:NSRect(x:16,y:50,width:270,height:26),withAttributes:[.font:NSFont.systemFont(ofSize:13.5,weight:.semibold),.foregroundColor:titleColor])
        (detail as NSString).draw(in:NSRect(x:16,y:12,width:282,height:36),withAttributes:[.font:NSFont.systemFont(ofSize:12.5),.foregroundColor:NSColor(srgbRed:0.77,green:0.75,blue:0.71,alpha:1)])
        ("×" as NSString).draw(at:NSPoint(x:296,y:65),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.gray])
    }
}
