import AppKit
import MetalKit
import SwiftUI
import Combine
import SessionCore

/// Native display surface. SPICE decoding remains in the protocol engine.
struct RemoteDisplayView: NSViewRepresentable {
    @ObservedObject var session: NativeSession
    var fitToWindow: Bool

    func makeNSView(context: Context) -> SpiceMetalView {
        let view = SpiceMetalView()
        view.session = session
        view.observeFrames(session)
        return view
    }

    func updateNSView(_ view: SpiceMetalView, context: Context) {
        view.session = session
        view.fitToWindow = fitToWindow
        view.updateCursor(session.cursor)
    }
}

@MainActor
final class SpiceMetalView: MTKView, MTKViewDelegate {
    weak var session: NativeSession?
    var fitToWindow = true { didSet { if oldValue != fitToWindow { needsDisplay = true } } }
    private var redrawPending = false
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameSubscription: AnyCancellable?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    @MainActor private final class TextureSlot {
        let texture: MTLTexture
        var readers = 0
        init(_ texture:MTLTexture){self.texture=texture}
    }
    private var slots: [TextureSlot] = []
    private var currentSlot: TextureSlot?
    private var pendingFrame: RemoteFrame?
    private var remoteWidth = 0
    private var remoteHeight = 0
    private var frameGeneration: UInt64?
    private var tracking: NSTrackingArea?
    private var buttons = 0
    private var pressedKeys = Set<UInt32>()
    private var remoteCursor: NSCursor = .arrow
    private let diagnostics = ProcessInfo.processInfo.environment["SPICE4MAC_DIAGNOSTICS"] == "1"
    private var sampleStart = CACurrentMediaTime()
    private var receivedFrames = 0, submittedFrames = 0
    private var uploadMilliseconds = 0.0
    private var scrollRemainder: CGFloat = 0

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.025, 0.03, 0.04, 1)
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        delegate = self
        queue = device?.makeCommandQueue()
        configurePipeline()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private func configurePipeline() {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Raster { float4 position [[position]]; float2 uv; };
        vertex Raster spice_vertex(uint id [[vertex_id]]) {
            const float2 positions[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
            const float2 coords[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
            Raster out; out.position=float4(positions[id],0,1); out.uv=coords[id]; return out;
        }
        fragment float4 spice_fragment(Raster in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(image.sample(s,in.uv).rgb,1);
        }
        """
        do {
            guard let device else { return }
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "spice_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spice_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("SPICE4Mac Metal pipeline unavailable: %@", String(describing: error))
        }
    }

    func observeFrames(_ session: NativeSession) {
        frameSubscription = session.frames.sink { [weak self] frame in self?.update(frame:frame) }
    }
    func updateCursor(_ cursor:RemoteCursor?) {if let cursor {setRemoteCursor(cursor)}}
    func update(frame: RemoteFrame?) {
        guard let frame else {
            currentSlot = nil
            slots.removeAll()
            pendingFrame = nil
            frameGeneration = nil
            remoteWidth = 0
            remoteHeight = 0
            needsDisplay = true
            return
        }
        let uploadStart = CACurrentMediaTime()
        if frame.generation != frameGeneration || frame.width != remoteWidth || frame.height != remoteHeight {
            guard frame.width > 0, frame.height > 0,
                  frame.width <= 16384, frame.height <= 16384,
                  frame.stride >= frame.width * 4,
                  frame.pixels.count >= frame.stride * frame.height else { return }
            if frame.width != remoteWidth || frame.height != remoteHeight || slots.isEmpty {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:frame.width,height:frame.height,mipmapped:false)
                descriptor.usage = .shaderRead;descriptor.storageMode = .shared
                // Readers are retained by their command buffers during a mode change.
                slots = (0..<3).compactMap { _ in device?.makeTexture(descriptor:descriptor).map(TextureSlot.init) }
                currentSlot = nil
            }
            guard let slot = slots.first(where:{$0.readers == 0}) else {pendingFrame=frame;return}
            pendingFrame=nil
            frame.pixels.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    slot.texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                                         mipmapLevel: 0, withBytes: base, bytesPerRow: frame.stride)
                }
            }
            receivedFrames += 1
            uploadMilliseconds += (CACurrentMediaTime()-uploadStart)*1000
            currentSlot = slot
            remoteWidth = frame.width
            remoteHeight = frame.height
            frameGeneration = frame.generation
            needsDisplay = true
        }
    }

    private var contentRect: CGRect {
        guard remoteWidth > 0, remoteHeight > 0 else { return bounds }
        let scale: CGFloat
        if fitToWindow {
            scale = min(bounds.width / CGFloat(remoteWidth), bounds.height / CGFloat(remoteHeight))
        } else {
            scale = 1 / (window?.backingScaleFactor ?? 1)
        }
        let size = CGSize(width: CGFloat(remoteWidth) * scale, height: CGFloat(remoteHeight) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { redrawPending = true; return }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = queue?.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        let gate = inFlight
        let submittedSlot = currentSlot
        submittedSlot?.readers += 1
        redrawPending = false
        command.addCompletedHandler { [weak self] _ in
            gate.signal()
            Task { @MainActor [weak self] in
                submittedSlot?.readers -= 1
                guard let self else {return}
                if let pending=self.pendingFrame {self.update(frame:pending)}
                if self.redrawPending {self.needsDisplay = true}
            }
        }
        if let texture = submittedSlot?.texture, let pipeline {
            let scaleX = drawableSize.width / max(bounds.width, 1)
            let scaleY = drawableSize.height / max(bounds.height, 1)
            let rect = contentRect
            encoder.setViewport(MTLViewport(originX: rect.minX * scaleX, originY: rect.minY * scaleY,
                width: rect.width * scaleX, height: rect.height * scaleY, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        submittedFrames += 1
        let elapsed = CACurrentMediaTime()-sampleStart
        if diagnostics && elapsed >= 1 {
            fputs(String(format:"display received_fps=%.1f submitted_fps=%.1f upload_ms=%.3f size=%dx%d\n",Double(receivedFrames)/elapsed,Double(submittedFrames)/elapsed,uploadMilliseconds/Double(max(1,receivedFrames)),remoteWidth,remoteHeight),stderr)
            sampleStart=CACurrentMediaTime();receivedFrames=0;submittedFrames=0;uploadMilliseconds=0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowLostFocus() { releaseInput() }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    private func releaseInput() {
        session?.releaseKeys()
        for (button, bit) in [(1, 1), (2, 2), (3, 4)] where buttons & bit != 0 {
            buttons &= ~bit
            session?.mouseButton(button, pressed: false, buttons: buttons)
        }
        pressedKeys.removeAll()
        buttons = 0
    }

    private func point(_ event: NSEvent) -> (Int, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let rect = contentRect
        guard remoteWidth > 0, remoteHeight > 0, rect.contains(p) else { return nil }
        return (min(remoteWidth - 1, max(0, Int((p.x - rect.minX) / rect.width * CGFloat(remoteWidth)))),
                min(remoteHeight - 1, max(0, Int((p.y - rect.minY) / rect.height * CGFloat(remoteHeight)))))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let (x, y) = point(event) else { NSCursor.arrow.set(); return }
        remoteCursor.set()
        if session?.serverMouse == true { session?.relativePointer(dx: Int(event.deltaX), dy: Int(event.deltaY), buttons: buttons) } else { session?.pointer(x: x, y: y, buttons: buttons) }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    private func mouse(_ event: NSEvent, button: Int, bit: Int, down: Bool) {
        if down {
            guard point(event) != nil else { return }
            window?.makeFirstResponder(self)
            mouseMoved(with: event)
            buttons |= bit
        } else {
            guard buttons & bit != 0 else { return }
            buttons &= ~bit
        }
        session?.mouseButton(button, pressed: down, buttons: buttons)
    }
    override func mouseDown(with event: NSEvent) { mouse(event, button: 1, bit: 1, down: true) }
    override func mouseUp(with event: NSEvent) { mouse(event, button: 1, bit: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, button: 3, bit: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, button: 3, bit: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, button: 2, bit: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, button: 2, bit: 2, down: false) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { remoteCursor.set() }

    override func scrollWheel(with event: NSEvent) {
        guard point(event) != nil else { return }
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 12 : 1)
        let steps = min(20, Int(abs(scrollRemainder)))
        guard steps > 0 else { return }
        let button = scrollRemainder > 0 ? 4 : 5
        scrollRemainder -= CGFloat(steps) * (scrollRemainder > 0 ? 1 : -1)
        for _ in 0..<steps {
            session?.mouseButton(button, pressed: true, buttons: buttons)
            session?.mouseButton(button, pressed: false, buttons: buttons)
        }
    }

    /// Control + Option hands keyboard and mouse back to macOS.
    private func releaseCaptureIfRequested(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains([.control, .option]) else { return false }
        releaseInput()
        window?.makeFirstResponder(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if releaseCaptureIfRequested(event) { return }
        guard let code = Self.keyCodes[event.keyCode] else { return }
        pressedKeys.insert(code)
        session?.sendKey(code, pressed: true)
    }
    override func keyUp(with event: NSEvent) {
        guard let code = Self.keyCodes[event.keyCode], pressedKeys.remove(code) != nil else { return }
        session?.sendKey(code, pressed: false)
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57 {
            session?.sendKey(0x3a, pressed: true)
            session?.sendKey(0x3a, pressed: false)
            return
        }
        guard let code = Self.keyCodes[event.keyCode], let flag = Self.modifiers[event.keyCode] else { return }
        let down = event.modifierFlags.contains(flag) && !pressedKeys.contains(code)
        if down { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        session?.sendKey(code, pressed: down)
        _ = releaseCaptureIfRequested(event)
    }

    private func setRemoteCursor(_ cursor: RemoteCursor) {
        if cursor.hidden {
            remoteCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
            return
        }
        guard cursor.width > 0, cursor.height > 0, cursor.width <= 512, cursor.height <= 512,
              let image = FrameImage.cgImage(width: cursor.width, height: cursor.height,
                    stride: cursor.width * 4, pixels: cursor.pixels) else { return }
        remoteCursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: cursor.width, height: cursor.height)),
            hotSpot: NSPoint(x: max(0, min(cursor.width - 1, cursor.hotX)), y: max(0, min(cursor.height - 1, cursor.hotY))))
    }

    private static let modifiers: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift, 58: .option, 61: .option,
        59: .control, 62: .control, 57: .capsLock
    ]
    // macOS virtual key codes → PC XT set 1, 0x100 denotes an extended key.
    private static let keyCodes: [UInt16: UInt32] = [
        0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,
        11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:0x02,19:0x03,
        20:0x04,21:0x05,22:0x07,23:0x06,24:0x0d,25:0x0a,26:0x08,27:0x0c,28:0x09,
        29:0x0b,30:0x1b,31:0x18,32:0x16,33:0x1a,34:0x17,35:0x19,36:0x1c,37:0x26,
        38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,43:0x33,44:0x35,45:0x31,46:0x32,
        47:0x34,48:0x0f,49:0x39,50:0x29,51:0x0e,53:0x01,54:0x15c,55:0x15b,
        56:0x2a,57:0x3a,58:0x38,59:0x1d,60:0x36,61:0x138,62:0x11d,
        65:0x53,67:0x37,69:0x4e,71:0x45,75:0x135,76:0x11c,78:0x4a,81:0x59,
        82:0x52,83:0x4f,84:0x50,85:0x51,86:0x4b,87:0x4c,88:0x4d,89:0x47,91:0x48,92:0x49,
        96:0x3f,97:0x40,98:0x41,99:0x3d,100:0x42,101:0x43,103:0x57,105:0x64,
        106:0x67,107:0x65,109:0x44,111:0x58,113:0x66,114:0x152,115:0x147,
        116:0x149,117:0x153,118:0x3e,119:0x14f,120:0x3c,121:0x151,122:0x3b,
        123:0x14b,124:0x14d,125:0x150,126:0x148,
        10:0x56,93:0x7d,94:0x73,102:0x7b,104:0x79
    ]
}

enum FrameImage {
    static func cgImage(width: Int, height: Int, stride: Int, pixels: Data, alpha: Bool = true) -> CGImage? {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              stride >= width * 4, pixels.count >= stride * height,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedFirst : CGImageAlphaInfo.noneSkipFirst).rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(frame: RemoteFrame, to url: URL) throws {
        guard let image = cgImage(width: frame.width, height: frame.height, stride: frame.stride, pixels: frame.pixels, alpha:false),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Spice4Mac", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to encode the remote framebuffer."])
        }
        try data.write(to: url, options: .atomic)
    }
}
