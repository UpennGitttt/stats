import Cocoa
import XCTest
import Kit
@testable import Servers

final class ServersTests: XCTestCase {
    private func sample(
        cpuTotal: UInt64 = 1_000,
        cpuIdle: UInt64 = 600,
        memoryAvailable: UInt64 = 500,
        rx: UInt64 = 1_000,
        tx: UInt64 = 2_000,
        uptime: Double = 100
    ) throws -> LinuxSample {
        try LinuxMetricsParser.parse("STATS_V1|CPURAW:\(cpuTotal) \(cpuIdle)|MEMINFO:2000 \(memoryAvailable)|DISK:10000 2500|NET:\(rx) \(tx)|HOST:test-host|OS:Ubuntu 24.04|UPTIME:\(uptime)|LOAD:0.1 0.2 0.3")
    }

    func testParsesMetricsProtocol() throws {
        let sample = try self.sample()
        XCTAssertEqual(sample.cpuTotal, 1_000)
        XCTAssertEqual(sample.cpuIdle, 600)
        XCTAssertEqual(sample.memoryTotal, 2_048_000)
        XCTAssertEqual(sample.memoryUsed, 1_536_000)
        XCTAssertEqual(sample.diskUsed, 2_560_000)
        XCTAssertEqual(sample.hostname, "test-host")
        XCTAssertEqual(sample.osName, "Ubuntu 24.04")
        XCTAssertEqual(sample.loadAverage, [0.1, 0.2, 0.3])
    }

    func testRejectsUnsupportedOS() {
        XCTAssertThrowsError(try LinuxMetricsParser.parse("UNSUPPORTED_OS:Darwin")) { error in
            XCTAssertEqual(error as? LinuxParseError, .unsupportedOS("Darwin"))
        }
    }

    func testRejectsInvalidAndMissingFields() {
        XCTAssertThrowsError(try LinuxMetricsParser.parse("not-a-stats-response"))
        XCTAssertThrowsError(try LinuxMetricsParser.parse("STATS_V1|CPURAW:1 2")) { error in
            XCTAssertEqual(error as? LinuxParseError, .missingField("MEMINFO"))
        }
        XCTAssertThrowsError(try LinuxMetricsParser.parse("STATS_V1|CPURAW:-1 2|MEMINFO:2000 500|DISK:10000 2500|NET:1 2|UPTIME:10")) { error in
            XCTAssertEqual(error as? LinuxParseError, .invalidField("CPURAW"))
        }
    }

