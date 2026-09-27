import Foundation

final class TBMetricsFileLogger: @unchecked Sendable {
    static let shared = TBMetricsFileLogger()

    private let queue = DispatchQueue(
        label: "com.targetbridge.sender.metrics-file",
        qos: .utility
    )
    private let logURL: URL
    private let previousURL: URL
    private let maximumBytes: UInt64 = 32 * 1024 * 1024
    private let pendingLock = NSLock()
    private var pendingLines: [Data] = []
    private var drainScheduled = false
    private var reportedOverflow = false
    private let maximumPendingLines = 120

    private init() {
        let logsDirectory = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("logs", isDirectory: true)
        logURL = logsDirectory.appendingPathComponent("sender-metrics.jsonl")
        previousURL = logsDirectory.appendingPathComponent("sender-metrics.previous.jsonl")
    }

    func append(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object) else {
            NSLog("TargetBridge: metrics JSON contains an unsupported value")
            return
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            data.append(0x0A)
            let line = data
            pendingLock.lock()
            if pendingLines.count >= maximumPendingLines {
                pendingLines.removeFirst()
                if !reportedOverflow {
                    reportedOverflow = true
                    NSLog(
                        "TargetBridge: metrics writer backlog full; dropping oldest samples"
                    )
                }
            }
            pendingLines.append(line)
            let shouldSchedule = !drainScheduled
            drainScheduled = true
            pendingLock.unlock()
            if shouldSchedule {
                queue.async { [self] in
                    drain()
                }
            }
        } catch {
            NSLog(
                "TargetBridge: unable to serialize metrics JSON: %@",
                error.localizedDescription
            )
        }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard !pendingLines.isEmpty else {
                drainScheduled = false
                reportedOverflow = false
                pendingLock.unlock()
                return
            }
            let line = pendingLines.removeFirst()
            pendingLock.unlock()
            write(line)
        }
    }

    private func write(_ data: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let attributes = try? fileManager.attributesOfItem(
                atPath: logURL.path
            )
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            if size + UInt64(data.count) > maximumBytes {
                if fileManager.fileExists(atPath: previousURL.path) {
                    try fileManager.removeItem(at: previousURL)
                }
                if fileManager.fileExists(atPath: logURL.path) {
                    try fileManager.moveItem(at: logURL, to: previousURL)
                }
            }
            if !fileManager.fileExists(atPath: logURL.path) {
                guard fileManager.createFile(
                    atPath: logURL.path,
                    contents: nil
                ) else {
                    NSLog(
                        "TargetBridge: unable to create metrics log at %@",
                        logURL.path
                    )
                    return
                }
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer {
                do {
                    try handle.close()
                } catch {
                    NSLog(
                        "TargetBridge: unable to close metrics log: %@",
                        error.localizedDescription
                    )
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog(
                "TargetBridge: unable to write metrics log %@: %@",
                logURL.path,
                error.localizedDescription
            )
        }
    }
}
