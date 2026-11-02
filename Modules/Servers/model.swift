import Cocoa
import Kit

public struct ServerConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var sshAlias: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, sshAlias: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.sshAlias = sshAlias
        self.enabled = enabled
    }
}

public enum ServerConnectionState: String, Codable {
    case idle
    case connecting
    case online
    case error
}

public struct ServerMetrics: Codable {
    public var cpuUsage: Double?
    public var memoryUsage: Double?
    public var memoryUsed: Int64?
    public var memoryTotal: Int64?
    public var diskUsage: Double?
    public var diskUsed: Int64?
    public var diskTotal: Int64?
    public var networkRead: Double?
    public var networkWrite: Double?
    public var latencyMS: Int?
    public var loadAverage: [Double]
    public var uptime: TimeInterval?
    public var osName: String?
    public var hostname: String?
    public var collectedAt: Date

    public init(
        cpuUsage: Double? = nil,
        memoryUsage: Double? = nil,
        memoryUsed: Int64? = nil,
        memoryTotal: Int64? = nil,
        diskUsage: Double? = nil,
        diskUsed: Int64? = nil,
        diskTotal: Int64? = nil,
        networkRead: Double? = nil,
        networkWrite: Double? = nil,
        latencyMS: Int? = nil,
        loadAverage: [Double] = [],
        uptime: TimeInterval? = nil,
        osName: String? = nil,
        hostname: String? = nil,
        collectedAt: Date = Date()
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsage = diskUsage
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.networkRead = networkRead
        self.networkWrite = networkWrite
        self.latencyMS = latencyMS
        self.loadAverage = loadAverage
        self.uptime = uptime
        self.osName = osName
        self.hostname = hostname
        self.collectedAt = collectedAt
    }
}

internal enum ServerHistory {
    internal static let defaultRetention = 3_600
    internal static let displayLimit = 120
    internal static let retentionOptions: [KeyValue_t] = [
        KeyValue_t(key: "1200", value: "20 min"),
        KeyValue_t(key: "3600", value: "1 hour"),
        KeyValue_t(key: "21600", value: "6 hours"),
        KeyValue_t(key: "86400", value: "24 hours")
    ]

    internal static func normalizedRetention(_ value: Int) -> Int {
        self.retentionOptions.contains { $0.key == "\(value)" } ? value : self.defaultRetention
    }

    internal static func append(_ metrics: ServerMetrics, to history: [ServerMetrics], retention: TimeInterval, now: Date = Date()) -> [ServerMetrics] {
        guard history.last?.collectedAt != metrics.collectedAt else {
            return self.prune(history, retention: retention, now: now)
        }
        return self.prune(history + [metrics], retention: retention, now: now)
    }

    internal static func prune(_ history: [ServerMetrics], retention: TimeInterval, now: Date = Date()) -> [ServerMetrics] {
        let cutoff = now.addingTimeInterval(-retention)
        guard let first = history.firstIndex(where: { $0.collectedAt >= cutoff }) else { return [] }
        return first == history.startIndex ? history : Array(history[first...])
    }

    internal static func display(_ history: [ServerMetrics], maxPoints: Int = ServerHistory.displayLimit) -> [ServerMetrics] {
        guard history.count > maxPoints, maxPoints > 1 else { return history }
        return (0..<maxPoints).map { index in
            history[index * (history.count - 1) / (maxPoints - 1)]
        }
    }

    internal static func percentagePoints(_ history: [ServerMetrics], _ metric: KeyPath<ServerMetrics, Double?>) -> [DoubleValue] {
        history.compactMap { sample in
            sample[keyPath: metric].map { DoubleValue($0, ts: sample.collectedAt) }
        }
    }
}

public struct ServerSnapshot: Codable {
    public var config: ServerConfig
    public var state: ServerConnectionState
    public var metrics: ServerMetrics?
    public var history: [ServerMetrics]
    public var errorMessage: String?
    public var lastSuccessAt: Date?

    public init(config: ServerConfig, state: ServerConnectionState = .idle, metrics: ServerMetrics? = nil, history: [ServerMetrics] = [], errorMessage: String? = nil, lastSuccessAt: Date? = nil) {
        self.config = config
        self.state = state
        self.metrics = metrics
        self.history = history
        self.errorMessage = errorMessage
        self.lastSuccessAt = lastSuccessAt
    }
}

public struct ServersSnapshot: Codable {
    public var servers: [ServerSnapshot]

    public init(servers: [ServerSnapshot] = []) {
        self.servers = servers
    }

    public var enabledCount: Int {
        self.servers.filter { $0.config.enabled }.count
    }

    public var onlineCount: Int {
        self.servers.filter { $0.config.enabled && $0.state == .online }.count
    }
}

internal enum ServerStore {
    private static let key = "Servers_configuration"

    internal static func load() -> [ServerConfig] {
        guard let data = Store.shared.data(key: self.key),
              let configs = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return configs
    }

    internal static func save(_ configs: [ServerConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        Store.shared.set(key: self.key, value: data)
    }

    internal static func upsert(_ config: ServerConfig) {
        var configs = self.load()
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        self.save(configs)
    }

    @discardableResult
    internal static func importAliases(_ aliases: [String]) -> Int {
        var configs = self.load()
        var existing = Set(configs.map(\.sshAlias))
        var imported = 0
        for alias in aliases where !existing.contains(alias) {
            configs.append(ServerConfig(name: alias, sshAlias: alias))
            existing.insert(alias)
            imported += 1
        }
        if imported > 0 { self.save(configs) }
        return imported
    }

    internal static func remove(_ id: String) {
        self.save(self.load().filter { $0.id != id })
    }
}
