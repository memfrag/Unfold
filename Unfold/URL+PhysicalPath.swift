import Foundation

extension URL {
    /// The physical path, with every symlink resolved.
    ///
    /// Not `resolvingSymlinksInPath()`, and not `standardizedFileURL`: both map
    /// `/private/tmp` back to `/tmp` and `/private/var` to `/var`, which is the
    /// opposite of what is wanted wherever two paths have to be compared.
    /// `FileManager` hands out the physical spelling, while a folder opened by
    /// path may carry the symlinked one — and the two are compared as strings by
    /// WebKit's file sandbox (which refuses the load, blank page, no
    /// explanation) and by the folder browser deciding whether a link points
    /// inside the folder it is showing.
    var physicalURL: URL {
        guard let resolved = realpath(path, nil) else { return self }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
