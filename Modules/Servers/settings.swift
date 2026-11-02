import Cocoa
import Kit

internal final class Settings: NSStackView, Settings_v {
    internal var callback: (() -> Void) = {}
    internal var intervalCallback: ((Int) -> Void) = { _ in }
    internal var historyCallback: ((Int) -> Void) = { _ in }
    private var serversSection: PreferencesSection?

    private var updateInterval: Int {
        Store.shared.int(key: "Servers_updateInterval", defaultValue: 10)
    }
    private var historyRetention: Int {
        ServerHistory.normalizedRetention(Store.shared.int(key: "Servers_historyRetention", defaultValue: ServerHistory.defaultRetention))
    }

    internal init() {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = Constants.Settings.margin

        let explanation = NSTextField(wrappingLabelWithString: localizedString("Connect directly over SSH. No agent or extra server port is required."))
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 440
        self.addArrangedSubview(explanation)
        self.addArrangedSubview(NSView())

        let actions = NSStackView()
        actions.orientation = .horizontal
        let add = NSButton(title: localizedString("Add server"), target: self, action: #selector(self.addServer))
        add.bezelStyle = .rounded
        let importButton = NSButton(title: localizedString("Import SSH config…"), target: self, action: #selector(self.importSSHConfig))
        importButton.bezelStyle = .rounded
        actions.addArrangedSubview(add)
        actions.addArrangedSubview(importButton)
        actions.addArrangedSubview(NSView())
        self.addArrangedSubview(actions)

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: self.selectView(
                action: #selector(self.changeInterval),
                items: ReaderUpdateIntervals.filter { [5, 10, 15, 30, 60].contains(Int($0.key) ?? 0) },
                selected: "\(self.updateInterval)"
            )),
            PreferencesRow(localizedString("History duration"), component: self.selectView(
                action: #selector(self.changeHistoryRetention),
                items: ServerHistory.retentionOptions,
                selected: "\(self.historyRetention)"
            ))
        ]))
        let historyHelp = NSTextField(wrappingLabelWithString: localizedString("History is kept in memory and cleared when Stats quits."))
        historyHelp.font = .systemFont(ofSize: 11)
        historyHelp.textColor = .secondaryLabelColor
        historyHelp.preferredMaxLayoutWidth = 440
        self.addArrangedSubview(historyHelp)
        let help = NSTextField(wrappingLabelWithString: localizedString("Use an alias from ~/.ssh/config. Authentication uses your existing keys or SSH Agent; passwords and private keys are never stored by Stats. New hosts must first be trusted in Terminal."))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 440
        self.addArrangedSubview(help)
        self.addArrangedSubview(NSView())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func load(widgets: [widget_t]) {
        self.reload()
    }

    private func reload() {
        self.serversSection?.removeFromSuperview()
        let section = PreferencesSection(title: localizedString("Servers"))
        let configs = ServerStore.load()
        if configs.isEmpty {
            section.add(PreferencesRow(localizedString("No servers configured"), component: NSView()))
        } else {
            configs.forEach { section.add(self.row($0)) }
        }
        self.insertArrangedSubview(section, at: 1)
        self.serversSection = section
    }

    private func row(_ config: ServerConfig) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let toggle = self.switchView(action: #selector(self.toggleServer(_:)), state: config.enabled)
        toggle.identifier = NSUserInterfaceItemIdentifier(config.id)
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let name = LabelField(config.name, size: 12)
        let alias = LabelField(config.sshAlias, size: 11)
        alias.textColor = .secondaryLabelColor
        labels.addArrangedSubview(name)
        labels.addArrangedSubview(alias)

        let edit = NSButton(title: localizedString("Edit"), target: self, action: #selector(self.editServer(_:)))
        edit.identifier = NSUserInterfaceItemIdentifier(config.id)
        edit.bezelStyle = .rounded
        edit.controlSize = .small
        let remove = NSButton(title: localizedString("Remove"), target: self, action: #selector(self.removeServer(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(config.id)
        remove.bezelStyle = .rounded
        remove.controlSize = .small

        row.addArrangedSubview(toggle)
        row.addArrangedSubview(labels)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(edit)
        row.addArrangedSubview(remove)
        return row
    }

    internal static func importView(_ aliases: [String]) -> (view: NSScrollView, toggles: [NSButton]) {
        let toggles = aliases.map { alias in
            let button = NSButton(checkboxWithTitle: alias, target: nil, action: nil)
            button.state = .on
            button.alignment = .left
            button.cell?.lineBreakMode = .byTruncatingMiddle
            return button
        }
        let contentHeight = max(42, CGFloat(aliases.count) * 26 + 16)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: min(contentHeight, 240)))
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentHeight > 240
        scroll.autohidesScrollers = true
        let list = NSStackView(views: toggles)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.heightAnchor.constraint(equalToConstant: contentHeight)
        ])
        toggles.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true }
        return (scroll, toggles)
    }

    @objc private func importSSHConfig() {
        do {
            let aliases = try SSHConfigImporter.loadAliases()
            let candidates = SSHConfigImporter.newAliases(aliases, existing: ServerStore.load())
            guard !candidates.isEmpty else {
                showAlert(localizedString("No new SSH hosts"), localizedString("All SSH config aliases are already imported."), .informational)
                return
            }
            let alert = NSAlert()
            alert.messageText = localizedString("Import SSH config")
            alert.informativeText = localizedString("Select new hosts to import. Only Linux servers are supported; existing aliases are skipped.")
            alert.addButton(withTitle: localizedString("Import"))
            alert.addButton(withTitle: localizedString("Cancel"))
            let editor = Self.importView(candidates)
            alert.accessoryView = editor.view
            alert.window.initialFirstResponder = editor.toggles.first
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let selected = editor.toggles.filter { $0.state == .on }.compactMap(\.title)
            guard !selected.isEmpty else {
                showAlert(localizedString("No hosts selected"), localizedString("Select at least one host to import."), .warning)
                return
            }
            let imported = ServerStore.importAliases(selected)
            self.reload()
            self.callback()
            showAlert(localizedString("Import complete"), localizedString("Imported %0 servers", "\(imported)"), .informational)
        } catch {
            showAlert(localizedString("Import failed"), error.localizedDescription, .warning)
        }
    }

    @objc private func addServer() {
        self.showEditor(nil)
    }

    @objc private func editServer(_ sender: NSButton) {
        guard let config = ServerStore.load().first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        self.showEditor(config)
    }

    internal static func editorView(_ existing: ServerConfig?) -> (form: NSStackView, name: NSTextField, alias: NSTextField) {
        let width: CGFloat = 340
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        name.placeholderString = localizedString("Display name")
        name.stringValue = existing?.name ?? ""
        let alias = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        alias.placeholderString = localizedString("SSH alias (for example: production)")
        alias.stringValue = existing?.sshAlias ?? ""
        let form = NSStackView(views: [name, alias])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: width, height: 56)
        NSLayoutConstraint.activate([
            name.widthAnchor.constraint(equalToConstant: width),
            alias.widthAnchor.constraint(equalToConstant: width)
        ])
        return (form, name, alias)
    }

    private func showEditor(_ existing: ServerConfig?) {
        let alert = NSAlert()
        alert.messageText = localizedString(existing == nil ? "Add server" : "Edit server")
        alert.informativeText = localizedString("The SSH alias can be a Host from ~/.ssh/config or user@host.")
        alert.addButton(withTitle: localizedString("Save"))
        alert.addButton(withTitle: localizedString("Cancel"))

        let editor = Self.editorView(existing)
        alert.accessoryView = editor.form
        alert.window.initialFirstResponder = editor.alias

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = editor.alias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            showAlert(localizedString("Invalid SSH alias"), localizedString("Enter a single Host alias or user@host without spaces."), .warning)
            return
        }
        let title = editor.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ServerConfig(
            id: existing?.id ?? UUID().uuidString,
            name: title.isEmpty ? target : title,
            sshAlias: target,
            enabled: existing?.enabled ?? true
        )
        ServerStore.upsert(config)
        self.reload()
        self.callback()
    }

    @objc private func removeServer(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let config = ServerStore.load().first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = localizedString("Remove %0?", config.name)
        alert.informativeText = localizedString("This only removes the server from Stats. It does not change your SSH configuration.")
        alert.addButton(withTitle: localizedString("Remove"))
        alert.addButton(withTitle: localizedString("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ServerStore.remove(id)
        self.reload()
        self.callback()
    }

    @objc private func toggleServer(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue,
              var config = ServerStore.load().first(where: { $0.id == id }) else { return }
        config.enabled = controlState(sender)
        ServerStore.upsert(config)
        self.callback()
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        Store.shared.set(key: "Servers_updateInterval", value: value)
        self.intervalCallback(value)
    }

    @objc private func changeHistoryRetention(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        let retention = ServerHistory.normalizedRetention(value)
        Store.shared.set(key: "Servers_historyRetention", value: retention)
        self.historyCallback(retention)
    }
}
