import Foundation
import Combine
import AppKit
import AVFoundation
import ConnectionCore
import CSpiceBridge

public struct RemoteFrame: Sendable {
    public let width, height, stride: Int
    public let pixels: Data
    public let generation: UInt64
}
public struct RemoteCursor: Sendable {
    public let width, height, hotX, hotY: Int
    public let pixels: Data
    public let hidden: Bool
}

private final class CallbackSink: @unchecked Sendable {
    weak var owner: NativeSession?
    let epoch: UUID
    private let lock = NSLock()
    private var pending: RemoteFrame?
    private var scheduled = false
    private var count: UInt64 = UInt64.random(in: 1...(UInt64.max / 2))
    private var audioPending = 0
    init(owner: NativeSession, epoch: UUID) { self.owner = owner; self.epoch = epoch }
    func frame(width: Int, height: Int, stride: Int, pixels: Data) {
        lock.lock(); count &+= 1
        pending = RemoteFrame(width: width, height: height, stride: stride, pixels: pixels, generation: count)
        let shouldSchedule = !scheduled; scheduled = true; lock.unlock()
        if shouldSchedule {
            Task { @MainActor [self] in
                let frame = takeFrame()
                guard let owner, owner.epoch == epoch else { return }
                owner.frame = frame
            }
        }
    }
    private func takeFrame() -> RemoteFrame? { lock.lock(); defer { lock.unlock() }; let value = pending; pending = nil; scheduled = false; return value }
    private func completeAudio() { lock.lock(); audioPending -= 1; lock.unlock() }
    func event(_ type: Int32, _ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, _ data: Data) {
        if type == SF_AUDIO_DATA { lock.lock(); if audioPending >= 16 { lock.unlock(); return }; audioPending += 1; lock.unlock() }
        Task { @MainActor [self] in
            if type == SF_AUDIO_DATA { completeAudio() }
            guard let owner, owner.epoch == epoch else { return }
            owner.receive(type, Int(a), Int(b), Int(c), Int(d), data)
        }
    }
}
private let receiveNative: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32, UnsafePointer<UInt8>?, Int) -> Void = { context, type, a, b, c, d, bytes, size in
    guard let context else { return }
    let unmanaged = Unmanaged<CallbackSink>.fromOpaque(context)
    if type == SF_DESTROYED { unmanaged.release(); return }
    let sink = unmanaged.takeUnretainedValue()
    let data = bytes.map { Data(bytes: $0, count: size) } ?? Data()
    if type == SF_FRAME { sink.frame(width: Int(a), height: Int(b), stride: Int(c), pixels: data) }
    else { sink.event(type, a, b, c, d, data) }
}

@MainActor
public final class NativeSession: ObservableObject {
    @Published public var fitToWindow = true
    @Published public var fullScreen = false
    @Published public private(set) var state = "Idle"
    @Published public private(set) var error: String?
    public let frames = CurrentValueSubject<RemoteFrame?, Never>(nil)
    public fileprivate(set) var frame: RemoteFrame? {
        get { frames.value }
        set { frames.send(newValue) }
    }
    @Published public private(set) var cursor: RemoteCursor?
    @Published public private(set) var connected = false
    @Published public private(set) var agentConnected = false
    @Published public private(set) var serverMouse = false
    @Published public private(set) var audioError: String?
    fileprivate var epoch = UUID()
    private var handle: OpaquePointer?
    private var options: ConnectionOptions?
    private var clipboardTimer: Timer?
    private var pasteboardChange = NSPasteboard.general.changeCount
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var queuedAudio = 0
    private var audioEpoch = UUID()
    private var resizeTask: Task<Void, Never>?
    private var requestedSize: CGSize?
    public init() {}
    public var backendVersion: String { String(cString: sf_backend_version()) }

