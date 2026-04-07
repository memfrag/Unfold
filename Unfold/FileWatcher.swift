import Foundation

class FileWatcher {
    private let path: String
    private let onEvent: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(path: String, onEvent: @escaping () -> Void) {
        self.path = path
        self.onEvent = onEvent
        startWatching()
    }

    private func startWatching() {
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.startWatching()
                    self.onEvent()
                }
            } else {
                self.onEvent()
            }
        }

        source.setCancelHandler { [fd = fileDescriptor] in
            close(fd)
        }

        source.resume()
        self.source = source
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
