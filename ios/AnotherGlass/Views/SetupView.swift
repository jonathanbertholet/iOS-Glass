import SwiftUI

struct SetupView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var location: LocationRelay
    @Environment(\.openURL) private var openURL

    init(model: CompanionModel) {
        self.model = model
        location = model.location
    }

    var body: some View {
        GlassPage {
            GlassPageHeading(title: "Setup", subtitle: "A new connection for the original Glass")

            GlassSection(title: "Connect your Explorer") {
                GlassPanel {
                    SetupStep(number: "1", title: "Install on Glass", detail: "Sideload this project's Explorer APK over USB. This iPhone app replaces the Android phone companion.")
                    Divider().overlay(GlassStyle.line)
                    SetupStep(number: "2", title: "Choose a connection", detail: "Select Bluetooth LE on the Glass tab for a background link without GPS. Start the companion, choose iPhone Bluetooth LE on Glass, then approve it here. Choose Wi-Fi for photos and video.")
                    Divider().overlay(GlassStyle.line)
                    SetupStep(number: "3", title: "For Wi-Fi, join the same network", detail: "Use 2.4 GHz Wi-Fi with WPA2 compatibility. For Personal Hotspot, enable Maximize Compatibility on iPhone.")
                    NavigationLink { WiFiSetupView(model: model) } label: {
                        SetupLink(title: "Wi-Fi setup QR code", symbol: "qrcode")
                    }
                    Divider().overlay(GlassStyle.line)
                    SetupStep(number: "4", title: "Scan the connection code", detail: "Start the companion with Wi-Fi selected. On Glass, open AnotherGlass → Scan Barcode and scan the address code on the Glass tab. Approve the connection here.")
                }
            }

            GlassSection(title: "Connection", detail: "If the hotspot address is missing, enter the gateway address shown by Glass. 172.20.10.1 is common; use the address for your network.") {
                GlassPanel {
                    Toggle("Enter iPhone address manually", isOn: $model.useManualAddress)
                    if model.useManualAddress {
                        TextField("IPv4 address · e.g. 172.20.10.1", text: $model.manualAddress)
                            .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .modifier(GlassFieldModifier())
                        if !model.manualAddress.isEmpty, model.connectionAddress.isEmpty {
                            Text("Enter a valid IPv4 address without a port").font(.footnote).foregroundStyle(GlassStyle.warning)
                        }
                    }
                    Divider().overlay(GlassStyle.line)
                    Toggle("Keep screen awake while hosting", isOn: $model.keepScreenAwake)
                    Divider().overlay(GlassStyle.line)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { SetupLink(title: "App permissions", symbol: "hand.raised") }
                }
            }

            GlassSection(title: "Background location", detail: "Optional. Bluetooth LE works in the background without GPS. Enable this only to share location while iPhone is locked. iOS shows a location indicator and battery use increases. Wi-Fi alone cannot keep the app running indefinitely.") {
                GlassPanel {
                    Toggle("Continue GPS in background", isOn: Binding(get: { location.backgroundEnabled }, set: { location.setBackgroundEnabled($0) }))
                }
            }

            GlassSection(title: "What you can share") {
                GlassPanel {
                    SupportRow(title: "Location & cards", detail: "GPS forwarding, text cards and Glass battery status")
                    Divider().overlay(GlassStyle.line)
                    SupportRow(title: "Apple Music", detail: "Playback controls for the Music app's queue")
                    Divider().overlay(GlassStyle.line)
                    SupportRow(title: "Wi-Fi setup", detail: "Network credentials and connection QR codes")
                    Divider().overlay(GlassStyle.line)
                    SupportRow(title: "Photos & video", detail: "Browse Glass captures and download originals over Wi-Fi")
                    Divider().overlay(GlassStyle.line)
                    SupportRow(title: "Bluetooth LE", detail: "Background cards, battery, Music controls and optional GPS")
                    DisclosureGroup("Platform limits") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("The older Android Bluetooth serial mode is a separate transport. The gallery and original downloads require Wi-Fi.")
                            Text("Automatic iPhone notification mirroring is not included. Apple's EU accessory notification APIs require a separate integration, approved entitlements and security support on Glass.")
                        }
                        .font(.footnote).foregroundStyle(GlassStyle.secondary).padding(.top, 12)
                    }
                    .font(.subheadline)
                }
            }

            GlassSection(title: "Shortcuts", detail: "Use Open URLs in Shortcuts to prepare a card. You always tap Send in the app.") {
                GlassPanel {
                    Text("anotherglass://card?title=Reminder&text=Take%20a%20break")
                        .font(.footnote.monospaced()).foregroundStyle(GlassStyle.secondary).textSelection(.enabled)
                }
            }

            GlassSection(title: "About") {
                GlassPanel {
                    LabeledContent("AnotherGlass for iPhone", value: "0.2.1").font(.subheadline)
                    Text("An independent companion for Google Glass Explorer Edition. Based on Alex Smirnov's AnotherGlass, under the MIT license.")
                        .font(.footnote).foregroundStyle(GlassStyle.secondary)
                    Link(destination: URL(string: "https://github.com/inckie/AnotherGlass")!) {
                        SetupLink(title: "Original project", symbol: "arrow.up.right")
                    }
                    NavigationLink { LicenseView() } label: {
                        SetupLink(title: "Open-source license", symbol: "doc.text")
                    }
                    Text("UI direction informed by Unslop, by Damir Sokolovsky (CC BY 4.0).")
                        .font(.caption).foregroundStyle(GlassStyle.muted)
                    Link("Unslop design guidance", destination: URL(string: "https://github.com/heydamir/unslop")!)
                        .font(.footnote).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.subheadline.monospaced()).foregroundStyle(GlassStyle.muted)
                .frame(width: 20, alignment: .leading).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupLink: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(GlassStyle.muted).accessibilityHidden(true)
            Text(title).foregroundStyle(GlassStyle.ink)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(GlassStyle.muted).accessibilityHidden(true)
        }
        .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct SupportRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(GlassStyle.secondary)
        }
    }
}

