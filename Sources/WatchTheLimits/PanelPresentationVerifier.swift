import AppKit

/// Exercises the live AppKit window, rather than only rendering its content offscreen.
@MainActor
enum PanelPresentationVerifier {
    static func run() async throws {
        guard #available(macOS 26.0, *) else {
            throw failure("Live glass verification requires macOS 26 or newer.")
        }
        try AppResources.verifyPackagedLocation()
        print("Resources: \(AppResources.bundle.bundleURL.path)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        guard let button = item.button else { throw failure("No status button.") }
        button.title = "Usage test"
        let model = UsageModel(demo: true)
        let panel = GlassUsagePanel(model: model)
        defer { panel.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        print("Screens: \(NSScreen.screens.map { $0.visibleFrame }), status window: \(String(describing: button.window?.frame)), status screen: \(String(describing: button.window?.screen))")
        NSApp.activate(ignoringOtherApps: true)
        panel.show(relativeTo: button)
        try await Task.sleep(nanoseconds: 300_000_000)
        print("Initial panel: \(panel.frame), visible: \(panel.isVisible), key: \(panel.isKeyWindow), active: \(NSApp.isActive)")
        guard panel.isVisible, panel.frame.width == 302, panel.frame.height >= 300,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else {
            throw failure("Panel did not open with visible content on screen.")
        }
        try verifyRoundedShell(panel)
        // A status-item click can be forwarded after activation/presentation.
        // It belongs to the opening interaction and must not dismiss the panel.
        let openingClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 1,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1)!
        NSApp.postEvent(openingClick, atStart: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard panel.isVisible else { throw failure("The delayed opening click dismissed the panel.") }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard panel.isVisible else { throw failure("An outdated activation notification dismissed the active panel.") }
        let collapsed = panel.frame
        model.showSettings = true
        try await Task.sleep(nanoseconds: 300_000_000)
        print("Expanded panel: \(panel.frame), visible: \(panel.isVisible), active: \(NSApp.isActive)")
        guard panel.isVisible, panel.frame.width == collapsed.width,
              panel.frame.height > collapsed.height, abs(panel.frame.maxY - collapsed.maxY) < 1 else {
            throw failure("Panel did not expand while keeping its top edge anchored.")
        }
        try verifyRoundedShell(panel)
        model.showSettings = false
        try await Task.sleep(nanoseconds: 300_000_000)
        guard panel.frame.size == collapsed.size else { throw failure("Panel did not collapse.") }
        try verifyRoundedShell(panel)
        panel.cancelOperation(nil)
        guard !panel.isVisible else { throw failure("Escape did not dismiss the panel.") }
        NSApp.activate(ignoringOtherApps: true)
        panel.show(relativeTo: button)
        try await Task.sleep(nanoseconds: 200_000_000)
        print("Reopened panel: \(panel.frame), visible: \(panel.isVisible), active: \(NSApp.isActive)")
        guard panel.isVisible, panel.frame.size == collapsed.size else { throw failure("Panel did not reopen.") }
        let outsideClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, eventNumber: 1,
                                             clickCount: 1, pressure: 1)!
        NSApp.postEvent(outsideClick, atStart: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard !panel.isVisible else { throw failure("A new outside click did not dismiss the panel.") }
        NSApp.activate(ignoringOtherApps: true)
        model.showAvailableResets = true
        panel.show(relativeTo: button)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let credit = model.resetCredits.first else { throw failure("No synthetic reset available.") }
        model.activateReset(credit)
        guard model.resetInteraction.confirmationID == credit.id else { throw failure("Reset did not enter confirmation.") }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: panel.windowNumber, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard !panel.isVisible, model.resetInteraction.confirmationID == nil else {
            throw failure("Escape did not close the panel and cancel unconfirmed reset selection.")
        }
        panel.show(relativeTo: button)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard model.showAvailableResets, model.resetInteraction.confirmationID == nil else {
            throw failure("Reopening did not preserve section expansion independently of confirmation.")
        }
        model.activateReset(credit)
        model.activateReset(credit)
        panel.close()
        guard model.hasPendingReset else { throw failure("Closing cancelled the submitted reset.") }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        guard !model.hasPendingReset, model.resetSummary?.count == 1,
              model.indicator.quotas.first?.value == "100%" else {
            throw failure("Background reset did not finish and refresh the indicator.")
        }
        panel.show(relativeTo: button)
        try await Task.sleep(nanoseconds: 100_000_000)
        try verifyRoundedShell(panel)
        print("Reset confirmation, Escape cancellation, remembered expansion, and background completion verified with synthetic data.")
        print("Panel presentation verification passed.")
    }

    private static func verifyRoundedShell(_ panel: NSWindow) throws {
        guard !panel.isOpaque, panel.hasShadow, panel.backgroundColor.alphaComponent == 0,
              let root = panel.contentView, !root.isOpaque,
              root.layer?.masksToBounds == true,
              root.layer?.cornerRadius == PanelShell.cornerRadius else {
            throw failure("The window backing does not share the glass's rounded silhouette.")
        }
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw failure("Could not capture shell corners.")
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let corners = [(0, 0), (bitmap.pixelsWide - 1, 0),
                       (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
        guard corners.allSatisfy({ (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.01 }) else {
            throw failure("A square backing is visible outside the rounded shell corners.")
        }
        print("Rounded window backing and transparent corner pixels verified at \(root.bounds.size).")
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: "PanelPresentationVerification", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
