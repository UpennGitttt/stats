import Cocoa
import Kit

public final class DataReader: Reader<ServersSnapshot> {
    private let stateQueue = DispatchQueue(label: "eu.exelban.Stats.Servers.state")
    private let workerQueue = DispatchQueue(label: "eu.exelban.Stats.Servers.worker", qos: .utility, attributes: .concurrent)
    private let ssh: SSHClient
    private let loadConfigurations: () -> [ServerConfig]
    private var snapshots: [String: ServerSnapshot] = [:]
    private var baselines: [String: LinuxSample] = [:]
    private var histories: [String: [ServerMetrics]] = [:]
    private var retentionInterval = TimeInterval(ServerHistory.defaultRetention)
    private var pending: [ServerConfig] = []
    private var inFlight: Set<String> = []
    private var generation: UInt = 0
    private var readRequested = false
    private var stopped = false

    internal init(
        ssh: SSHClient = SSHClient(),
        loadConfigurations: @escaping () -> [ServerConfig] = ServerStore.load,
        callback: @escaping (ServersSnapshot?) -> Void = { _ in }
    ) {
        self.ssh = ssh
        self.loadConfigurations = loadConfigurations
        super.init(.servers, callback: callback)
    }

    public override func setup() {
        self.defaultInterval = 10
        let retention = Store.shared.int(key: "Servers_historyRetention", defaultValue: ServerHistory.defaultRetention)
        self.retentionInterval = TimeInterval(ServerHistory.normalizedRetention(retention))
    }

    internal func setHistoryRetention(_ value: Int) {
        self.stateQueue.async {
            self.retentionInterval = TimeInterval(ServerHistory.normalizedRetention(value))
            self.emit()
        }
    }

    public override func start() {
        self.stateQueue.sync { self.stopped = false }
        super.start()
    }

    public override func read() {
        self.stateQueue.async { self.beginRead() }
    }

    public override func pause() {
        super.pause()
        self.invalidateRead()
    }

    public override func stop() {
        super.stop()
        self.invalidateRead()
    }

    public override func terminate() {
        self.invalidateRead()
    }

    private func beginRead() {
        guard !self.stopped else { return }
        guard self.inFlight.isEmpty else {
            self.readRequested = true
            return
        }
        self.readRequested = false
        self.generation &+= 1

        let configs = self.loadConfigurations()
        let ids = Set(configs.map(\.id))
        self.snapshots = self.snapshots.filter { ids.contains($0.key) }
        self.baselines = self.baselines.filter { ids.contains($0.key) }
        self.histories = self.histories.filter { ids.contains($0.key) }
        for config in configs {
            var snapshot = self.snapshots[config.id] ?? ServerSnapshot(config: config)
            let sameTarget = snapshot.config.sshAlias == config.sshAlias
            snapshot.config = config
            if !sameTarget {
                snapshot.state = .idle
                snapshot.metrics = nil
                snapshot.history = []
                snapshot.errorMessage = nil
                snapshot.lastSuccessAt = nil
                self.baselines.removeValue(forKey: config.id)
                self.histories.removeValue(forKey: config.id)
            }
            if !config.enabled {
                snapshot.state = .idle
                snapshot.errorMessage = nil
            } else if snapshot.state == .idle {
                snapshot.state = .connecting
            }
            self.snapshots[config.id] = snapshot
        }
        self.pending = configs.filter { $0.enabled }
        self.emit()
        self.pump()
    }

    private func pump() {
        while self.inFlight.count < 3, !self.pending.isEmpty {
            let config = self.pending.removeFirst()
            let generation = self.generation
            self.inFlight.insert(config.id)
            self.workerQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.ssh.collect(config) }
                self.stateQueue.async {
                    self.complete(config, generation: generation, result: result)
                }
            }
        }
    }

    private func complete(_ config: ServerConfig, generation: UInt, result: Result<SSHCommandResult, Error>) {
        self.inFlight.remove(config.id)
        guard generation == self.generation, !self.stopped else { return }
        switch result {
        case .success(let value):
            do {
                let sample = try LinuxMetricsParser.parse(value.output)
                let metrics = SampleCalculator.metrics(from: sample, previous: self.baselines[config.id], latencyMS: value.latencyMS)
                self.baselines[config.id] = sample
                let history = ServerHistory.append(metrics, to: self.histories[config.id] ?? [], retention: self.retentionInterval)
                self.histories[config.id] = history
                self.snapshots[config.id] = ServerSnapshot(
                    config: config,
                    state: .online,
                    metrics: metrics,
                    history: ServerHistory.display(history),
                    lastSuccessAt: sample.collectedAt
                )
            } catch {
                self.setError(self.describe(error), for: config)
            }
        case .failure(let error):
            if case SSHError.cancelled = error { return }
            self.setError(self.describe(error), for: config)
        }
        self.emit()
        self.pump()
        if self.inFlight.isEmpty && self.pending.isEmpty && self.readRequested {
            self.beginRead()
        }
    }

    private func setError(_ message: String, for config: ServerConfig) {
        guard var snapshot = self.snapshots[config.id], snapshot.config.sshAlias == config.sshAlias else { return }
        snapshot.state = .error
        snapshot.errorMessage = message
        self.snapshots[config.id] = snapshot
    }

    private func emit() {
        for (id, history) in self.histories {
            let pruned = ServerHistory.prune(history, retention: self.retentionInterval)
            self.histories[id] = pruned
            self.snapshots[id]?.history = ServerHistory.display(pruned)
        }
        let configs = self.loadConfigurations()
        let snapshot = ServersSnapshot(servers: configs.compactMap { self.snapshots[$0.id] })
        self.callbackHandler(snapshot)
    }

    private func invalidateRead() {
        self.stateQueue.async {
            self.stopped = true
            self.generation &+= 1
            self.pending.removeAll()
            self.readRequested = false
            self.ssh.cancelAll()
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? SSHError { return error.localizedDescription }
        if let error = error as? LinuxParseError {
            switch error {
            case .unsupportedOS(let name): return localizedString("Only Linux servers are supported (received %0)", name)
            case .invalidOutput: return localizedString("Invalid response from server")
            case .missingField(let field): return localizedString("Missing metric: %0", field)
            case .invalidField(let field): return localizedString("Invalid metric: %0", field)
            }
        }
        return error.localizedDescription
    }
}
