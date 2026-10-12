import AppKit
import PockKit

/// Settings shared by the widget and its preference pane.
///
/// Stored in their own defaults domain: the widget runs inside Pock's process,
/// so `UserDefaults.standard` would be Pock's own preferences. The widget
/// re-reads these on every refresh, so changes apply without restarting Pock.
enum Preferences {

    static let intervals: [Double] = [1, 2, 3, 5, 10]
    static let historyRange = 3...40
    static let dotSizes: [Double] = [1.5, 2, 2.5, 3, 4, 5]
    static let textSizes: [Double] = [8, 9, 10, 11, 12, 14, 16]
    /// Row choices; `fullRows` means "as many as fit the Touch Bar's height".
    static let rowChoices = [3, 4, 5, 6, 8, fullRows]
    static let fullRows = 0

    private static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "com.st4rdhoom.devpulse")!
        defaults.register(defaults: [
            "showCPU": true,
            "showMemory": true,
            "showBattery": true,
            "historyLength": 10,
            "interval": 3.0,
            "dotSize": 2.5,
            "rows": 5,
            "textSize": 10.0
        ])
        return defaults
    }()

    static var showCPU: Bool {
        get { defaults.bool(forKey: "showCPU") }
        set { defaults.set(newValue, forKey: "showCPU") }
    }

    static var showMemory: Bool {
        get { defaults.bool(forKey: "showMemory") }
        set { defaults.set(newValue, forKey: "showMemory") }
    }

    static var showBattery: Bool {
        get { defaults.bool(forKey: "showBattery") }
        set { defaults.set(newValue, forKey: "showBattery") }
    }

    static var historyLength: Int {
        get { defaults.integer(forKey: "historyLength") }
        set { defaults.set(newValue, forKey: "historyLength") }
    }

    static var interval: TimeInterval {
        get { defaults.double(forKey: "interval") }
        set { defaults.set(newValue, forKey: "interval") }
    }

    static var dotSize: Double {
        get { defaults.double(forKey: "dotSize") }
        set { defaults.set(newValue, forKey: "dotSize") }
    }

    static var rows: Int {
        get { defaults.integer(forKey: "rows") }
        set { defaults.set(newValue, forKey: "rows") }
    }

    static var textSize: Double {
        get { defaults.double(forKey: "textSize") }
        set { defaults.set(newValue, forKey: "textSize") }
    }

    static func reset() {
        for key in ["showCPU", "showMemory", "showBattery", "historyLength", "interval", "dotSize", "rows", "textSize"] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Pane shown in Pock's Widgets Manager (`PKWidgetPreferenceClass` in Info.plist).
///
/// Built in code: compiling a .xib needs Xcode's ibtool, which this project
/// avoids. Overriding `loadView` means the nib named below is never looked up.
final class DevPulsePreferencePane: NSViewController, PKWidgetPreference {

    static var nibName: NSNib.Name = "DevPulsePreferencePane"

    private let cpu = NSButton(checkboxWithTitle: "CPU", target: nil, action: nil)
    private let memory = NSButton(checkboxWithTitle: "Memory", target: nil, action: nil)
    private let battery = NSButton(checkboxWithTitle: "Battery", target: nil, action: nil)
    private let dotSize = NSPopUpButton()
    private let rows = NSPopUpButton()
    private let columns = NSStepper()
    private let columnsLabel = NSTextField(labelWithString: "")
    private let textSize = NSPopUpButton()
    private let interval = NSPopUpButton()

    override func loadView() {
        for button in [cpu, memory, battery] {
            button.target = self
            button.action = #selector(changed)
        }

        dotSize.addItems(withTitles: Preferences.dotSizes.map { String(format: "%g pt", $0) })
        rows.addItems(withTitles: Preferences.rowChoices.map {
            $0 == Preferences.fullRows ? "Full height" : "\($0) dots"
        })
        textSize.addItems(withTitles: Preferences.textSizes.map { String(format: "%g pt", $0) })
        interval.addItems(withTitles: Preferences.intervals.map { "\(Int($0)) s" })
        for control in [dotSize, rows, textSize, interval, columns] {
            control.target = self
            control.action = #selector(changed)
        }

        columns.minValue = Double(Preferences.historyRange.lowerBound)
        columns.maxValue = Double(Preferences.historyRange.upperBound)
        columns.increment = 1
        columns.valueWraps = false
        columnsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let columnsRow = NSStackView(views: [columnsLabel, columns])
        columnsRow.spacing = 6

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Show:"), cpu],
            [NSGridCell.emptyContentView, memory],
            [NSGridCell.emptyContentView, battery],
            [NSTextField(labelWithString: "Dot size:"), dotSize],
            [NSTextField(labelWithString: "Rows:"), rows],
            [NSTextField(labelWithString: "Columns:"), columnsRow],
            [NSTextField(labelWithString: "Text size:"), textSize],
            [NSTextField(labelWithString: "Refresh every:"), interval]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.row(at: 3).topPadding = 8
        grid.row(at: 7).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 330))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        view = container
        load()
    }

    func reset() {
        Preferences.reset()
        load()
    }

    private func load() {
        cpu.state = Preferences.showCPU ? .on : .off
        memory.state = Preferences.showMemory ? .on : .off
        battery.state = Preferences.showBattery ? .on : .off
        dotSize.selectItem(at: Preferences.dotSizes.firstIndex(of: Preferences.dotSize) ?? 2)
        rows.selectItem(at: Preferences.rowChoices.firstIndex(of: Preferences.rows) ?? 2)
        columns.integerValue = Preferences.historyLength
        textSize.selectItem(at: Preferences.textSizes.firstIndex(of: Preferences.textSize) ?? 2)
        interval.selectItem(at: Preferences.intervals.firstIndex(of: Preferences.interval) ?? 2)
        updateColumnsLabel()
    }

    private func updateColumnsLabel() {
        columnsLabel.stringValue = "\(columns.integerValue) samples"
    }

    @objc private func changed() {
        Preferences.showCPU = cpu.state == .on
        Preferences.showMemory = memory.state == .on
        Preferences.showBattery = battery.state == .on
        Preferences.dotSize = Preferences.dotSizes[dotSize.indexOfSelectedItem]
        Preferences.rows = Preferences.rowChoices[rows.indexOfSelectedItem]
        Preferences.historyLength = columns.integerValue
        Preferences.textSize = Preferences.textSizes[textSize.indexOfSelectedItem]
        Preferences.interval = Preferences.intervals[interval.indexOfSelectedItem]
        updateColumnsLabel()
    }
}
