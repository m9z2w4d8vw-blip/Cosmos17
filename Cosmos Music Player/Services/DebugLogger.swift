//
//  DebugLogger.swift
//  Cosmos Music Player
//
//  Lightweight in-app debug logger. Writes to a rotating file on disk so logs
//  can be inspected/exported directly from the device, without relying on
//  Xcode being attached or Apple's Settings > Analytics data (which is often
//  delayed, sampled, or missing symbols entirely on TestFlight/ad-hoc builds).
//

import Foundation
import Combine

enum DebugLogLevel: String {
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

struct DebugLogEntry: Identifiable {
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

/// Singleton debug logger. Use `DebugLogger.shared.log(...)` from anywhere.
/// Safe to call from any thread/actor context — internal queue serializes writes.
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    /// Most recent entries, newest last. Capped for in-memory display.
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxInMemoryEntries = 1000
    private let maxFileSizeBytes = 2 * 1024 * 1024 // 2 MB, then rotate
    private let queue = DispatchQueue(label: "dev.clq.CosmosMusicPlayer.debuglogger", qos: .utility)

    private let logFileURL: URL
    private let rotatedFileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDir = docs.appendingPathComponent("DebugLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("debug.log")
        rotatedFileURL = logsDir.appendingPathComponent("debug.previous.log")

        log(.info, category: "DebugLogger", "Session started", file: #file, function: #function, line: #line)
    }

    // MARK: - Public logging API

    func info(_ message: String, category: String = "General",
              file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }

    func warning(_ message: String, category: String = "General",
                 file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }

    func error(_ message: String, category: String = "General",
               file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }

    /// Generic entry point (also used internally).
    func log(_ level: DebugLogLevel, category: String = "General", _ message: String,
              file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let entry = DebugLogEntry(timestamp: Date(), level: level, category: category,
                                   message: message, file: fileName, function: function, line: line)

        // Mirror to Xcode console immediately, same style as the existing print() calls.
        print(entry.formatted)

        // Update in-memory list on main thread (drives the UI).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxInMemoryEntries {
                self.entries.removeFirst(self.entries.count - self.maxInMemoryEntries)
            }
        }

        // Persist to disk off the main thread.
        queue.async { [weak self] in
            self?.appendToFile(entry.formatted)
        }
    }

    // MARK: - File handling

    private func appendToFile(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!

        rotateIfNeeded()

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

    // MARK: - Export / management

    /// Combined contents of current + rotated log file, for sharing/export.
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

    /// URL suitable for a share sheet (writes a fresh export snapshot to a temp file).
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
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.logFileURL)
            try? FileManager.default.removeItem(at: self.rotatedFileURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }
}
