import AppKit

/// Left-pane session list. NSTableView wrapped in NSScrollView, populated
/// from `SessionDiscovery.listSessions()`. Sortable by status (active →
/// idle → unknown) and refreshable on demand. Selection notifies the
/// delegate so the main window can route the choice to the transcript host.
protocol SessionSidebarDelegate: AnyObject {
    func sessionSidebar(_ sidebar: SessionSidebar, didSelect session: ClaudeSession?)
    /// Double-click means "focus that terminal tab AND start voice."
    func sessionSidebar(_ sidebar: SessionSidebar, didActivate session: ClaudeSession)
}

final class SessionSidebar: NSView {

    weak var delegate: SessionSidebarDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var sessions: [ClaudeSession] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
        reload()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
        reload()
    }

    /// Re-query SessionDiscovery and update the table. Selection is preserved
    /// when the previously selected session is still present.
    ///
    /// `SessionDiscovery.listSessions()` shells out to `ps -A` AND runs
    /// AppleScript against Terminal.app — both can take 100s of ms. Run
    /// off the main thread so window-open / settings-open / refresh-click
    /// never freeze the UI.
    func reload() {
        let previousID = selectedSession.map { "\($0.windowID).\($0.tabIndex)" }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = SessionDiscovery.listSessions()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.sessions = self.sortSessions(fresh)
                self.tableView.reloadData()
                if let pid = previousID,
                   let idx = self.sessions.firstIndex(where: { "\($0.windowID).\($0.tabIndex)" == pid }) {
                    self.tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                } else {
                    // Selection lost — push nil so the host can show the empty state.
                    self.delegate?.sessionSidebar(self, didSelect: nil)
                }
            }
        }
    }

    var selectedSession: ClaudeSession? {
        let row = tableView.selectedRow
        guard row >= 0, row < sessions.count else { return nil }
        return sessions[row]
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        // One column, full-width. Custom NSTableCellView renders title + status badge.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = "Session"
        column.minWidth = 160
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        // Header strip: "Sessions" + refresh button.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerLabel = NSTextField(labelWithString: "Sessions")
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // SF Symbol with safe fallback — if the system can't resolve the symbol
        // (corrupt symbol caches, missing on a future OS) we'd rather show a
        // text refresh glyph than crash on window open.
        let refreshIcon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh sessions")
            ?? NSImage(size: .zero)
        let refreshButton = NSButton(image: refreshIcon, target: self, action: #selector(refreshClicked))
        if refreshIcon.size == .zero { refreshButton.title = "↻" }
        refreshButton.bezelStyle = .accessoryBar
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(headerLabel)
        header.addSubview(refreshButton)
        addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            headerLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 18),
            refreshButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @objc private func refreshClicked() {
        reload()
    }

    @objc private func rowDoubleClicked() {
        guard let s = selectedSession else { return }
        delegate?.sessionSidebar(self, didActivate: s)
    }

    /// Active first, then idle, then unknown; alphabetical within each.
    private func sortSessions(_ raw: [ClaudeSession]) -> [ClaudeSession] {
        return raw.sorted { lhs, rhs in
            func order(_ s: SessionStatus) -> Int {
                switch s {
                case .active:  return 0
                case .idle:    return 1
                case .unknown: return 2
                }
            }
            let l = order(lhs.status), r = order(rhs.status)
            return l != r ? l < r : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: – DataSource

extension SessionSidebar: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return sessions.count
    }
}

// MARK: – Delegate / cell rendering

extension SessionSidebar: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionRowView
            ?? SessionRowView(identifier: identifier)
        cell.configure(with: sessions[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.sessionSidebar(self, didSelect: selectedSession)
    }
}

// MARK: – Cell

private final class SessionRowView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 4
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        badgeLabel.alignment = .center

        addSubview(titleLabel)
        addSubview(badgeView)

        NSLayoutConstraint.activate([
            badgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 16),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with session: ClaudeSession) {
        titleLabel.stringValue = session.title
        badgeLabel.stringValue = session.status.label.uppercased()
        let color = session.status.badgeColor
        badgeView.layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
        badgeLabel.textColor = color
    }
}
