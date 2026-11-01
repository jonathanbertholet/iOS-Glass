import Combine
import Foundation
import Network

/// One serial executor owns the listener, framing buffer, and connection lifetime.
@MainActor
final class GlassServer: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case bluetooth, wifi
        var id: String { rawValue }
        var title: String { self == .bluetooth ? "Bluetooth LE" : "Wi-Fi" }
    }
    enum State: Equatable {
        case stopped, starting, listening, awaitingApproval, connected, failed(String)

        var title: String {
            switch self {
            case .stopped: return "Ready when you are"
            case .starting: return "Starting companion"
            case .listening: return "Waiting for Glass"
            case .awaitingApproval: return "Approve your Glass"
            case .connected: return "Glass connected"
            case .failed: return "Connection needs attention"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var mode: Mode = .wifi
    @Published private(set) var peer: String?
    @Published private(set) var pendingPeer: String?
    @Published private(set) var sentCount = 0
    @Published private(set) var receivedCount = 0

    var onMessage: ((IncomingMessage) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onLog: ((String) -> Void)?
    var isRunning: Bool { listener != nil || bluetooth?.isRunning == true }
    var isConnected: Bool { state == .connected }

    private var listener: NWListener?
    private var bluetooth: BluetoothHost?
    private var foreground = true
    private var connection: NWConnection?
    private var buffer = Data()
    private var lineScanOffset = 0
    private let decoder = JSONDecoder()
    private var heartbeat: Task<Void, Never>?
    private var lastReceived = Date()
    private var approvalDeadline = Date()
    private var pendingWrites = 0
    private var initialBattery: IncomingMessage?

    func selectMode(_ mode: Mode) {
        guard !isRunning else { return }
        self.mode = mode
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value { lastReceived = Date() }
    }

    func start() {
        guard !isRunning else { return }
        if mode == .bluetooth { startBluetooth(); return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            // Cellular is never a route for this local, legacy protocol.
            parameters.prohibitedInterfaceTypes = [.cellular]
            let host = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: GlassProtocol.port)!)
            listener = host
            state = .starting
            host.service = NWListener.Service(name: "AnotherGlass", type: "_anotherglass._tcp")
            host.stateUpdateHandler = { [weak self, weak host] state in
                Task { @MainActor in
                    guard let self, let host, self.listener === host else { return }
                    switch state {
                    case .ready:
                        if self.connection == nil { self.state = .listening }
                        self.onLog?("Listening on TCP 9090.")
                    case .failed(let error):
                        self.stop()
                        self.state = .failed(error.localizedDescription)
                        self.onLog?("Listener failed: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            host.newConnectionHandler = { [weak self, weak host] incoming in
                Task { @MainActor in
                    guard let self, let host, self.listener === host else { incoming.cancel(); return }
                    self.accept(incoming)
                }
            }
            host.start(queue: .main)
        } catch {
            state = .failed(error.localizedDescription)
            onLog?("Could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
        disconnect()
        bluetooth?.stop()
        bluetooth = nil
        state = .stopped
    }

    func approve() {
        guard connection != nil || bluetooth?.hasPeer == true, pendingPeer != nil else { return }
        pendingPeer = nil
        state = .connected
        onLog?("Glass connection approved.")
        onConnected?()
        if let initialBattery { onMessage?(initialBattery) }
        initialBattery = nil
    }

    func disconnect(reason: String? = nil) {
        let oldConnection = connection
        let hadBluetooth = mode == .bluetooth && (bluetooth?.hasPeer == true || peer != nil)
        connection = nil
        heartbeat?.cancel()
        heartbeat = nil
        buffer.removeAll(keepingCapacity: false)
        lineScanOffset = 0
        peer = nil
        pendingPeer = nil
        pendingWrites = 0
        initialBattery = nil
        bluetooth?.disconnect()
        state = isRunning ? .listening : .stopped
        oldConnection?.cancel()
        if oldConnection != nil || hadBluetooth {
            onLog?(reason ?? "Glass disconnected.")
            onDisconnected?()
        }
    }

    /// Completion means the TCP stack accepted the bytes; Glass has no delivery ACK.
    func send<Payload: Encodable>(service: String, type: String, payload: Payload,
                                  completion: ((Bool) -> Void)? = nil) {
        guard isConnected else { completion?(false); return }
        do {
            let bytes = try GlassProtocol.line(service: service, type: type, payload: payload)
            if mode == .bluetooth, let bluetooth {
                // Keep the low-bandwidth control link responsive. Bulk media stays on Wi-Fi.
                guard service != "MediaLibrary" else { completion?(false); return }
                bluetooth.send(bytes) { [weak self] sent in
                    if sent { self?.sentCount += 1 }
                    completion?(sent)
                }
            } else if let connection {
                write(bytes, to: connection, completion: completion)
            } else { completion?(false) }
        } catch {
            onLog?(error.localizedDescription)
            completion?(false)
        }
    }

    private func accept(_ incoming: NWConnection) {
        guard connection == nil else { incoming.cancel(); return }
        connection = incoming
        buffer.removeAll(keepingCapacity: true)
        lineScanOffset = 0
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            Task { @MainActor in
                guard let self, let incoming, self.connection === incoming else { return }
                switch state {
                case .ready:
                    let endpoint = String(describing: incoming.endpoint)
                    self.peer = endpoint
                    self.pendingPeer = endpoint
                    self.state = .awaitingApproval
                    self.lastReceived = Date()
                    self.approvalDeadline = Date().addingTimeInterval(60)
                    self.onLog?("Incoming Glass connection; awaiting approval.")
                    self.receive(from: incoming)
                    self.startHeartbeat(for: incoming)
                case .failed(let error): self.disconnect(reason: error.localizedDescription)
                case .cancelled: self.disconnect()
                default: break
                }
            }
        }
        incoming.start(queue: .main)
    }

    private func receive(from client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, ended, error in
            Task { @MainActor in
                guard let self, let client, self.connection === client else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    do { try self.drainLines { self.write($0, to: client) } }
                    catch { self.disconnect(reason: error.localizedDescription); return }
                }
                guard self.connection === client else { return }
                if let error { self.disconnect(reason: error.localizedDescription) }
                else if ended { self.disconnect() }
                else { self.receive(from: client) }
            }
        }
    }

    private func drainLines(reply: (Data) -> Void) throws {
        // A partial line has already been scanned. Continue at the newly appended bytes
        // instead of rescanning a growing Base64 payload on every network callback.
        while let newline = buffer[buffer.index(buffer.startIndex, offsetBy: lineScanOffset)...].firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            lineScanOffset = 0
            guard line.count <= GlassProtocol.maximumLineBytes else { throw GlassProtocol.WireError.messageTooLarge }
            if line.isEmpty { continue }
            let message: IncomingMessage
            do { message = try decoder.decode(IncomingMessage.self, from: line) }
            catch { throw GlassProtocol.WireError.malformedMessage }
            lastReceived = Date()
            receivedCount += 1
            guard let service = message.service else { disconnect(); return }
            switch service {
            case "Ping": reply(GlassProtocol.control("Pong"))
            case "Pong": break
            default:
                // Unapproved clients cannot control playback or receive private data.
                if isConnected { onMessage?(message) }
                else if service == "device", message.type == GlassProtocol.batteryType {
                    initialBattery = message
                }
            }
            if peer == nil { return }
        }
        guard buffer.count <= GlassProtocol.maximumLineBytes else { throw GlassProtocol.WireError.messageTooLarge }
        lineScanOffset = buffer.count
    }

    private func write(_ bytes: Data, to client: NWConnection, completion: ((Bool) -> Void)? = nil) {
        guard connection === client, pendingWrites < 32 else { completion?(false); return }
        pendingWrites += 1
        client.send(content: bytes, completion: .contentProcessed { [weak self, weak client] error in
            Task { @MainActor in
                guard let self, let client, self.connection === client else { completion?(false); return }
                self.pendingWrites -= 1
                if let error {
                    completion?(false)
                    self.disconnect(reason: error.localizedDescription)
                } else {
                    self.sentCount += 1
                    completion?(true)
                }
            }
        })
    }

    private func startHeartbeat(for client: NWConnection) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self, weak client] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let client, self.connection === client else { return }
                if self.pendingPeer != nil && Date() > self.approvalDeadline {
                    self.disconnect(reason: "Connection approval timed out.")
                    return
                }
                if Date().timeIntervalSince(self.lastReceived) > 20 {
                    self.disconnect(reason: "Glass stopped responding. Reconnect from Glass.")
                    return
                }
                self.write(GlassProtocol.control("Ping"), to: client)
            }
        }
    }

    private func startBluetooth() {
        let host = BluetoothHost()
        bluetooth = host
        state = .starting
        host.onListening = { [weak self, weak host] in
            guard let self, let host, self.bluetooth === host else { return }
            if !host.hasPeer { self.state = .listening }
            self.onLog?("Bluetooth LE companion is available. GPS is not required.")
        }
        host.onPeer = { [weak self, weak host] name in
            guard let self, let host, self.bluetooth === host else { return }
            self.buffer.removeAll(keepingCapacity: true)
            self.peer = name
            self.pendingPeer = name
            self.state = .awaitingApproval
            self.lastReceived = Date()
            self.approvalDeadline = Date().addingTimeInterval(60)
            self.startBluetoothHeartbeat(host)
        }
        host.onData = { [weak self, weak host] bytes in
            guard let self, let host, self.bluetooth === host, host.hasPeer else { return }
            self.lastReceived = Date() // Even a fragmented message proves the BLE peer is alive.
            self.buffer.append(bytes)
            do {
                try self.drainLines { data in
                    host.send(data) { [weak self] sent in if sent { self?.sentCount += 1 } }
                }
            } catch { self.disconnect(reason: error.localizedDescription) }
        }
        host.onDisconnect = { [weak self, weak host] in
            guard let self, let host, self.bluetooth === host else { return }
            self.disconnect(reason: "Bluetooth LE connection lost.")
        }
        host.onError = { [weak self, weak host] error in
            guard let self, let host, self.bluetooth === host else { return }
            self.stop()
            self.state = .failed(error)
            self.onLog?(error)
        }
        host.start()
    }

    private func startBluetoothHeartbeat(_ host: BluetoothHost) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self, weak host] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let host, self.bluetooth === host, host.hasPeer else { return }
                if self.pendingPeer != nil && Date() > self.approvalDeadline {
                    self.disconnect(reason: "Connection approval timed out."); return
                }
                // Background execution is event-driven. Glass writes Ping and Core Bluetooth
                // wakes the app to send Pong; no background Swift timer is required to run.
                if self.foreground && Date().timeIntervalSince(self.lastReceived) > 45 {
                    self.disconnect(reason: "Glass stopped responding over Bluetooth."); return
                }
                host.send(GlassProtocol.control("Ping"))
            }
        }
    }
}
