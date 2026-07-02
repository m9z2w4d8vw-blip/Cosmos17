//
//  DebugLogView.swift
//  Cosmos Music Player
//
//  Simple in-app viewer for DebugLogger output. Add a way to reach this
//  screen from Settings (e.g. a hidden "Debug Log" row, or a shake gesture)
//  so it's reachable on-device without a cable attached.
//

import SwiftUI

struct DebugLogView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @State private var shareURL: URL?
    @State private var showingClearConfirm = false
    @State private var filterLevel: DebugLogLevel?

    private var filteredEntries: [DebugLogEntry] {
        guard let filterLevel = filterLevel else { return logger.entries }
        return logger.entries.filter { $0.level == filterLevel }
    }

    var body: some View {
        VStack(spacing: 0) {
            levelFilterBar

            if filteredEntries.isEmpty {
                Spacer()
                Text("No log entries yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredEntries) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: logger.entries.count) { _ in
                        if let last = filteredEntries.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task {
                            shareURL = await DebugLogger.shared.exportFileURL()
                        }
                    } label: {
                        Label("Export / Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map { IdentifiableURL(url: $0) } },
            set: { shareURL = $0?.url }
        )) { wrapper in
            ActivityShareSheet(activityItems: [wrapper.url])
        }
        .confirmationDialog("Clear all debug logs?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) {
                DebugLogger.shared.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var levelFilterBar: some View {
        HStack(spacing: 8) {
            filterChip(title: "All", level: nil)
            filterChip(title: "Info", level: .info)
            filterChip(title: "Warn", level: .warning)
            filterChip(title: "Error", level: .error)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func filterChip(title: String, level: DebugLogLevel?) -> some View {
        Button {
            filterLevel = level
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(filterLevel == level ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundStyle(filterLevel == level ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func logRow(_ entry: DebugLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.level.emoji)
                Text(DebugLogEntry.formatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.category)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
            Text("\(entry.file):\(entry.line)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(rowBackground(for: entry.level))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rowBackground(for level: DebugLogLevel) -> Color {
        switch level {
        case .info: return Color.gray.opacity(0.08)
        case .warning: return Color.yellow.opacity(0.12)
        case .error: return Color.red.opacity(0.12)
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIKit share sheet wrapper (no SwiftUI ShareLink dependency needed, works iOS 16+).
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        DebugLogView()
    }
}