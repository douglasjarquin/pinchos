import AppKit
import Darwin
import Dispatch
import PinchosCore

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    let shutdownCoordinator = MainActor.assumeIsolated {
        let coordinator = ShutdownCoordinator(
            signalNumbers: [SIGTERM, SIGINT],
            cleanup: {},
            forcedExit: { code in Darwin.exit(code) },
            autoFinishOnCleanup: false
        )
        coordinator.start()
        return coordinator
    }
    Task { @MainActor in
        let exitCode = await PinchosCLI(shutdownCoordinator: shutdownCoordinator).run(arguments: arguments)
        let finalExitCode = await shutdownCoordinator.finish(exitCode: exitCode)
        shutdownCoordinator.stop()
        Darwin.exit(finalExitCode)
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