    func testFirstSampleHasNoDeltas() throws {
        let metrics = SampleCalculator.metrics(from: try self.sample(), previous: nil, latencyMS: 25)
        XCTAssertNil(metrics.cpuUsage)
        XCTAssertNil(metrics.networkRead)
        XCTAssertNil(metrics.networkWrite)
        XCTAssertEqual(try XCTUnwrap(metrics.memoryUsage), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.diskUsage), 0.25, accuracy: 0.0001)
        XCTAssertEqual(metrics.latencyMS, 25)
    }

    func testCalculatesDeltas() throws {
        let first = try self.sample()
        let second = try self.sample(cpuTotal: 1_400, cpuIdle: 700, rx: 2_000, tx: 5_000, uptime: 110)
        let metrics = SampleCalculator.metrics(from: second, previous: first, latencyMS: 20)
        XCTAssertEqual(metrics.cpuUsage ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(metrics.networkRead ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(metrics.networkWrite ?? 0, 300, accuracy: 0.0001)
    }

    func testCounterRollbackDoesNotUnderflow() throws {
        let first = try self.sample(cpuTotal: 5_000, cpuIdle: 4_000, rx: 5_000, tx: 5_000)
        let second = try self.sample(cpuTotal: 100, cpuIdle: 90, rx: 100, tx: 100, uptime: 110)
        let metrics = SampleCalculator.metrics(from: second, previous: first, latencyMS: 20)
        XCTAssertNil(metrics.cpuUsage)
        XCTAssertNil(metrics.networkRead)
        XCTAssertNil(metrics.networkWrite)
        XCTAssertNotNil(metrics.memoryUsage)
    }

    func testServerRestartClearsDeltas() throws {
        let first = try self.sample(uptime: 5_000)
        let second = try self.sample(cpuTotal: 1_400, cpuIdle: 700, uptime: 10)
        let metrics = SampleCalculator.metrics(from: second, previous: first, latencyMS: 20)
        XCTAssertNil(metrics.cpuUsage)
        XCTAssertNil(metrics.networkRead)
        XCTAssertNil(metrics.networkWrite)
    }

    func testSnapshotCountsOnlyEnabledOnlineServers() {
        let online = ServerConfig(name: "One", sshAlias: "one")
        let offline = ServerConfig(name: "Two", sshAlias: "two")
        let disabled = ServerConfig(name: "Three", sshAlias: "three", enabled: false)
        let snapshot = ServersSnapshot(servers: [
            ServerSnapshot(config: online, state: .online),
            ServerSnapshot(config: offline, state: .error),
            ServerSnapshot(config: disabled, state: .online)
        ])
        XCTAssertEqual(snapshot.enabledCount, 2)
        XCTAssertEqual(snapshot.onlineCount, 1)
        XCTAssertEqual(Servers.statusText(snapshot), "Servers 1/2")
        XCTAssertEqual(Servers.statusText(ServersSnapshot()), "Servers")
    }

    func testSSHConfigImportParsesAliasesAndSkipsPatterns() {
        let contents = """
        # managed hosts
        Host alpha
            HostName example.com
        Host duplicate
        Host duplicate
        Host * ?bad !bad
        Host=production
        Host "prod one" # quoted alias
        Host = workstation
        Host 192.0.2.10
        """
        let aliases = SSHConfigImporter.aliases(from: contents)
        XCTAssertEqual(aliases, ["alpha", "duplicate", "production", "prod one", "workstation", "192.0.2.10"])
        let existing = [ServerConfig(name: "Existing", sshAlias: "duplicate")]
        XCTAssertEqual(SSHConfigImporter.newAliases(aliases, existing: existing), ["alpha", "production", "prod one", "workstation", "192.0.2.10"])
    }

    func testSSHTransportUsesSafeArgumentsAndParsesResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        let output = "STATS_V1|CPURAW:100 60|MEMINFO:2000 500|DISK:10000 2500|NET:1000 2000|HOST:test|OS:Linux|UPTIME:100|LOAD:0 0 0"
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(directory.path)/arguments\"\ncat >/dev/null\nprintf '%s\\n' '\(output)'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = SSHClient(executablePath: executable.path, controlDirectory: directory.appendingPathComponent("control"))
        let result = try client.collect(ServerConfig(name: "Test", sshAlias: "integration-test"))
        let sample = try LinuxMetricsParser.parse(result.output)
        XCTAssertEqual(sample.hostname, "test")

        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("integration-test"))
    }

    func testSSHTimeoutTerminatesProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        try Data("#!/bin/sh\ncat >/dev/null\nsleep 5\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = SSHClient(executablePath: executable.path, controlDirectory: directory.appendingPathComponent("control"))
        XCTAssertThrowsError(try client.collect(ServerConfig(name: "Test", sshAlias: "test"), timeout: 0.1)) { error in
            guard case SSHError.timeout = error else { return XCTFail("Expected timeout, got \(error)") }
        }
    }

    func testReaderKeepsMetricsOnFailureAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        let counter = directory.appendingPathComponent("counter")
        let output = "STATS_V1|CPURAW:100 60|MEMINFO:2000 500|DISK:10000 2500|NET:1000 2000|HOST:test|OS:Linux|UPTIME:100|LOAD:0 0 0"
        let script = """
        #!/bin/sh
        cat >/dev/null
        count=0
        if [ -f '\(counter.path)' ]; then count=$(cat '\(counter.path)'); fi
        count=$((count + 1))
        printf '%s\n' "$count" > '\(counter.path)'
        if [ "$count" -eq 2 ]; then printf 'simulated disconnect\n' >&2; exit 1; fi
        printf '%s\n' '\(output)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = SSHClient(executablePath: executable.path, controlDirectory: directory.appendingPathComponent("control"))
        let config = ServerConfig(name: "Test", sshAlias: "test")
        let offline = self.expectation(description: "Server reports offline")
        let online = self.expectation(description: "Server connects and recovers")
        online.expectedFulfillmentCount = 2
        let lock = NSLock()
        var snapshots: [ServerSnapshot] = []
        var lastEvent: String?
        var reader: DataReader!
        reader = DataReader(ssh: client, loadConfigurations: { [config] }) { snapshot in
            guard let server = snapshot?.servers.first else { return }
            guard server.state == .online || server.state == .error else { return }
            let event = "\(server.state.rawValue)|\(server.lastSuccessAt?.timeIntervalSince1970 ?? 0)|\(server.errorMessage ?? "")"
            lock.lock()
            guard event != lastEvent else {
                lock.unlock()
                return
            }
            lastEvent = event
            snapshots.append(server)
            let count = snapshots.count
            lock.unlock()
            switch server.state {
            case .online:
                online.fulfill()
                if count == 1 { reader.read() }
            case .error:
                offline.fulfill()
                reader.read()
            default: break
            }
        }
        reader.read()
        self.wait(for: [offline, online], timeout: 5)
        reader.stop()
        XCTAssertEqual(snapshots.map(\.state), [.online, .error, .online])
        XCTAssertNotNil(snapshots[1].metrics)
        XCTAssertEqual(snapshots[1].errorMessage, "simulated disconnect")
        XCTAssertNil(snapshots[2].errorMessage)
        XCTAssertEqual(snapshots.map(\.history.count), [1, 1, 2])
    }

    func testHistoryUsesRetentionAndDeduplicates() throws {
        let start = Date(timeIntervalSince1970: 0)
        var history: [ServerMetrics] = []
        for index in 0...120 {
            let now = start.addingTimeInterval(TimeInterval(index))
            let metrics = ServerMetrics(cpuUsage: Double(index), collectedAt: now)
            history = ServerHistory.append(metrics, to: history, retention: 60, now: now)
        }
        XCTAssertEqual(history.count, 61)
        XCTAssertEqual(history.first?.cpuUsage, 60)
        XCTAssertEqual(history.last?.cpuUsage, 120)
        let last = try XCTUnwrap(history.last)
        let duplicate = ServerHistory.append(last, to: history, retention: 60, now: start.addingTimeInterval(120))
        XCTAssertEqual(duplicate.count, 61)
        let pruned = ServerHistory.prune(history, retention: 60, now: start.addingTimeInterval(180))
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.cpuUsage, 120)
        XCTAssertTrue(ServerHistory.prune(history, retention: 60, now: start.addingTimeInterval(181)).isEmpty)
    }

    func testPercentageChartPointsUseFractionalValues() throws {
        let date = Date(timeIntervalSince1970: 100)
        let history = [ServerMetrics(cpuUsage: 0.2, memoryUsage: 0.125, collectedAt: date)]
        let cpu = ServerHistory.percentagePoints(history, \.cpuUsage)
        let memory = ServerHistory.percentagePoints(history, \.memoryUsage)
        XCTAssertEqual(try XCTUnwrap(cpu.first).value, 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(cpu.first).ts, date)
        XCTAssertEqual(Int(cpu[0].value.rounded(toPlaces: 2) * 100), 20)
        XCTAssertEqual(Int(memory[0].value.rounded(toPlaces: 2) * 100), 13)
    }

    func testHistoryDownsamplingKeepsEndpointsForLongestWindow() {
        let start = Date(timeIntervalSince1970: 0)
        var history: [ServerMetrics] = []
        for index in 0...17_280 {
            history.append(ServerMetrics(collectedAt: start.addingTimeInterval(TimeInterval(index * 5))))
        }
        let display = ServerHistory.display(history)
        XCTAssertEqual(history.count, 17_281)
        XCTAssertEqual(display.count, 120)
        XCTAssertEqual(display.first?.collectedAt, start)
        XCTAssertEqual(display.last?.collectedAt, start.addingTimeInterval(86_400))
        XCTAssertEqual(Set(display.map(\.collectedAt)).count, 120)
        XCTAssertEqual(ServerHistory.display(Array(history.prefix(20))).count, 20)
    }

    func testProcessParsingSortingAndCountLimit() throws {
        let output = """
          1 root      2.0 10.0   1024 init
          2 user     95.5  2.0 204800 node app
          3 user      5.0 80.0   4096 postgres
          4 user     -1.0  1.0   4096 invalid
          5 user      1.0  1.0 9223372036854775807 overflow
        """
        let list = try ServerProcessesParser.parse(output)
        XCTAssertEqual(list.processes.count, 3)
        XCTAssertEqual(list.processes[1].pid, 2)
        XCTAssertEqual(list.processes[1].user, "user")
        XCTAssertEqual(list.processes[1].command, "node app")
        XCTAssertEqual(list.processes[1].rssBytes, 209_715_200)
        XCTAssertEqual(list.processes[1].cpuUsage, 0.955, accuracy: 0.0001)
        XCTAssertEqual(ServerProcesses.top(list, by: .cpu, count: 20).map(\.pid), [2, 3, 1])
        XCTAssertEqual(ServerProcesses.top(list, by: .memory, count: 20).map(\.pid), [3, 1, 2])
        XCTAssertEqual(ServerProcesses.top(list, by: .cpu, count: 5).count, 3)
        XCTAssertEqual(ServerProcesses.defaultCount, 15)
        XCTAssertEqual(ServerProcesses.normalizedCount(20), 20)
        XCTAssertEqual(ServerProcesses.normalizedCount(21), 15)
        XCTAssertEqual(ServerProcesses.normalizedCount(0), 15)
        XCTAssertThrowsError(try ServerProcessesParser.parse("not-a-process-list"))
    }

    func testLegacyServerConfigurationKeepsProcessesDisabled() throws {
        let legacy = #"{"id":"one","name":"One","sshAlias":"one","enabled":true}"#
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.processesEnabled)
        XCTAssertFalse(ServerConfig(name: "New", sshAlias: "new").processesEnabled)

        let enabled = ServerConfig(name: "Enabled", sshAlias: "enabled", processesEnabled: true)
        let data = try JSONEncoder().encode(enabled)
        XCTAssertTrue(try JSONDecoder().decode(ServerConfig.self, from: data).processesEnabled)
    }

    func testProcessReaderIsOptInAndCoalescesRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        let counter = directory.appendingPathComponent("process-requests")
        let script = """
        #!/bin/sh
        cat >/dev/null
        count=0
        if [ -f '\(counter.path)' ]; then count=$(cat '\(counter.path)'); fi
        count=$((count + 1))
        printf '%s\n' "$count" > '\(counter.path)'
        sleep 0.2
        printf '  2 user 95.5 2.0 204800 node app\n  1 root 2.0 10.0 1024 init\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = SSHClient(executablePath: executable.path, controlDirectory: directory.appendingPathComponent("control"))
        let direct = try client.topProcesses(ServerConfig(id: "direct", name: "Direct", sshAlias: "direct"))
        XCTAssertEqual(try ServerProcessesParser.parse(direct.output).processes.count, 2)
        try FileManager.default.removeItem(at: counter)

        let disabled = ServerConfig(id: "disabled", name: "Disabled", sshAlias: "disabled")
        let disabledClient = SSHClient(executablePath: executable.path, controlDirectory: directory.appendingPathComponent("disabled-control"))
        let disabledReader = DataReader(ssh: disabledClient, loadConfigurations: { [disabled] })
        let denied = self.expectation(description: "Disabled server does not execute process query")
        disabledReader.readProcesses(disabled) { result in
            guard case .failure = result else { return XCTFail("Expected disabled process query to fail") }
            denied.fulfill()
        }
        self.wait(for: [denied], timeout: 1)
        disabledReader.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: counter.path))

        let config = ServerConfig(id: "enabled", name: "Enabled", sshAlias: "enabled", processesEnabled: true)
        let reader = DataReader(ssh: client, loadConfigurations: { [config] })
        let responses = self.expectation(description: "Both views receive the same process response")
        responses.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            reader.readProcesses(config) { result in
                switch result {
                case .success(let list): XCTAssertEqual(list.processes.count, 2)
                case .failure(let error): XCTFail("Unexpected process query error: \(error.message)")
                }
                responses.fulfill()
            }
        }
        self.wait(for: [responses], timeout: 3)
        reader.stop()
        let calls = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(calls, 1)
    }

    func testProcessesScriptHasValidShellSyntax() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-n"]
        let input = Pipe()
        task.standardInput = input
        try task.run()
        try input.fileHandleForWriting.write(contentsOf: Data(ProcessesCommand.script.utf8))
        try input.fileHandleForWriting.close()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    @MainActor
    func testProcessCountSettings() throws {
        let key = "Servers_processCount"
        let hadValue = Store.shared.exist(key: key)
        let previous = Store.shared.int(key: key, defaultValue: ServerProcesses.defaultCount)
        defer {
            if hadValue {
                Store.shared.set(key: key, value: previous)
            } else {
                Store.shared.remove(key)
            }
        }
        let settings = Settings()
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let popup = try XCTUnwrap(descendants(of: settings).compactMap { $0 as? NSPopUpButton }.first {
            popup in popup.menu?.items.contains { ($0.representedObject as? String) == "20" } ?? false
        })
        XCTAssertEqual(popup.selectedItem?.representedObject as? String, "15")
        var received: Int?
        settings.processCountCallback = { received = $0 }
        let item = try XCTUnwrap(popup.menu?.items.first { ($0.representedObject as? String) == "20" })
        popup.select(item)
        _ = try XCTUnwrap(popup.target as? NSObject).perform(try XCTUnwrap(popup.action), with: item)
        XCTAssertEqual(received, 20)
        XCTAssertEqual(Store.shared.int(key: key, defaultValue: 0), 20)
    }

    @MainActor
    func testTopProcessesViewIsOptInAndUsesSelectedCount() throws {
        let disabled = ServerConfig(id: "disabled", name: "Disabled", sshAlias: "disabled")
        let disabledDetail = ServerDetailView(ServerSnapshot(config: disabled))
        XCTAssertFalse(disabledDetail.modeControl.isEnabled(forSegment: 1))
        disabledDetail.showProcesses()
        XCTAssertEqual(disabledDetail.modeControl.selectedSegment, 0)

        let config = ServerConfig(id: "enabled", name: "Enabled", sshAlias: "enabled", processesEnabled: true)
        let detail = ServerDetailView(ServerSnapshot(config: config))
        var requests = 0
        detail.processesCallback = { _ in requests += 1 }
        XCTAssertEqual(requests, 0)
        detail.showProcesses()
        detail.showProcesses()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(detail.processesView.isLoading)

        let processes = (1...25).map { index in
            ServerProcess(
                pid: index,
                user: "user",
                cpuUsage: Double(index) / 100,
                memoryUsage: Double(26 - index) / 100,
                rssBytes: Int64(index * 1024),
                command: "process-\(index)"
            )
        }
        let list = ServerProcessList(processes: processes)
        detail.processCallback(.success(list), for: config)
        XCTAssertFalse(detail.processesView.isLoading)
        XCTAssertEqual(detail.processesView.displayedProcesses.count, 15)
        XCTAssertEqual(detail.processesView.displayedProcesses.first?.pid, 25)

        detail.setProcessCount(20)
        XCTAssertEqual(detail.processesView.displayedProcesses.count, 20)
        XCTAssertEqual(requests, 1)
        detail.modeControl.selectedSegment = 0
        _ = detail.perform(try XCTUnwrap(detail.modeControl.action))
        detail.showProcesses()
        XCTAssertEqual(requests, 1)

        let wrongHost = ServerConfig(id: config.id, name: config.name, sshAlias: "another-host", processesEnabled: true)
        detail.processCallback(.success(ServerProcessList(processes: [])), for: wrongHost)
        XCTAssertEqual(detail.processesView.displayedProcesses.count, 20)

        detail.setFrameSize(NSSize(width: 360, height: detail.fittingSize.height))
        detail.layoutSubtreeIfNeeded()
        try self.capture(detail, name: "processes")

        detail.processCallback(.failure(ServerProcessError(message: "Query failed")), for: config)
        XCTAssertTrue(detail.processesView.displayedProcesses.isEmpty)
        detail.setProcessCount(21)
        XCTAssertEqual(ServerProcesses.normalizedCount(21), 15)
    }

    @MainActor
    func testLiveSSHMetricsCollection() throws {
        guard let alias = ProcessInfo.processInfo.environment["STATS_TEST_SSH_ALIAS"], !alias.isEmpty else {
            throw XCTSkip("Set STATS_TEST_SSH_ALIAS to test a trusted SSH host")
        }
        let config = ServerConfig(name: alias, sshAlias: alias, processesEnabled: true)
        let client = SSHClient()
        let firstResult = try client.collect(config)
        let first = try LinuxMetricsParser.parse(firstResult.output)
        sleep(2)
        let secondResult = try client.collect(config)
        let second = try LinuxMetricsParser.parse(secondResult.output)
        let metrics = SampleCalculator.metrics(from: second, previous: first, latencyMS: secondResult.latencyMS)

        XCTAssertGreaterThan(second.memoryTotal, 0)
        XCTAssertGreaterThan(second.diskTotal, 0)
        XCTAssertTrue((0.0...1.0).contains(try XCTUnwrap(metrics.cpuUsage)))
        XCTAssertTrue((0.0...1.0).contains(try XCTUnwrap(metrics.memoryUsage)))
        XCTAssertTrue((0.0...1.0).contains(try XCTUnwrap(metrics.diskUsage)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics.networkRead), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics.networkWrite), 0)
        XCTAssertGreaterThan(metrics.latencyMS ?? 0, 0)
        print("Live SSH metrics for \(second.hostname ?? alias): CPU=\((metrics.cpuUsage ?? 0) * 100)%, memory=\((metrics.memoryUsage ?? 0) * 100)%, disk=\((metrics.diskUsage ?? 0) * 100)%, rx=\(metrics.networkRead ?? 0) B/s, tx=\(metrics.networkWrite ?? 0) B/s, latency=\(metrics.latencyMS ?? 0) ms, OS=\(second.osName ?? "unknown")")
        let snapshot = ServerSnapshot(config: config, state: .online, metrics: metrics, lastSuccessAt: second.collectedAt)
        let popup = Popup()
        popup.callback(ServersSnapshot(servers: [snapshot]))
        popup.layoutSubtreeIfNeeded()
        try self.capture(popup, name: "live")
        popup.showDetails(snapshot)
        popup.layoutSubtreeIfNeeded()
        try self.capture(popup, name: "live-detail")

        let processResult = try client.topProcesses(config)
        let processList = try ServerProcessesParser.parse(processResult.output)
        XCTAssertFalse(processList.processes.isEmpty)
        XCTAssertLessThanOrEqual(ServerProcesses.top(processList, by: .cpu, count: 20).count, 20)
        let detail = ServerDetailView(snapshot)
        detail.showProcesses()
        detail.processCallback(.success(processList), for: config)
        detail.setFrameSize(NSSize(width: 360, height: detail.fittingSize.height))
        detail.layoutSubtreeIfNeeded()
        try self.capture(detail, name: "live-processes")
        print("Live SSH process query returned \(processList.processes.count) processes")
    }

    @MainActor
    func testEditorLayoutKeepsInputFieldsVisible() throws {
        let editor = Settings.editorView(nil)
        let alert = NSAlert()
        alert.messageText = localizedString("Add server")
        alert.informativeText = localizedString("The SSH alias can be a Host from ~/.ssh/config or user@host.")
        alert.addButton(withTitle: localizedString("Save"))
        alert.addButton(withTitle: localizedString("Cancel"))
        alert.accessoryView = editor.form
        alert.layout()
        let content = try XCTUnwrap(alert.window.contentView)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(editor.form.frame.width, 340, accuracy: 0.001)
        for field in [editor.name, editor.alias] {
            XCTAssertEqual(field.frame.width, 340, accuracy: 0.001)
            XCTAssertEqual(field.frame.height, 24, accuracy: 0.001)
            XCTAssertTrue(editor.form.bounds.contains(field.frame))
        }
        let accessory = try XCTUnwrap(editor.form.superview)
        let information = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == localizedString("The SSH alias can be a Host from ~/.ssh/config or user@host.")
        })
        XCTAssertGreaterThanOrEqual(accessory.frame.width, editor.form.frame.width)
        XCTAssertLessThanOrEqual(accessory.frame.maxY, information.frame.minY)
        try self.capture(content, name: "editor")
    }

    @MainActor
    func testSSHConfigImportViewLayout() throws {
        let aliases = (1...10).map { "server-\($0)" }
        let editor = Settings.importView(aliases)
        let alert = NSAlert()
        alert.messageText = localizedString("Import SSH config")
        alert.informativeText = localizedString("Select new hosts to import. Only Linux servers are supported; existing aliases are skipped.")
        alert.addButton(withTitle: localizedString("Import"))
        alert.addButton(withTitle: localizedString("Cancel"))
        alert.accessoryView = editor.view
        alert.layout()
        let content = try XCTUnwrap(alert.window.contentView)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(editor.view.frame.width, 340, accuracy: 0.001)
        XCTAssertEqual(editor.view.frame.height, 240, accuracy: 0.001)
        XCTAssertEqual(editor.toggles.count, 10)
        XCTAssertTrue(editor.toggles.allSatisfy { $0.state == .on && $0.frame.width > 200 })
        let accessory = try XCTUnwrap(editor.view.superview)
        let information = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == localizedString("Select new hosts to import. Only Linux servers are supported; existing aliases are skipped.")
        })
        XCTAssertGreaterThanOrEqual(accessory.frame.width, editor.view.frame.width)
        XCTAssertLessThanOrEqual(accessory.frame.maxY, information.frame.minY)
        try self.capture(content, name: "import")
    }

    @MainActor
    func testHistoryRetentionSettings() throws {
        let key = "Servers_historyRetention"
        let hadValue = Store.shared.exist(key: key)
        let previous = Store.shared.int(key: key, defaultValue: ServerHistory.defaultRetention)
        defer {
            if hadValue {
                Store.shared.set(key: key, value: previous)
            } else {
                Store.shared.remove(key)
            }
        }
        let config = ServerConfig(id: "layout", name: "Production server", sshAlias: "production-long-alias")
        let settings = Settings(loadConfigurations: { [config] })
        settings.load(widgets: [])
        settings.setFrameSize(NSSize(width: 480, height: 560))
        settings.layoutSubtreeIfNeeded()
        try self.capture(settings, name: "settings")
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let buttons = descendants(of: settings).compactMap { $0 as? NSButton }
        let topToggle = try XCTUnwrap(buttons.first { $0.title == localizedString("Top") })
        XCTAssertEqual(topToggle.state, .off)
        XCTAssertTrue(topToggle.isEnabled)
        for title in ["Top", "Edit", "Remove"] {
            let button = try XCTUnwrap(buttons.first { $0.title == localizedString(title) })
            XCTAssertTrue(settings.bounds.contains(button.convert(button.bounds, to: settings)))
        }
        let popups = descendants(of: settings).compactMap { $0 as? NSPopUpButton }
        let historyPopup = try XCTUnwrap(popups.first { popup in
            popup.menu?.items.contains { ($0.representedObject as? String) == "86400" } ?? false
        })
        let keys = Set(historyPopup.menu?.items.compactMap { $0.representedObject as? String } ?? [])
        XCTAssertEqual(keys, ["1200", "3600", "21600", "86400"])
        var received: Int?
        settings.historyCallback = { received = $0 }
        let item = try XCTUnwrap(historyPopup.menu?.items.first { ($0.representedObject as? String) == "86400" })
        historyPopup.select(item)
        let action = try XCTUnwrap(historyPopup.action)
        let target = try XCTUnwrap(historyPopup.target as? NSObject)
        _ = target.perform(action, with: item)
        XCTAssertEqual(received, 86_400)
        XCTAssertEqual(Store.shared.int(key: key, defaultValue: 0), 86_400)
    }

    func testMetricsScriptHasValidShellSyntax() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-n"]
        let input = Pipe()
        task.standardInput = input
        try task.run()
        try input.fileHandleForWriting.write(contentsOf: Data(MetricsCommand.script.utf8))
        try input.fileHandleForWriting.close()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    @MainActor
    func testPopupListAndDetails() throws {
        let metrics = ServerMetrics(
            cpuUsage: 0.12,
            memoryUsage: 0.5,
            memoryUsed: 4_000_000_000,
            memoryTotal: 8_000_000_000,
            diskUsage: 0.25,
            diskUsed: 50_000_000_000,
            diskTotal: 200_000_000_000,
            networkRead: 1_200,
            networkWrite: 800,
            latencyMS: 24,
            loadAverage: [0.2, 0.3, 0.4],
            uptime: 90_061,
            osName: "Ubuntu 24.04",
            hostname: "production-1"
        )
        var history: [ServerMetrics] = []
        for index in 0..<19 {
            let value = Double(index)
            let sample = ServerMetrics(
                cpuUsage: 0.08 + value * 0.002,
                memoryUsage: 0.4 + value * 0.005,
                networkRead: 1_000 + value * 50,
                networkWrite: 600 + value * 20,
                collectedAt: Date().addingTimeInterval(-Double(19 - index) * 10)
            )
            history.append(sample)
        }
        history.append(metrics)
        let first = ServerSnapshot(config: ServerConfig(name: "Production", sshAlias: "prod"), state: .online, metrics: metrics, history: history, lastSuccessAt: Date())
        let second = ServerSnapshot(config: ServerConfig(name: "Backup", sshAlias: "backup"), state: .error, metrics: metrics, errorMessage: "Connection timed out", lastSuccessAt: Date())
        let popup = Popup()
        popup.callback(ServersSnapshot(servers: [first, second]))
        popup.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let rows = descendants(of: popup).filter { $0.accessibilityRole() == .button }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(popup.frame.width, 360)
        XCTAssertEqual(popup.frame.height, 189)
        let labels = descendants(of: popup).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("CPU 12%") })
        let metricsLabel = try XCTUnwrap(descendants(of: popup).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("CPU ") })
        XCTAssertGreaterThanOrEqual(metricsLabel.frame.width, metricsLabel.intrinsicContentSize.width)

        try self.capture(popup, name: "list")

        popup.showDetails(first)
        popup.layoutSubtreeIfNeeded()
        XCTAssertTrue(popup.arrangedSubviews.contains { NSStringFromClass(type(of: $0)).contains("ServerDetailView") })
        let systemLabel = try XCTUnwrap(descendants(of: popup).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Ubuntu ") })
        XCTAssertLessThanOrEqual(systemLabel.frame.width, 332)
        try self.capture(popup, name: "detail")
        popup.callback(ServersSnapshot())
        XCTAssertFalse(popup.arrangedSubviews.contains { NSStringFromClass(type(of: $0)).contains("ServerDetailView") })
        popup.callback(ServersSnapshot(servers: [first, second]))
        popup.showDetails(first)
        popup.layoutSubtreeIfNeeded()
        try self.capture(popup, name: "detail-reopened")
        popup.callback(ServersSnapshot())
    }

    @MainActor
    func testPreviewUsesSharedSnapshotsAndKeepsSelection() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let metrics = ServerMetrics(
            cpuUsage: 0.12,
            memoryUsage: 0.5,
            memoryUsed: 4_000_000_000,
            memoryTotal: 8_000_000_000,
            diskUsage: 0.25,
            diskUsed: 50_000_000_000,
            diskTotal: 200_000_000_000,
            networkRead: 1_200,
            networkWrite: 800,
            latencyMS: 24,
            osName: "Ubuntu 24.04",
            hostname: "production-1",
            collectedAt: date
        )
        let first = ServerSnapshot(
            config: ServerConfig(id: "first", name: "Production", sshAlias: "prod"),
            state: .online,
            metrics: metrics,
            history: [metrics],
            lastSuccessAt: date
        )
        let second = ServerSnapshot(
            config: ServerConfig(id: "second", name: "Backup", sshAlias: "backup"),
            state: .error,
            errorMessage: "Connection timed out"
        )
        let preview = Preview()
        preview.callback(ServersSnapshot(servers: [first, second]))
        XCTAssertEqual(preview.serverSelector.itemTitles, ["Production", "Backup"])
        XCTAssertEqual(preview.selectedServerID, "first")
        XCTAssertEqual(preview.detailView?.id, "first")

        var updatedMetrics = metrics
        updatedMetrics.cpuUsage = 0.35
        let updated = ServerSnapshot(config: first.config, state: .online, metrics: updatedMetrics, history: [updatedMetrics], lastSuccessAt: date)
        let originalDetail = preview.detailView
        preview.callback(ServersSnapshot(servers: [updated, second]))
        XCTAssertTrue(originalDetail === preview.detailView)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        XCTAssertTrue(descendants(of: preview).compactMap { ($0 as? NSTextField)?.stringValue }.contains("35%"))

        let backupItem = try XCTUnwrap(preview.serverSelector.menu?.items.first { ($0.representedObject as? String) == "second" })
        preview.serverSelector.select(backupItem)
        let action = try XCTUnwrap(preview.serverSelector.action)
        _ = preview.perform(action)
        XCTAssertEqual(preview.selectedServerID, "second")
        XCTAssertEqual(preview.detailView?.id, "second")
        XCTAssertTrue(descendants(of: preview).compactMap { ($0 as? NSTextField)?.stringValue }.contains("Connection timed out"))

        let disabled = ServerSnapshot(config: ServerConfig(id: "second", name: "Backup", sshAlias: "backup", enabled: false))
        preview.callback(ServersSnapshot(servers: [updated, disabled]))
        XCTAssertEqual(preview.serverSelector.itemTitles, ["Production"])
        XCTAssertEqual(preview.selectedServerID, "first")
        XCTAssertEqual(preview.detailView?.id, "first")

        preview.setFrameSize(NSSize(width: 480, height: 600))
        preview.layoutSubtreeIfNeeded()
        let charts = descendants(of: preview).filter { $0 is LineChartView || $0 is NetworkChartView }
        XCTAssertEqual(charts.count, 5)
        XCTAssertEqual(charts.filter { $0 is NetworkChartView }.count, 1)
        for chart in charts {
            XCTAssertEqual(chart.frame.width, 450, accuracy: 0.001)
        }
        XCTAssertLessThanOrEqual(preview.fittingSize.width, 510)
        try self.capture(preview, name: "preview")
    }

    @MainActor
    func testPreviewShowsEmptyAndConnectingStates() {
        let preview = Preview()
        preview.callback(ServersSnapshot())
        XCTAssertNil(preview.selectedServerID)
        XCTAssertNil(preview.detailView)
        XCTAssertFalse(preview.serverSelector.isEnabled)

        let connecting = ServerSnapshot(config: ServerConfig(id: "first", name: "Production", sshAlias: "prod"), state: .connecting)
        preview.callback(ServersSnapshot(servers: [connecting]))
        XCTAssertEqual(preview.selectedServerID, "first")
        XCTAssertTrue(preview.serverSelector.isEnabled)
        XCTAssertEqual(preview.detailView?.id, "first")

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let labels = descendants(of: preview).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(localizedString("Waiting for the first response…")))
        XCTAssertTrue(labels.contains("Connecting…"))

        preview.callback(ServersSnapshot())
        XCTAssertNil(preview.selectedServerID)
        XCTAssertFalse(preview.serverSelector.isEnabled)
        XCTAssertEqual(preview.serverSelector.numberOfItems, 0)
    }

    @MainActor
    private func capture(_ view: NSView, name: String) throws {
        view.appearance = NSAppearance(named: .aqua)
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSColor.white.setFill()
        NSBezierPath(rect: view.bounds).fill()
        view.cacheDisplay(in: view.bounds, to: image)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "Servers \(name)"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }
}
