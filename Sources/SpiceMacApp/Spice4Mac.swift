import AppKit
import SwiftUI
import Combine
import ConnectionCore
import SessionCore

@main
@MainActor
enum Spice4Mac {
    static func configureBundledRuntime() {
        if let resources = Bundle.main.resourceURL, Bundle.main.bundleURL.pathExtension == "app" {
            let plugins = resources.appendingPathComponent("gstreamer-1.0").path
            setenv("GST_PLUGIN_SYSTEM_PATH_1_0", plugins, 1)
            setenv("GST_PLUGIN_PATH_1_0", "", 1)
            setenv("GST_REGISTRY_FORK", "no", 1)
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent("ca-bundle.pem").path) { setenv("SSL_CERT_FILE", resources.appendingPathComponent("ca-bundle.pem").path, 1) }
        }
    }
    static func main() {
        do {
            let request = try LaunchRequest.parse(arguments:Array(CommandLine.arguments.dropFirst()))
            if request.help { print(LaunchRequest.helpText); return }
            if request.version { print("Spice4Mac \(AppVersion.current)"); return }
            let data = request.connectionFromStdin || request.passwordFromStdin ? try readLimited(handle:.standardInput) : nil
            let options = try request.resolveConnection(stdin:data)
            if request.validateOnly { if let options { FileHandle.standardOutput.write(try options.redactedJSON()); print("") }; return }
            configureBundledRuntime()
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = AppDelegate(request:request,options:options)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch { fputs("Spice4Mac: \(error.localizedDescription)\n",stderr); exit(64) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let session = NativeSession()
    let request: LaunchRequest
    var initialOptions: ConnectionOptions?
    var window: NSWindow!
    var subscriptions = Set<AnyCancellable>()
    var timeout: Timer?
    var didCapture = false
    var finishing = false
    func flag(_ key:String) -> Bool { request.forwardedArguments.contains(key) }
    var exitOnDisconnect: Bool { flag("--exit-on-disconnect") }
    var automation: Bool { ["--exit-after-connect","--screenshot","--window-screenshot","--timeout"].contains(where:flag) }
    init(request:LaunchRequest,options:ConnectionOptions?) { self.request=request; initialOptions=options }
    func argument(_ key:String) -> String? {
        guard let i=request.forwardedArguments.firstIndex(of:key),i+1<request.forwardedArguments.count else{return nil}
        return request.forwardedArguments[i+1]
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        installMenus()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        let toolbar=NSToolbar(identifier:"session-toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly
        window.toolbar=toolbar;window.toolbarStyle = .unified
        window.title="Spice4Mac";window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:760,height:520)
        window.contentView=NSHostingView(rootView:ClientView(session:session,initialOptions:initialOptions,autoResizeEnabled:!flag("--no-auto-resize")))
        window.delegate=self;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        session.$state.sink { [weak self] state in
            self?.event("state",["state":state.rawValue])
            if state == .failed, self?.automation==true || self?.exitOnDisconnect==true {self?.finish(2)}
            // The server or network ended the session; user-initiated disconnects finish(0) directly.
            if state == .disconnected, self?.exitOnDisconnect==true {self?.finish(5)}
        }.store(in:&subscriptions)
        session.frames.compactMap{$0}.sink { [weak self] frame in
            guard let self,!self.didCapture else{return}
            self.didCapture=true
            self.event("frame",["width":frame.width,"height":frame.height])
            if let path=self.argument("--screenshot") {
                do {try FrameImage.writePNG(frame:frame,to:URL(fileURLWithPath:path));self.event("screenshot",["path":path])}
                catch {self.event("error",["message":"Unable to write screenshot"]);self.finish(3);return}
            }
            if let path=self.argument("--window-screenshot") {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    guard let view=self.window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {self.finish(3);return}
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    guard let png=bitmap.representation(using:.png,properties:[:]) else {self.finish(3);return}
                    do {try png.write(to:URL(fileURLWithPath:path));self.event("window-screenshot",["path":path]);if self.flag("--exit-after-connect"){self.finish(0)}} catch {self.finish(3)}
                }
            } else if self.flag("--exit-after-connect") { self.finish(0) }
        }.store(in:&subscriptions)
        if let options=initialOptions { session.connect(options) }
        if flag("--fullscreen") {window.toggleFullScreen(nil)}
        if let seconds=argument("--timeout").flatMap(Double.init) ?? (automation ? 20:nil) {
            timeout=Timer.scheduledTimer(withTimeInterval:seconds,repeats:false){[weak self] _ in
                Task{@MainActor in guard let self else{return};if !self.didCapture {self.event("error",["message":"Connection timed out"]);self.finish(4)}}
            }
        }
    }
    func window(_ window:NSWindow, willUseFullScreenPresentationOptions proposedOptions:NSApplication.PresentationOptions)->NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .autoHideDock])
    }
    func windowWillEnterFullScreen(_ notification:Notification){session.fullScreen=true}
    func windowDidEnterFullScreen(_ notification:Notification){event("fullscreen",["active":true,"autoHideControls":true])}
    func windowDidExitFullScreen(_ notification:Notification){session.fullScreen=false}
    func windowDidFailToEnterFullScreen(_ window:NSWindow){session.fullScreen=false}
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("scale"), .init("fullscreen"), .init("secureattention"), .space, .init("disconnect")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        let entries:[String:(String,String,Selector)] = [
            "scale":("Fit / actual pixels","arrow.up.left.and.arrow.down.right",#selector(toggleScale)),
            "fullscreen":("Full screen","arrow.up.left.and.arrow.down.right.square",#selector(toggleFullscreen)),
            "secureattention":("Send Ctrl-Alt-Delete","keyboard",#selector(secureAttention)),
            "disconnect":("Disconnect","xmark.circle",#selector(disconnectSession))]
        guard let entry=entries[id.rawValue] else{return nil}
        let item=NSToolbarItem(itemIdentifier:id);item.label=entry.0;item.toolTip=entry.0
        item.image=NSImage(systemSymbolName:entry.1,accessibilityDescription:entry.0);item.target=self;item.action=entry.2;return item
    }
    @objc func toggleScale(){session.fitToWindow.toggle()}
    @objc func toggleFullscreen(){window.toggleFullScreen(nil)}
    @objc func disconnectSession(){if exitOnDisconnect {finish(0)} else {session.disconnect()}}
    @objc func fitDisplay(){session.fitToWindow=true}
    @objc func actualPixels(){session.fitToWindow=false}
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(fitDisplay) {item.state=session.fitToWindow ? .on:.off}
        if item.action == #selector(actualPixels) {item.state=session.fitToWindow ? .off:.on}
        return true
    }
    @objc func secureAttention(){guard session.connected else{return};session.releaseKeys();session.sendKey(0x1d,pressed:true);session.sendKey(0x38,pressed:true);session.sendKey(0x153,pressed:true);session.sendKey(0x153,pressed:false);session.releaseKeys()}
    func event(_ name:String,_ values:[String:Any]) {
        var object=values;object["event"]=name
        if let data=try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]){FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))}
    }
    func finish(_ status:Int32) {guard !finishing else{return};finishing=true;timeout?.invalidate();session.disconnect();DispatchQueue.main.asyncAfter(deadline:.now()+0.15){exit(status)}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){session.disconnect()}
    func windowWillClose(_ notification:Notification){session.disconnect()}
    func installMenus(){
        let menu=NSMenu(),app=NSMenuItem(),sub=NSMenu();sub.addItem(withTitle:"Quit Spice4Mac",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");app.submenu=sub;menu.addItem(app)
        let edit=NSMenuItem(title:"Edit",action:nil,keyEquivalent:""),em=NSMenu(title:"Edit")
        for (name,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {em.addItem(withTitle:name,action:action,keyEquivalent:key)}
        edit.submenu=em;menu.addItem(edit)
        let view=NSMenuItem(title:"View",action:nil,keyEquivalent:""),vm=NSMenu(title:"View")
        for (title,action,key) in [("Fit to Window",#selector(fitDisplay),"0"),("Actual Pixels (100%)",#selector(actualPixels),"1"),("Full Screen",#selector(toggleFullscreen),"f")] {
            let item=vm.addItem(withTitle:title,action:action,keyEquivalent:key);item.target=self
            if key=="f" {item.keyEquivalentModifierMask=[.command,.control]}
        }
        view.submenu=vm;menu.addItem(view);NSApp.mainMenu=menu
    }
}

struct ClientView: View {
    @ObservedObject var session:NativeSession
    @StateObject var profiles = ProfileStore()
    @State var selectedProfile: UUID?
    @State var saveTicket = false
    @State var form=ConnectionForm()
    @State var autoResize=true
    @State var displaySize=CGSize.zero
    @State var validationError:String?
    @State var lastOptions:ConnectionOptions?
    let initialOptions:ConnectionOptions?
    var autoResizeEnabled=true
    var body:some View {
        HStack(spacing:0) {
            if !session.connected && !session.fullScreen {
            VStack(alignment:.leading,spacing:20){
                Label("Spice4Mac",systemImage:"desktopcomputer").font(.title2.bold())
                Text("Your remote workspace").font(.subheadline).foregroundStyle(.secondary)
                Form {
                    if !profiles.profiles.isEmpty {
                        Section("Saved connections") {
                            Picker("Connection", selection: $selectedProfile) {
                                Text("Choose a connection").tag(UUID?.none)
                                ForEach(profiles.profiles) { profile in Text(profile.options.label).tag(Optional(profile.id)) }
                            }.onChange(of: selectedProfile) { _, id in
                                if let profile = profiles.profiles.first(where: { $0.id == id }) { populate(profile.connectionOptions()) }
                            }
                            if let selectedProfile { Button("Remove saved connection",role:.destructive) { profiles.remove(selectedProfile);self.selectedProfile=nil } }
                        }
                    }
                    Section("Connection") {
                        TextField("Host",text:$form.host)
                        TextField(form.tls ? "TLS port":"Port",text:$form.port)
                        Toggle("Use TLS",isOn:$form.tls)
                        SecureField("Ticket / password",text:$form.ticket)
                    }
                    Section("Trust & routing") {
                        TextField("CA certificate path",text:$form.caFile)
                        TextField("Certificate subject",text:$form.subject)
                        TextField("Proxy URL",text:$form.proxy)
                    }
                    Section("Session permissions") {
                        Toggle("Text clipboard",isOn:$form.clipboard)
                        Toggle("Audio output",isOn:$form.audio)
                        Toggle("Resize guest with window",isOn:$autoResize)
                        Toggle("Save ticket in Keychain",isOn:$saveTicket)
                    }
                }.formStyle(.grouped)
                if !form.tls {Label("Unencrypted connection",systemImage:"lock.slash").font(.caption).foregroundStyle(.orange)}
                if let message=validationError ?? session.error {Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)}
                HStack {
                    Button("Open .vv…",action:openFile)
                    Button("Save", action:saveProfile).disabled(form.host.isEmpty)
                    Spacer()
                    Button("Connect",action:connect).buttonStyle(.borderedProminent).disabled(form.host.isEmpty)
                }
                Text("SPICE \(session.backendVersion) · Apple Silicon").font(.caption2).foregroundStyle(.secondary)
            }.padding(20).frame(width:360)
            Divider()
            }
            ZStack {
                Color.black
                if session.connected {
                    RemoteDisplayView(session:session,fitToWindow:session.fitToWindow)
                } else {
                    VStack(spacing:14){
                        Image(systemName:session.state == .failed ? "network.slash":"display").font(.system(size:48,weight:.light)).foregroundStyle(.secondary)
                        Text(session.state.isConnecting ? "Connecting to your workspace…":"Connect to a SPICE desktop").font(.title2)
                        Text("Use a host address or open a .vv connection file.").foregroundStyle(.secondary)
                        if session.state.isConnecting {ProgressView()}
                    }.foregroundStyle(.white)
                }
            }
            .overlay(alignment:.bottomLeading){
                if !session.fullScreen {
                HStack(spacing:8){Circle().fill(session.connected ? .green:.gray).frame(width:6,height:6);Text(session.state.rawValue);if session.agentConnected {Text("Guest agent").foregroundStyle(.secondary)};Spacer();Text("Control + Option releases input")}
                    .font(.caption).padding(10).glassEffect().padding(12).allowsHitTesting(false)
                }
            }
            .onGeometryChange(for:CGSize.self){$0.size} action:{size in
                displaySize=size;resizeGuest()
            }
        }
        .onAppear {autoResize=autoResizeEnabled;if let initialOptions {populate(initialOptions);lastOptions=initialOptions}}
        .onChange(of:session.agentConnected) { _, _ in resizeGuest() }
        .onChange(of:autoResize) { _, _ in resizeGuest() }
    }
    func resizeGuest(){guard autoResize,session.agentConnected,displaySize.width>0,displaySize.height>0 else{return};session.requestResolution(width:Int(displaySize.width),height:Int(displaySize.height))}
    func populate(_ o:ConnectionOptions){form=ConnectionForm(o)}
    func connect(){
        do{let o=try form.connectionOptions();validationError=nil;lastOptions=o;session.connect(o)}catch{validationError=error.localizedDescription}
    }
    func saveProfile() {
        guard form.importedCA == nil || !form.caFile.isEmpty else {validationError="To save this connection, first save its inline CA to a PEM file and enter the path.";return}
        do {
            let o=try form.connectionOptions()
            try profiles.save(ConnectionOptionsForStorage(o),ticket:saveTicket ? o.password:nil);validationError=nil
        } catch {validationError=error.localizedDescription}
    }
    func openFile(){let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false;if panel.runModal() == .OK,let url=panel.url {do{let o=try ConnectionOptions.fromVV(data:readLimited(file:url));populate(o);lastOptions=o;validationError=nil;if o.tlsPort != nil {session.connect(o)}}catch{validationError=error.localizedDescription}}}
}
