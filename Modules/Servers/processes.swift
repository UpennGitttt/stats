import Cocoa
import Kit

public struct ServerProcess: Codable {
    public var pid: Int
    public var user: String
    public var cpuUsage: Double
    public var memoryUsage: Double
    public var rssBytes: Int64
    public var command: String

    public init(pid: Int, user: String, cpuUsage: Double, memoryUsage: Double, rssBytes: Int64, command: String) {
        self.pid = pid
        self.user = user
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.rssBytes = rssBytes
        self.command = command
    }
}

public struct ServerProcessList: Codable {
    public var processes: [ServerProcess]
    public var collectedAt: Date

    public init(processes: [ServerProcess], collectedAt: Date = Date()) {
        self.processes = processes
        self.collectedAt = collectedAt
    }
}

internal enum ServerProcessSort {
    case cpu
    case memory
}

internal struct ServerProcessError: Error {
    internal let message: String
}

internal typealias ServerProcessesResult = Result<ServerProcessList, ServerProcessError>

internal enum ServerProcesses {
    internal static let defaultCount = 15
    internal static let countOptions: [KeyValue_t] = [
        KeyValue_t(key: "5", value: "5"),
        KeyValue_t(key: "10", value: "10"),
        KeyValue_t(key: "15", value: "15"),
        KeyValue_t(key: "20", value: "20")
    ]

    internal static var count: Int {
        self.normalizedCount(Store.shared.int(key: "Servers_processCount", defaultValue: self.defaultCount))
    }

    internal static func normalizedCount(_ value: Int) -> Int {
        self.countOptions.contains { $0.key == "\(value)" } ? value : self.defaultCount
    }

    internal static func top(_ list: ServerProcessList, by sort: ServerProcessSort, count: Int) -> [ServerProcess] {
        let sorted = list.processes.sorted { first, second in
            let lhs = sort == .cpu ? first.cpuUsage : first.memoryUsage
            let rhs = sort == .cpu ? second.cpuUsage : second.memoryUsage
            return lhs == rhs ? first.pid < second.pid : lhs > rhs
        }
        return Array(sorted.prefix(self.normalizedCount(count)))
    }
}

internal enum ServerProcessesParser {
    internal static func parse(_ output: String, collectedAt: Date = Date()) throws -> ServerProcessList {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("UNSUPPORTED_OS:") {
            throw LinuxParseError.unsupportedOS(String(text.dropFirst("UNSUPPORTED_OS:".count)))
        }

        var processes: [ServerProcess] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 5, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard fields.count == 6,
                  let pid = Int(fields[0]), pid > 0,
                  let cpu = Double(fields[2]), cpu.isFinite, cpu >= 0,
                  let memory = Double(fields[3]), memory.isFinite, memory >= 0,
                  let rss = Int64(fields[4]), rss >= 0, rss <= Int64.max / 1024 else { continue }
            let command = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            processes.append(ServerProcess(
                pid: pid,
                user: String(fields[1]),
                cpuUsage: cpu / 100,
                memoryUsage: memory / 100,
                rssBytes: rss * 1024,
                command: command
            ))
        }
        guard !processes.isEmpty else { throw LinuxParseError.invalidOutput }
        return ServerProcessList(processes: processes, collectedAt: collectedAt)
    }
}

internal enum ProcessesCommand {
    internal static let script = """
    LC_ALL=C
    export LC_ALL
    ostype=$(uname -s 2>/dev/null || echo Unknown)
    if [ "$ostype" != "Linux" ]; then printf 'UNSUPPORTED_OS:%s\n' "$ostype"; exit 0; fi
    ps -eo pid=,user=,pcpu=,pmem=,rss=,comm=
    """
}

internal final class ServerProcessesView: NSStackView {
    internal var refreshCallback: (() -> Void) = {}
    internal var sizeCallback: (() -> Void) = {}
    internal private(set) var displayedProcesses: [ServerProcess] = []
    internal private(set) var isLoading = false

    private let contentWidth: CGFloat
    private let sortControl = NSSegmentedControl(labels: [localizedString("CPU"), localizedString("Memory")], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: localizedString("Refresh"), target: nil, action: nil)
    private let listView = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint?
    private var documentHeight: NSLayoutConstraint?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let footer = LabelField(size: 9)
    private var snapshot: ServerProcessList?
    private var sort: ServerProcessSort = .cpu
    private var count = ServerProcesses.count

