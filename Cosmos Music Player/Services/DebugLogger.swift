//
//  DebugLogger.swift
//  Cosmos Music Player
//
//  Lightweight in-app debug logger. Writes to a rotating file on disk so logs
//  can be inspected/exported directly from the device, without relying on
//  Xcode being attached or Apple's Settings > Analytics data (which is often
//  delayed, sampled, or missing symbols entirely on TestFlight/ad-hoc builds).
//
//  Design notes (Swift 6 strict concurrency):
//  - All file I/O lives on `DebugLogFileStore`, an actor, so writes are
//    serialized safely without a manual DispatchQueue.
//  - `DebugLogger` itself is @MainActor (it drives @Published UI state), but
//    its logging methods are `nonisolated` so `DebugLogger.shared.info(...)`
//    can still be called synchronously from any thread/closure, exactly like
//    the print() calls it replaces.
//

import Foundation
import Combine

enum DebugLogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "🛑"
        }
    }
}

struct DebugLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: DebugLogLevel
    let category: String
    let message: String
    let file: String
    let function: String
    let line: Int

    var formatted: String {
        let ts = DebugLogEntry.formatter.string(from: timestamp)
        return "[\(ts)] \(level.emoji) [\(category)] \(message)  (\(file):\(line) \(function))"
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - File store (actor = safe serialized file I/O, no manual queue needed)

actor DebugLogFileStore {
    // Immutable, Sendable (URL) stored properties on an actor are safe to
    // read from outside without `await` — used by DebugLogger for the
    // synchronous nonisolated logging path.
    nonisolated let logFileURL: URL
    nonisolated let rotatedFileURL: URL

    private let maxFileSizeBytes = 2 * 1024 * 1024 // 2 MB, then rotate

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDir = docs.appendingPathComponent("DebugLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("debug.log")
        rotatedFileURL = logsDir.appendingPathComponent("debug.previous.log")
    }

    func append(_ line: String) {
        rotateIfNeeded()
        let data = (line + "\n").data(using: .utf8)!

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int, size > maxFileSizeBytes else { return }

        try? FileManager.default.removeItem(at: rotatedFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedFileURL)
    }

    func exportText() -> String {
        var combined = ""
        if let previous = try? String(contentsOf: rotatedFileURL, encoding: .utf8) {
            combined += "----- Previous log -----\n" + previous + "\n"
        }
        if let current = try? String(contentsOf: logFileURL, encoding: .utf8) {
            combined += "----- Current log -----\n" + current
        }
        return combined.isEmpty ? "No log data yet." : combined
    }

    func exportFileURL() -> URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CosmosDebugLog-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try exportText().write(to: tmp, atomically: true, encoding: .utf8)
            return tmp
        } catch {
            print("DebugLogger: failed to write export file: \(error.localizedDescription)")
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: logFileURL)
        try? FileManager.default.removeItem(at: rotatedFileURL)
    }
}

// MARK: - Public-facing logger

/// Singleton debug logger. Use `DebugLogger.shared.log(...)` from anywhere,
/// on any thread — logging methods are `nonisolated` and safe to call
/// synchronously, matching how the old print() calls were used.
@MainActor
final class DebugLogger: ObservableObject {
    // Suggested by the compiler itself for exactly this pattern: the
    // instance is created once, never reassigned, and all its mutable
    // state (entries) is only ever touched on MainActor internally.
    nonisolated(unsafe) static let shared = DebugLogger()

    /// Most recent entries, newest last. Capped for in-memory display.
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxInMemoryEntries = 1000
    private nonisolated let fileStore = DebugLogFileStore()

    private init() {
        log(.info, category: "DebugLogger", "Session started", file: #file, function: #function, line: #line)
    }

    // MARK: - Public logging API (callable from any thread)

    nonisolated func info(_ message: String, category: String = "General",
              file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }

    nonisolated func warning(_ message: String, category: String = "General",
                 file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }

    nonisolated func error(_ message: String, category: String = "General",
               file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }

    /// Generic entry point (also used internally).
    nonisolated func log(_ level: DebugLogLevel, category: String = "General", _ message: String,
              file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let entry = DebugLogEntry(timestamp: Date(), level: level, category: category,
                                   message: message, file: fileName, function: function, line: line)

        // Mirror to Xcode console immediately, same style as the print() calls it replaces.
        print(entry.formatted)

        // Update @Published state on the main actor (drives the UI).
        Task { @MainActor [weak self] in
            self?.appendToMemory(entry)
        }

        // Persist to disk via the file-store actor (serialized, off the main thread).
        Task {
            await self.fileStore.append(entry.formatted)
        }
    }

    @MainActor
    private func appendToMemory(_ entry: DebugLogEntry) {
        entries.append(entry)
        if entries.count > maxInMemoryEntries {
            entries.removeFirst(entries.count - maxInMemoryEntries)
        }
    }

    // MARK: - Export / management

    /// Combined contents of current + rotated log file, for sharing/export.
    func exportText() async -> String {
        await fileStore.exportText()
    }

    /// URL suitable for a share sheet (writes a fresh export snapshot to a temp file).
    func exportFileURL() async -> URL? {
        await fileStore.exportFileURL()
    }

    nonisolated func clear() {
        Task { @MainActor [weak self] in
            self?.entries.removeAll()
        }
        Task {
            await fileStore.clear()
        }
    }
}