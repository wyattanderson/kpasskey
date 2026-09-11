import AppKit
import KPasskeyCache
import Testing

@Test @MainActor func statusDotDoesNotChangeButtonSizeOrKeyPosition() throws {
  _ = NSApplication.shared
  let status = TicketStatusItem()
  let button = try #require(status.item.button)
  let cell = try #require(button.cell)
  let size = button.frame.size
  let imageRect = cell.imageRect(forBounds: button.bounds)
  let dot = try #require(button.subviews.last)
  for state: CachedTicket.State in [.none, .passkey, .password, .expiring, .expired, .unavailable, .none] {
    status.update(state: state, summary: state.rawValue)
    button.layoutSubtreeIfNeeded()
    #expect(button.frame.size == size)
    #expect(cell.imageRect(forBounds: button.bounds) == imageRect)
    #expect(imageRect.midX == button.bounds.midX)
    #expect(imageRect.midY == button.bounds.midY)
    #expect(dot.isHidden == (state == .none || state == .unavailable))
    #expect(dot.frame.minX == imageRect.maxX + 2)
    #expect(dot.frame.midY == button.bounds.midY)
    #expect(button.bounds.contains(dot.frame))
    #expect(dot.hitTest(NSPoint(x: dot.frame.midX, y: dot.frame.midY)) == nil)
  }
}

@Test @MainActor func ticketMenuShowsOnlyUsableTicketsWithAccessibleCapabilities() throws {
  _ = NSApplication.shared
  let now = Date()
  func ticket(_ name: String, expires: Date, starts: Date = .distantPast,
              invalid: Bool = false, method: CachedTicket.Method = .unknown,
              renewable: Bool = false, forwardable: Bool = false) -> CachedTicket {
    CachedTicket(cache: "MEMORY:\(name)", principal: name, starts: starts, expires: expires,
      invalid: invalid, method: method, renewable: renewable, forwardable: forwardable)
  }
  let tickets = [
    ticket("passkey@EXAMPLE.INVALID", expires: .distantFuture, method: .passkey, renewable: true, forwardable: true),
    ticket("unknown@EXAMPLE.INVALID", expires: now.addingTimeInterval(1), forwardable: true),
    ticket("expired", expires: now),
    ticket("future", expires: .distantFuture, starts: now.addingTimeInterval(1)),
    ticket("invalid", expires: .distantFuture, invalid: true),
  ]
  #expect(hasRefreshableTickets(tickets, at: now))
  #expect(!hasRefreshableTickets(Array(tickets.dropFirst()), at: now))
  let items = ticketMenuItems(tickets, state: .passkey, summary: "Valid passkey ticket", at: now)
  #expect(items.map(\.title) == ["KPasskey", "Valid passkey ticket", "", "Active Tickets",
                               "passkey@EXAMPLE.INVALID", "unknown@EXAMPLE.INVALID", ""])
  #expect(items[3].isSectionHeader)
  #expect(items[2].isSeparatorItem && items[6].isSeparatorItem)
  let row = try #require(items[4].view as? NSStackView)
  #expect(row.accessibilityLabel() == "passkey@EXAMPLE.INVALID, Passkey, Renewable, Forwardable")
  #expect(items[5].view?.accessibilityLabel() == "unknown@EXAMPLE.INVALID, Authentication method unreported, Forwardable")
  #expect(row.arrangedSubviews.compactMap { $0 as? NSImageView }.count == 3)
  #expect(row.arrangedSubviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.image != nil })
  #expect(CachedTicket.Method.password.symbolName == CachedTicket.Method.unknown.symbolName)
  #expect(CachedTicket.Method.passkey.symbolName == "key.horizontal")
  let status = try #require(items[1].view as? NSStackView)
  let dot = try #require(status.arrangedSubviews.first as? StatusDot)
  #expect(dot.gradient && dot.color == CachedTicket.State.passkey.statusColor)
  for item in items where item.view != nil {
    let view = try #require(item.view)
    #expect(!item.isEnabled && item.action == nil)
    #expect(view.frame.width >= 260 && view.frame.height >= 20)
    #expect(view.autoresizingMask.contains(.width))
  }
  let empty = ticketMenuItems(Array(tickets.dropFirst(2)), state: .expired, summary: "Expired ticket", at: now)
  #expect(empty.count == 3)
  #expect(!empty.contains { $0.isSectionHeader })

  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                        styleMask: .borderless, backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: .darkAqua)
  let content = try #require(window.contentView)
  let longName = String(repeating: "long-principal-", count: 10) + "@EXAMPLE.INVALID"
  let longItems = ticketMenuItems([ticket(longName, expires: .distantFuture, renewable: true, forwardable: true)],
                                 state: .password, summary: "Valid ticket", at: now)
  #expect(longItems[4].toolTip?.hasPrefix(longName) == true)
  #expect(longItems[4].view?.frame.width == 440)
  for item in items.filter({ $0.view != nil }) + [longItems[4]] {
    let view = try #require(item.view as? NSStackView)
    content.addSubview(view)
    for width: CGFloat in [260, 440] {
      view.frame = NSRect(x: 0, y: 0, width: width, height: 30)
      view.layoutSubtreeIfNeeded()
      for child in view.arrangedSubviews {
        #expect(view.bounds.contains(child.frame))
        #expect(child.frame.width > 0 && child.frame.height > 0)
      }
      for (left, right) in zip(view.arrangedSubviews, view.arrangedSubviews.dropFirst()) {
        #expect(left.frame.maxX <= right.frame.minX)
      }
      if let badge = view.arrangedSubviews.last as? NSImageView {
        #expect(abs(badge.frame.maxX - (view.bounds.maxX - 14)) < 1)
      }
    }
  }
}
