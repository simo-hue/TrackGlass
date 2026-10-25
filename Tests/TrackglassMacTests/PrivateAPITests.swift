import CoreGraphics
import Foundation
import XCTest
@testable import TrackglassMac

final class PrivateAPITests: XCTestCase {
    func testReportsRuntimeCapabilities() {
        let caps = TGPrivateAPIGetCapabilities()
        let again = TGPrivateAPIGetCapabilities()
        XCTAssertEqual(caps.dockSwipe, again.dockSwipe)
        XCTAssertEqual(caps.attachmentSymbol, again.attachmentSymbol)
        XCTAssertTrue(caps.gestureEvents)
        XCTAssertFalse(caps.fluidTouchGesture, "G-NC has not passed")
        XCTAssertFalse(caps.forceEvent, "G-FORCE has not passed")
        if caps.dockSwipe {
            XCTAssertTrue(caps.hidEventClass)
            XCTAssertNotEqual(caps.attachmentSymbol, 0)
        }
        let report = "attachmentSymbol=\(caps.attachmentSymbol), HIDEvent=\(caps.hidEventClass), dockSwipe=\(caps.dockSwipe), gestureEvents=\(caps.gestureEvents), fluidTouchGesture=\(caps.fluidTouchGesture), forceEvent=\(caps.forceEvent)"
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
    }

    func testMissingRuntimeAPIsDisableDockSwipeWithoutDisablingPublicEvents() {
        let caps = TGPrivateAPIProbe({ _ in nil }, { _ in nil })
        XCTAssertFalse(caps.dockSwipe)
        XCTAssertFalse(caps.hidEventClass)
        XCTAssertEqual(caps.attachmentSymbol, 0)
        XCTAssertTrue(caps.gestureEvents)
    }

    func testAlternateSymbolAndIncompleteClassAreHandledSafely() {
        let caps = TGPrivateAPIProbe({ name in
            String(cString: name) == "CGEventSetIOHIDEvent" ? UnsafeMutableRawPointer(bitPattern: 1) : nil
        }, { _ in NSObject.self })
        XCTAssertEqual(caps.attachmentSymbol, 2)
        XCTAssertTrue(caps.hidEventClass)
        XCTAssertFalse(caps.dockSwipe, "A class without the required selectors cannot be used")
    }

    func testPreferredSymbolTakesPriorityAndStillRequiresClass() {
        let caps = TGPrivateAPIProbe({ _ in UnsafeMutableRawPointer(bitPattern: 1) }, { _ in nil })
        XCTAssertEqual(caps.attachmentSymbol, 1)
        XCTAssertFalse(caps.dockSwipe)
    }

    func testPrivateFieldsStayInsidePrivateAPIModule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Mac")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"CGEventField\s*\(\s*rawValue\s*:"#)
        var inspected = 0
        for case let url as URL in files {
            guard ["swift", "h", "m", "mm"].contains(url.pathExtension),
                  !url.path.contains("/Injection/Quartz/PrivateAPI/") else { continue }
            inspected += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), url.path)
        }
        XCTAssertGreaterThan(inspected, 0, "The source boundary test must inspect the actual Mac tree")
    }
}