    internal init(contentWidth: CGFloat) {
        self.contentWidth = contentWidth
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 8

        self.sortControl.selectedSegment = 0
        self.sortControl.controlSize = .small
        self.sortControl.target = self
        self.sortControl.action = #selector(self.changeSort)
        self.sortControl.widthAnchor.constraint(equalToConstant: 130).isActive = true
        self.refreshButton.bezelStyle = .rounded
        self.refreshButton.controlSize = .small
        self.refreshButton.target = self
        self.refreshButton.action = #selector(self.refresh)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.addArrangedSubview(self.sortControl)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(self.refreshButton)
        toolbar.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

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
        self.scrollView.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        self.scrollHeight = self.scrollView.heightAnchor.constraint(equalToConstant: 72)
        self.scrollHeight?.isActive = true
        self.documentHeight = self.listView.heightAnchor.constraint(equalToConstant: 72)
        NSLayoutConstraint.activate([
            self.listView.leadingAnchor.constraint(equalTo: self.scrollView.contentView.leadingAnchor),
            self.listView.trailingAnchor.constraint(equalTo: self.scrollView.contentView.trailingAnchor),
            self.listView.topAnchor.constraint(equalTo: self.scrollView.contentView.topAnchor),
            self.listView.widthAnchor.constraint(equalTo: self.scrollView.contentView.widthAnchor),
            self.documentHeight!
        ])

        self.status.font = .systemFont(ofSize: 11)
        self.status.textColor = .secondaryLabelColor
        self.status.alignment = .center
        self.status.preferredMaxLayoutWidth = contentWidth
        self.status.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        self.status.heightAnchor.constraint(equalToConstant: 72).isActive = true
        self.status.isHidden = true
        self.footer.textColor = .secondaryLabelColor
        self.footer.lineBreakMode = .byTruncatingTail
        self.footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        self.addArrangedSubview(toolbar)
        self.addArrangedSubview(self.scrollView)
        self.addArrangedSubview(self.status)
        self.addArrangedSubview(self.footer)
        self.scrollView.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func setCount(_ value: Int) {
        self.count = ServerProcesses.normalizedCount(value)
        self.render()
        self.sizeCallback()
    }

    internal func clear() {
        self.snapshot = nil
        self.displayedProcesses = []
        self.isLoading = false
        self.refreshButton.isEnabled = true
        self.status.stringValue = ""
        self.status.isHidden = true
        self.scrollView.isHidden = true
        self.footer.stringValue = ""
        self.renderRows([])
        self.updateHeight(rowCount: 0)
        self.sizeCallback()
    }

    internal func beginLoading() {
        self.isLoading = true
        self.refreshButton.isEnabled = false
        self.status.stringValue = localizedString("Loading processes…")
        self.status.isHidden = false
        self.scrollView.isHidden = true
        self.footer.stringValue = ""
        self.updateHeight(rowCount: 0)
        self.sizeCallback()
    }

    internal func callback(_ result: ServerProcessesResult) {
        self.isLoading = false
        self.refreshButton.isEnabled = true
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            self.render()
            let time = DateFormatter.localizedString(from: snapshot.collectedAt, dateStyle: .none, timeStyle: .medium)
            self.footer.stringValue = "CPU: lifetime average · \(localizedString("Updated %0", time))"
        case .failure(let error):
            self.snapshot = nil
            self.displayedProcesses = []
            self.renderRows([])
            self.status.stringValue = error.message
            self.status.isHidden = false
            self.scrollView.isHidden = true
            self.footer.stringValue = ""
            self.updateHeight(rowCount: 0)
        }
        self.sizeCallback()
    }

    private func render() {
        guard let snapshot else { return }
        self.displayedProcesses = ServerProcesses.top(snapshot, by: self.sort, count: self.count)
        self.renderRows(self.displayedProcesses)
        self.status.stringValue = localizedString("No processes found")
        self.status.isHidden = !self.displayedProcesses.isEmpty
        self.scrollView.isHidden = self.displayedProcesses.isEmpty
        self.updateHeight(rowCount: self.displayedProcesses.count)
    }

    private func renderRows(_ processes: [ServerProcess]) {
        self.listView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = ServerProcessRow(nil)
        self.listView.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: self.listView.widthAnchor).isActive = true
        for process in processes {
            let row = ServerProcessRow(process)
            self.listView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: self.listView.widthAnchor).isActive = true
        }
    }

    private func updateHeight(rowCount: Int) {
        let contentHeight = CGFloat(rowCount + 1) * 26
        self.scrollHeight?.constant = min(contentHeight, 420)
        self.documentHeight?.constant = contentHeight
    }

    @objc private func changeSort() {
        self.sort = self.sortControl.selectedSegment == 1 ? .memory : .cpu
        self.render()
        self.sizeCallback()
    }

    @objc private func refresh() {
        self.refreshCallback()
    }
}

private final class ServerProcessRow: NSStackView {
    internal init(_ process: ServerProcess?) {
        super.init(frame: .zero)
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 6
        self.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let name = LabelField(process?.command ?? localizedString("Process"), size: 11)
        name.font = .systemFont(ofSize: 11, weight: process == nil ? .semibold : .regular)
        name.textColor = process == nil ? .secondaryLabelColor : .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pid = self.field(process.map { "\($0.pid)" } ?? "PID", width: 44)
        let cpu = self.field(process.map { ServerFormat.percent($0.cpuUsage) } ?? localizedString("CPU"), width: 52)
        let memory = self.field(process.map { ServerFormat.percent($0.memoryUsage) } ?? localizedString("RAM"), width: 52)
        self.addArrangedSubview(name)
        self.addArrangedSubview(pid)
        self.addArrangedSubview(cpu)
        self.addArrangedSubview(memory)

        if let process {
            self.toolTip = "\(process.user) · RSS \(ServerFormat.bytes(process.rssBytes))"
            self.setAccessibilityLabel("\(process.command), PID \(process.pid)")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func field(_ value: String, width: CGFloat) -> NSTextField {
        let field = LabelField(value, size: 11)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }
}
