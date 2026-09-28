import AppKit
import Testing

@Test @MainActor func visibilityFollowsItsWindowAndStopsAfterDetachment() async {
    // Drive AppKit's notification path without depending on a desktop's stacking order.
    final class Window: NSWindow {
        var reportedVisibility = false
        override var occlusionState: NSWindow.OcclusionState {
            reportedVisibility ? [.visible] : []
        }
    }
    _ = NSApplication.shared
    let window = Window(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    let view = WindowVisibilityView()
    var observed: Bool?
    view.changed = { observed = $0 }
    window.contentView = view
    await Task.yield()
    #expect(observed == false)
    for visible in [true, false, true] {
        window.reportedVisibility = visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await Task.yield()
        #expect(observed == visible)
    }
    window.contentView = nil
    await Task.yield()
    #expect(observed == false)
    observed = nil
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await Task.yield()
    #expect(observed == nil)
}
