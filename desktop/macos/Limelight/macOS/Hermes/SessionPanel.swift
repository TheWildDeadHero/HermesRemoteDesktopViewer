//
//  SessionPanel.swift
//  Hermes for macOS
//
//  The in-session side panel, modelled on Chrome Remote Desktop: a small tab on the
//  right edge of the stream (or ⌃⌥⌘S) slides out controls for keys, pointer, display,
//  clipboard and disconnecting.
//

import Cocoa
import SwiftUI

/// Hosting view that always shows the normal arrow, even though the stream view
/// underneath hides the Mac cursor.
final class ArrowCursorHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Windows virtual-key codes used by the quick-key buttons.
private enum VK {
    static let lShift: Int = 0xA0
    static let lCtrl: Int = 0xA2
    static let lAlt: Int = 0xA4
    static let lWin: Int = 0x5B
    static let tab: Int = 0x09
    static let escape: Int = 0x1B
    static let f4: Int = 0x73
    static let d: Int = 0x44
    static let printScreen: Int = 0x2C
}

private struct QuickKey: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: [Int]
}

private let quickKeys: [QuickKey] = [
    QuickKey(id: "taskmgr", title: "Task Manager", symbol: "list.bullet.rectangle", keys: [VK.lCtrl, VK.lShift, VK.escape]),
    QuickKey(id: "start", title: "Start menu", symbol: "square.grid.2x2", keys: [VK.lWin]),
    QuickKey(id: "alttab", title: "Alt+Tab", symbol: "rectangle.stack", keys: [VK.lAlt, VK.tab]),
    QuickKey(id: "altf4", title: "Alt+F4", symbol: "xmark.rectangle", keys: [VK.lAlt, VK.f4]),
    QuickKey(id: "desktop", title: "Show desktop", symbol: "menubar.dock.rectangle", keys: [VK.lWin, VK.d]),
    QuickKey(id: "esc", title: "Esc", symbol: "escape", keys: [VK.escape]),
    QuickKey(id: "prtsc", title: "Print Screen", symbol: "camera.viewfinder", keys: [VK.printScreen]),
]

final class SessionPanelModel: ObservableObject {
    let computerName: String
    @Published var scaleMode: HermesScaleMode = HermesSettings.scaleMode
    @Published var pointerMode: HermesPointerMode = HermesSettings.pointerMode
    @Published var stats: String = ""
    @Published var isFullScreen = false
    @Published var message: String?

    init(computerName: String) {
        self.computerName = computerName
    }
}

@objc(HermesSessionPanelController)
final class SessionPanelController: NSObject {
    private let model: SessionPanelModel
    private weak var actions: HermesSessionActions?
    private var panelView: NSView!
    private var handleView: NSView!
    private var statsTimer: Timer?
    private var messageWorkItem: DispatchWorkItem?

    private static let panelWidth: CGFloat = 320
    private static let handleSize = CGSize(width: 22, height: 72)

    @objc private(set) var isOpen = false

    @objc(initWithComputerName:actions:)
    init(computerName: String, actions: HermesSessionActions) {
        self.model = SessionPanelModel(computerName: computerName)
        self.actions = actions
        super.init()

        let panel = ArrowCursorHostingView(rootView: SessionPanelView(model: model, controller: self))
        panel.isHidden = true
        panel.autoresizingMask = [.minXMargin, .height]
        panelView = panel

        let handle = ArrowCursorHostingView(rootView: SessionHandleView(open: { [weak self] in self?.open() }))
        handle.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        handle.isHidden = !HermesSettings.showSessionHandle
        handleView = handle
    }

    deinit {
        statsTimer?.invalidate()
    }

    /// The two views to add above the video (handle first, panel on top).
    @objc var overlayViews: [NSView] { [handleView, panelView] }

    /// Positions the overlays inside the stream view's bounds; they then follow resizes.
    @objc(layoutInBounds:)
    func layout(in bounds: NSRect) {
        panelView.frame = NSRect(x: bounds.maxX - Self.panelWidth, y: bounds.minY,
                                 width: Self.panelWidth, height: bounds.height)
        handleView.frame = NSRect(x: bounds.maxX - Self.handleSize.width,
                                  y: bounds.midY - Self.handleSize.height / 2,
                                  width: Self.handleSize.width, height: Self.handleSize.height)
    }

    @objc func toggle() {
        isOpen ? close() : open()
    }

