import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    Task {
        let exitCode = await PinchosCLI().run(arguments: arguments)
        Darwin.exit(exitCode)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
