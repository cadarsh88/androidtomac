import SwiftUI
import QuickShareEngine

public struct TransferConsentView: View {
    let transfer: TransferMetadata
    let onAccept: () -> Void
    let onDecline: () -> Void

    public var body: some View {
        VStack(spacing: 16) {
            // Header: Device Info
            HStack(spacing: 12) {
                Image(systemName: transfer.sender.type.systemImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.sender.name)
                        .font(.headline)
                    Text("wants to share files with you")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // 4-Digit Auth PIN Display
            if let pin = transfer.pinCode {
                VStack(spacing: 4) {
                    Text("VERIFICATION PIN")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(pin)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(8)

                    Text("Confirm this code matches your phone's screen")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // File Information
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(transfer.files.count) file\(transfer.files.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(transfer.formattedTotalSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(transfer.files) { file in
                            HStack {
                                Image(systemName: "doc")
                                    .foregroundColor(.secondary)
                                Text(file.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .font(.caption)
                                Spacer()
                                Text(file.formattedSize)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            // Action Buttons
            HStack(spacing: 12) {
                Button("Decline", role: .cancel) {
                    onDecline()
                }
                .keyboardShortcut(.cancelAction)

                Button("Accept") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
