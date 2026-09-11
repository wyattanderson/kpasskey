import AppKit
import KPasskeyCache

@MainActor
final class TicketStatusItem {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let dot = StatusDot()

  init() {
    guard let button = item.button else { return }
    let symbol = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)
    let size = symbol?.size ?? NSSize(width: 18, height: 18)
    let scale = min(18 / size.width, 18 / size.height)
    let width = size.width * scale, height = size.height * scale
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      symbol?.draw(in: NSRect(x: (18 - width) / 2, y: (18 - height) / 2, width: width, height: height))
      return true
    }
    image.isTemplate = true
    button.image = image
    // The dot occupies the button's existing padding, without contributing to its size.
    dot.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(dot)
    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: button.centerXAnchor, constant: 11),
      dot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 4),
      dot.heightAnchor.constraint(equalToConstant: 4),
    ])
    update(state: .none, summary: "No tickets")
  }

  func update(state: CachedTicket.State, summary: String) {
    dot.color = state.statusColor
    dot.isHidden = dot.color == nil
    dot.needsDisplay = true
    item.button?.setAccessibilityLabel("KPasskey: \(summary)")
    item.button?.toolTip = summary
  }

  isolated deinit { NSStatusBar.system.removeStatusItem(item) }
}

extension CachedTicket.State {
  var statusColor: NSColor? {
    switch self {
    case .password: .systemYellow
    case .passkey: .systemGreen
    case .expiring: .systemOrange
    case .expired: .systemRed
    case .none, .unavailable: nil
    }
  }
}

final class StatusDot: NSView {
  var color: NSColor?
  var gradient = false
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    guard let color else { return }
    let circle = NSBezierPath(ovalIn: bounds)
    if gradient, let shading = NSGradient(
      starting: color.blended(withFraction: 0.15, of: .white) ?? color,
      ending: color.blended(withFraction: 0.10, of: .black) ?? color) {
      shading.draw(in: circle, angle: -90)
    } else {
      color.setFill()
      circle.fill()
    }
  }
}
