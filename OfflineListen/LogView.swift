import SwiftUI
import UIKit

struct LogView: View {
    @EnvironmentObject private var log: LogStore
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No activity yet",
                        systemImage: "doc.plaintext",
                        description: "Start a download and the steps, statuses, and errors will stream in here."
                    )
                } else {
                    logScroll
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) {
                        log.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(log.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = log.plainText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(log.entries.isEmpty)
                }
            }
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(log.entries) { entry in
                        LogRow(time: log.time(for: entry), entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .onChange(of: log.entries.count) { _ in
                if let last = log.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = log.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct LogRow: View {
    let time: String
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(entry.category.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)

            Text("\(entry.level.symbol) \(entry.message)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
