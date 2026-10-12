import AppKit
import PockKit

/// Pock entry point.
///
/// Keep lifecycle work here and rendering work in DevPulseView. Separating them
/// prevents the widget class from becoming a pile of UI, polling and shell code.
@objc(DevPulseWidget)
public final class DevPulseWidget: NSObject, PKWidget {

    @available(*, deprecated, message: "Pock reads the identifier from Info.plist")
    public static var identifier: String = "com.st4rdhoom.devpulse"

    public var customizationLabel = "DevPulse"
    public var view: NSView!

    private let devView: DevPulseView
    private let monitor = DevPulseMonitor()

    private var timer: Timer?
    private var refreshInFlight = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var lastWake: TimeInterval = -.infinity

    override public required init() {
        devView = DevPulseView(
            frame: NSRect(x: 0, y: 0, width: DevPulseView.preferredWidth, height: 30)
        )

        super.init()

        view = devView

        // A tap is intentionally cheap: it requests a refresh rather than
        // launching another app or shell. We can add richer actions later.
        devView.onTap = { [weak self] in
            self?.refresh()
        }

        // After sleep (system or just the screen) the graphs are stale: start
        // them over with fresh readings, which replays the sparkle intro.
        // A full wake fires both notifications; the 5s window plays it once.
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastWake > 5 else { return }
                self.lastWake = now
                self.devView.restartHistory()
                self.refresh()
            }
        }
    }

    deinit {
        wakeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    // Pock calls these lifecycle hooks when the widget enters/leaves the bar.
    // We only poll while visible, otherwise a tiny Touch Bar widget becomes
    // an impressively pointless background daemon.
    @objc public func viewWillAppear() {
        startPolling()
    }

    @objc public func viewDidDisappear() {
        stopPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Preferences.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // Pick up an interval changed in the preference pane. Takes effect
        // on the next tick of the old timer.
        if let timer, timer.timeInterval != Preferences.interval {
            stopPolling()
            startPolling()  // calls refresh() again with the new timer
            return
        }

        guard !refreshInFlight else { return }
        refreshInFlight = true

        monitor.snapshot { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                self.devView.apply(snapshot)
            }
        }
    }
}
