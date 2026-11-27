//
//  ComputerListView.swift
//  Hermes for macOS
//
//  Chrome Remote Desktop-style home screen: a grid of your computers with their status.
//  Click one to connect to its desktop.
//

import SwiftUI

struct ComputerListView: View {
    @ObservedObject var store: ComputerStore

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)]

    var body: some View {
        ZStack(alignment: .bottom) {
            if store.computers.isEmpty {
                EmptyStateView(add: { store.sheet = .addComputer })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Remote computers")
                            .font(.title2.weight(.semibold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(store.computers) { computer in
                                ComputerCard(computer: computer, store: store)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let banner = store.banner {
                Text(banner)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let busy = store.busyText {
                BusyOverlay(text: busy)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.banner)
        .frame(minWidth: 560, minHeight: 380)
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .addComputer:
                AddComputerSheet(store: store)
            case .pair(let computer):
                PairSheet(computer: computer, store: store)
            case .showPin(let name, let pin):
                PinSheet(computerName: name, pin: pin) { store.sheet = nil }
            case .chooseDesktop(let choice):
                DesktopChoiceSheet(choice: choice, store: store)
            }
        }
        .alert(item: $store.message) { message in
            if let actionTitle = message.actionTitle, let action = message.action {
                let primary: Alert.Button = message.isDestructive
                    ? .destructive(Text(actionTitle), action: action)
                    : .default(Text(actionTitle), action: action)
                return Alert(title: Text(message.title),
                             message: message.text.map { Text($0) },
                             primaryButton: primary,
                             secondaryButton: .cancel())
            }
            return Alert(title: Text(message.title),
                         message: message.text.map { Text($0) },
                         dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - Cards

private struct StatusDot: View {
    let status: ComputerStore.Status

    var color: Color {
        switch status {
        case .online, .inSession: return .green
        case .needsPairing: return .orange
        case .offline, .checking: return Color.secondary.opacity(0.6)
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

private extension ComputerStore.Computer {
    var statusText: String {
        switch status {
        case .checking: return "Checking…"
        case .offline: return "Offline"
        case .needsPairing: return "Online · Click to pair"
        case .online: return isStreaming ? "Connected" : "Online"
        case .inSession: return isStreaming ? "Connected" : "Online · Session running"
        }
    }

    var isReachable: Bool {
        status == .online || status == .inSession || status == .needsPairing
    }
}

private struct ComputerCard: View {
    let computer: ComputerStore.Computer
    @ObservedObject var store: ComputerStore
    @SwiftUI.State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: computer.isStreaming ? "display.and.arrow.down" : "desktopcomputer")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(computer.isReachable ? .accentColor : .secondary)
                    .frame(width: 46, height: 40)
                StatusDot(status: computer.status)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(computer.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(computer.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let address = computer.address {
                    Text(address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Menu {
                ComputerMenuItems(computer: computer, store: store)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options for \(computer.name)")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 6 : 2, y: 1)
        .opacity(computer.isReachable ? 1 : 0.7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(computer) }
        .contextMenu { ComputerMenuItems(computer: computer, store: store) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Connects to \(computer.name)")
    }
}

private struct ComputerMenuItems: View {
    let computer: ComputerStore.Computer
    let store: ComputerStore

    var body: some View {
        switch computer.status {
        case .online, .inSession:
            Button("Connect") { store.connect(computer) }
            if computer.status == .inSession {
                Button("End Remote Session…") { store.endSession(computer) }
            }
            Button("Choose Desktop Entry…") { store.connect(computer, chooseDesktop: true) }
        case .needsPairing:
            Button("Pair…") { store.sheet = .pair(computer) }
        case .offline:
            if computer.canWake {
                Button("Wake Computer") { store.wake(computer) }
            }
        case .checking:
            EmptyView()
        }

        Divider()

        if computer.isReachable {
            Button("Open Apollo Web UI") { store.openWebUI(computer) }
        }
        if computer.status == .online || computer.status == .inSession {
            Button("Unpair") { store.unpair(computer) }
        }
        Button("Remove Computer…") { store.remove(computer) }
    }
}

// MARK: - Empty state & busy overlay

private struct EmptyStateView: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.secondary)
            ProgressView()
                .controlSize(.small)
            Text("Looking for computers…")
                .font(.title3.weight(.semibold))
            Text("Make sure Apollo is running on your computer and it's on the same network as this Mac. You can also add a computer by its address, including Tailscale names.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 420)
            Button("Add Computer…", action: add)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(text)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .transition(.opacity)
    }
}

// MARK: - Sheets

private struct SheetContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle = subtitle {
                Text(subtitle)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct AddComputerSheet: View {
    @ObservedObject var store: ComputerStore
    @SwiftUI.State private var address = ""

    var body: some View {
        SheetContainer(title: "Add a computer",
                       subtitle: "Enter the IP address or host name of a computer running Apollo, for example 192.168.1.20 or my-pc.tailnet.ts.net.") {
            TextField("IP address or host name", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.addComputer(address: address) }
            HStack {
                if store.isAdding {
                    ProgressView().controlSize(.small)
                    Text("Contacting computer…").foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { store.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { store.addComputer(address: address) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || store.isAdding)
            }
        }
    }
}

private struct PairSheet: View {
    let computer: ComputerStore.Computer
    @ObservedObject var store: ComputerStore

    private enum Method: Hashable { case otp, classic }
    @SwiftUI.State private var method: Method = .otp
    @SwiftUI.State private var pin = ""
    @SwiftUI.State private var passphrase = ""

    private var otpValid: Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber) && passphrase.count >= 4
    }

    var body: some View {
        SheetContainer(title: "Pair with \(computer.name)", subtitle: nil) {
            Picker("", selection: $method) {
                Text("One-time PIN from Apollo").tag(Method.otp)
                Text("Show a PIN on this Mac").tag(Method.classic)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if method == .otp {
                Text("In Apollo's web UI, open PIN pairing, create a one-time PIN, and enter it here with its passphrase.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("4-digit PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if otpValid { pair() } }
            } else {
                Text("Hermes will show a PIN. Type it into the PIN page of Apollo's web UI. This also works with Sunshine.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Apollo Web UI") { store.openWebUI(computer) }
                Spacer()
                Button("Cancel") { store.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(method == .otp && !otpValid)
            }
        }
    }

    private func pair() {
        if method == .otp {
            store.pair(computer, otpPin: pin, passphrase: passphrase)
        } else {
            store.pair(computer, otpPin: nil, passphrase: nil)
        }
    }
}

private struct PinSheet: View {
    let computerName: String
    let pin: String
    let dismiss: () -> Void

    var body: some View {
        SheetContainer(title: "Enter this PIN on \(computerName)",
                       subtitle: "Open Apollo's web UI on the computer, go to PIN pairing, and type:") {
            Text(pin.map { String($0) }.joined(separator: " "))
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for \(computerName)…").foregroundColor(.secondary)
                Spacer()
                Button("Hide", action: dismiss)
            }
        }
    }
}

private struct DesktopChoiceSheet: View {
    let choice: ComputerStore.DesktopChoice
    @ObservedObject var store: ComputerStore
    @SwiftUI.State private var selection: String?

    var body: some View {
        SheetContainer(title: "Which entry is \(choice.computerName)'s desktop?",
                       subtitle: "Hermes couldn't find an entry called \"Desktop\". Pick the one to connect to; you can change it later from the computer's menu.") {
            List(choice.apps, id: \.id, selection: $selection) { app in
                Text(app.name)
            }
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Cancel") { store.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(choice.launchAfter ? "Connect" : "Save") {
                    if let id = selection, let app = choice.apps.first(where: { $0.id == id }) {
                        store.choose(app, in: choice)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .onAppear { selection = choice.apps.first?.id }
    }
}
