import SwiftUI

final class TBDisplaySenderAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        TBDisplaySenderService.shared.stopAll(closeContext: .appQuit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            TBSenderDiagnosticsLogger.shared.finishProcess(reason: "app_quit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TBDisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(TBDisplaySenderAppDelegate.self)
    private var appDelegate
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        Window("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 660, minHeight: 620)
                .task {
                    statusItemController.activate()
                    TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 760, height: 820)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 860, minHeight: 720)
        }
    }
}