    public func connect(_ options: ConnectionOptions) {
        disconnect()
        do { try options.validate() } catch { self.error = error.localizedDescription; state = "Failed"; return }
        self.options = options; self.error = nil; state = "Connecting"
        let strings = [options.host, options.port.map(String.init), options.tlsPort.map(String.init), options.password,
                       options.caFile, options.caPEM, options.certificateSubject, options.proxy].map { $0.flatMap { strdup($0) } }
        defer { strings.forEach { free($0) } }
        func ptr(_ i: Int) -> UnsafePointer<CChar>? { strings[i].map { UnsafePointer($0) } }
        var config = SFConfig(host: ptr(0), port: ptr(1), tls_port: ptr(2), password: ptr(3), ca_file: ptr(4), ca_pem: ptr(5), subject: ptr(6), proxy: ptr(7), insecure: options.insecure ? 1 : 0, clipboard: options.clipboard ? 1 : 0, audio: options.audio ? 1 : 0)
        let sink = Unmanaged.passRetained(CallbackSink(owner: self, epoch: epoch))
        handle = sf_session_create(&config, receiveNative, sink.toOpaque())
        if options.clipboard {
            pasteboardChange = NSPasteboard.general.changeCount
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollClipboard() }
            }
        }
    }
    public func disconnect() {
        epoch = UUID()
        resizeTask?.cancel(); resizeTask = nil; requestedSize = nil
        clipboardTimer?.invalidate(); clipboardTimer = nil
        if let handle { sf_session_destroy(handle); self.handle = nil }
        stopAudio(); frame = nil; cursor = nil; connected = false; agentConnected = false; serverMouse = false; state = "Idle"
    }
    public func sendKey(_ code: UInt32, pressed: Bool) { if let handle { sf_key(handle, code, pressed ? 1 : 0) } }
    public func pointer(x: Int, y: Int, buttons: Int) { if let handle { sf_pointer(handle, Int32(clamping:x), Int32(clamping:y), Int32(buttons), 0) } }
    public func relativePointer(dx: Int, dy: Int, buttons: Int) { if let handle { sf_pointer(handle,Int32(clamping:dx),Int32(clamping:dy),Int32(buttons),1) } }
    public func mouseButton(_ button: Int, pressed: Bool, buttons: Int) { if let handle { sf_button(handle,Int32(button),pressed ? 1:0,Int32(buttons)) } }
    public func releaseKeys() { if let handle { sf_release_keys(handle) } }
    public func requestResolution(width: Int, height: Int) {
        let size = CGSize(width:width,height:height)
        guard requestedSize != size else { return }
        requestedSize = size
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, let handle = self.handle else { return }
            sf_resolution(handle,Int32(clamping:width),Int32(clamping:height))
        }
    }
    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard connected, agentConnected, options?.clipboard == true, pasteboardChange != pasteboard.changeCount else { return }
        pasteboardChange = pasteboard.changeCount
        guard let handle, let text = pasteboard.string(forType: .string), let data = text.data(using:.utf8), data.count <= 1_048_576 else { return }
        data.withUnsafeBytes { sf_clipboard(handle,$0.bindMemory(to:UInt8.self).baseAddress,data.count) }
    }
    func receive(_ type: Int32, _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ data: Data) {
        switch type {
        case Int32(SF_STATE):
            state = String(decoding:data,as:UTF8.self); connected = state == "Ready"
            if state == "Disconnected" { stopAudio(); frame = nil; agentConnected = false }
        case Int32(SF_ERROR):
            let message = String(decoding:data,as:UTF8.self)
            disconnect(); error = message; state = "Failed"
        case Int32(SF_CURSOR): cursor = RemoteCursor(width:a,height:b,hotX:c,hotY:d,pixels:data,hidden:a==0)
        case Int32(SF_AGENT): agentConnected = a != 0
        case Int32(SF_MOUSE): serverMouse = a != 0
        case Int32(SF_CLEAR): frame = nil // A surface resize does not disconnect the session.
        case Int32(SF_CLIPBOARD):
            if options?.clipboard == true, let text = String(data:data,encoding:.utf8) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
                pasteboardChange = NSPasteboard.general.changeCount
            }
        case Int32(SF_AUDIO_START): startAudio(rate:a,channels:b)
        case Int32(SF_AUDIO_DATA): playAudio(data)
        case Int32(SF_AUDIO_STOP): stopAudio()
        default: break
        }
    }
    private func startAudio(rate:Int,channels:Int) {
        stopAudio()
        guard let format = AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:AVAudioChannelCount(channels)) else { return }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player); engine.connect(player,to:engine.mainMixerNode,format:format)
        do { try engine.start(); player.play(); audioEngine = engine; audioPlayer = player; audioFormat = format; audioError = nil }
        catch { audioError = "Audio output could not start." }
    }
    private func stopAudio() { audioEpoch = UUID(); audioPlayer?.stop(); audioEngine?.stop(); audioPlayer = nil; audioEngine = nil; audioFormat = nil; queuedAudio = 0 }
    private func playAudio(_ data:Data) {
        guard let player = audioPlayer,let format = audioFormat,queuedAudio < 12 else { return }
        let channels = Int(format.channelCount), count = data.count / (2 * Int(format.channelCount))
        guard count > 0,let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)),let output = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { for channel in 0..<channels {
                let value = raw.loadUnaligned(fromByteOffset:(i*channels+channel)*2,as:Int16.self)
                output[channel][i] = Float(Int16(littleEndian:value)) / 32768
            } }
        }
        queuedAudio += 1; let current = audioEpoch
        player.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
            Task { @MainActor in if let self,self.audioEpoch == current { self.queuedAudio = max(0,self.queuedAudio-1) } }
        }
    }
}
