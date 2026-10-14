import AppKit

/// Compact Touch Bar presentation: up to three meters, each an icon, a
/// dot-matrix history graph and the current value, drawn directly in `draw(_:)`.
///
/// Graph: one column per sample (newest on the right). Which meters show, the
/// dot size, row count and column count all come from `Preferences`.
final class DevPulseView: NSView {

    private static let height: CGFloat = 30
    /// Space kept above and below the graph; "Full" rows fill the rest.
    private static let verticalMargin: CGFloat = 1
    private static var font: NSFont { text.font }

    private static let iconSlot = NSSize(width: 16, height: 11)
    private static let gap: CGFloat = 4
    private static let meterSpacing: CGFloat = 12
    private static let padding: CGFloat = 8

    /// Room for the widest value, so the layout doesn't shuffle as numbers change.
    private static var textWidth: CGFloat { text.width }

    /// Font and value width, rebuilt only when the text size changes. Making a
    /// fresh system font and measuring with it on every call (many times per
    /// frame while animating) crashed Pock inside CoreText ("attempt to insert
    /// nil object" in `sizeWithAttributes:`).
    private static var cachedText: (size: Double, font: NSFont, width: CGFloat)?
    private static var text: (font: NSFont, width: CGFloat) {
        let size = Preferences.textSize
        if let cached = cachedText, cached.size == size { return (cached.font, cached.width) }
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .medium)
        let width = ("100%" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        cachedText = (size, font, width)
        return (font, width)
    }

    /// Dot-grid geometry for the current preferences.
    private struct Graph {
        let dot: CGFloat
        let pitch: CGFloat
        let rows: Int
        let columns: Int

        var width: CGFloat { CGFloat(columns - 1) * pitch + dot }
        var height: CGFloat { CGFloat(rows - 1) * pitch + dot }

        static var current: Graph {
            let dot = CGFloat(Preferences.dotSize)
            // Spacing grows with the dot; snapped to half points so dots
            // land on whole Retina pixels.
            let pitch = ((dot + max(1, dot * 0.4)) * 2).rounded() / 2
            let usable = DevPulseView.height - 2 * DevPulseView.verticalMargin
            let maxRows = max(Int((usable - dot) / pitch) + 1, 1)
            let rows = Preferences.rows == Preferences.fullRows ? maxRows : min(Preferences.rows, maxRows)
            return Graph(dot: dot, pitch: pitch, rows: rows, columns: Preferences.historyLength)
        }
    }

    private static func meterWidth(_ graph: Graph, showsValue: Bool = true) -> CGFloat {
        iconSlot.width + gap + graph.width + (showsValue ? gap + textWidth : 0)
    }

    private static func width(_ meterWidths: [CGFloat]) -> CGFloat {
        (meterWidths.reduce(0, +) + CGFloat(max(meterWidths.count - 1, 0)) * meterSpacing
            + 2 * padding).rounded(.up)
    }

    private func width(_ meters: [Meter], graph: Graph) -> CGFloat {
        Self.width(meters.map { Self.meterWidth(graph, showsValue: $0.showsValue) })
    }

    /// Initial frame width; the real width follows `intrinsicContentSize`.
    static var preferredWidth: CGFloat { width(Array(repeating: meterWidth(.current), count: 3)) }

