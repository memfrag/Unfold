import Foundation
import CoreServices

/// Watches a folder tree for changes made by anything other than us — a file
/// dropped in from Finder, a `git checkout`, a script writing a new page — and
/// calls `onChange` on the main queue.
///
/// FSEvents rather than the per-file `DispatchSource` that `FileWatcher` uses:
/// one stream covers the whole tree however deep it goes, including directories
/// created after the window opened, and it costs one stream rather than a file
/// descriptor per folder. Which path changed is deliberately not reported on —
/// the browser reconciles the directories it has actually loaded, and that is
/// cheaper to reason about than mapping every event back to a node.
final class FolderWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// FSEvents' own coalescing window.
    private let latency: CFTimeInterval = 0.3

    /// A debounce on top of it: one logical operation — unpacking an archive,
    /// switching branches — arrives as a string of batches, and each would
    /// otherwise re-read the tree.
    private let coalesceInterval: TimeInterval = 0.2

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleCallback()
            },
            &context,
            // The physical path: FSEvents reports resolved paths, and a root
            // reached through a symlink would otherwise never match them.
            [url.physicalURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
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
