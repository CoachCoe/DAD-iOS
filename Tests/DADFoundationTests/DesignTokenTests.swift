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

    func testPrimaryButtonPairingMeetsAA() {
        func luminance(_ hex: String) -> Double {
            let digits = hex.dropFirst()
            let channels = stride(from: 0, to: 6, by: 2).map { offset -> Double in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let value = Double(Int(digits[start..<digits.index(start, offsetBy: 2)], radix: 16)!) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        func ratio(_ a: String, _ b: String) -> Double {
            let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
            return (hi + 0.05) / (lo + 0.05)
        }
        let paper = DADTokens.color["paper"]!
        XCTAssertLessThan(ratio(paper, DADTokens.color["brand"]!), 4.5, "brand is the decorative colour, not a text background")
        XCTAssertGreaterThanOrEqual(ratio(paper, DADTokens.color["brand-ink"]!), 4.5)
    }

    func testShorthandHexExpands() {
        XCTAssertNotNil(Color.parseHex("#fff"))
        XCTAssertNotNil(Color.parseHex("#0e1e1e"))
        XCTAssertNil(Color.parseHex("#ffff"))
        XCTAssertNil(Color.parseHex("fff"))
        XCTAssertNil(Color.parseHex("#ggg"))
    }
}
