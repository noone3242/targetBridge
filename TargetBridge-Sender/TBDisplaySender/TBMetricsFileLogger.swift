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
        previousURL = logsDirectory.appendingPathComponent(
            "sender-metrics.previous.jsonl"
        )
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
                        "TargetBridge: metrics writer backlog full; " +
                        "dropping oldest samples"
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

final class TBSenderDiagnosticsLogger: @unchecked Sendable {
    static let shared = TBSenderDiagnosticsLogger()

    let processInstanceID: String
    let logFileURL: URL
    let runStateFileURL: URL

    private let queue = DispatchQueue(
        label: "com.targetbridge.sender.diagnostics-file",
        qos: .utility
    )
    private let previousURL: URL
    private let maximumBytes: UInt64 = 8 * 1024 * 1024

    init(
        logsDirectoryOverride: URL? = nil,
        processInstanceIDOverride: String? = nil
    ) {
        let fileManager = FileManager.default
        let logsDirectory: URL
        if let logsDirectoryOverride {
            logsDirectory = logsDirectoryOverride
        } else {
            let base: URL
            if ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] != nil {
                base = fileManager.temporaryDirectory.appendingPathComponent(
                    "TargetBridgeTests-" +
                    "\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            } else {
                base = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent(
                            "Library/Application Support",
                            isDirectory: true
                        )
            }
            logsDirectory = base
                .appendingPathComponent("TargetBridge", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
        }
        logFileURL = logsDirectory.appendingPathComponent("sender.jsonl")
        previousURL = logsDirectory.appendingPathComponent(
            "sender.previous.jsonl"
        )
        runStateFileURL = logsDirectory.appendingPathComponent(
            "run-state.json"
        )
        processInstanceID = processInstanceIDOverride ??
            (
                "\(TBDisplaySenderBuildInfo.gitCommit)-" +
                "\(ProcessInfo.processInfo.processIdentifier)-" +
                "\(DispatchTime.now().uptimeNanoseconds / 1_000_000)"
            )

        queue.sync {
            do {
                try fileManager.createDirectory(
                    at: logsDirectory,
                    withIntermediateDirectories: true
                )
                let previousUnclean = readPreviousUnclean()
                if fileManager.fileExists(atPath: logFileURL.path) {
                    let attributes = try? fileManager.attributesOfItem(
                        atPath: logFileURL.path
                    )
                    let size =
                        (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                    if size > 0 {
                        if fileManager.fileExists(atPath: previousURL.path) {
                            try fileManager.removeItem(at: previousURL)
                        }
                        try fileManager.moveItem(
                            at: logFileURL,
                            to: previousURL
                        )
                    }
                }
                try writeRunState(cleanExit: false, reason: "running")
                writeEvent(
                    "process_start",
                    fields: [
                        "version": TBDisplaySenderBuildInfo.marketingVersion,
                        "build": TBDisplaySenderBuildInfo.buildNumber,
                        "commit": TBDisplaySenderBuildInfo.gitCommit,
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "previousRunUnclean": previousUnclean
                    ]
                )
                if previousUnclean {
                    writeEvent("unclean_previous_run", fields: [:])
                }
            } catch {
                NSLog(
                    "TargetBridge: unable to initialize sender diagnostics: %@",
                    error.localizedDescription
                )
            }
        }
    }

    func append(event: String, fields: [String: Any] = [:]) {
        queue.async { [self] in
            writeEvent(event, fields: fields)
        }
    }

    func finishProcess(reason: String) {
        queue.sync {
            writeEvent(
                "process_exit",
                fields: ["reason": reason]
            )
            do {
                try writeRunState(cleanExit: true, reason: reason)
            } catch {
                writeEvent(
                    "run_state_write_error",
                    fields: [
                        "operation": "mark_clean_exit",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func readPreviousUnclean() -> Bool {
        guard let data = try? Data(contentsOf: runStateFileURL),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return false }
        return object["cleanExit"] as? Bool == false
    }

    private func writeRunState(cleanExit: Bool, reason: String) throws {
        let object: [String: Any] = [
            "timestampMs": currentTimestampMs(),
            "processInstanceID": processInstanceID,
            "cleanExit": cleanExit,
            "reason": reason
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(to: runStateFileURL, options: .atomic)
    }

    private func writeEvent(_ event: String, fields: [String: Any]) {
        var object = fields
        object["timestampMs"] = currentTimestampMs()
        object["monotonicMs"] =
            DispatchTime.now().uptimeNanoseconds / 1_000_000
        object["processInstanceID"] = processInstanceID
        object["event"] = event
        guard JSONSerialization.isValidJSONObject(object) else {
            NSLog(
                "TargetBridge: sender diagnostics event is not valid JSON: %@",
                event
            )
            return
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            data.append(0x0A)
            try rotateIfNeeded(adding: UInt64(data.count))
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                guard FileManager.default.createFile(
                    atPath: logFileURL.path,
                    contents: nil
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            NSLog(
                "TargetBridge: unable to write sender diagnostics: %@",
                error.localizedDescription
            )
        }
    }

    private func rotateIfNeeded(adding bytes: UInt64) throws {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(
            atPath: logFileURL.path
        )
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size + bytes > maximumBytes else { return }
        if fileManager.fileExists(atPath: previousURL.path) {
            try fileManager.removeItem(at: previousURL)
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            try fileManager.moveItem(at: logFileURL, to: previousURL)
        }
    }

    private func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