    /// Unlit dots: a little brighter than `.quaternaryLabelColor`, which
    /// disappears next to yellow. The Touch Bar is always dark.
    private static let unlitColor = NSColor.white.withAlphaComponent(0.2)
    /// Memory sits in the yellow band a lot; a warm off-white reads better
    /// next to it than grey. Dimmer than lit white so normal load stays legible.
    private static let memoryUnlitColor = NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.88, alpha: 0.5)

    private struct Meter {
        let symbol: String
        let history: [Int?]
        let color: (Int) -> NSColor
        var animation = BatteryAnimation.none
        var showsValue = true
        var unlitColor = DevPulseView.unlitColor
        /// Lit dots pulse in brightness with this period (memory pressure).
        var breathPeriod: TimeInterval?
        /// Draw the current value as RAM chips instead of a history graph.
        var chips = false
        /// When this meter's first reading arrived; it starts full and sparkles down.
        var introStart: TimeInterval?
    }

    private enum BatteryAnimation {
        case none
        /// Gaining charge: empty dots fill upward in a diagonal wave.
        case charging
        /// Plugged in but not charging (running off the adapter): lit dots
        /// drift to grey and back at random, while the base colour slowly
        /// cycles green → blue → green.
        case onAdapter
    }

    /// Step time of the charging wave.
    private static let chargeStep: TimeInterval = 0.25
    /// Frame time of the on-adapter fades; needs to be fast to look fluid.
    private static let fadeFrame: TimeInterval = 1.0 / 20
    /// Length of the sparkle intro after the first reading.
    private static let introDuration: TimeInterval = 1.2
    /// Length of one full green → blue → green cycle on the adapter.
    private static let colorCycle: TimeInterval = 10

    var onTap: (() -> Void)?

    private var cpuHistory: [Int?] = []
    private var memoryHistory: [Int?] = []
    private var batteryHistory: [Int?] = []
    private var onAC = false
    private var charging = false
    private var memoryPressure = MemoryPressure.normal
    /// Intro start time per meter ("cpu", "memory", "battery").
    private var intros: [String: TimeInterval] = [:]

    private var introPlaying: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return window != nil && intros.values.contains { now - $0 < Self.introDuration }
    }

    /// Redraws the battery animation. Frames are derived from the clock, so
    /// the timer only has to trigger redraws.
    private var animationTimer: Timer?
    private var timerInterval: TimeInterval?

    /// Memory breathes only under pressure: slowly at warning, fast at critical.
    private var memoryBreath: TimeInterval? {
        guard Preferences.showMemory, window != nil else { return nil }
        switch memoryPressure {
        case .normal:   return nil
        case .warning:  return 4
        case .critical: return 1.5
        }
    }

    private var batteryAnimation: BatteryAnimation {
        guard Preferences.showBattery, window != nil else { return .none }
        // macOS keeps reporting "charging" while topping off near 100%. Once
        // the newest column is full the wave has nothing to fill, so show
        // the on-adapter animation instead.
        let rows = Graph.current.rows
        if charging, Self.litDots(batteryHistory.last ?? nil, rows: rows) < rows { return .charging }
        if onAC { return .onAdapter }
        return .none
    }

    /// Dots lit for `value`: nearest row, but any non-zero value lights one.
    private static func litDots(_ value: Int?, rows: Int) -> Int {
        guard let value, value > 0 else { return 0 }
        return max(1, Int((Double(value) / 100 * Double(rows)).rounded()))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap))

        // `.direct` means actual Touch Bar finger input rather than ordinary
        // pointer clicks. Pock widgets live in slightly unusual AppKit territory.
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(meters, graph: .current), height: Self.height)
    }

    private var meters: [Meter] {
        var meters: [Meter] = []
        if Preferences.showCPU {
            meters.append(Meter(symbol: "cpu", history: cpuHistory, color: Self.loadColor, introStart: intros["cpu"]))
        }
        if Preferences.showMemory {
            meters.append(Meter(
                symbol: "memorychip", history: memoryHistory, color: Self.loadColor,
                unlitColor: Self.memoryUnlitColor, breathPeriod: memoryBreath, chips: true,
                introStart: intros["memory"]
            ))
        }
        if Preferences.showBattery {
            let onAC = self.onAC
            meters.append(Meter(
                symbol: Self.batterySymbol(batteryHistory.last ?? nil, onAC: onAC),
                history: batteryHistory,
                color: { Self.batteryColor($0, onAC: onAC) },
                animation: batteryAnimation,
                // On the adapter the charge level doesn't matter; the
                // animation alone says "plugged in".
                showsValue: batteryAnimation != .onAdapter,
                introStart: intros["battery"]
            ))
        }
        return meters
    }

    func apply(_ snapshot: DevPulseSnapshot) {
        func push(_ history: inout [Int?], _ value: Int?, intro: String) {
            // First real reading (after launch or wake): fill the whole history
            // with it and sparkle it in, instead of growing one column per refresh.
            if let value, history.allSatisfy({ $0 == nil }) {
                history = Array(repeating: value, count: Preferences.historyRange.upperBound)
                intros[intro] = ProcessInfo.processInfo.systemUptime
                return
            }
            history.append(value)
            // Keep the longest selectable history so changing it is instant.
            history.removeFirst(max(history.count - Preferences.historyRange.upperBound, 0))
        }

        push(&cpuHistory, snapshot.cpu, intro: "cpu")
        push(&memoryHistory, snapshot.memory, intro: "memory")
        push(&batteryHistory, snapshot.battery, intro: "battery")
        onAC = snapshot.onAC
        charging = snapshot.charging
        memoryPressure = snapshot.memoryPressure
        updateAnimation()

        // Preferences may have changed which meters show or the graph size.
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Forget all readings, so the next ones fill the graphs and sparkle in.
    func restartHistory() {
        cpuHistory = []
        memoryHistory = []
        batteryHistory = []
        needsDisplay = true
    }

    private func updateAnimation() {
        // One timer at the fastest rate any running animation needs.
        let battery = batteryAnimation
        let wanted: TimeInterval? = battery == .onAdapter || memoryBreath != nil || introPlaying ? Self.fadeFrame
            : battery == .charging ? Self.chargeStep
            : nil
        guard wanted != timerInterval else { return }

        animationTimer?.invalidate()
        animationTimer = nil
        timerInterval = wanted
        needsDisplay = true

        guard let interval = wanted else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.invalidateAnimatingGraphs()
            // Drops back to a slower rate (or none) once the intro ends.
            self?.updateAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Stop animating as soon as the widget leaves the Touch Bar.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func draw(_ dirtyRect: NSRect) {
        let graph = Graph.current
        for (meter, x) in layout(graph) where needsToDraw(slot(at: x, meter, graph: graph)) {
            drawMeter(at: x, meter, graph: graph)
        }
    }

    /// Each visible meter with its left edge.
    private func layout(_ graph: Graph) -> [(meter: Meter, x: CGFloat)] {
        let meters = self.meters
        var x = ((bounds.width - width(meters, graph: graph)) / 2).rounded() + Self.padding
        return meters.map { meter in
            defer { x += Self.meterWidth(graph, showsValue: meter.showsValue) + Self.meterSpacing }
            return (meter, x)
        }
    }

    private func slot(at x: CGFloat, _ meter: Meter, graph: Graph) -> NSRect {
        NSRect(x: x, y: 0, width: Self.meterWidth(graph, showsValue: meter.showsValue), height: bounds.height)
    }

    /// Animation frames redraw only the graphs that move, not icons, text or
    /// still meters: full-view redraws at 20fps kept Pock at ~35% CPU.
    private func invalidateAnimatingGraphs() {
        let graph = Graph.current
        let now = ProcessInfo.processInfo.systemUptime
        for (meter, x) in layout(graph) {
            let intro = meter.introStart.map { now - $0 < Self.introDuration } ?? false
            guard meter.animation != .none || meter.breathPeriod != nil || intro else { continue }
            setNeedsDisplay(NSRect(
                x: x + Self.iconSlot.width + Self.gap, y: 0, width: graph.width, height: bounds.height
            ))
        }
    }

    private func drawMeter(at x: CGFloat, _ meter: Meter, graph: Graph) {
        let midY = bounds.midY
        let history = Array(meter.history.suffix(graph.columns))
        var x = x

        if let icon = Self.icon(meter.symbol) {
            // Fit inside the slot, keeping aspect ratio (battery is wide).
            let scale = min(Self.iconSlot.width / icon.size.width, Self.iconSlot.height / icon.size.height, 1)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(
                x: x + (Self.iconSlot.width - size.width) / 2,
                y: midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
        x += Self.iconSlot.width + Self.gap

        let bottom = ((midY - graph.height / 2) * 2).rounded() / 2
        let columns = Array(repeating: nil, count: graph.columns - history.count) + history
        let now = ProcessInfo.processInfo.systemUptime
        let chargePhase = Int(now / Self.chargeStep)
        // 0 = green, 1 = blue; cosine eases the turn at each end.
        let blue = CGFloat(1 - cos(2 * .pi * now / Self.colorCycle)) / 2
        // Resolve the dynamic colours once per frame: blending them per dot
        // was the hottest path in the animation.
        let unlit = meter.unlitColor.usingColorSpace(.sRGB) ?? meter.unlitColor
        let adapterBlue = NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let cells = meter.chips
            ? Self.chipColumns(history.last ?? nil, columns: graph.columns, rows: graph.rows)
            : columns.map { value -> (value: Int?, dots: [Bool?])? in
                let lit = Self.litDots(value, rows: graph.rows)
                return (value, (0..<graph.rows).map { $0 < lit })
            }
        // Chips can come out narrower than the graph; centre them in its slot.
        let left = x + CGFloat(graph.columns - cells.count) * graph.pitch / 2

        for (column, cell) in cells.enumerated() {
            guard let (value, dots) = cell else { continue }
            let lit = dots.prefix { $0 == true }.count
            // While charging, the empty dots above the level fill upward one
            // row per step. Each column lags its left neighbour by one step,
            // so the fill sweeps across the graph as a diagonal wave.
            let empty = graph.rows - lit
            let rising = meter.animation == .charging && value != nil && empty > 0
                ? ((chargePhase - column) % (empty + 1) + empty + 1) % (empty + 1)
                : 0

            var litColor = meter.color(value ?? 0).usingColorSpace(.sRGB) ?? meter.color(value ?? 0)
            if meter.animation == .onAdapter {
                litColor = litColor.blended(withFraction: blue, of: adapterBlue) ?? litColor
            }

            for row in 0..<graph.rows {
                guard let on = dots[row] else { continue }
                var color: NSColor
                if on {
                    // Dots fade out in 2×2 blocks (single dots are too small
                    // to see at small dot sizes), plus single dots on top
                    // for extra sparkle.
                    let off = meter.animation == .onAdapter
                        ? max(Self.fade(column: column / 2, row: row / 2, time: now),
                              Self.fade(column: column, row: row, time: now))
                        : 0
                    color = off > 0
                        ? litColor.blended(withFraction: off, of: unlit) ?? litColor
                        : litColor
                    if let period = meter.breathPeriod {
                        // Dims to half brightness and back on a cosine curve.
                        let dim = (1 - cos(2 * .pi * now / period)) / 4
                        color = color.withAlphaComponent(CGFloat(1 - dim))
                    }
                } else if row < lit + rising {
                    color = meter.color(value ?? 0).withAlphaComponent(0.6)
                } else {
                    color = unlit
                }
                if !on, let start = meter.introStart, now - start < Self.introDuration {
                    // Intro: the grid starts full and the dots above the
                    // reading switch off at random.
                    let off = Self.sparkle(column: column, row: row, elapsed: now - start)
                    color = meter.color(value ?? 0).blended(withFraction: off, of: color) ?? color
                }
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(
                    x: left + CGFloat(column) * graph.pitch,
                    y: bottom + CGFloat(row) * graph.pitch,
                    width: graph.dot,
                    height: graph.dot
                ))
            }
        }
        guard meter.showsValue else { return }
        x += graph.width + Self.gap

        // Right-aligned and fixed-width so the layout doesn't shuffle.
        let text = (history.last ?? nil).map { "\($0)%" } ?? "—"
        let font = Self.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let width = (text as NSString).size(withAttributes: attributes).width
        // draw(at:) takes the line's bottom-left; centre the digits' cap height.
        let y = midY - font.capHeight / 2 + font.descender
        (text as NSString).draw(at: NSPoint(x: x + Self.textWidth - width, y: y), withAttributes: attributes)
    }

    /// Columns of a RAM stick showing `value`: 4 chips, each split
    /// horizontally into two halves, so 8 sections of 1/8 of RAM each. A
    /// column is `nil` between chips and a row is `nil` between halves.
    /// Sections fill bottom half left to right, then top half; each one
    /// bottom-up, row by row.
    private static func chipColumns(_ value: Int?, columns: Int, rows: Int) -> [(value: Int?, dots: [Bool?])?] {
        let chips = min(4, (columns + 1) / 2)
        let width = (columns - (chips - 1)) / chips
        let half = max((rows - 1) / 2, 1)
        let level = Double(value ?? 0) / 100 * Double(chips * 2)

        var cells: [(value: Int?, dots: [Bool?])?] = []
        for chip in 0..<chips {
            if chip > 0 { cells.append(nil) }
            // Lit dots in this chip's bottom and top sections.
            let lit = [chip, chips + chip].map { section in
                Int((min(max(level - Double(section), 0), 1) * Double(width * half)).rounded())
            }
            for column in 0..<width {
                func height(_ dots: Int) -> Int { dots / width + (column < dots % width ? 1 : 0) }
                let bottom = height(lit[0]), top = height(lit[1])
                cells.append((value, (0..<rows).map { row -> Bool? in
                    if row < half { return row < bottom }
                    if row >= rows - half { return row - (rows - half) < top }
                    return nil
                }))
            }
        }
        return cells
    }

    /// How far (0…1) an unlit dot has switched off during the intro: each dot
    /// starts at its own random moment in the first 75% of `introDuration` and
    /// fades out over the remaining 25%.
    private static func sparkle(column: Int, row: Int, elapsed: TimeInterval) -> CGFloat {
        // SplitMix64 finaliser: neighbouring dots get unrelated delays.
        var seed = UInt64(truncatingIfNeeded: column &* 1_000_003 &+ row) &* 0x9E37_79B9_7F4A_7C15
        seed = (seed ^ (seed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        seed = (seed ^ (seed >> 27)) &* 0x94D0_49BB_1331_11EB
        seed ^= seed >> 31
        let delay = Double(seed >> 11) / Double(1 << 53) * 0.75 * introDuration
        return CGFloat(min(max((elapsed - delay) / (0.25 * introDuration), 0), 1))
    }

    /// How far (0…1) a 2×2 block has faded off at `time` in the on-adapter animation.
    ///
    /// Each block gets its own pseudo-random period (3–7s) and phase from its
    /// position, and fades out and back during 35% of its cycle with eased
    /// sin² curves, so roughly a third of the dots drift at any moment,
    /// independently of each other.
    private static func fade(column: Int, row: Int, time: TimeInterval) -> CGFloat {
        var seed = UInt64(truncatingIfNeeded: (column &* 73_856_093) ^ (row &* 19_349_663))
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }

        let period = 3 + 4 * random()
        let x = (time / period + random()).truncatingRemainder(dividingBy: 1)
        let window = 0.35
        guard x < window else { return 0 }

        let s = sin(.pi * x / window)
        return CGFloat(s * s)
    }

    /// SF Symbol painted grey (symbol images ignore the fill colour),
    /// rendered once into a Retina bitmap so frames don't redraw the vector.
    private static var icons: [String: NSImage] = [:]
    private static func icon(_ name: String) -> NSImage? {
        if let icon = icons[name] { return icon }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        else { return nil }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((symbol.size.width * 2).rounded(.up)),
            pixelsHigh: Int((symbol.size.height * 2).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect)
        NSColor.secondaryLabelColor.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let icon = NSImage(size: symbol.size)
        icon.addRepresentation(bitmap)
        icons[name] = icon
        return icon
    }

    private static func loadColor(_ value: Int) -> NSColor {
        switch value {
        case 90...: return .systemRed
        case 70...: return .systemYellow
        default:    return .labelColor
        }
    }

    private static func batteryColor(_ value: Int, onAC: Bool) -> NSColor {
        if onAC { return .systemGreen }
        switch value {
        case ...10: return .systemRed
        case ...20: return .systemYellow
        default:    return .labelColor
        }
    }

    private static func batterySymbol(_ value: Int?, onAC: Bool) -> String {
        if onAC { return "battery.100.bolt" }
        switch value ?? 100 {
        case ...12: return "battery.0"
        case ...37: return "battery.25"
        case ...62: return "battery.50"
        case ...87: return "battery.75"
        default:    return "battery.100"
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}
