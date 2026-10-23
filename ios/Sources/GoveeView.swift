import SwiftUI
import HouseCore

/// Govee: lights on this Wi-Fi (Govee LAN API, no account), and optionally the lights of a
/// Govee account through its Developer API key, for models without LAN control.
struct GoveeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.insideEditor) private var insideEditor
    @State private var lan = true
    @State private var apiKey = ""
    @State private var hosts = ""
    @State private var working = false
    @State private var problem: String?
    @State private var lights: [ServiceDevice] = []
    @State private var scanning = false
    @State private var editing = false
    @State private var confirmDisconnect = false
    @FocusState private var focus: Field?

    private enum Field { case key, hosts }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                if model.goveeName != nil && !editing {
                    connected
                } else {
                    setup
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.goveeName)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: editing)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Govee")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear(perform: loadSettings)
        .task { if model.goveeName != nil { await scan() } }
    }

    // MARK: - Setting up

    private var setup: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                SectionTitle("On this Wi-Fi")
                Card {
                    Toggle(isOn: $lan) {
                        HStack(spacing: 14) {
                            IconBadge(symbol: "wifi", tint: ConnectionLook.govee)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local control").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("Fast, works without internet").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .tint(ConnectionLook.govee)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 70)
                }
                Footnote(text: "In the Govee app, open each light, tap the settings gear and switch on LAN Control. Lights that have no such switch need the API key below.")
            }

            VStack(spacing: 10) {
                SectionTitle("Govee account (optional)")
                Card(padding: 16) {
                    InputField(title: "API key", text: $apiKey, prompt: "Paste your Govee API key", focused: focus == .key) {
                        SecureField("", text: $apiKey)
                            .focused($focus, equals: .key)
                            .submitLabel(.done)
                    }
                }
                Footnote(text: "Govee app → Profile → Settings (gear) → Apply for API Key. Govee emails it to you. Used for lights without LAN Control; it stays on this iPhone and your paired Mac.")
            }

            VStack(spacing: 10) {
                SectionTitle("Addresses (optional)")
                Card(padding: 16) {
                    InputField(title: "Light IP addresses", text: $hosts, prompt: "e.g. 192.168.1.40, 192.168.1.41", focused: focus == .hosts) {
                        TextField("", text: $hosts)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focus, equals: .hosts)
                            .submitLabel(.done)
                    }
                }
                Footnote(text: "Only if a light is not found by itself. Your router's app lists each light's address.")
            }

            VStack(spacing: 12) {
                if let problem { ProblemLabel(text: problem) }
                Button { Task { await connect() } } label: {
                    if working {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text("Looking for lights…") }
                    } else {
                        Text(model.goveeName == nil ? "Connect" : "Save")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working || (!lan && apiKey.trimmingCharacters(in: .whitespaces).isEmpty))
                if editing {
                    Button("Cancel") { editing = false; loadSettings() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func connect() async {
        focus = nil
        problem = nil
        working = true
        defer { working = false }
        let list = hosts.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        do {
            try await model.connectGovee(lan: lan, apiKey: apiKey, hosts: list)
            editing = false
            await scan()
        } catch {
            problem = error.localizedDescription
            Haptics.shared.play("error")
        }
    }

    private func loadSettings() {
        let info = model.goveeInfo
        lan = info["lan"] as? Bool ?? true
        hosts = (info["hosts"] as? [String] ?? []).joined(separator: ", ")
        apiKey = model.hub.govee.shareable?["apiKey"] as? String ?? ""
    }

    // MARK: - Connected

    private var connected: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                SectionTitle("Lights")
                Card {
                    if scanning && lights.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView().tint(Theme.muted)
                            Text("Looking for Govee lights…").font(.system(size: 15)).foregroundStyle(Theme.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 60)
                    } else if lights.isEmpty {
                        Text("No light found yet. Check that LAN Control is on in the Govee app and that this iPhone is on the same Wi-Fi as the lights, or add an API key.")
                            .font(.system(size: 15)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ForEach(Array(lights.enumerated()), id: \.offset) { index, light in
                            if index > 0 { RowDivider() }
                            HStack(spacing: 14) {
                                IconBadge(symbol: ConnectionLook.symbol("govee"), tint: ConnectionLook.govee)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(light.name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                    HStack(spacing: 7) {
                                        StatusDot(color: light.online ? Theme.green : Theme.faint)
                                        Text(light.detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 66)
                        }
                    }
                }
                if let problem { ProblemLabel(text: problem) }
                if !scanning {
                    Button { Task { await scan() } } label: { Label("Look again", systemImage: "dot.radiowaves.left.and.right") }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
            VStack(spacing: 12) {
                if !insideEditor {
                    NavigationLink(value: SettingsRoute.devices) {
                        Label("Link lights to your plan", systemImage: "link")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button { loadSettings(); editing = true } label: { Text("Settings and API key") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { confirmDisconnect = true } label: { Text("Disconnect") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.red))
                    .confirmationDialog("Disconnect Govee?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) { model.disconnect(service: "govee"); lights = [] }
                    } message: {
                        Text("Its lights go back to being simulated, here and on your paired Mac.")
                    }
            }
        }
        .transition(.opacity)
    }

    private func scan() async {
        scanning = true
        problem = nil
        do {
            lights = try await model.goveeLights()
        } catch {
            problem = error.localizedDescription
        }
        scanning = false
    }
}
