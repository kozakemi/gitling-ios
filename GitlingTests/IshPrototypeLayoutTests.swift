#if ISH_PROTOTYPE
import SwiftUI
import UIKit
import XCTest
@testable import Gitling

@MainActor final class IshPrototypeLayoutTests: XCTestCase {
    func testFixtureConsoleFitsDuoAndAccessibilityWidthsWithoutStartingKernel() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [240, 346, 466, 619, 951] {
            for font in [DynamicTypeSize.large, .accessibility3] {
                let content = IshPrototypePanel(transcript: String(repeating: "git status: clean\n", count: 80), running: false, command: .constant("git status"), execute: {})
                    .environment(\.dynamicTypeSize, font)
                let host = UIHostingController(rootView: content)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
                defer { window.isHidden = true; window.rootViewController = nil }
                func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let fields = descendants(host.view).compactMap { $0 as? UITextField }
                let field = try XCTUnwrap(fields.first)
                let frame = field.convert(field.bounds, to: host.view)
                XCTAssertGreaterThan(frame.width, 60)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, host.view.bounds.width + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.height + 1)
                XCTAssertFalse(field.isEnabled, "Unsafe interactive execution stays disabled")
            }
        }
    }
}
#endif
