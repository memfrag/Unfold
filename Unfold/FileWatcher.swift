import Foundation

/// Watches a single file for external changes, calling `onChange` on the main
/// queue when it's modified by something other than us.
///
/// Two wrinkles this has to handle:
///
/// - Most editors save *atomically* — they write a temporary file and rename it
///   over the original — which leaves our file descriptor pointing at an inode
///   that no longer has the path. A `.rename`/`.delete` event therefore re-opens
///   the path rather than merely reporting a change; otherwise the watcher goes
///   deaf after the first external save.
/// - A single logical save can emit several events, so they're coalesced behind
///   a short debounce.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// Window over which a burst of events collapses into one callback.
    private let coalesceInterval: TimeInterval = 0.15
    /// Grace period before re-opening after an atomic replace, so the
    /// replacement file has appeared at the path.
    private let reopenDelay: TimeInterval = 0.1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let flags = self.source?.data else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopen()
            } else {
                self.scheduleCallback()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Re-attach to the path after an atomic replace, then report the change.
    private func reopen() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + reopenDelay) { [weak self] in
            guard let self else { return }
            self.start()
            self.scheduleCallback()
        }
    }

    private func scheduleCallback() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }
}
