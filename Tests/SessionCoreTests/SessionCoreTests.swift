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
        XCTAssertEqual(session.state,"Ready")
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
}
