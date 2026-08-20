import Foundation

/// Watches a config file for changes without ever falling back to a periodic
/// poll, including while the file (or its parent directories) do not exist yet.
///
/// Strategy: attach one `O_EVTONLY` `DispatchSourceFileSystemObject` to the
/// deepest existing ancestor of `path` (which may be the file itself, a parent
/// directory, or an arbitrarily higher ancestor if nothing below exists yet).
/// Any relevant event re-resolves the deepest existing ancestor from scratch
/// and moves the watch there - deeper as directories/the file appear, or back
/// up an ancestor on delete/rename - rather than trusting kqueue's coalesced
/// flags to describe one exact mutation.
///
/// While the file itself exists, a second "guard" source also watches its
/// immediate parent directory for delete/rename. This is necessary because a
/// kqueue vnode source tracks the *vnode*, not the path: renaming an ancestor
/// directory out from under an already-open file does not deliver any event
/// to a source watching that file directly, only to a source watching the
/// directory that was actually the target of the rename.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.pinchos.watcher")

    /// Bumped on every start()/stop() so async work items captured under an
    /// older generation are provably stale and become no-ops, even if they
    /// were already enqueued (e.g. a debounce timer or a backoff retry).
    private var generation = 0
    private var isRunning = false

    private var fileSource: DispatchSourceFileSystemObject?
    private var parentGuardSource: DispatchSourceFileSystemObject?
    private var changeWorkItem: DispatchWorkItem?
    private var backoffWorkItem: DispatchWorkItem?
    /// Path + whether it is the config file itself for the currently attached
    /// source. Used to ignore no-op directory events (busy ancestors) that do
    /// not change where we should be watching.
    private var attachedTarget: WatchTarget?

    /// Exceptional-failure retry delay. This path is not the normal way missing
    /// config is handled - see `WatchTarget` resolution below - it only fires if
    /// `open()` fails on a path `stat()` just confirmed exists (e.g. a TOCTOU
    /// race or a transient descriptor-table exhaustion), so it must stay rare
    /// and coarse rather than a disguised 500ms poll.
    private let backoffDelay: TimeInterval

    /// Test-only observation hook: called once per real `open()` attempt inside
    /// `attach()`, letting tests distinguish genuine event-driven reattachment
    /// from a disguised timer without depending on timing alone.
    private let onAttachAttempt: (() -> Void)?

    init(
        path: String,
        onChange: @escaping () -> Void,
        backoffDelay: TimeInterval = 10.0,
        onAttachAttempt: (() -> Void)? = nil
    ) {
        self.path = path
        self.onChange = onChange
        self.backoffDelay = backoffDelay
        self.onAttachAttempt = onAttachAttempt
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.generation += 1
            self.attach(generation: self.generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.generation += 1
            self.changeWorkItem?.cancel()
            self.changeWorkItem = nil
            self.backoffWorkItem?.cancel()
            self.backoffWorkItem = nil
            self.cancelActiveSources()
        }
    }

    // MARK: - Attachment

    private func attach(generation: Int) {
        guard generation == self.generation, isRunning else { return }

        let watchTarget = Self.deepestExistingAncestor(of: path)
        onAttachAttempt?()
        guard let fd = openSource(watchTarget.path) else {
            attachedTarget = nil
            scheduleBackoff(generation: generation)
            return
        }

        let eventMask: DispatchSource.FileSystemEvent = watchTarget.isTarget
            ? [.write, .delete, .rename, .extend]
            : [.write, .delete, .rename]

        let newSource = makeSource(fd: fd, eventMask: eventMask) { [weak self] flags in
            self?.handleFileOrAncestorEvent(generation: generation, flags: flags, isTarget: watchTarget.isTarget)
        }
        fileSource = newSource
        attachedTarget = watchTarget

        var guardSource: DispatchSourceFileSystemObject?
        if watchTarget.isTarget {
            guardSource = attachParentGuard(of: watchTarget.path, generation: generation)
        }

        newSource.resume()
        guardSource?.resume()

        // The world may have moved on between resolving watchTarget and the
        // sources becoming live (e.g. the file was created in that window).
        // Re-resolve once more now that we're guaranteed not to miss anything
        // *after* this point, and immediately retry if reality already diverged
        // instead of waiting for some unrelated future event to notice.
        let settled = Self.deepestExistingAncestor(of: path)
        guard settled.path == watchTarget.path, settled.isTarget == watchTarget.isTarget else {
            cancelActiveSources()
            attach(generation: generation)
            return
        }

        if watchTarget.isTarget {
            scheduleChange(generation: generation)
        }
    }

    private func attachParentGuard(of filePath: String, generation: Int) -> DispatchSourceFileSystemObject? {
        let parentPath = (filePath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, let parentFD = openSource(parentPath) else { return nil }

        let guardSource = makeSource(fd: parentFD, eventMask: [.delete, .rename]) { [weak self] _ in
            // Only delete/rename of the parent directory itself lands here (see
            // the type-level doc comment); any occurrence means the ancestry
            // under our feet changed, so re-resolve from scratch.
            self?.reattach(generation: generation)
        }
        parentGuardSource = guardSource
        return guardSource
    }

    private func handleFileOrAncestorEvent(generation: Int, flags: DispatchSource.FileSystemEvent, isTarget: Bool) {
        guard generation == self.generation, isRunning else { return }

        if isTarget {
            if flags.contains(.delete) || flags.contains(.rename) {
                // The vnode we were watching is gone (deleted, or replaced/moved
                // away by a rename); this source is dead regardless of what now
                // exists at `path`, so always re-resolve and reopen.
                reattach(generation: generation)
            } else {
                // In-place write/extend on the file we're already watching
                // (including the "new file" side of an atomic rename-replace,
                // which lands here after the replace event moved the watch onto
                // the new inode): no need to reattach, just coalesce a reload.
                scheduleChange(generation: generation)
            }
            return
        }

        // Directory contents changed while we're watching an ancestor because
        // the config file doesn't exist yet. Don't infer the exact mutation
        // from the flags (directory events coalesce); re-resolve and only
        // reattach when the deepest existing ancestor actually moved. A busy
        // ancestor (e.g. a shared temp directory with unrelated sibling
        // churn) would otherwise thrash open/close for events that don't
        // concern our target path at all.
        let next = Self.deepestExistingAncestor(of: path)
        guard let attached = attachedTarget, attached.path == next.path, attached.isTarget == next.isTarget else {
            reattach(generation: generation)
            return
        }
    }

    private func reattach(generation: Int) {
        guard generation == self.generation, isRunning else { return }
        cancelActiveSources()
        attach(generation: generation)
    }

    private func cancelActiveSources() {
        fileSource?.cancel()
        fileSource = nil
        parentGuardSource?.cancel()
        parentGuardSource = nil
        attachedTarget = nil
    }

    // MARK: - Dispatch source construction

    private func openSource(_ path: String) -> Int32? {
        let fd = open(path, O_EVTONLY)
        return fd >= 0 ? fd : nil
    }

    private func makeSource(
        fd: Int32,
        eventMask: DispatchSource.FileSystemEvent,
        onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: eventMask, queue: queue)
        source.setEventHandler { [weak source] in
            onEvent(source?.data ?? [])
        }
        // `fd` is a local, immutable capture owned by this one source instance:
        // this closure can only ever close the exact descriptor opened for it,
        // never a descriptor belonging to a source created before or after it.
        source.setCancelHandler {
            close(fd)
        }
        return source
    }

    private func scheduleChange(generation: Int) {
        changeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.generation, self.isRunning else { return }
            self.changeWorkItem = nil
            self.onChange()
        }
        changeWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func scheduleBackoff(generation: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.attach(generation: generation)
        }
        backoffWorkItem = workItem
        queue.asyncAfter(deadline: .now() + backoffDelay, execute: workItem)
    }

    // MARK: - Ancestor resolution

    private struct WatchTarget {
        let path: String
        let isTarget: Bool
    }

    private static func deepestExistingAncestor(of path: String) -> WatchTarget {
        var info = stat()
        if stat(path, &info) == 0 {
            return WatchTarget(path: path, isTarget: true)
        }

        var directory = (path as NSString).deletingLastPathComponent
        while true {
            if stat(directory, &info) == 0 {
                return WatchTarget(path: directory, isTarget: false)
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty {
                return WatchTarget(path: "/", isTarget: false)
            }
            directory = parent
        }
    }
}
