import AppKit
import SwiftUI
import CodexQuotaCore

@MainActor
final class StatusMenuController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = DashboardViewModel()
    private var client = SheetsDashboardClient()
    private var timer: Timer?
    private var dismissTimer: Timer?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var refreshGeneration = 0
    private var stopped = false

    override init() {
        super.init()
        if let cached = client.cached() {
            model.dashboard = cached.0
            model.fetchedAt = cached.1
        }
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(toggleCard(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tokivue Google Sheets 用量看板")
        }
        model.refresh = { [weak self] in self?.refresh() }
        model.reconnect = { [weak self] in self?.reconnect() }
        model.openSheet = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.client.sheetURL)
        }
        model.quit = { NSApp.terminate(nil) }
        model.navigationChanged = { [weak self] in
            // Re-measure after SwiftUI has applied the navigation state change.
            DispatchQueue.main.async { self?.resizeCard() }
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)
        let host = NSHostingController(rootView: DashboardView(model: model))
        host.preferredContentSize = host.view.fittingSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        updateStatusItem()
        refresh()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        cancelAutoDismiss()
        client.stop()
        stopOutsideClickMonitoring()
        popover.close()
    }

    @objc private func toggleCard(_ sender: Any?) {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        model.showOverview()
        resizeCard()
        if model.fetchedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        startOutsideClickMonitoring()
        resetAutoDismiss()
    }

    private func resizeCard() {
        guard !stopped, let host = popover.contentViewController else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        host.preferredContentSize = size
        popover.contentSize = size
        if popover.isShown { resetAutoDismiss() }
    }

    private func resetAutoDismiss() {
        cancelAutoDismiss()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissTimer = nil
                if self.popover.isShown { self.popover.performClose(nil) }
            }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
        cancelAutoDismiss()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A non-activating menu-bar popover can miss AppKit's transient dismissal.
        // Global monitors observe other apps; local monitors cover our own windows.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                if let window = self.popover.contentViewController?.view.window,
                   event.window === window { return }
                // Let the status button's mouse-up action toggle the card once.
                if let button = self.statusItem.button, let window = button.window,
                   event.window === window,
                   button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                    return
                }
                self.popover.performClose(nil)
            }
            return event // Never swallow the click intended for another control.
        }
    }

    private func stopOutsideClickMonitoring() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    private func cancelAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func reconnect() {
        guard !stopped else { return }
        timer?.invalidate()
        client.stop()
        client = SheetsDashboardClient()
        model.refreshing = false
        refresh()
    }

    private func refresh() {
        guard !stopped, !model.refreshing else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        timer?.invalidate()
        model.nextRefreshAt = nil
        model.refreshing = true
        updateStatusItem()
        client.fetch { [weak self] result in
            DispatchQueue.main.async {
                // A cancelled request must not overwrite the manually reconnected session.
                guard let self, !self.stopped, self.refreshGeneration == generation else { return }
                self.model.refreshing = false
                let interval: TimeInterval = 60
                switch result {
                case let .success(data):
                    self.model.dashboard = data
                    self.model.error = nil
                    self.model.fetchedAt = Date()
                case let .failure(error):
                    self.model.error = error.localizedDescription
                }
                self.updateStatusItem()
                self.model.nextRefreshAt = Date().addingTimeInterval(interval)
                let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                timer.tolerance = 1
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func updateStatusItem() {
        let percent = model.dashboard?.remainingPercent()
        let value = percent.map { QuotaFormatting.percent($0) }
        let stale = model.error != nil || model.dashboard?.isStale() == true
        statusItem.button?.image = QuotaRingIcon.make(remainingPercent: percent)
        statusItem.button?.title = value.map { "\($0)%\(stale ? " ·" : "")" } ?? "—"
        statusItem.button?.setAccessibilityValue(value.map { "本周剩余 \($0)%" } ?? "等待表格额度")
        statusItem.button?.toolTip = "Google Sheets 用量看板" + (stale ? " · 缓存可能已过期" : "")
    }
}
