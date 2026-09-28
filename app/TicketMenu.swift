import AppKit
import KPasskeyCache

extension CachedTicket.Method {
    var symbolName: String {
        self == .passkey ? "key.horizontal" : "questionmark.key.filled"
    }
}

func hasRefreshableTickets(_ tickets: [CachedTicket], at now: Date) -> Bool {
    tickets.contains { $0.renewable && $0.starts <= now && $0.expires > now && !$0.invalid }
}

@MainActor
func ticketMenuItems(_ tickets: [CachedTicket], state: CachedTicket.State,
                     summary: String, at now: Date) -> [NSMenuItem] {
    let title = menuLabel("KPasskey")
    title.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
    let dot = StatusDot()
    dot.color = state.statusColor ?? .secondaryLabelColor
    dot.gradient = true
    NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 8),
        dot.heightAnchor.constraint(equalToConstant: 8)
    ])
    var items = [menuRow("KPasskey", views: [title]),
                 menuRow(summary, views: [dot, menuLabel(summary)]), .separator()]
    let active = tickets.filter { $0.starts <= now && $0.expires > now && !$0.invalid }
    if !active.isEmpty {
        items.append(.sectionHeader(title: "Active Tickets"))
        for ticket in active {
            var views: [NSView] = [menuSymbol(ticket.method.symbolName, size: 18), menuLabel(ticket.principal)]
            var details = [ticket.principal, ticket.method.rawValue]
            if ticket.renewable {
                views.append(menuSymbol("r.circle", size: 12))
                details.append("Renewable")
            }
            if ticket.forwardable {
                views.append(menuSymbol("f.circle", size: 12))
                details.append("Forwardable")
            }
            let item = menuRow(ticket.principal, views: views)
            let description = details.joined(separator: ", ")
            item.view?.setAccessibilityLabel(description)
            item.toolTip = description
            items.append(item)
        }
        items.append(.separator())
    }
    return items
}

@MainActor
private func menuLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .menuFont(ofSize: 0)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

@MainActor
private func menuSymbol(_ name: String, size: CGFloat) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    view.symbolConfiguration = .init(pointSize: size, weight: .regular)
    view.contentTintColor = .secondaryLabelColor
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: size + 2),
        view.heightAnchor.constraint(equalToConstant: size + 2)
    ])
    return view
}

@MainActor
private func menuRow(_ title: String, views: [NSView]) -> NSMenuItem {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.distribution = .fill
    row.alignment = .centerY
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.staticText)
    row.setAccessibilityLabel(title)
    row.setAccessibilityChildren([])
    row.setClippingResistancePriority(.defaultLow, for: .horizontal)
    row.frame.size = NSSize(width: min(440, max(260, row.fittingSize.width)), height: max(28, row.fittingSize.height))
    // AppKit uses the initial frame as the minimum and expands it to the menu width.
    row.translatesAutoresizingMaskIntoConstraints = true
    row.autoresizingMask = [.width]
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.toolTip = title
    item.view = row
    return item
}
