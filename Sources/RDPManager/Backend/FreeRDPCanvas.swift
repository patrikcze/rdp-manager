import AppKit
import FreeRDPBridge

/// Shows a FreeRDP session's framebuffer and sends the Mac's keyboard and pointer to it.
/// The picture is aspect-fit into the view; pointer positions map through the same rect.
final class FreeRDPCanvas: NSView {
    /// Input goes to the session this returns, when it is connected.
    var input: (() -> FreeRDPConnection?)?
    var onSurfaceChange: ((_ pointSize: CGSize, _ backingScaleFactor: CGFloat) -> Void)?
    /// While on, ⌘ and ⌃ chords go to the remote desktop (⌘ as the Windows key), except
    /// ⌥⌘ chords, which stay with RDP Manager's menus.
    var claimsCommandShortcuts = true

    private var desktopSize = CGSize.zero
    private var cursor = NSCursor.arrow
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<Int>()
    private var scrollRemainderY: CGFloat = 0
    private var scrollRemainderX: CGFloat = 0
    private var lastReportedSurface: (CGSize, CGFloat)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        setAccessibilityLabel("Remote desktop")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Picture

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        let size = CGSize(width: image.width, height: image.height)
        if size != desktopSize {
            desktopSize = size
            window?.invalidateCursorRects(for: self)
        }
    }

    func clear() {
        layer?.contents = nil
        desktopSize = .zero
    }

    /// Where the desktop is drawn, in view points.
    private var contentRect: CGRect {
        guard desktopSize.width > 0, desktopSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / desktopSize.width, bounds.height / desktopSize.height)
        let size = CGSize(width: desktopSize.width * scale, height: desktopSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The desktop pixel under `point` (view coordinates), clamped to the desktop.
    private func desktopPoint(_ point: CGPoint) -> (UInt16, UInt16)? {
        let rect = contentRect
        guard rect.width > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * desktopSize.width
        let y = (rect.maxY - point.y) / rect.height * desktopSize.height // view is bottom-up
        let clampedX = min(max(x, 0), desktopSize.width - 1)
        let clampedY = min(max(y, 0), desktopSize.height - 1)
        return (UInt16(clampedX), UInt16(clampedY))
    }

    // MARK: - Layout and cursor

    override func layout() {
        super.layout()
        reportSurfaceIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        reportSurfaceIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastReportedSurface = nil
        reportSurfaceIfNeeded()
    }

    private func reportSurfaceIfNeeded() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let next = (bounds.size, window.backingScaleFactor)
        if let last = lastReportedSurface, last.0 == next.0, last.1 == next.1 { return }
        lastReportedSurface = next
        onSurfaceChange?(next.0, next.1)
    }

    var initialPointSize: CGSize {
        if bounds.width >= 200, bounds.height >= 200 { return bounds.size }
        return (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }

    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func setRemoteCursor(_ cursor: NSCursor) {
        self.cursor = cursor
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            cursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(contentRect, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        releaseEverything()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releaseEverything() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: newWindow)
        }
    }

    @objc private func windowResignedKey() {
        releaseEverything()
    }

    /// A key or button still down when focus leaves would stay down on the server.
    private func releaseEverything() {
        guard let connection = input?() else {
            pressedKeys.removeAll()
            pressedButtons.removeAll()
            return
        }
        for key in pressedKeys {
            connection.sendMacKey(key, down: false)
        }
        pressedKeys.removeAll()
        for button in pressedButtons {
            sendButton(button, down: false, at: CGPoint(x: contentRect.midX, y: contentRect.midY))
        }
        pressedButtons.removeAll()
    }

    // MARK: - Keyboard

    private static let kVKEnd: UInt16 = 119

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isAppShortcut = flags.contains(.command) && flags.contains(.option)
        if claimsCommandShortcuts, isAppShortcut == false, flags.contains(.command) || flags.contains(.control) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let connection = input?() else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if event.keyCode == Self.kVKEnd, flags == [.control, .option] {
            // Ctrl+Option+End: the remote Ctrl+Alt+Del, without the Option and End keys.
            connection.sendChord([.control, .alt, .delete])
            return
        }
        pressedKeys.insert(event.keyCode)
        connection.sendMacKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let connection = input?() else { return }
        pressedKeys.remove(event.keyCode)
        connection.sendMacKey(event.keyCode, down: false)
    }

    /// Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK), so left and right keys are
    /// told apart.
    private static let modifierBits: [UInt16: UInt] = [
        59: 0x0001, 62: 0x2000, // control
        56: 0x0002, 60: 0x0004, // shift
        58: 0x0020, 61: 0x0040, // option
        55: 0x0008, 54: 0x0010, // command
    ]

    override func flagsChanged(with event: NSEvent) {
        guard let connection = input?() else { return }
        let code = event.keyCode
        if code == 57 { // Caps Lock: a press and release per toggle
            connection.sendMacKey(code, down: true)
            connection.sendMacKey(code, down: false)
            return
        }
        guard let bit = Self.modifierBits[code] else { return }
        if (code == 55 || code == 54), claimsCommandShortcuts == false { return }
        let down = event.modifierFlags.rawValue & bit != 0
        if down {
            pressedKeys.insert(code)
        } else {
            pressedKeys.remove(code)
        }
        connection.sendMacKey(code, down: down)
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(event, number: 0, down: true)
    }

    override func mouseUp(with event: NSEvent) {
        button(event, number: 0, down: false)
    }

    override func rightMouseDown(with event: NSEvent) { button(event, number: 1, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, number: 1, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, number: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, number: 2, down: false) }

    private func move(_ event: NSEvent) {
        guard let connection = input?(), let (x, y) = desktopPoint(convert(event.locationInWindow, from: nil)) else { return }
        connection.sendPointer(flags: UInt16(RM_PTR_MOVE), x: x, y: y)
    }

    private func button(_ event: NSEvent, number: Int, down: Bool) {
        if down {
            pressedButtons.insert(number)
        } else {
            pressedButtons.remove(number)
        }
        sendButton(number, down: down, at: convert(event.locationInWindow, from: nil))
    }

    private func sendButton(_ number: Int, down: Bool, at point: CGPoint) {
        guard let connection = input?(), let (x, y) = desktopPoint(point) else { return }
        let buttonFlag = switch number {
        case 1: UInt16(RM_PTR_BUTTON2)
        case 2: UInt16(RM_PTR_BUTTON3)
        default: UInt16(RM_PTR_BUTTON1)
        }
        connection.sendPointer(flags: buttonFlag | (down ? UInt16(RM_PTR_DOWN) : 0), x: x, y: y)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let connection = input?(), let (x, y) = desktopPoint(convert(event.locationInWindow, from: nil)) else { return }
        // One wheel notch is 120 units; a trackpad's points scroll proportionally.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 120
        scrollRemainderY += event.scrollingDeltaY * factor
        scrollRemainderX += event.scrollingDeltaX * factor
        while abs(scrollRemainderY) >= 1 {
            let step = Int(max(min(scrollRemainderY, 255), -255))
            scrollRemainderY -= CGFloat(step)
            connection.sendPointer(flags: Self.wheelFlags(step, horizontal: false), x: x, y: y)
        }
        while abs(scrollRemainderX) >= 1 {
            // A swipe to the left (positive delta) scrolls the remote content right.
            let step = Int(max(min(-scrollRemainderX, 255), -255))
            scrollRemainderX += CGFloat(step)
            connection.sendPointer(flags: Self.wheelFlags(step, horizontal: true), x: x, y: y)
        }
    }

    /// TS_POINTER_EVENT wheel flags: a 9-bit two's complement rotation.
    static func wheelFlags(_ rotation: Int, horizontal: Bool) -> UInt16 {
        var flags = UInt16(horizontal ? RM_PTR_HWHEEL : RM_PTR_WHEEL)
        if rotation < 0 {
            flags |= UInt16(RM_PTR_WHEEL_NEGATIVE) | UInt16((0x100 + rotation) & 0xFF)
        } else {
            flags |= UInt16(rotation & 0xFF)
        }
        return flags
    }
}
