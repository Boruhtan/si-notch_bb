import CoreServices
import Foundation

/// File events make old, resumed rollouts discoverable without polling the
/// entire session history. All access stays on the observer's serial queue.
final class CodexRolloutWatcher {
    private let root: URL
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var rescan = true
    private var changed: Set<URL> = []

    init(root: URL, queue: DispatchQueue) {
        self.root = root
        self.queue = queue
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<CodexRolloutWatcher>.fromOpaque(info).takeUnretainedValue()
            let urls = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for index in 0..<min(count, urls.count) {
                let flag = flags[index]
                let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
                    kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                    kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
                if flag & dropped != 0 || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    watcher.rescan = true
                } else {
                    watcher.changed.insert(URL(fileURLWithPath: urls[index]).standardizedFileURL)
                }
                if watcher.changed.count > 4096 { watcher.rescan = true; watcher.changed.removeAll() }
            }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// nil requests a complete discovery, including after dropped events or an
    /// unavailable watcher. Already tracked files are always polled as well.
    func takeChanges() -> [URL]? {
        defer { rescan = false; changed.removeAll(keepingCapacity: true) }
        return stream == nil || rescan ? nil : Array(changed)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        rescan = true
    }

    deinit { stop() }
}
