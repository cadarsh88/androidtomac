import SwiftUI

@main
struct AndroidToMacApp: App {
    @StateObject private var viewModel = TransferViewModel()

    var body: some Scene {
        MenuBarExtra("Quick Share", systemImage: "arrow.triangle.2.circlepath.circle") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
