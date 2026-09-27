import AppKit
import Combine

func tbMenuBarByteRateText(gigabitsPerSecond: Double) -> String {
    let bytesPerSecond = max(0, gigabitsPerSecond) * 1_000_000_000 / 8
    if bytesPerSecond >= 1_000_000_000 {
        return "\(Int((bytesPerSecond / 1_000_000_000).rounded())) GB/s"
    }
    if bytesPerSecond >= 1_000_000 {
        return "\(Int((bytesPerSecond / 1_000_000).rounded())) MB/s"
    }
    if bytesPerSecond >= 1_000 {
        return "\(Int((bytesPerSecond / 1_000).rounded())) KB/s"
    }
    return "\(Int(bytesPerSecond.rounded())) B/s"
}

@MainActor
final class TBDisplaySenderStatusItemController: NSObject {
    private let service: TBDisplaySenderService
    nonisolated(unsafe) private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    nonisolated(unsafe) private var statsTimer: Timer?

    init(service: TBDisplaySenderService) {
        self.service = service
        super.init()
        bind()
        observeApplicationLifecycle()
    }

    deinit {
        statsTimer?.invalidate()
        let item = statusItem
        DispatchQueue.main.async { [item] in
            if let item {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
    }

    private func bind() {
        service.$showsMenuBarIcon
            .sink { [weak self] _ in
                guard let self, self.hasActivated else { return }
                self.syncVisibility()
            }
            .store(in: &cancellables)

        service.objectWillChange
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.activate()
            }
            .store(in: &cancellables)
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        syncVisibility()
        statsTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusItem()
            }
        }
        RunLoop.main.add(statsTimer!, forMode: .common)
    }

    private func syncVisibility() {
        if service.showsMenuBarIcon {
            ensureStatusItem()
            refreshStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "TargetBridge")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)

        // Assign one menu instance for the lifetime of the status item and
        // repopulate it lazily in `menuNeedsUpdate(_:)`. Swapping `item.menu`
        // out from under an open/tracking menu leaves macOS holding an
        // orphaned, invisible menu window that swallows clicks at the menu's
        // location — the "dead zone" below the menu bar icon.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        item.button?.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)
        guard let button = item.button else { return }
        if let session = service.sessions.first(where: { $0.isStreaming }) ??
            service.sessions.first(where: { $0.isConnected }) {
            let fps = max(
                session.liveMetrics.senderFPS,
                Int(session.liveMetrics.receiverFPS.rounded())
            )
            let bandwidth = session.liveMetrics.senderNetworkGbps
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineSpacing = -2
            paragraph.minimumLineHeight = 8
            paragraph.maximumLineHeight = 9
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: 9,
                weight: .medium
            )
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: "● ",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemGreen,
                    .paragraphStyle: paragraph
                ]
            ))
            title.append(NSAttributedString(
                string: "\(fps) FPS\n",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            ))
            title.append(NSAttributedString(
                string: "● ",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemBlue,
                    .paragraphStyle: paragraph
                ]
            ))
            title.append(NSAttributedString(
                string: tbMenuBarByteRateText(
                    gigabitsPerSecond: bandwidth
                ),
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            ))
            button.attributedTitle = title
            button.toolTip =
                "TargetBridge\nFrame rate: \(fps) FPS\n" +
                "Thunderbolt throughput: " +
                tbMenuBarByteRateText(gigabitsPerSecond: bandwidth)
            button.cell?.usesSingleLineMode = false
            button.cell?.lineBreakMode = .byClipping
            button.imagePosition = .noImage
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.cell?.usesSingleLineMode = true
            button.imagePosition = .imageOnly
        }
    }

    private func rebuildMenuItems(in menu: NSMenu) {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "TargetBridge", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusItem = NSMenuItem(title: service.summaryStatusText(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if !service.localInterfaces.isEmpty {
            let ipItem = NSMenuItem(title: TBDisplaySenderL10n.topBarIP(service.language, service.localInterfaceSummaryText), action: nil, keyEquivalent: "")
            ipItem.isEnabled = false
            menu.addItem(ipItem)
        }

        for session in service.sessions {
            let line = "\(service.sessionTitle(for: session)): \(session.statusText)"
            let sessionItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            sessionItem.isEnabled = false
            menu.addItem(sessionItem)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: TBDisplaySenderL10n.showMainWindow(service.language),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let addItem = NSMenuItem(
            title: TBDisplaySenderL10n.addSessionButton(service.language),
            action: #selector(addSession),
            keyEquivalent: ""
        )
        addItem.target = self
        menu.addItem(addItem)

        let stopAllItem = NSMenuItem(
            title: TBDisplaySenderL10n.stopAllButton(service.language),
            action: #selector(stopAll),
            keyEquivalent: ""
        )
        stopAllItem.target = self
        stopAllItem.isEnabled = service.anyConnected
        menu.addItem(stopAllItem)

        let hideItem = NSMenuItem(
            title: TBDisplaySenderL10n.hideMenuBarIcon(service.language),
            action: #selector(hideStatusItem),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: TBDisplaySenderL10n.quitApp(service.language), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // Menu-item handlers run while the menu is still dismissing. Doing work
    // synchronously here (activating the app, ordering windows front, mutating
    // observed session state) interrupts the menu window's fade-out: its alpha
    // animates to 0 but the window is never closed, leaving an invisible
    // menu-layer window that swallows clicks at the menu's footprint. Deferring
    // to the next runloop tick lets the menu fully tear down first.
    private func runAfterMenuDismissal(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    @objc
    private func showMainWindow() {
        runAfterMenuDismissal {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc
    private func addSession() {
        runAfterMenuDismissal { [service] in
            service.addSession()
        }
    }

    @objc
    private func stopAll() {
        runAfterMenuDismissal { [service] in
            service.stopAll()
        }
    }

    @objc
    private func hideStatusItem() {
        runAfterMenuDismissal { [service] in
            service.showsMenuBarIcon = false
        }
    }

    @objc
    private func quitApp() {
        runAfterMenuDismissal {
            NSApp.terminate(nil)
        }
    }
}

extension TBDisplaySenderStatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(in: menu)
    }
}
