import AppKit
import SwiftUI
import XCTest
@testable import NookKit

@MainActor
final class HTMLContentVisualLayoutTests: XCTestCase {
    /// Regression: a list nested inside another list subtracts marker width
    /// twice. The former nested `HStack` measured enough row height but still
    /// drew borderline text as one truncated line, leaving the reserved second
    /// line blank. Verify pixels are actually drawn on multiple text lines.
    func testNestedListRowsDrawTheirWrappedContinuationLines() throws {
        let html = """
        <ul><li>
          <p><strong>차등 테스트</strong>는 800개 이상의 프로그램을 Node와 네이티브 바이너리에서 각각 실행해 stdout, stderr, 종료 코드를 바이트 단위로 비교함</p>
          <ul>
            <li><p>숫자 출력은 최단 왕복 표현을 따르며, 100만 개의 <code>doubles</code>에 대해 Node와 퍼즈 검증을 수행함</p></li>
            <li><p>서버는 두 구현 모두에 실제 클라이언트 드라이버를 연결해 동일한 동작을 검증함</p></li>
          </ul>
        </li></ul>
        """
        let content = HTMLContentView(
            html: html,
            selectable: false,
            typography: ReaderTypography(
                font: .system,
                fontSize: 18,
                lineHeightMultiple: 1.7,
                letterSpacingEM: 0
            )
        )
        .frame(width: 480, alignment: .leading)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 480, height: nil)

        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let metrics = inkMetrics(in: bitmap)
        XCTAssertGreaterThanOrEqual(metrics.lineBands, 7)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh - metrics.lastRow, 14)
    }

    private func inkMetrics(in bitmap: NSBitmapImageRep) -> (lineBands: Int, lastRow: Int) {
        var occupiedRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            var inkPixels = 0
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if color.alphaComponent > 0.15, luminance < 0.8 {
                    inkPixels += 1
                }
            }
            if inkPixels >= 3 { occupiedRows.append(y) }
        }

        var bands = 0
        var previous: Int?
        for row in occupiedRows {
            if previous.map({ row - $0 > 6 }) ?? true { bands += 1 }
            previous = row
        }
        return (bands, occupiedRows.last ?? 0)
    }
}
