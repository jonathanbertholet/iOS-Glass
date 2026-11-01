import Combine
import Foundation
import Network
import UIKit

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

struct SentCard: Identifiable {
    let id: Int32
    let title: String
    let text: String
    let date = Date()
}

@MainActor
final class CompanionModel: ObservableObject {
    let server: GlassServer
    let location = LocationRelay()
    let music = MusicRelay()
    let gallery: MediaGallery

    @Published private(set) var addresses: [LocalAddress] = []
    @Published var selectedAddress = ""
    @Published var manualAddress = ""
    @Published var useManualAddress = false
    @Published private(set) var battery: GlassBattery?
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var cards: [SentCard] = []
    @Published var cardTitle = ""
    @Published var cardText = ""
    @Published var selectedTab = 0
    @Published var notice: String?
    @Published var keepScreenAwake = true {
        didSet { updateIdleTimer() }
    }
    private var foreground = true
    private let pathMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var cardID = Int32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(Int32.max)))

    var connectionAddress: String {
        let candidate = useManualAddress ? manualAddress.trimmingCharacters(in: .whitespacesAndNewlines) : selectedAddress
        return LocalAddress.isIPv4(candidate) ? candidate : ""
    }

    init() {
        let server = GlassServer()
        self.server = server
        gallery = MediaGallery(server: server)
        server.onLog = { [weak self] in self?.log($0) }
        server.onMessage = { [weak self] in self?.route($0) }
        server.onConnected = { [weak self] in
            guard let self else { return }
            self.battery = nil
            self.cards.removeAll()
            self.location.setConnected(true)
            self.gallery.setConnected(self.server.mode == .wifi)
            self.music.refresh()
            self.updateIdleTimer()
        }
        server.onDisconnected = { [weak self] in
            self?.battery = nil
            self?.location.setConnected(false)
            self?.gallery.setConnected(false)
            self?.cards.removeAll()
            self?.updateIdleTimer()
        }
        location.onLog = { [weak self] in self?.log($0) }
        location.onLocation = { [weak self] location in
            self?.server.send(service: "MockGPS", type: GlassProtocol.locationType, payload: GlassLocation(location))
        }
        music.onState = { [weak self] state in
            self?.server.send(service: "Media", type: GlassProtocol.mediaStateType, payload: state)
        }
        refreshAddresses()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshAddresses() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.anotherglass.path"))
        server.$state.dropFirst().sink { [weak self] _ in
            // @Published emits before the stored state changes.
            Task { @MainActor in self?.updateIdleTimer() }
        }.store(in: &cancellables)
    }

    func start() {
        refreshAddresses()
        server.start()
        updateIdleTimer()
    }

    func stop() {
        server.stop()
        updateIdleTimer()
    }

    func sceneChanged(isForeground: Bool) {
        foreground = isForeground
        server.setForeground(isForeground)
        location.setForeground(isForeground)
        updateIdleTimer()
        if isForeground {
            refreshAddresses()
            music.refresh()
        }
    }

    func refreshAddresses() {
        addresses = LocalAddress.all()
        if !addresses.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = addresses.first?.address ?? ""
        }
    }

    func sendCard() {
        let title = cardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty else { return }
        guard title.count <= 120, text.count <= 4000 else {
            notice = "Keep the title under 120 characters and the message under 4,000."
            return
        }
        guard server.isConnected else { notice = "Connect Glass before sending a card."; return }
        cardID = cardID == Int32.max ? 1 : cardID + 1
        let card = SentCard(id: cardID, title: title, text: text)
        let notification = GlassNotification(id: card.id, title: title, text: text)
        server.send(service: "Notifications", type: GlassProtocol.notificationType, payload: notification) { [weak self] sent in
            guard let self else { return }
            if sent {
                self.cards.insert(card, at: 0)
                self.cards = Array(self.cards.prefix(50))
                self.log("Card sent to Glass.")
                // Preserve edits made while the send was in progress.
                if self.cardTitle.trimmingCharacters(in: .whitespacesAndNewlines) == title,
                   self.cardText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.cardTitle = ""
                    self.cardText = ""
                }
            } else { self.notice = "The card could not be sent. Reconnect Glass and try again." }
        }
    }

    func removeCard(_ card: SentCard) {
        guard server.isConnected else { return }
        server.send(service: "Notifications", type: GlassProtocol.notificationType,
                    payload: GlassNotification(id: card.id, action: "Removed")) { [weak self] sent in
            if sent { self?.cards.removeAll { $0.id == card.id } }
            else { self?.notice = "The card could not be removed from Glass." }
        }
    }

    func sendWiFi(ssid: String, password: String, completion: @escaping (Bool) -> Void) {
        guard !ssid.isEmpty, ssid.utf8.count <= 32, password.isEmpty || (8...63).contains(password.utf8.count) else {
            notice = "Enter a network name of 1–32 bytes and a WPA password of 8–63 bytes, or leave the password empty for an open network."
            completion(false)
            return
        }
        server.send(service: "WiFi", type: GlassProtocol.wifiType, payload: GlassWiFi(ssid: ssid, password: password)) { [weak self] sent in
            if sent { self?.log("Wi-Fi configuration sent. Glass may disconnect while changing networks.") }
            else { self?.notice = "Connect Glass before sending Wi-Fi settings." }
            completion(sent)
        }
    }

    /// Shortcuts can open a URL to fill the composer. Sending always needs a tap.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "anotherglass", url.host == "card",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        cardTitle = String((items.first { $0.name == "title" }?.value ?? "").prefix(120))
        cardText = String((items.first { $0.name == "text" }?.value ?? "").prefix(4000))
        selectedTab = 1
    }

    private func route(_ message: IncomingMessage) {
        do {
            if message.service == "device", message.type == GlassProtocol.batteryType {
                let value = try message.decodePayload(GlassBattery.self)
                guard (0...100).contains(value.level) else { return }
                battery = value
            } else if message.service == "Media", message.type == GlassProtocol.mediaCommandType {
                music.handle(try message.decodePayload(GlassMediaCommand.self))
            } else if message.service == "MediaLibrary", message.type == GlassProtocol.mediaLibraryResponseType {
                gallery.receive(message)
            }
        } catch { log("Could not read a Glass update: \(error.localizedDescription)") }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = foreground && keepScreenAwake && server.isRunning
    }

    private func log(_ message: String) {
        // No coordinates, card contents, or Wi-Fi credentials in the activity log.
        activity.insert(ActivityEntry(message: message), at: 0)
        activity = Array(activity.prefix(100))
    }
}
