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
