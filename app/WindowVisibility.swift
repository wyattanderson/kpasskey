import AppKit
import SwiftUI

/// View lifetime alone does not reflect minimization, app hiding, or occlusion.
struct WindowVisibility: NSViewRepresentable {
  let changed: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> WindowVisibilityView {
    let view = WindowVisibilityView()
    view.changed = changed
    return view
  }

  func updateNSView(_ view: WindowVisibilityView, context: Context) {
    view.changed = changed
  }
}

final class WindowVisibilityView: NSView {
  var changed: @MainActor (Bool) -> Void = { _ in }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      NotificationCenter.default.addObserver(self, selector: #selector(refresh),
        name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
    refresh()
  }

  @objc private func refresh() {
    // Defer binding updates until AppKit has finished attaching/updating the view.
    Task { @MainActor [weak self] in
      guard let self else { return }
      changed(window?.occlusionState.contains(.visible) == true)
    }
  }

  deinit { NotificationCenter.default.removeObserver(self) }
}
