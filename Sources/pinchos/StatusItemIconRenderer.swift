import AppKit
import PinchosCore

/// Turns an `ItemIconSource` into the 16×16 template image drawn on a
/// status-item button. File icons keep the existing `NSImage(contentsOfFile:)`
/// path; symbols go through AppKit's system-symbol initializer so the menu
/// bar supplies the foreground tint (no hard-coded black or white).
///
/// Loaders are injectable so tests can exercise source selection without a
/// live `NSStatusBar` or a particular SF Symbols catalog.
struct StatusItemIconRenderer {
    static let visualSize = NSSize(width: 16, height: 16)

    struct RenderedIcon: Equatable {
        var image: NSImage?
        var isLoaded: Bool
        var diagnosticNote: String?
    }

    var loadFileImage: (String) -> NSImage?
    var loadSymbolImage: (String) -> NSImage?

    static let system = StatusItemIconRenderer(
        loadFileImage: { NSImage(contentsOfFile: $0) },
        loadSymbolImage: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    )

    static func isSymbolAvailable(_ name: String) -> Bool {
        system.loadSymbolImage(name) != nil
    }

    func render(_ source: ItemIconSource?) -> RenderedIcon {
        switch source {
        case nil:
            return RenderedIcon(image: nil, isLoaded: false, diagnosticNote: nil)
        case .file(let path):
            guard let image = loadFileImage(path) else {
                return RenderedIcon(image: nil, isLoaded: false, diagnosticNote: nil)
            }
            prepareFileImage(image)
            return RenderedIcon(image: image, isLoaded: true, diagnosticNote: nil)
        case .symbol(let name):
            guard let image = makeSymbolImage(named: name) else {
                return RenderedIcon(
                    image: nil,
                    isLoaded: false,
                    diagnosticNote: "symbol '\(name)' is unavailable on this macOS version; rendering text-only"
                )
            }
            return RenderedIcon(image: image, isLoaded: true, diagnosticNote: nil)
        }
    }

    func apply(_ rendered: RenderedIcon, to button: NSButton?) {
        button?.image = rendered.image
        if rendered.image != nil {
            button?.imagePosition = .imageLeft
        }
    }

    private func prepareFileImage(_ image: NSImage) {
        image.size = Self.visualSize
        image.isTemplate = true
    }

    private func makeSymbolImage(named name: String) -> NSImage? {
        guard let image = loadSymbolImage(name) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.visualSize.height, weight: .regular)
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.size = Self.visualSize
        configured.isTemplate = true
        return configured
    }
}