    @objc func open() {
        guard !isOpen else { return }
        isOpen = true
        model.scaleMode = HermesSettings.scaleMode
        model.pointerMode = HermesSettings.pointerMode
        refresh()
        panelView.alphaValue = 0
        panelView.isHidden = false
        handleView.isHidden = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panelView.animator().alphaValue = 1
        }
        panelView.window?.makeFirstResponder(panelView)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        actions?.panelVisibilityChanged(true)
    }

    @objc func close() {
        guard isOpen else { return }
        isOpen = false
        statsTimer?.invalidate()
        statsTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panelView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isOpen else { return }
            self.panelView.isHidden = true
            self.handleView.isHidden = !HermesSettings.showSessionHandle
        })
        actions?.panelVisibilityChanged(false)
    }

    /// Shows a short confirmation or error at the bottom of the panel.
    @objc(showMessage:)
    func show(message: String) {
        model.message = message
        messageWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.model.message = nil }
        messageWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func refresh() {
        guard let actions = actions else { return }
        model.stats = actions.statsText()
        model.isFullScreen = actions.isFullScreen()
    }

    // MARK: Actions from the SwiftUI view

    fileprivate func send(_ keys: [Int]) {
        actions?.sendKeyCombo(keys.map { NSNumber(value: $0) })
    }

    fileprivate func setScaleMode(_ mode: HermesScaleMode) {
        actions?.setScaleMode(mode.rawValue)
    }

    fileprivate func setPointerMode(_ mode: HermesPointerMode) {
        actions?.setPointerMode(mode.rawValue)
    }

    fileprivate func toggleFullScreen() {
        actions?.toggleFullScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    fileprivate func actualSize() { actions?.resizeToActualSize() }
    fileprivate func sendClipboard() { actions?.sendClipboard() }
    fileprivate func getClipboard() { actions?.getClipboard() }

    fileprivate func disconnect() {
        close()
        actions?.disconnect()
    }

    fileprivate func endSession() {
        close()
        actions?.endSession()
    }
}

// MARK: - Views

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SessionHandleView: View {
    let open: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: open) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(hovering ? 0.75 : 0.45))
                )
        }
        .buttonStyle(.plain)
        .help("Show session controls (⌃⌥⌘S)")
        .onHover { hovering = $0 }
        .padding(.vertical, 2)
        .padding(.trailing, 2)
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionPanelView: View {
    @ObservedObject var model: SessionPanelModel
    weak var controller: SessionPanelController?
    @SwiftUI.State private var confirmEnd = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PanelSection(title: "Pointer") {
                        Picker("", selection: Binding(
                            get: { model.pointerMode },
                            set: { model.pointerMode = $0; controller?.setPointerMode($0) }
                        )) {
                            Text("Desktop").tag(HermesPointerMode.desktop)
                            Text("Captured").tag(HermesPointerMode.captured)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(model.pointerMode == .desktop
                             ? "Your pointer moves freely and clicks exactly where you point."
                             : "The pointer is locked to the stream, for games. Press Control-Option to release it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PanelSection(title: "Send keys") {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(quickKeys) { key in
                                PanelButton(title: key.title, symbol: key.symbol) {
                                    controller?.send(key.keys)
                                }
                            }
                        }
                        Text("⌘ is sent as the Windows key. Ctrl+Alt+Del can't be sent remotely; use Task Manager instead.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PanelSection(title: "Display") {
                        Picker("", selection: Binding(
                            get: { model.scaleMode },
                            set: { model.scaleMode = $0; controller?.setScaleMode($0) }
                        )) {
                            Text("Fit").tag(HermesScaleMode.fit)
                            Text("Fill").tag(HermesScaleMode.fill)
                            Text("Stretch").tag(HermesScaleMode.stretch)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        LazyVGrid(columns: columns, spacing: 8) {
                            PanelButton(title: model.isFullScreen ? "Exit full screen" : "Full screen",
                                        symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                                controller?.toggleFullScreen()
                            }
                            PanelButton(title: "Actual size", symbol: "1.magnifyingglass") {
                                controller?.actualSize()
                            }
                        }
                    }

                    PanelSection(title: "Clipboard") {
                        PanelButton(title: "Send this Mac's clipboard", symbol: "arrow.up.doc.on.clipboard") {
                            controller?.sendClipboard()
                        }
                        PanelButton(title: "Copy the computer's clipboard", symbol: "arrow.down.doc") {
                            controller?.getClipboard()
                        }
                    }
                }
                .padding(16)
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.1))
                    .transition(.opacity)
            }

            Divider()
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirmEnd = true
                } label: {
                    Text("End session")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    controller?.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
        }
        .background(VisualEffectBackground())
        .colorScheme(.dark)
        .onExitCommand { controller?.close() }
        .alert(isPresented: $confirmEnd) {
            Alert(
                title: Text("End the remote session?"),
                message: Text("Apps stay open on \(model.computerName), but its virtual display closes."),
                primaryButton: .destructive(Text("End session")) { controller?.endSession() },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.computerName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(model.stats.isEmpty ? "Connected" : model.stats)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                controller?.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(16)
    }
}
