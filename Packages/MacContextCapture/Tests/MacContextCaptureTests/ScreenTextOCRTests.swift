import XCTest
@testable import MacContextCapture

final class ScreenTextOCRTests: XCTestCase {
    func testDropsBlankAndWhitespaceLines() {
        let text = ScreenTextOCR.cleanedText(
            fromLines: ["  Subject: schedule ", "", "   ", "Agenda for Monday"],
            maxLines: 40,
            maxChars: 2000
        )
        XCTAssertEqual(text, "Subject: schedule\nAgenda for Monday")
    }

    func testCapsLineCount() {
        let lines = (1...100).map { "line \($0)" }
        let text = ScreenTextOCR.cleanedText(fromLines: lines, maxLines: 3, maxChars: 2000)
        XCTAssertEqual(text, "line 1\nline 2\nline 3")
    }

    func testCapsCharacterCount() {
        let text = ScreenTextOCR.cleanedText(
            fromLines: [String(repeating: "a", count: 50)],
            maxLines: 40,
            maxChars: 10
        )
        XCTAssertEqual(text.count, 10)
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(ScreenTextOCR.cleanedText(fromLines: [], maxLines: 40, maxChars: 2000), "")
    }
}
