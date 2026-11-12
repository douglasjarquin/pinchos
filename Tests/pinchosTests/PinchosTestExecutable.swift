import Foundation

/// Resolves the Pinchos executable that executable-level tests must launch.
///
/// Contract: always use `.build/debug/pinchos`, the stable SwiftPM debug
/// symlink. `swift test` rebuilds that binary from the current checkout.
/// A leftover `.build/release/pinchos` is never selected, even when it is
/// present and executable. Do not hardcode a toolchain triple path; newer
/// SwiftPM layouts still expose this symlink.
enum PinchosTestExecutable {
    static func resolve(
        from root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) throws -> URL {
        let debug = debugBinary(in: root)
        guard fileManager.isExecutableFile(atPath: debug.path) else {
            throw PinchosTestExecutableError.missingDebugBinary(path: debug.path)
        }
        return debug
    }

    static func debugBinary(in root: URL) -> URL {
        root.appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("pinchos")
    }

    static func releaseBinary(in root: URL) -> URL {
        root.appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent("pinchos")
    }
}

enum PinchosTestExecutableError: Error, Equatable, CustomStringConvertible {
    case missingDebugBinary(path: String)

    var description: String {
        switch self {
        case .missingDebugBinary(let path):
            return "could not locate the current-checkout Pinchos executable at \(path); swift test rebuilds .build/debug/pinchos and leftover .build/release/pinchos is never used"
        }
    }
}
