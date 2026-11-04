import AppKit
import RDPKit
import RDPKitAppKit

/// The remote desktop surface: RDPKit's video view with its input view on top, edge to edge.
/// The video view aspect-fits the frame on whole device pixels and the input view maps the
/// pointer through the same frame metadata, so clicks land where the picture shows them.
/// Adapted from RDPeek's canvas (MIT, © 2026 Anees Iqbal).
final class RemoteDesktopCanvas: NSView {
    let videoView = RDPRemoteDesktopVideoView()
    private let inputView = RDPRemoteInputView()
    private var lastReportedSurface: Surface?

    /// The canvas's size in points and its backing scale, whenever either changes: the
    /// session resizes the remote desktop to follow it.
    var onSurfaceChange: ((_ pointSize: CGSize, _ backingScaleFactor: CGFloat) -> Void)?
    /// Ctrl+Option+End while the desktop has the keyboard: the remote Ctrl+Alt+Del, as in
    /// Microsoft's client (on a Mac keyboard, End is Fn+→).
    var onCtrlAltEnd: (() -> Void)?
    private var keyMonitor: Any?

    var keyboard: RDPKeyboard {
        get { inputView.keyboard }
        set { inputView.keyboard = newValue }
    }

    /// While on, ⌘ and ⌃ chords go to the remote desktop ahead of the menu bar, ⌘ as the
    /// Windows key (⌘R is Win+R).
    var claimsCommandShortcuts: Bool {
        get { inputView.claimsCommandShortcuts }
        set { inputView.claimsCommandShortcuts = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        videoView.autoresizingMask = [.width, .height]
        inputView.autoresizingMask = [.width, .height]
        addSubview(videoView)
        addSubview(inputView)
        setAccessibilityLabel("Remote desktop")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        videoView.frame = bounds
        inputView.frame = bounds
        reportSurfaceIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSurfaceIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastReportedSurface = nil
        reportSurfaceIfNeeded()
        installKeyMonitorIfNeeded()
    }

    /// The input view is RDPKit's and cannot be subclassed, so the shortcut is caught before it.
    private func installKeyMonitorIfNeeded() {
        if window == nil, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard keyMonitor == nil, window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, hasInputFocus, Self.isCtrlAltEnd(event) else { return event }
            onCtrlAltEnd?()
            return nil
        }
    }

    static func isCtrlAltEnd(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        return event.keyCode == 119 && flags == [.control, .option] // kVK_End
    }

    /// The size the first connection asks for, before Display Control follows the view.
    var initialPointSize: CGSize {
        if bounds.width >= 200, bounds.height >= 200 { return bounds.size }
        return (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }

    func update(frame: RDPFrameMetadata?, showsDesktop: Bool, inputSession: RDPInputSession?) {
        videoView.isHidden = !showsDesktop
        inputView.isHidden = !showsDesktop
        inputView.rdpFrame = frame
        inputView.inputSession = showsDesktop ? inputSession : nil
    }

    func makeInputFirstResponder() {
        guard inputView.isHidden == false else { return }
        window?.makeFirstResponder(inputView)
    }

    var hasInputFocus: Bool {
        window?.firstResponder === inputView
    }

    private func reportSurfaceIfNeeded() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let next = Surface(pointSize: bounds.size, backingScaleFactor: window.backingScaleFactor)
        guard next != lastReportedSurface else { return }
        lastReportedSurface = next
        // After layout settles: a live resize reports many sizes in a row.
        DispatchQueue.main.async { [weak self] in
            guard self?.lastReportedSurface == next else { return }
            self?.onSurfaceChange?(next.pointSize, next.backingScaleFactor)
        }
    }

    private struct Surface: Equatable {
        var pointSize: CGSize
        var backingScaleFactor: CGFloat
    }
}
