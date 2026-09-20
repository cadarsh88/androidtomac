import SwiftUI
import QuickShareEngine

public struct ActiveTransferView: View {
    let progress: TransferProgress
    let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Current File & Cancel
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.currentFileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Receiving via Quick Share...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Cancel Transfer")
            }

            // Progress Bar
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)

            // Telemetry: Sizes, Speed, ETA
            HStack {
                Text(formatBytes(progress.transferredBytes) + " / " + formatBytes(progress.totalBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    Text(progress.formattedSpeed)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(progress.estimatedTimeRemaining)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
