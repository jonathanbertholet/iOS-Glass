import SwiftUI

struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var server: GlassServer

    init(model: CompanionModel) {
        self.model = model
        server = model.server
    }

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { GlassDashboard(model: model) }
                .tabItem { Label("Glass", systemImage: "eyeglasses") }.tag(0)
            NavigationStack { CardsView(model: model) }
                .tabItem { Label("Cards", systemImage: "rectangle.on.rectangle") }.tag(1)
            NavigationStack { GalleryView(model: model) }
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }.tag(2)
            NavigationStack { SetupView(model: model) }
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .toolbarBackground(GlassStyle.background, for: .tabBar)
        .alert("Allow this Glass connection?", isPresented: Binding(
            get: { server.pendingPeer != nil },
            set: { _ in } // Alert actions own approval and rejection.
        )) {
            Button("Allow Glass") { server.approve() }
            Button("Decline", role: .cancel) { server.disconnect() }
        } message: {
            Text("Device: \(server.pendingPeer ?? "unknown")\nApprove only the connection you just started on Glass. This enables gallery access and any location or Music sharing you have turned on.")
        }
        .alert("AnotherGlass", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}

struct GlassDashboard: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var server: GlassServer
    @ObservedObject private var location: LocationRelay
    @ObservedObject private var music: MusicRelay
    @Environment(\.openURL) private var openURL

    init(model: CompanionModel) {
        self.model = model
        server = model.server
        location = model.location
        music = model.music
    }

    var body: some View {
        GlassPage {
            GlassPageHeading(title: "AnotherGlass", subtitle: "An iPhone companion for your Explorer Edition")

            VStack(alignment: .leading, spacing: 12) {
                Picker("Connection", selection: Binding(get: { server.mode }, set: { server.selectMode($0) })) {
                    ForEach(GlassServer.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .disabled(server.isRunning)
                Text(server.isRunning ? "Stop the companion to change connection mode" : "Bluetooth for the background link. Wi-Fi for photos and video.")
                    .font(.footnote).foregroundStyle(GlassStyle.secondary)
            }

            GlassPanel {
                HStack(alignment: .firstTextBaseline) {
                    Text("Explorer Edition").font(.subheadline).foregroundStyle(GlassStyle.secondary)
                    Spacer(minLength: 8)
                    GlassStatus(text: connectionLabel, active: server.isConnected)
                }
                ExplorerIllustration().padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(server.state.title).font(.title2.weight(.medium)).foregroundStyle(GlassStyle.ink)
                    Text(statusDetail).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(GlassStyle.line)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        batteryReading
                        Spacer(minLength: 16)
                        Text(server.mode.title).font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        batteryReading
                        Text(server.mode.title).font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                    }
                }
                Button {
                    if server.isRunning { model.stop() } else { model.start() }
                } label: {
                    Label(server.isRunning ? "Stop companion" : "Start companion",
                          systemImage: server.isRunning ? "stop" : "arrow.right")
                }
                .buttonStyle(GlassPrimaryButtonStyle())
                if server.isConnected {
                    Button("Disconnect Glass", role: .destructive) { server.disconnect() }
                        .font(.subheadline).frame(minHeight: 44).frame(maxWidth: .infinity)
                }
            }

            if server.isRunning, !server.isConnected {
                GlassSection(title: "Connect from Glass") {
                    GlassPanel {
                        if server.mode == .bluetooth {
                            Label("Choose iPhone Bluetooth LE", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.body.weight(.medium))
                            Text("Keep this app open for discovery and approval. Once connected, the companion can respond in the background with GPS off.")
                                .font(.subheadline).foregroundStyle(GlassStyle.secondary)
                            Text("Use the updated Explorer APK. If the link breaks, reopen this app to reconnect.")
                                .font(.footnote).foregroundStyle(GlassStyle.muted)
                        } else {
                            ConnectionCodeView(model: model)
                            Text("On Glass, open AnotherGlass → Scan Barcode. Join the same Wi-Fi network, then approve the connection here.")
                                .font(.footnote).foregroundStyle(GlassStyle.secondary)
                        }
                    }
                }
            }

            GlassSection(title: "Location", detail: "Your iPhone supplies the GPS fix. Sharing starts only after you approve a Glass connection.") {
                GlassPanel {
                    Toggle(isOn: Binding(get: { location.enabled }, set: { location.setEnabled($0) })) {
                        Label("Share GPS", systemImage: "location")
                    }
                    Text(location.status).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                    if let fix = location.latest {
                        Divider().overlay(GlassStyle.line)
                        Text("\(fix.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(fix.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))")
                            .font(.subheadline.monospacedDigit()).textSelection(.enabled)
                        Text(fix.timestamp, style: .relative).font(.caption).foregroundStyle(GlassStyle.muted)
                    }
                    if location.authorization == .denied || location.authorization == .restricted {
                        Button("Open location settings") { openSettings() }.frame(minHeight: 44)
                    }
                }
            }

            GlassSection(title: "Music", detail: "Control the Apple Music app’s queue from Glass. Other players need their own integrations.") {
                GlassPanel {
                    Toggle(isOn: Binding(get: { music.enabled }, set: { music.setEnabled($0) })) {
                        Label("Share Music playback", systemImage: "music.note")
                    }
                    if music.enabled, let title = music.current.title {
                        Divider().overlay(GlassStyle.line)
                        Text(title).font(.title3.weight(.medium))
                        if let artist = music.current.artist { Text(artist).font(.subheadline).foregroundStyle(GlassStyle.secondary) }
                        GlassStatus(text: music.current.playbackState, active: music.current.playbackState == "Playing")
                    } else {
                        Text(music.status).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ActivityView(model: model) } label: {
                    Image(systemName: "waveform.path").accessibilityLabel("Connection activity")
                }
            }
        }
    }

    private var connectionLabel: String {
        switch server.state {
        case .stopped: return "Standby"
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .awaitingApproval: return "Approval needed"
        case .connected: return "Connected"
        case .failed: return "Needs attention"
        }
    }

    private var batteryReading: some View {
        Label {
            if let battery = model.battery {
                Text("\(battery.level)%\(battery.isCharging ? " · Charging" : "")")
            } else { Text("Battery unavailable") }
        } icon: {
            Image(systemName: model.battery?.isCharging == true ? "battery.100.bolt" : "battery.75")
        }
        .font(.subheadline.monospacedDigit()).foregroundStyle(GlassStyle.secondary)
    }

    private var statusDetail: String {
        switch server.state {
        case .connected: return "\(server.peer ?? "Glass") · Ready to share"
        case .awaitingApproval: return "Approve the connection request on this iPhone to begin sharing"
        case .listening: return server.mode == .bluetooth ? "Select iPhone Bluetooth LE in AnotherGlass on your Glass" : "Your connection code is ready below"
        case .starting: return server.mode == .bluetooth ? "Allow Bluetooth access when iOS asks" : "Allow Local Network access when iOS asks"
        case .failed(let error): return error
        case .stopped: return "Bring cards, music and location back to your Glass"
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

struct ConnectionCodeView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(spacing: 20) {
            if !model.useManualAddress, model.addresses.count > 1 {
                Picker("iPhone address", selection: $model.selectedAddress) {
                    ForEach(model.addresses) { address in
                        Text("\(address.address) · \(address.label)").tag(address.address)
                    }
                }
            }
            if model.connectionAddress.isEmpty {
                GlassEmptyState(symbol: "wifi.slash", title: "Join a Wi-Fi network", detail: "Connect iPhone and Glass to the same network, or enter the hotspot address in Setup.")
            } else {
                QRCodeView(value: model.connectionAddress + "|iPhone")
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Glass connection QR code for \(model.connectionAddress)")
                VStack(spacing: 8) {
                    Text(model.connectionAddress).font(.title3.monospaced()).textSelection(.enabled)
                    Text("Connection address · TCP 9090").font(.caption).foregroundStyle(GlassStyle.muted)
                }
            }
            Button("Refresh addresses", systemImage: "arrow.clockwise") { model.refreshAddresses() }
                .font(.subheadline).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActivityView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var server: GlassServer

    init(model: CompanionModel) {
        self.model = model
        server = model.server
    }

    var body: some View {
        GlassPage {
            GlassPageHeading(title: "Activity", subtitle: "The current companion session")
            GlassPanel {
                LabeledContent("Messages sent", value: server.sentCount.formatted())
                Divider().overlay(GlassStyle.line)
                LabeledContent("Messages received", value: server.receivedCount.formatted())
            }
            .monospacedDigit()
            GlassSection(title: "Recent activity", detail: "Session only. Card contents, coordinates and Wi-Fi credentials stay out of this log.") {
                if model.activity.isEmpty {
                    GlassEmptyState(symbol: "waveform.path", title: "No events yet", detail: "Start the companion to see connection activity here.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(model.activity) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.date, style: .time).font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                                Text(entry.message).font(.subheadline)
                                Divider().overlay(GlassStyle.line)
                            }
                        }
                    }
                }
            }
        }
    }
}
