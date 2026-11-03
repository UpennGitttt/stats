import Cocoa
import Kit

public final class Servers: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let previewView: Preview
    private var dataReader: DataReader?

    public init() {
        self.popupView = Popup()
        self.settingsView = Settings()
        self.previewView = Preview()
        super.init(moduleType: .servers, popup: self.popupView, settings: self.settingsView, preview: self.previewView)

        self.dataReader = DataReader { [weak self] snapshot in
            self?.callback(snapshot)
        }
        self.settingsView.callback = { [weak self] in
            self?.dataReader?.read()
        }
        self.settingsView.intervalCallback = { [weak self] value in
            self?.dataReader?.setInterval(value)
        }
        self.settingsView.historyCallback = { [weak self] value in
            self?.dataReader?.setHistoryRetention(value)
        }
        self.settingsView.processCountCallback = { [weak self] value in
            self?.popupView.setProcessCount(value)
            self?.previewView.setProcessCount(value)
        }
        self.popupView.refreshCallback = { [weak self] in
            self?.dataReader?.read()
        }
        self.popupView.settingsCallback = {
            NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": ModuleType.servers.stringValue])
        }
        self.popupView.processesCallback = { [weak self] config in
            self?.loadProcesses(config)
        }
        self.previewView.processesCallback = { [weak self] config in
            self?.loadProcesses(config)
        }
        self.setReaders([self.dataReader])
    }

    private func loadProcesses(_ config: ServerConfig) {
        self.dataReader?.readProcesses(config) { [weak self] result in
            self?.popupView.processCallback(result, for: config)
            self?.previewView.processCallback(result, for: config)
        }
    }

    private func callback(_ snapshot: ServersSnapshot?) {
        guard let snapshot, self.enabled else { return }
        DispatchQueue.main.async {
            self.popupView.callback(snapshot)
            self.previewView.callback(snapshot)
        }

        let enabled = snapshot.servers.filter(\.config.enabled)
        let text = Self.statusText(snapshot)
        let color = self.aggregateColor(enabled)
        self.menuBar.widgets.filter(\.isActive).forEach { widget in
            switch widget.item {
            case let item as TextWidget: item.setValue(text)
            case let item as DotWidget: item.setValue(color)
            default: break
            }
        }
    }

    internal static func statusText(_ snapshot: ServersSnapshot) -> String {
        let enabled = snapshot.servers.filter(\.config.enabled)
        guard !enabled.isEmpty else { return localizedString("Servers") }
        return localizedString("Servers %0/%1", "\(snapshot.onlineCount)", "\(enabled.count)")
    }

    private func aggregateColor(_ servers: [ServerSnapshot]) -> NSColor {
        guard !servers.isEmpty else { return .systemGray }
        let online = servers.filter { $0.state == .online }.count
        if online == servers.count { return .systemGreen }
        if servers.allSatisfy({ $0.state == .error }) { return .systemRed }
        return .systemOrange
    }
}
