import SwiftUI
import XCTest
@testable import DADFoundation

final class DesignTokenTests: XCTestCase {
    /// An unparsed token silently falls back to `.primary` (black in light mode), which once
    /// turned every `#fff` card and secondary button black. Every shipped token must resolve.
    func testEveryColorTokenParses() {
        for (name, value) in DADTokens.color {
            XCTAssertTrue(Color.parseHex(value) != nil || Color.parseRGBA(value) != nil, "token \(name) = \(value) does not parse")
        }
    }

    func testShorthandHexExpands() {
        XCTAssertNotNil(Color.parseHex("#fff"))
        XCTAssertNotNil(Color.parseHex("#0e1e1e"))
        XCTAssertNil(Color.parseHex("#ffff"))
        XCTAssertNil(Color.parseHex("fff"))
        XCTAssertNil(Color.parseHex("#ggg"))
    }
}