struct WiFiSetupView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var server: GlassServer
    @State private var ssid = ""
    @State private var password = ""
    @State private var showCode = false
    @State private var sending = false
    @State private var sent = false

    init(model: CompanionModel) {
        self.model = model
        server = model.server
    }

    private var valid: Bool {
        !ssid.isEmpty && ssid.utf8.count <= 32 && (password.isEmpty || (8...63).contains(password.utf8.count))
    }

    var body: some View {
        GlassPage {
            GlassPageHeading(title: "Glass Wi-Fi", subtitle: "Get your Explorer onto the network")
            GlassSection(title: "Network for Glass", detail: "Use 2.4 GHz Wi-Fi with WPA2 compatibility. WPA3-only networks are unsupported. Leave the password empty for an open network. Credentials stay in memory and are never logged or saved.") {
                GlassPanel {
                    TextField("Network name (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().modifier(GlassFieldModifier())
                    SecureField("WPA / WPA2 password", text: $password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().modifier(GlassFieldModifier())
                    Button { showCode = true } label: {
                        Label("Show Wi-Fi QR code", systemImage: "qrcode")
                    }
                    .buttonStyle(GlassPrimaryButtonStyle()).disabled(!valid)
                    if server.isConnected {
                        Button(sending ? "Sending…" : "Send over current connection") {
                            sending = true
                            model.sendWiFi(ssid: ssid, password: password) { success in
                                sending = false
                                sent = success
                                if success { password = ""; showCode = false }
                            }
                        }
                        .font(.subheadline).frame(minHeight: 44).frame(maxWidth: .infinity)
                        .disabled(!valid || sending)
                    }
                }
            }
            if sent {
                Label("Settings sent. Glass may disconnect while switching networks.", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(GlassStyle.positive)
            }
            if showCode, valid {
                GlassSection(title: "Scan from Glass", detail: "In the bundled Explorer APK, open AnotherGlass → Scan Barcode. After joining Wi-Fi, scan the separate connection code on the Glass tab. Anyone who scans this code can read the Wi-Fi password.") {
                    GlassPanel {
                        QRCodeView(value: wifiCode).frame(maxWidth: 280).frame(maxWidth: .infinity)
                            .accessibilityLabel("Wi-Fi credential QR code for \(ssid)")
                        Button("Hide QR and clear password") { showCode = false; password = "" }
                            .font(.subheadline).frame(minHeight: 44).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onChange(of: ssid) { _, _ in showCode = false; sent = false }
        .onChange(of: password) { _, _ in showCode = false }
        .onDisappear { password = ""; showCode = false }
    }

    private var wifiCode: String {
        func escaped(_ value: String) -> String {
            value.reduce(into: "") { result, character in
                if "\\;,:\"".contains(character) { result.append("\\") }
                result.append(character)
            }
        }
        return "WIFI:T:\(password.isEmpty ? "nopass" : "WPA");S:\(escaped(ssid));P:\(escaped(password));;"
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text("""
            MIT License

            Copyright (c) 2020 Alex Smirnov

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """)
            .font(.footnote).foregroundStyle(GlassStyle.secondary).textSelection(.enabled).padding(24)
        }
        .background(GlassStyle.background)
        .navigationTitle("MIT License")
    }
}
