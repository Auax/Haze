import AppKit
import SwiftUI

@MainActor
final class RegionPicker {
    static let shared = RegionPicker()
    private var window: RegionPickerWindow?
    private var retiredWindows: [RegionPickerWindow] = []
    private var isFinishing = false

    func pick(completion: @escaping (CGRect) -> Void) {
        closeExistingPickerIfNeeded()
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        isFinishing = false
        let window = RegionPickerWindow(
            screen: screen,
            completion: { [weak self] rect in
                self?.finish(rect: rect, completion: completion)
            },
            cancel: { [weak self] in
                self?.cancelActivePicker()
            }
        )
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(rect: CGRect, completion: @escaping (CGRect) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        let windowToClose = window
        window = nil
        DispatchQueue.main.async { [weak self, windowToClose] in
            guard let self else { return }
            self.retire(windowToClose)
            completion(rect)
            self.isFinishing = false
        }
    }

    private func cancelActivePicker() {
        guard !isFinishing else { return }
        isFinishing = true
        let windowToClose = window
        window = nil
        DispatchQueue.main.async { [weak self, windowToClose] in
            guard let self else { return }
            self.retire(windowToClose)
            self.isFinishing = false
        }
    }

    private func closeExistingPickerIfNeeded() {
        guard let existingWindow = window else { return }
        window = nil
        existingWindow.orderOut(nil)
        retiredWindows.append(existingWindow)
    }

    private func retire(_ window: RegionPickerWindow?) {
        guard let window else { return }
        window.orderOut(nil)
        retiredWindows.append(window)
    }
}

private final class RegionPickerWindow: NSWindow {
    init(screen: NSScreen, completion: @escaping (CGRect) -> Void, cancel: @escaping () -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        let view = RegionPickerView(screen: screen, completion: completion, cancel: cancel)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class RegionPickerView: NSView {
    private let screen: NSScreen
    private let completion: (CGRect) -> Void
    private let cancel: () -> Void
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var cancelRect: CGRect = .zero

    init(screen: NSScreen, completion: @escaping (CGRect) -> Void, cancel: @escaping () -> Void) {
        self.screen = screen
        self.completion = completion
        self.cancel = cancel
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if cancelRect.contains(point) {
            cancel()
            return
        }
        startPoint = point
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        let rect = selectedRect
        guard rect.width >= 32, rect.height >= 32 else { return }
        let topLeftRect = CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        completion(topLeftRect.integral)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        bounds.fill()

        let rect = selectedRect
        drawInstructions()
        if rect.width > 0, rect.height > 0 {
            NSColor.clear.setFill()
            rect.fill(using: .clear)

            let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            border.lineWidth = 2
            border.stroke()

            let label = "\(Int(rect.width)) x \(Int(rect.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7)
            ]
            label.draw(at: CGPoint(x: rect.minX + 8, y: rect.maxY + 8), withAttributes: attributes)
        }
    }

    private func drawInstructions() {
        let text = "Drag to select area"
        let cancelText = "Cancel  Esc"
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let cancelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: textAttributes)
        let cancelSize = cancelText.size(withAttributes: cancelAttributes)
        let pillPadding = CGSize(width: 16, height: 9)
        let pillRect = CGRect(
            x: bounds.midX - (textSize.width + pillPadding.width * 2) / 2,
            y: bounds.maxY - 72,
            width: textSize.width + pillPadding.width * 2,
            height: textSize.height + pillPadding.height * 2
        )
        let cancelPadding = CGSize(width: 14, height: 8)
        cancelRect = CGRect(
            x: bounds.maxX - cancelSize.width - cancelPadding.width * 2 - 24,
            y: bounds.maxY - cancelSize.height - cancelPadding.height * 2 - 24,
            width: cancelSize.width + cancelPadding.width * 2,
            height: cancelSize.height + cancelPadding.height * 2
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 18, yRadius: 18).fill()
        text.draw(
            at: CGPoint(x: pillRect.minX + pillPadding.width, y: pillRect.minY + pillPadding.height),
            withAttributes: textAttributes
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: cancelRect, xRadius: 16, yRadius: 16).fill()
        cancelText.draw(
            at: CGPoint(x: cancelRect.minX + cancelPadding.width, y: cancelRect.minY + cancelPadding.height),
            withAttributes: cancelAttributes
        )
    }

    private var selectedRect: CGRect {
        guard let startPoint, let currentPoint else { return .zero }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }
}
