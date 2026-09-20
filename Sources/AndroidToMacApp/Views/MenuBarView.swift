import SwiftUI
import QuickShareEngine

public struct MenuBarView: View {
    @ObservedObject var viewModel: TransferViewModel
    @State private var showingSettings: Bool = false

    public var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .resizable()
                    .frame(width: 22, height: 22)
                    .foregroundColor(viewModel.isRunning ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Android to Mac (Quick Share)")
                        .font(.system(size: 13, weight: .bold))
                    Text(viewModel.currentStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    if viewModel.isRunning {
                        viewModel.stopServer()
                    } else {
                        viewModel.startServer()
                    }
                }) {
                    Image(systemName: viewModel.isRunning ? "power" : "play.fill")
                        .foregroundColor(viewModel.isRunning ? .red : .green)
                }
                .buttonStyle(.plain)
                .help(viewModel.isRunning ? "Turn Off Discovery" : "Turn On Discovery")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Pairing QR Code Toggle
            Button(action: {
                withAnimation {
                    viewModel.toggleQRCode()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.showQRCode ? "chevron.up.circle" : "qrcode")
                    Text(viewModel.showQRCode ? "Hide Pairing QR Code" : "Show Pairing QR Code")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.link)
            .padding(.horizontal, 14)

            if viewModel.showQRCode, let qrImage = viewModel.pairingQRCodeImage {
                VStack(spacing: 8) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .background(Color.white)
                        .cornerRadius(8)
                        .shadow(radius: 2)

                    Text("Scan with phone camera or Quick Share scanner")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Consent Modal (if incoming request)
            if let transfer = viewModel.activeTransfer, viewModel.currentProgress == nil {
                TransferConsentView(
                    transfer: transfer,
                    onAccept: { viewModel.acceptTransfer() },
                    onDecline: { viewModel.declineTransfer() }
                )
                .padding(.horizontal, 8)
            }

            // Live Progress (if transferring)
            if let progress = viewModel.currentProgress {
                ActiveTransferView(
                    progress: progress,
                    onCancel: { viewModel.cancelTransfer() }
                )
                .padding(.horizontal, 12)
            }

            // Recent Transfers
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT TRANSFERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)

                if viewModel.transferHistory.isEmpty {
                    Text("No transfers yet. Open Quick Share on your Android phone to send files.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                } else {
                    List {
                        ForEach(viewModel.transferHistory.prefix(5)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.fileNames.first ?? "File")
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(item.senderName) • \(item.formattedSize)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if let firstURL = item.savedURLs.first {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([firstURL])
                                    }) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(viewModel.transferHistory.count) * 44, 180))
                }
            }

            Divider()

            // Footer Actions
            HStack {
                Button(action: {
                    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(downloads)
                    }
                }) {
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
