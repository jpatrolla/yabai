import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 380)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Min/Max Test Window"
        window.isReleasedWhenClosed = false
        window.delegate = self

        // --- Constraints you can tweak ---
        // a) Min + Max (clamped range)
        window.contentMinSize = NSSize(width: 400, height: 200)
        window.contentMaxSize = NSSize(width: 600, height: 400)

        // b) Uncomment to test fixed size (no visible resize handle still allowed, but size won’t change)
        // let fixed = NSSize(width: 700, height: 420)
        // window.contentMinSize = fixed
        // window.contentMaxSize = fixed

        // c) Optional: lock aspect ratio while still honoring min/max
        // window.contentAspectRatio = NSSize(width: 16, height: 10)

        // Center and show
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Nice: print actual size whenever it changes (helps verify clamping)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let w = self?.window else { return }
            print("Resized to: \(w.frame.size)  (content: \(w.contentLayoutRect.size))")
        }
    }

    // (Optional) Extra belt-and-braces clamping via delegate:
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // AppKit already enforces contentMin/MaxSize, but you can add custom logic here.
        return frameSize
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()