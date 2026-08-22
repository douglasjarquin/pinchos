import AppKit
import XCTest
@testable import PinchosCore
@testable import pinchos

final class StatusItemIconRendererTests: XCTestCase {
    private func makeTestImage() -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32))
    }

    func testNeitherSourceIsTextOnly() {
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in XCTFail("file loader should not run"); return nil },
            loadSymbolImage: { _ in XCTFail("symbol loader should not run"); return nil }
        )
        let rendered = renderer.render(nil)
        XCTAssertNil(rendered.image)
        XCTAssertFalse(rendered.isLoaded)
        XCTAssertNil(rendered.diagnosticNote)
    }

    func testFileSourceUsesTemplateSixteenBySixteenWithoutInvokingSymbolLoader() {
        let fileImage = makeTestImage()
        var loadedPath: String?
        let renderer = StatusItemIconRenderer(
            loadFileImage: { path in
                loadedPath = path
                return fileImage
            },
            loadSymbolImage: { _ in
                XCTFail("symbol loader must not run for a file source")
                return nil
            }
        )

        let rendered = renderer.render(.file("/tmp/status.png"))

        XCTAssertEqual(loadedPath, "/tmp/status.png")
        XCTAssertTrue(rendered.isLoaded)
        XCTAssertTrue(rendered.image === fileImage)
        XCTAssertEqual(rendered.image?.size, StatusItemIconRenderer.visualSize)
        XCTAssertEqual(rendered.image?.isTemplate, true)
        XCTAssertNil(rendered.diagnosticNote)
    }

    func testKnownSymbolUsesNativeTemplateImageAtSixteenBySixteen() {
        let symbolImage = makeTestImage()
        var loadedName: String?
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in
                XCTFail("file loader must not run for a symbol source")
                return nil
            },
            loadSymbolImage: { name in
                loadedName = name
                return symbolImage
            }
        )

        let rendered = renderer.render(.symbol("chart.bar.fill"))

        XCTAssertEqual(loadedName, "chart.bar.fill")
        XCTAssertTrue(rendered.isLoaded)
        XCTAssertNotNil(rendered.image)
        XCTAssertEqual(rendered.image?.size, StatusItemIconRenderer.visualSize)
        XCTAssertEqual(rendered.image?.isTemplate, true)
        XCTAssertNil(rendered.diagnosticNote)
    }

    func testUnavailableSymbolIsTextOnlyWithDiagnosticAndDoesNotCrash() {
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in nil },
            loadSymbolImage: { _ in nil }
        )

        let rendered = renderer.render(.symbol("pinchos.definitely.not.a.real.symbol"))

        XCTAssertNil(rendered.image)
        XCTAssertFalse(rendered.isLoaded)
        XCTAssertTrue(rendered.diagnosticNote?.contains("pinchos.definitely.not.a.real.symbol") == true)
        XCTAssertTrue(rendered.diagnosticNote?.contains("unavailable") == true)
    }

    func testSystemRendererAcceptsChartBarFillWithoutHardCodedColors() {
        let rendered = StatusItemIconRenderer.system.render(.symbol("chart.bar.fill"))
        XCTAssertTrue(rendered.isLoaded, "chart.bar.fill must exist on the macOS 14 catalog")
        XCTAssertEqual(rendered.image?.isTemplate, true)
        XCTAssertEqual(rendered.image?.size, StatusItemIconRenderer.visualSize)
        XCTAssertNil(rendered.diagnosticNote)
    }

    func testMissingFileFallsBackWithoutDiagnosticNote() {
        let renderer = StatusItemIconRenderer(
            loadFileImage: { _ in nil },
            loadSymbolImage: { _ in
                XCTFail("symbol loader must not run for a file source")
                return nil
            }
        )
        let rendered = renderer.render(.file("/nonexistent/pinchos-icon.png"))
        XCTAssertNil(rendered.image)
        XCTAssertFalse(rendered.isLoaded)
        XCTAssertNil(rendered.diagnosticNote)
    }
}
