import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        Window("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 780, minHeight: 680)
                .task {
                    statusItemController.activate()
                    TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 1040, height: 900)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 860, minHeight: 720)
        }
    }
}
