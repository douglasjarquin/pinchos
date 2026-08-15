import Foundation

final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.pinchos.watcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var retryWorkItem: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            self?.openAndWatch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.retryWorkItem?.cancel()
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func openAndWatch() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry()
            return
        }
        fileDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = newSource.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopen()
            }
        }
        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.fileDescriptor)
        }
        source = newSource
        newSource.resume()
        onChange()
    }

    private func reopen() {
        source?.cancel()
        source = nil
        scheduleRetry(delay: 0.15)
    }

    private func scheduleRetry(delay: TimeInterval = 0.5) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.openAndWatch()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
