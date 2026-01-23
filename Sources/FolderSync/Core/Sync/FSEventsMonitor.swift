import Foundation

public class FSEventsMonitor {
    private var stream: FSEventStreamRef?
    private let path: String
    private let callback: (String) -> Void
    
    public init(path: String, callback: @escaping (String) -> Void) {
        self.path = path
        self.callback = callback
    }
    
    public func start() {
        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext(version: 0, info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), retain: nil, release: nil, copyDescription: nil)
        
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        
        stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(clientCallBackInfo!).takeUnretainedValue()
                let paths = UnsafeBufferPointer(start: eventPaths.assumingMemoryBound(to: UnsafePointer<Int8>.self), count: numEvents)
                
                for i in 0..<numEvents {
                    let path = String(cString: paths[i])
                    monitor.callback(path)
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            flags
        )
        
        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }
    
    public func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    
    deinit {
        stop()
    }
}
