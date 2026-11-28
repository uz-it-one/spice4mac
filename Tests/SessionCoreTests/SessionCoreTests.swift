import XCTest
import Combine
import CSpiceBridge
@testable import SessionCore

final class SessionCoreTests: XCTestCase {
    @MainActor func testSurfaceRecreationKeepsConnection() async {
        let session = NativeSession()
        session.receive(Int32(SF_STATE),0,0,0,0,Data("Ready".utf8))
        session.receive(Int32(SF_CLEAR),0,0,0,0,Data())
        XCTAssertTrue(session.connected, "A guest mode change must not reopen the sidebar and resize again")
        XCTAssertEqual(session.state,.ready)
        XCTAssertNil(session.frame)
        session.receive(Int32(SF_STATE),0,0,0,0,Data("Disconnected".utf8))
        XCTAssertFalse(session.connected)
    }
    @MainActor func testFramesDoNotInvalidateEntireUI() async {
        let session = NativeSession()
        var invalidations=0, frames=0
        let ui=session.objectWillChange.sink { invalidations += 1 }
        let display=session.frames.compactMap{$0}.sink { _ in frames += 1 }
        for n in 1...120 {
            session.frames.send(RemoteFrame(width:1,height:1,stride:4,pixels:Data([0,0,0,0]),generation:UInt64(n)))
        }
        XCTAssertEqual(frames,120)
        XCTAssertEqual(invalidations,0)
        withExtendedLifetime((ui,display)) {}
    }

    @MainActor func testErrorDoesNotPublishTransientIdleOrDuplicates() {
        let session = NativeSession()
        var states: [SessionState] = []
        let observer = session.$state.sink { states.append($0) }
        session.receive(Int32(SF_STATE),0,0,0,0,Data("Connecting".utf8))
        session.receive(Int32(SF_STATE),0,0,0,0,Data("Connecting".utf8))
        session.receive(Int32(SF_STATE),0,0,0,0,Data("Bogus".utf8))
        session.receive(Int32(SF_ERROR),0,0,0,0,Data("TLS verification or handshake failed".utf8))
        XCTAssertEqual(states, [.idle, .connecting, .failed])
        XCTAssertEqual(session.error, "TLS verification or handshake failed")
        withExtendedLifetime(observer) {}
    }

    func testPixelRectUnionAndClamp() {
        let a = PixelRect(x: 10, y: 10, width: 5, height: 5), b = PixelRect(x: 0, y: 12, width: 2, height: 10)
        XCTAssertEqual(a.union(b), PixelRect(x: 0, y: 10, width: 15, height: 12))
        XCTAssertEqual(PixelRect(x: 0, y: 0, width: 0, height: 0).union(a), a)
        XCTAssertEqual(PixelRect(x: -4, y: 90, width: 20, height: 20).clamped(width: 100, height: 100), PixelRect(x: 0, y: 90, width: 16, height: 10))
        XCTAssertTrue(PixelRect(x: 200, y: 0, width: 5, height: 5).clamped(width: 100, height: 100).isEmpty)
        XCTAssertEqual(RemoteFrame(width: 4, height: 3, stride: 16, pixels: Data(count: 48), generation: 1).dirty, .full(width: 4, height: 3))
    }

    func testDisplayGeometryMapsPointsInBothScaleModes() throws {
        // 1600x900 guest in a 800x600 view: letterboxed to 800x450 starting at y=75.
        var g = DisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), remoteWidth: 1600, remoteHeight: 900, fitToWindow: true, backingScale: 2)
        XCTAssertEqual(g.contentRect, CGRect(x: 0, y: 75, width: 800, height: 450))
        XCTAssertNil(g.remotePoint(CGPoint(x: 400, y: 50)), "Letterbox bars are outside the guest")
        let centre = try XCTUnwrap(g.remotePoint(CGPoint(x: 400, y: 300)))
        XCTAssertEqual(centre.x, 800); XCTAssertEqual(centre.y, 450)
        let corner = try XCTUnwrap(g.remotePoint(CGPoint(x: 799.9, y: 524.9)))
        XCTAssertEqual(corner.x, 1599); XCTAssertEqual(corner.y, 899)
        // Actual pixels on a Retina display: one guest pixel per device pixel.
        g.fitToWindow = false
        XCTAssertEqual(g.contentRect.size, CGSize(width: 800, height: 450))
        g.remoteWidth = 0
        XCTAssertNil(g.remotePoint(.zero))
    }

    func testPCM16ConversionMatchesScalarReference() {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 12345, -12345, 2]
        var data = Data(); for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        for (input, offset) in [(data, 0), (Data([0]) + data, 1)] {   // aligned and unaligned storage
            let bytes = input.subdata(in: offset..<input.count)
            let left = UnsafeMutablePointer<Float>.allocate(capacity: 4), right = UnsafeMutablePointer<Float>.allocate(capacity: 4)
            defer { left.deallocate(); right.deallocate() }
            let channels = [left, right]
            channels.withUnsafeBufferPointer { NativeSession.convertPCM16(bytes, channels: 2, frames: 4, into: $0.baseAddress!) }
            for i in 0..<4 {
                XCTAssertEqual(left[i], Float(samples[i * 2]) / 32768)
                XCTAssertEqual(right[i], Float(samples[i * 2 + 1]) / 32768)
            }
        }
    }
}
