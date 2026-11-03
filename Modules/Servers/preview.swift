import Cocoa
import Kit

internal final class Preview: PreviewWrapper {
    internal private(set) var selectedServerID: String?
    internal private(set) var detailView: ServerDetailView?
    internal let serverSelector = NSPopUpButton()
    private let detailContainer = NSStackView()
    private let emptyState = NSTextField(wrappingLabelWithString: localizedString("No servers configured"))
    private var menuSignature: [String] = []
    private let contentWidth: CGFloat = 450

    internal init() {
        super.init(type: .servers)
        self.alignment = .leading
        self.distribution = .fill

        self.serverSelector.font = .systemFont(ofSize: 12)
        self.serverSelector.target = self
        self.serverSelector.action = #selector(self.selectServer)
        self.serverSelector.identifier = NSUserInterfaceItemIdentifier("servers-preview-selector")
        self.serverSelector.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.serverSelector.isEnabled = false

        let selectorRow = PreferencesRow(component: self.serverSelector)
        selectorRow.identifier = NSUserInterfaceItemIdentifier("servers-preview-selector-row")
        self.addArrangedSubview(PreferencesSection(
            title: localizedString("Servers"),
            subtitle: localizedString("Live CPU, RAM, disk and network metrics"),
            [selectorRow]
        ))

        self.detailContainer.orientation = .vertical
        self.detailContainer.alignment = .leading
        self.detailContainer.distribution = .fill
        self.detailContainer.spacing = 0
        self.detailContainer.isHidden = true

        self.emptyState.font = .systemFont(ofSize: 12)
        self.emptyState.textColor = .secondaryLabelColor
        self.emptyState.alignment = .center
        self.emptyState.preferredMaxLayoutWidth = self.contentWidth
        self.emptyState.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
        self.emptyState.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        let content = NSStackView(views: [self.detailContainer, self.emptyState])
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        self.addArrangedSubview(PreferencesSection([content]))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func callback(_ snapshot: ServersSnapshot) {
        self.snapshot = snapshot
        let servers = snapshot.servers.filter(\.config.enabled)
        let signature = servers.map { "\($0.config.id)\u{0}\($0.config.name)\u{0}\($0.config.sshAlias)" }
        if signature != self.menuSignature {
            let previousID = self.selectedServerID
            self.serverSelector.removeAllItems()
            for server in servers {
                self.serverSelector.addItem(withTitle: server.config.name)
                self.serverSelector.lastItem?.representedObject = server.config.id
                self.serverSelector.lastItem?.toolTip = server.config.sshAlias
            }
            self.menuSignature = signature
            if !servers.contains(where: { $0.config.id == previousID }) {
                self.selectedServerID = nil
            }
        }

        guard let server = servers.first(where: { $0.config.id == self.selectedServerID }) ?? servers.first else {
            self.selectedServerID = nil
            self.serverSelector.isEnabled = false
            self.detailContainer.isHidden = true
            self.emptyState.isHidden = false
            return
        }

        self.selectedServerID = server.config.id
        self.serverSelector.isEnabled = true
        if let item = self.serverSelector.menu?.items.first(where: { $0.representedObject as? String == server.config.id }) {
            self.serverSelector.select(item)
        }
        self.detailContainer.isHidden = false
        self.emptyState.isHidden = true
        if self.detailView?.id != server.config.id {
            self.detailView?.removeFromSuperview()
            let detail = ServerDetailView(server, showsBackButton: false, contentWidth: self.contentWidth)
            self.detailView = detail
            self.detailContainer.addArrangedSubview(detail)
        } else {
            self.detailView?.update(server)
        }
    }

    @objc private func selectServer() {
        guard let id = self.serverSelector.selectedItem?.representedObject as? String else { return }
        self.selectedServerID = id
        self.callback(self.snapshot)
    }

    private var snapshot = ServersSnapshot()
}

internal final class ServerDetailView: NSStackView {
    internal let id: String
    internal var backCallback: (() -> Void) = {}
    private let name = LabelField(size: 16)
    private let alias = LabelField(size: 11)
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
    private let contentWidth: CGFloat

    internal init(_ server: ServerSnapshot, showsBackButton: Bool = true, contentWidth: CGFloat = 332) {
        self.id = server.config.id
        self.contentWidth = contentWidth
        super.init(frame: .zero)
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .leading
        self.spacing = 10
        self.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)

        if showsBackButton {
            let back = NSButton(title: localizedString("‹ Servers"), target: self, action: #selector(self.back))
            back.isBordered = false
            back.font = .systemFont(ofSize: 11)
            back.contentTintColor = .secondaryLabelColor
            back.alignment = .left
            self.addArrangedSubview(back)
        }

        self.name.font = .systemFont(ofSize: 16, weight: .semibold)
        self.name.lineBreakMode = .byTruncatingTail
        self.name.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        self.alias.textColor = .secondaryLabelColor
        self.alias.lineBreakMode = .byTruncatingMiddle
        self.alias.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        self.status.textColor = .secondaryLabelColor
        self.error.font = .systemFont(ofSize: 10)
        self.error.textColor = .systemRed
        self.error.preferredMaxLayoutWidth = contentWidth
        self.system.textColor = .secondaryLabelColor
        self.system.lineBreakMode = .byTruncatingTail
        self.system.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        self.addArrangedSubview(self.name)
        self.addArrangedSubview(self.alias)
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
        container.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
        return container
    }

    internal func update(_ server: ServerSnapshot) {
        self.name.stringValue = server.config.name
        self.alias.stringValue = server.config.sshAlias
        self.status.stringValue = ServerFormat.status(server)
        self.error.stringValue = server.errorMessage ?? ""
        self.error.isHidden = server.errorMessage == nil

        let history = server.history.isEmpty ? (server.metrics.map { [$0] } ?? []) : server.history
        self.cpuChart.setPoints(ServerHistory.percentagePoints(history, \.cpuUsage))
        self.memoryChart.setPoints(ServerHistory.percentagePoints(history, \.memoryUsage))
        self.networkChart.setPoints(
            upload: history.map { DoubleValue($0.networkWrite ?? 0, ts: $0.collectedAt) },
            download: history.map { DoubleValue($0.networkRead ?? 0, ts: $0.collectedAt) }
        )

        guard let metrics = server.metrics else {
            self.memory.stringValue = server.state == .idle ? localizedString("Idle") : localizedString("Waiting for the first response…")
            self.disk.stringValue = ""
            self.system.stringValue = ""
            self.cpuValue.stringValue = "--"
            self.memoryValue.stringValue = "--"
            self.networkValue.stringValue = "--"
            return
        }
        self.memory.stringValue = "\(localizedString("Memory"))  \(ServerFormat.bytes(metrics.memoryUsed)) / \(ServerFormat.bytes(metrics.memoryTotal))"
        self.disk.stringValue = "\(localizedString("Disk")) /  \(ServerFormat.bytes(metrics.diskUsed)) / \(ServerFormat.bytes(metrics.diskTotal))  (\(ServerFormat.percent(metrics.diskUsage)))"
        self.system.stringValue = ServerFormat.system(metrics)
        self.cpuValue.stringValue = ServerFormat.percent(metrics.cpuUsage)
        self.memoryValue.stringValue = ServerFormat.percent(metrics.memoryUsage)
        self.networkValue.stringValue = "↓ \(ServerFormat.speed(metrics.networkRead))  ↑ \(ServerFormat.speed(metrics.networkWrite))"
    }

    @objc private func back() {
        self.backCallback()
    }
}

internal enum ServerFormat {
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
