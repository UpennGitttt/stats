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
