//
//  ComputerStore.swift
//  Hermes for macOS
//
//  State and actions behind the computer list. Hermes only ever streams a computer's
//  desktop, so there is no per-computer app grid: connecting resolves the host's
//  "Desktop" entry (remembering the user's choice if there isn't an obvious one) and
//  opens the stream straight away.
//

import Cocoa
import SwiftUI

final class ComputerStore: ObservableObject {

    enum Status: Equatable {
        case checking
        case offline
        case needsPairing
        case online
        case inSession
    }

    struct Computer: Identifiable, Equatable {
        let id: String
        let name: String
        let address: String?
        let status: Status
        let canWake: Bool
        let hasVirtualDisplay: Bool
        let isStreaming: Bool
    }

    struct DesktopChoice: Equatable {
        let computerId: String
        let computerName: String
        let apps: [App]
        let launchAfter: Bool

        struct App: Identifiable, Equatable {
            let id: String
            let name: String
        }
    }

    enum Sheet: Identifiable, Equatable {
        case addComputer
        case pair(Computer)
        case showPin(computerName: String, pin: String)
        case chooseDesktop(DesktopChoice)

        var id: String {
            switch self {
            case .addComputer: return "add"
            case .pair(let c): return "pair-\(c.id)"
            case .showPin(let name, _): return "pin-\(name)"
            case .chooseDesktop(let choice): return "desktop-\(choice.computerId)"
            }
        }
    }

    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let text: String?
        var actionTitle: String?
        var isDestructive = false
        var action: (() -> Void)?
    }

    @Published private(set) var computers: [Computer] = []
    @Published var sheet: Sheet?
    @Published var message: Message?
    @Published private(set) var busyText: String?
    @Published private(set) var banner: String?
    @Published private(set) var isAdding = false

    private let directory = HermesHostDirectory()
    private var refreshTimer: Timer?
    private var streamWindows: [String: NSWindowController] = [:]
    private var wakeConnect: (id: String, deadline: Date)?
    private var bannerWork: DispatchWorkItem?
    private var started = false

    private static let desktopAppKeyPrefix = "hermes.desktopApp."

    init() {
        directory.onListChanged = { [weak self] in self?.refresh() }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        directory.start()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        started = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        directory.stop()
    }

    private func host(_ id: String) -> TemporaryHost? {
        directory.hosts.first { $0.uuid == id }
    }

    private func refresh() {
        let items: [Computer] = directory.hosts.map { host in
            let status: Status
            switch host.state {
            case .online:
                if host.pairState != .paired {
                    status = .needsPairing
                } else if let game = host.currentGame, !game.isEmpty, game != "0" {
                    status = .inSession
                } else {
                    status = .online
                }
            case .offline:
                status = .offline
            default:
                status = .checking
            }
            return Computer(
                id: host.uuid,
                name: host.name.isEmpty ? (host.activeAddress ?? "Computer") : host.name,
                address: host.activeAddress ?? host.localAddress ?? host.address,
                status: status,
                canWake: (host.mac?.isEmpty == false) && host.mac != "00:00:00:00:00:00",
                hasVirtualDisplay: host.vDisplaySupported,
                isStreaming: streamWindows[host.uuid] != nil
            )
        }
        // Online computers first, then by name (Chrome Remote Desktop ordering)
        let sorted = items.sorted { a, b in
            let ra = a.status == .offline || a.status == .checking ? 1 : 0
            let rb = b.status == .offline || b.status == .checking ? 1 : 0
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if sorted != computers {
            computers = sorted
        }

        // Connect automatically once a computer we woke up comes online
        if let pending = wakeConnect {
            if Date() > pending.deadline {
                wakeConnect = nil
            } else if let c = sorted.first(where: { $0.id == pending.id }), c.status == .online || c.status == .inSession {
                wakeConnect = nil
                connect(c)
            }
        }
    }

    private func showBanner(_ text: String) {
        banner = text
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: Primary action

    func open(_ computer: Computer) {
        switch computer.status {
        case .checking:
            showBanner("Still checking \(computer.name)…")
        case .offline:
            if computer.canWake {
                message = Message(title: "\(computer.name) is offline",
                                  text: "Hermes can try to wake it. This works if Wake-on-LAN is turned on for that computer.",
                                  actionTitle: "Wake") { [weak self] in self?.wake(computer) }
            } else {
                message = Message(title: "\(computer.name) is offline",
                                  text: "Make sure it's turned on, connected to the network and running Apollo.")
            }
        case .needsPairing:
            sheet = .pair(computer)
        case .online, .inSession:
            connect(computer)
        }
    }

    // MARK: Connecting

    func connect(_ computer: Computer, chooseDesktop: Bool = false) {
        if let existing = streamWindows[computer.id], !chooseDesktop {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let host = host(computer.id) else { return }
        guard busyText == nil else { return }

        SettingsClass.loadMoonlightSettings(for: host.uuid)

        // A session is already running: rejoin it, whatever entry it was started from
        if !chooseDesktop, let game = host.currentGame, !game.isEmpty, game != "0" {
            launch(host: host, appId: game)
            return
        }

        busyText = "Connecting to \(computer.name)…"
        HermesHostActions.fetchApps(for: host) { [weak self] apps, error in
            guard let self = self else { return }
            self.busyText = nil
            guard let apps = apps, !apps.isEmpty else {
                self.message = Message(title: "Couldn't connect to \(computer.name)",
                                       text: error ?? "Apollo didn't report anything to stream. Check its Applications page.")
                return
            }
            let choices = apps.compactMap { app -> DesktopChoice.App? in
                guard let id = app.id else { return nil }
                return DesktopChoice.App(id: id, name: app.name ?? "Untitled")
            }
            if !chooseDesktop, let pick = self.pickDesktop(for: host.uuid, from: choices) {
                self.launch(host: host, appId: pick.id)
            } else {
                self.sheet = .chooseDesktop(DesktopChoice(computerId: host.uuid, computerName: computer.name,
                                                          apps: choices, launchAfter: !chooseDesktop))
            }
        }
    }

    /// The saved choice, then an entry called "Desktop", then anything with "desktop" in its
    /// name, then the only entry. Nil means "ask".
    private func pickDesktop(for hostId: String, from apps: [DesktopChoice.App]) -> DesktopChoice.App? {
        if let saved = UserDefaults.standard.string(forKey: Self.desktopAppKeyPrefix + hostId),
           let app = apps.first(where: { $0.id == saved }) {
            return app
        }
        if let app = apps.first(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Desktop") == .orderedSame }) {
            return app
        }
        if let app = apps.first(where: { $0.name.localizedCaseInsensitiveContains("desktop") }) {
            return app
        }
        return apps.count == 1 ? apps[0] : nil
    }

    func choose(_ app: DesktopChoice.App, in choice: DesktopChoice) {
        UserDefaults.standard.set(app.id, forKey: Self.desktopAppKeyPrefix + choice.computerId)
        sheet = nil
        if choice.launchAfter, let host = host(choice.computerId) {
            launch(host: host, appId: app.id)
        } else {
            showBanner("\(choice.computerName) will open \(app.name).")
        }
    }

    private func launch(host: TemporaryHost, appId: String) {
        let name = host.name.isEmpty ? "Remote desktop" : host.name
        let app = HermesHostActions.makeApp(id: appId, name: name, host: host)
        let id = host.uuid
        let controller = HermesHostActions.openStreamWindow(for: app) { [weak self] in
            guard let self = self else { return }
            if self.streamWindows.removeValue(forKey: id) != nil {
                self.refresh()
            }
        }
        streamWindows[id] = controller
        refresh()
    }

    // MARK: Other actions

    func wake(_ computer: Computer) {
        guard let host = host(computer.id) else { return }
        HermesHostActions.wake(host)
        wakeConnect = (computer.id, Date().addingTimeInterval(180))
        showBanner("Waking \(computer.name)… Hermes will connect when it's ready.")
    }

    func endSession(_ computer: Computer) {
        guard let host = host(computer.id) else { return }
        message = Message(title: "End the remote session on \(computer.name)?",
                          text: "Apps stay open on the computer, but its virtual display closes.",
                          actionTitle: "End Session", isDestructive: true) { [weak self] in
            HermesHostActions.quitSession(on: host) { ok in
                guard let self = self else { return }
                if ok {
                    self.showBanner("Session on \(computer.name) ended.")
                } else {
                    self.message = Message(title: "Couldn't end the session",
                                           text: "If it was started from another device, end it from that device.")
                }
                self.refresh()
            }
        }
    }

    func unpair(_ computer: Computer) {
        guard let host = host(computer.id) else { return }
        HermesHostActions.unpair(host) { [weak self] ok, error in
            if ok {
                self?.showBanner("Unpaired from \(computer.name).")
            } else {
                self?.message = Message(title: "Couldn't unpair", text: error)
            }
            self?.refresh()
        }
    }

    func remove(_ computer: Computer) {
        message = Message(title: "Remove \(computer.name)?",
                          text: "You'll need to pair again to connect to it from this Mac.",
                          actionTitle: "Remove", isDestructive: true) { [weak self] in
            guard let self = self, let host = self.host(computer.id) else { return }
            self.directory.remove(host)
            UserDefaults.standard.removeObject(forKey: Self.desktopAppKeyPrefix + computer.id)
            self.refresh()
        }
    }

    func openWebUI(_ computer: Computer) {
        guard let address = computer.address else { return }
        let hostPart = address.contains(":") ? "[\(address)]" : address
        if let url = URL(string: "https://\(hostPart):47990") {
            NSWorkspace.shared.open(url)
        }
    }

    func addComputer(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAdding else { return }
        isAdding = true
        directory.addHost(address: trimmed) { [weak self] host, error in
            guard let self = self else { return }
            self.isAdding = false
            if let host = host {
                self.sheet = nil
                self.refresh()
                self.showBanner("Added \(host.name.isEmpty ? trimmed : host.name).")
            } else {
                self.message = Message(title: "Couldn't add \(trimmed)", text: error)
            }
        }
    }

    // MARK: Pairing

    /// Pairs, then connects. With a PIN + passphrase from Apollo's web UI this is Apollo's
    /// one-time-PIN flow; without them Hermes shows a PIN to type into Apollo.
    func pair(_ computer: Computer, otpPin: String?, passphrase: String?) {
        guard let host = host(computer.id) else { return }
        let otp = (otpPin?.isEmpty == false && passphrase?.isEmpty == false)
        sheet = nil
        busyText = otp ? "Pairing with \(computer.name)…" : nil

        // Polling the host while pairing confuses it, so stop discovery first (this blocks)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.directory.pauseBlocking()
            DispatchQueue.main.async {
                guard let self = self else { return }
                HermesHostActions.pair(host, otpPin: otp ? otpPin : nil, passphrase: otp ? passphrase : nil,
                                       onShowPin: { [weak self] pin in
                                           self?.sheet = .showPin(computerName: computer.name, pin: pin)
                                       },
                                       completion: { [weak self] success, error in
                                           guard let self = self else { return }
                                           self.busyText = nil
                                           if case .some(.showPin(_, _)) = self.sheet { self.sheet = nil }
                                           self.directory.start()
                                           self.refresh()
                                           if success {
                                               self.showBanner("Paired with \(computer.name). If the mouse or keyboard don't respond, allow input for this Mac under Clients in Apollo's web UI.")
                                               self.connect(Computer(id: computer.id, name: computer.name,
                                                                     address: computer.address, status: .online,
                                                                     canWake: computer.canWake,
                                                                     hasVirtualDisplay: computer.hasVirtualDisplay,
                                                                     isStreaming: false))
                                           } else {
                                               self.message = Message(title: "Pairing with \(computer.name) failed",
                                                                      text: error)
                                           }
                                       })
            }
        }
    }
}
