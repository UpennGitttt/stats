import Cocoa
import Kit

internal final class Popup: PopupWrapper {
    internal var refreshCallback: (() -> Void) = {}
    internal var settingsCallback: (() -> Void) = {}
    private let listPage = NSStackView()
    private let listView = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint?
    private var documentHeight: NSLayoutConstraint?
    private var detailView: ServerDetailView?
    private var selectedID: String?
    private var snapshot = ServersSnapshot()

    internal init() {
        super.init(.servers, frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 0
        self.setupList()
        self.addArrangedSubview(self.listPage)
        self.listPage.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        self.scrollView.widthAnchor.constraint(equalTo: self.listPage.widthAnchor).isActive = true
        self.callback(self.snapshot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupList() {
        self.listPage.orientation = .vertical
        self.listPage.alignment = .leading
        self.listPage.distribution = .fill
        self.listPage.spacing = 0

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        let title = LabelField(localizedString("Servers"), size: 12)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let transport = LabelField("SSH", size: 10)
        transport.textColor = .tertiaryLabelColor
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(transport)

        self.listView.orientation = .vertical
        self.listView.alignment = .leading
        self.listView.distribution = .fill
        self.listView.spacing = 0
        self.listView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.documentView = self.listView
        self.scrollView.drawsBackground = false
        self.scrollView.borderType = .noBorder
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.autohidesScrollers = true
        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollHeight = self.scrollView.heightAnchor.constraint(equalToConstant: 56)
        self.scrollHeight?.isActive = true
        self.documentHeight = self.listView.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([
            self.listView.leadingAnchor.constraint(equalTo: self.scrollView.contentView.leadingAnchor),
            self.listView.trailingAnchor.constraint(equalTo: self.scrollView.contentView.trailingAnchor),
            self.listView.topAnchor.constraint(equalTo: self.scrollView.contentView.topAnchor),
            self.listView.widthAnchor.constraint(equalTo: self.scrollView.contentView.widthAnchor),
            self.documentHeight!
        ])

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 8, right: 14)
        let local = LabelField(localizedString("Direct SSH · no agent"), size: 10)
        local.textColor = .secondaryLabelColor
        let manage = NSButton(title: localizedString("Manage…"), target: self, action: #selector(self.manage))
        manage.bezelStyle = .rounded
        manage.controlSize = .small
        let refresh = NSButton(title: localizedString("Refresh"), target: self, action: #selector(self.refresh))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        footer.addArrangedSubview(local)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(manage)
        footer.addArrangedSubview(refresh)

        self.listPage.addArrangedSubview(header)
        self.listPage.addArrangedSubview(self.scrollView)
        self.listPage.addArrangedSubview(footer)
    }

    internal func callback(_ snapshot: ServersSnapshot) {
        self.snapshot = snapshot
        if let selectedID, let selected = snapshot.servers.first(where: { $0.config.id == selectedID }) {
            if self.detailView?.id != selectedID { self.showDetails(selected) }
            self.detailView?.update(selected)
        } else if selectedID != nil {
            self.showList()
        }
        self.renderList()
    }

    private func renderList() {
        guard self.selectedID == nil else { return }
        self.listView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let servers = self.snapshot.servers.filter(\.config.enabled)
        if servers.isEmpty {
            let empty = NSStackView()
            empty.orientation = .vertical
            empty.alignment = .centerX
            empty.spacing = 8
            empty.edgeInsets = NSEdgeInsets(top: 22, left: 16, bottom: 20, right: 16)
            let label = LabelField(localizedString("No servers configured"), size: 12)
            label.textColor = .secondaryLabelColor
            let add = NSButton(title: localizedString("Add server"), target: self, action: #selector(self.manage))
            add.bezelStyle = .rounded
            empty.addArrangedSubview(label)
            empty.addArrangedSubview(add)
            self.listView.addArrangedSubview(empty)
        } else {
            servers.forEach { server in
                let row = ServerRow(server)
                row.selectCallback = { [weak self] in self?.showDetails(server) }
                self.listView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: self.listView.widthAnchor).isActive = true
            }
        }
        let contentHeight = servers.isEmpty ? 104 : min(servers.count * 58, 348)
        self.scrollHeight?.constant = CGFloat(contentHeight)
        self.documentHeight?.constant = CGFloat(servers.isEmpty ? 104 : servers.count * 58)
        self.recalculateHeight()
    }

    internal func showDetails(_ server: ServerSnapshot) {
        self.selectedID = server.config.id
        self.detailView?.removeFromSuperview()
        let detail = ServerDetailView(server)
        detail.backCallback = { [weak self] in self?.showList() }
        self.detailView = detail
        self.addArrangedSubview(detail)
        self.listPage.isHidden = true
        self.recalculateHeight()
    }

    private func showList() {
        self.selectedID = nil
        self.detailView?.removeFromSuperview()
        self.detailView = nil
        self.listPage.isHidden = false
        self.renderList()
    }

    private func recalculateHeight() {
        let height = self.selectedID == nil ? 36 + (self.scrollHeight?.constant ?? 0) + 37 : 484
        self.setFrameSize(NSSize(width: 360, height: height))
        self.sizeCallback?(self.frame.size)
    }

    @objc private func refresh() {
        self.refreshCallback()
    }

    @objc private func manage() {
        self.settingsCallback()
    }
}

private final class ServerRow: NSStackView {
    internal var selectCallback: (() -> Void) = {}
    private var tracking: NSTrackingArea?

    internal init(_ server: ServerSnapshot) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 5
        self.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 12)
        self.heightAnchor.constraint(equalToConstant: 58).isActive = true
        self.wantsLayer = true

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 7
        let dot = DotView(color: ServerFormat.color(server.state), size: 7)
        let name = LabelField(server.config.name, size: 12)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let latency = LabelField(ServerFormat.latency(server), size: 10)
        latency.textColor = server.state == .error ? .systemRed : .secondaryLabelColor
        latency.alignment = .right
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        top.addArrangedSubview(dot)
        top.addArrangedSubview(name)
        top.addArrangedSubview(NSView())
        top.addArrangedSubview(latency)
        top.addArrangedSubview(chevron)

        let metrics = LabelField(ServerFormat.rowMetrics(server), size: 11)
        metrics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metrics.textColor = .secondaryLabelColor
        metrics.lineBreakMode = .byTruncatingTail
        self.addArrangedSubview(top)
        self.addArrangedSubview(metrics)
        top.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -26).isActive = true
        metrics.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        self.setAccessibilityRole(.button)
        self.setAccessibilityLabel(server.config.name)
        self.toolTip = server.errorMessage ?? server.config.sshAlias
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { self.removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        self.addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if self.bounds.contains(point) { self.selectCallback() }
    }
}

private final class ServerDetailView: NSStackView {
    internal let id: String
    internal var backCallback: (() -> Void) = {}
    private let status = LabelField(size: 11)
    private let memory = LabelField(size: 11)
    private let disk = LabelField(size: 11)
    private let system = LabelField(size: 11)
    private let error = NSTextField(wrappingLabelWithString: "")
    private let cpuValue = LabelField(size: 11)
    private let memoryValue = LabelField(size: 11)
    private let networkValue = LabelField(size: 11)
    private let cpuChart = LineChartView(num: 120, suffix: "%", scale: .fixed, fixedScale: 1, animation: false)
    private let memoryChart = LineChartView(num: 120, suffix: "%", scale: .fixed, fixedScale: 1, animation: false)
    private let networkChart = NetworkChartView(num: 120, minMax: false, animation: false)

    internal init(_ server: ServerSnapshot) {
        self.id = server.config.id
        super.init(frame: .zero)
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .leading
        self.spacing = 10
        self.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)

        let back = NSButton(title: localizedString("‹ Servers"), target: self, action: #selector(self.back))
        back.isBordered = false
        back.font = .systemFont(ofSize: 11)
        back.contentTintColor = .secondaryLabelColor
        back.alignment = .left
        let name = LabelField(server.config.name, size: 16)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let alias = LabelField(server.config.sshAlias, size: 11)
        alias.textColor = .secondaryLabelColor
        self.status.textColor = .secondaryLabelColor
        self.error.font = .systemFont(ofSize: 10)
        self.error.textColor = .systemRed
        self.error.preferredMaxLayoutWidth = 330
        self.system.textColor = .secondaryLabelColor
        self.system.widthAnchor.constraint(equalToConstant: 332).isActive = true

        self.addArrangedSubview(back)
        self.addArrangedSubview(name)
        self.addArrangedSubview(alias)
        self.addArrangedSubview(self.status)
        self.addArrangedSubview(self.error)
        self.addArrangedSubview(self.system)
        self.addArrangedSubview(self.memory)
        self.addArrangedSubview(self.disk)
        self.addArrangedSubview(self.chart(localizedString("CPU"), value: self.cpuValue, chart: self.cpuChart))
        self.addArrangedSubview(self.chart(localizedString("Memory"), value: self.memoryValue, chart: self.memoryChart))
        self.addArrangedSubview(self.chart(localizedString("Network"), value: self.networkValue, chart: self.networkChart))
        self.update(server)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func chart(_ title: String, value: NSTextField, chart: NSView) -> NSStackView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        let header = NSStackView()
        header.orientation = .horizontal
        let label = LabelField(title, size: 11)
        label.textColor = .secondaryLabelColor
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        header.addArrangedSubview(label)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(value)
        chart.heightAnchor.constraint(equalToConstant: 58).isActive = true
        container.addArrangedSubview(header)
        container.addArrangedSubview(chart)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        chart.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return container
    }

    internal func update(_ server: ServerSnapshot) {
        self.status.stringValue = ServerFormat.status(server)
        self.error.stringValue = server.errorMessage ?? ""
        self.error.isHidden = server.errorMessage == nil
        guard let metrics = server.metrics else {
            self.memory.stringValue = localizedString("Waiting for the first response…")
            self.disk.stringValue = ""
            self.system.stringValue = ""
            return
        }
        self.memory.stringValue = "\(localizedString("Memory"))  \(ServerFormat.bytes(metrics.memoryUsed)) / \(ServerFormat.bytes(metrics.memoryTotal))"
        self.disk.stringValue = "\(localizedString("Disk")) /  \(ServerFormat.bytes(metrics.diskUsed)) / \(ServerFormat.bytes(metrics.diskTotal))  (\(ServerFormat.percent(metrics.diskUsage)))"
        self.system.stringValue = ServerFormat.system(metrics)
        self.cpuValue.stringValue = ServerFormat.percent(metrics.cpuUsage)
        self.memoryValue.stringValue = ServerFormat.percent(metrics.memoryUsage)
        self.networkValue.stringValue = "↓ \(ServerFormat.speed(metrics.networkRead))  ↑ \(ServerFormat.speed(metrics.networkWrite))"
        let history = server.history.isEmpty ? (server.metrics.map { [$0] } ?? []) : server.history
        self.cpuChart.setPoints(ServerHistory.percentagePoints(history, \.cpuUsage))
        self.memoryChart.setPoints(ServerHistory.percentagePoints(history, \.memoryUsage))
        self.networkChart.setPoints(
            upload: history.map { DoubleValue($0.networkWrite ?? 0, ts: $0.collectedAt) },
            download: history.map { DoubleValue($0.networkRead ?? 0, ts: $0.collectedAt) }
        )
    }

    @objc private func back() {
        self.backCallback()
    }
}

private enum ServerFormat {
    internal static func color(_ state: ServerConnectionState) -> NSColor {
        switch state {
        case .online: return .systemGreen
        case .error: return .systemRed
        case .connecting: return .systemOrange
        case .idle: return .tertiaryLabelColor
        }
    }

    internal static func rowMetrics(_ server: ServerSnapshot) -> String {
        guard let metrics = server.metrics else { return localizedString("Waiting for metrics…") }
        return "CPU \(self.percent(metrics.cpuUsage))   RAM \(self.percent(metrics.memoryUsage))   Disk \(self.percent(metrics.diskUsage))"
    }

    internal static func latency(_ server: ServerSnapshot) -> String {
        switch server.state {
        case .online: return server.metrics?.latencyMS.map { "\($0) ms" } ?? localizedString("Online")
        case .error: return localizedString("Offline")
        case .connecting: return localizedString("Connecting…")
        case .idle: return localizedString("Idle")
        }
    }

    internal static func status(_ server: ServerSnapshot) -> String {
        var value = self.latency(server)
        if let last = server.lastSuccessAt {
            let time = DateFormatter.localizedString(from: last, dateStyle: .none, timeStyle: .medium)
            value += " · \(localizedString("Updated %0", time))"
        }
        return value
    }

    internal static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.0f%%", value * 100)
    }

    internal static func bytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return Units(bytes: value).getReadableMemory(style: .memory)
    }

    internal static func speed(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= Double(Int64.max) else { return "--" }
        return Units(bytes: Int64(value)).getReadableSpeed()
    }

    internal static func system(_ metrics: ServerMetrics) -> String {
        var values = [metrics.osName, metrics.hostname].compactMap { $0 }.filter { !$0.isEmpty }
        if let uptime = metrics.uptime {
            let days = Int(uptime) / 86400
            let hours = (Int(uptime) % 86400) / 3600
            values.append(days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(Int(uptime) % 3600 / 60)m")
        }
        if !metrics.loadAverage.isEmpty {
            values.append("Load " + metrics.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }
        return values.joined(separator: " · ")
    }
}
