//
//  ComputerListViewController.swift
//  Hermes for macOS
//
//  Hosts the SwiftUI computer list in the main window (replacing Moonlight's host and
//  app grids) and wires the window's toolbar to it.
//

import Cocoa
import SwiftUI

@objc(ComputerListViewController)
final class ComputerListViewController: NSViewController {
    private let store = ComputerStore()

    @objc override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func loadView() {
        view = NSHostingView(rootView: ComputerListView(store: store))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        HermesMenus.install()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }
        window.title = "Hermes"
        window.subtitle = ""
        configureToolbar(window.toolbar)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        store.start()
    }

    private func configureToolbar(_ toolbar: NSToolbar?) {
        guard let toolbar = toolbar else { return }
        // Hermes has no app grid to go "back" from
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "BackToolbarItem" }) {
            toolbar.removeItem(at: index)
        }
        for item in toolbar.items {
            switch item.itemIdentifier.rawValue {
            case "AddHostToolbarItem":
                item.label = "Add Computer"
                item.toolTip = "Add a computer by its address"
                item.isEnabled = true
                if let button = item.view as? NSButton {
                    button.target = self
                    button.action = #selector(addHostButtonClicked(_:))
                    button.toolTip = item.toolTip
                } else {
                    item.target = self
                    item.action = #selector(addHostButtonClicked(_:))
                }
            case "PreferencesToolbarItem":
                (item.view as? NSButton)?.toolTip = "Settings"
            default:
                break
            }
        }
    }

    /// Also reachable from the File menu / toolbar through the responder chain.
    @objc func addHostButtonClicked(_ sender: Any?) {
        store.sheet = .addComputer
    }
}

/// Adds Hermes' "Session" menu (acted on by the frontmost stream window).
enum HermesMenus {
    private static var installed = false

    static func install() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        installed = true

        let session = NSMenu(title: "Session")
        func add(_ title: String, _ action: String, _ key: String, _ mods: NSEvent.ModifierFlags) {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            session.addItem(item)
        }
        let ctrlOptCmd: NSEvent.ModifierFlags = [.control, .option, .command]
        add("Show Session Controls", "hermesToggleSessionPanel:", "s", ctrlOptCmd)
        session.addItem(.separator())
        add("Send Clipboard to Computer", "hermesSendClipboard:", "v", ctrlOptCmd)
        add("Copy Computer's Clipboard", "hermesGetClipboard:", "c", ctrlOptCmd)
        session.addItem(.separator())
        add("Send Task Manager (Ctrl+Shift+Esc)", "hermesSendTaskManager:", "", [])
        add("Send Windows Key", "hermesSendWindowsKey:", "", [])
        add("Send Alt+Tab", "hermesSendAltTab:", "", [])
        session.addItem(.separator())
        add("Fit to Window", "hermesScaleFit:", "", [])
        add("Fill Window", "hermesScaleFill:", "", [])
        add("Stretch to Window", "hermesScaleStretch:", "", [])
        session.addItem(.separator())
        add("Use Desktop Pointer", "hermesPointerDesktop:", "", [])
        add("Capture Pointer (for Games)", "hermesPointerCaptured:", "", [])

        let sessionItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        sessionItem.submenu = session
        // Before Window/Help if present, otherwise at the end
        let insertAt = mainMenu.items.firstIndex(where: { $0.submenu === NSApp.windowsMenu })
            ?? mainMenu.items.firstIndex(where: { $0.submenu === NSApp.helpMenu })
            ?? mainMenu.items.count
        mainMenu.insertItem(sessionItem, at: insertAt)
    }
}
