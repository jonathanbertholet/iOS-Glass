import CoreBluetooth
import Foundation

/// A GATT peripheral receives writes from Glass while iOS is backgrounded.
/// API 19 Glass cannot advertise, so the iPhone must take the peripheral role.
@MainActor
final class BluetoothHost: NSObject, CBPeripheralManagerDelegate {
    private static let serviceID = CBUUID(string: "05f2934c-1e81-4554-bb08-44aa761afbfc")
    private static let receiveID = CBUUID(string: "b4e1cb2c-f87d-49bb-a02a-a5eb6b0af001")
    private static let transmitID = CBUUID(string: "b4e1cb2c-f87d-49bb-a02a-a5eb6b0af002")

    var onListening: (() -> Void)?
    var onPeer: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isRunning = false
    var hasPeer: Bool { central != nil }

    private var manager: CBPeripheralManager?
    private var central: CBCentral?
    private var transmit: CBMutableCharacteristic?
    private var published = false
    private var rejectedCentral: UUID?
    private struct Frame {
        let bytes: Data
        var offset = 0
        let completion: ((Bool) -> Void)?
    }
    private var frames: [Frame] = []
    private var queuedBytes = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rejectedCentral = nil
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        isRunning = false
        central = nil
        failFrames()
        if manager?.state == .poweredOn {
            manager?.stopAdvertising()
            manager?.removeAllServices()
        }
        manager?.delegate = nil
        manager = nil
        transmit = nil
        published = false
    }

    func disconnect() {
        rejectedCentral = central?.identifier
        central = nil
        failFrames()
        // A subsequent GATT write is denied, which tells Glass to close its link.
    }

    func send(_ bytes: Data, completion: ((Bool) -> Void)? = nil) {
        guard isRunning, hasPeer, bytes.count <= 64 * 1024,
              queuedBytes + bytes.count <= 64 * 1024, frames.count < 32 else { completion?(false); return }
        frames.append(Frame(bytes: bytes, completion: completion))
        queuedBytes += bytes.count
        drain()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard isRunning, manager === peripheral else { return }
        switch peripheral.state {
        case .poweredOn: publish(on: peripheral)
        case .poweredOff: onError?("Turn on Bluetooth on this iPhone, then start the companion again.")
        case .unauthorized: onError?("Allow Bluetooth access for AnotherGlass in iPhone Settings.")
        case .unsupported: onError?("Bluetooth LE peripheral mode is unavailable on this device.")
        case .resetting, .unknown: break
        @unknown default: break
        }
    }

    private func publish(on manager: CBPeripheralManager) {
        guard !published else { return }
        published = true
        let receive = CBMutableCharacteristic(type: Self.receiveID, properties: [.write], value: nil, permissions: [.writeable])
        let transmit = CBMutableCharacteristic(type: Self.transmitID, properties: [.notify], value: nil, permissions: [])
        self.transmit = transmit
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [receive, transmit]
        manager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard isRunning, manager === peripheral else { return }
        if let error { onError?(error.localizedDescription); return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
            CBAdvertisementDataLocalNameKey: "AnotherGlass iPhone"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard isRunning, manager === peripheral else { return }
        if let error { onError?(error.localizedDescription) }
        else { onListening?() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central incoming: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard isRunning, manager === peripheral, characteristic.uuid == Self.transmitID,
              incoming.identifier != rejectedCentral else { return }
        guard central == nil else { return } // One Glass connection, approved in the app.
        central = incoming
        onPeer?("Google Glass")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central incoming: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard manager === peripheral, central?.identifier == incoming.identifier,
              characteristic.uuid == Self.transmitID else { return }
        central = nil
        failFrames()
        onDisconnect?()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard isRunning, manager === peripheral else { peripheral.respond(to: first, withResult: .unlikelyError); return }
        // Validate the entire ATT transaction before delivering any bytes.
        for request in requests {
            guard request.central.identifier == central?.identifier else {
                peripheral.respond(to: first, withResult: .insufficientAuthorization); return
            }
            guard request.characteristic.uuid == Self.receiveID, request.offset == 0,
                  request.value != nil else {
                peripheral.respond(to: first, withResult: .requestNotSupported); return
            }
        }
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            if let bytes = request.value { onData?(bytes) }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if manager === peripheral { drain() }
    }

    private func drain() {
        guard let manager, let central, let transmit, isRunning, manager.state == .poweredOn else { return }
        while !frames.isEmpty {
            let index = frames[0].offset
            let length = min(central.maximumUpdateValueLength, frames[0].bytes.count - index)
            guard length > 0 else { return }
            let packet = frames[0].bytes.subdata(in: index..<(index + length))
            // false is flow control: wait for peripheralManagerIsReady, never drop a fragment.
            guard manager.updateValue(packet, for: transmit, onSubscribedCentrals: [central]) else { return }
            frames[0].offset += length
            if frames[0].offset == frames[0].bytes.count {
                let frame = frames.removeFirst()
                queuedBytes -= frame.bytes.count
                frame.completion?(true)
            }
        }
    }

    private func failFrames() {
        let previous = frames
        frames.removeAll()
        queuedBytes = 0
        previous.forEach { $0.completion?(false) }
    }
}
