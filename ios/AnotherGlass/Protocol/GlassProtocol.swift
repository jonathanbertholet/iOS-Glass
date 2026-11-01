import CoreLocation
import Foundation

/// Java class names and enum spelling are part of AnotherGlass's wire protocol.
enum GlassProtocol {
    static let port: UInt16 = 9090
    static let locationType = "com.damn.anotherglass.shared.gps.Location"
    static let notificationType = "com.damn.anotherglass.shared.notifications.NotificationData"
    static let batteryType = "com.damn.anotherglass.shared.device.BatteryStatusData"
    static let wifiType = "com.damn.anotherglass.shared.wifi.WiFiConfiguration"
    static let mediaStateType = "com.damn.anotherglass.shared.media.MediaStateData"
    static let mediaCommandType = "com.damn.anotherglass.shared.media.MediaCommandData"
    static let mediaLibraryRequestType = "com.damn.anotherglass.shared.gallery.MediaLibraryRequest"
    static let mediaLibraryResponseType = "com.damn.anotherglass.shared.gallery.MediaLibraryResponse"
    static let maximumLineBytes = 256 * 1024

    static func line<Payload: Encodable>(service: String, type: String, payload: Payload) throws -> Data {
        let message = OutgoingMessage(service: service, type: type, payload: payload)
        var bytes = try JSONEncoder().encode(message)
        guard bytes.count <= maximumLineBytes else { throw WireError.messageTooLarge }
        bytes.append(0x0A)
        return bytes
    }

    static func control(_ service: String?) -> Data {
        // Explicit nulls also support old Glass builds that expect all three fields.
        let object: [String: Any] = ["service": service.map { $0 as Any } ?? NSNull(),
                                     "type": NSNull(), "payload": NSNull()]
        var bytes = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        bytes.append(0x0A)
        return bytes
    }

    enum WireError: LocalizedError {
        case messageTooLarge, malformedMessage
        var errorDescription: String? {
            switch self {
            case .messageTooLarge: return "The Glass message exceeded the size limit."
            case .malformedMessage: return "Glass sent an invalid JSON message. Use a current JSON-protocol Glass APK."
            }
        }
    }
}

private struct OutgoingMessage<Payload: Encodable>: Encodable {
    let service: String
    let type: String
    let payload: Payload
}

struct IncomingMessage: Decodable {
    let service: String?
    let type: String?
    private let payload: Payload?

    private enum CodingKeys: String, CodingKey { case service, type, payload }
    private enum Payload {
        case battery(GlassBattery)
        case command(GlassMediaCommand)
        case library(GlassMediaReply)
        case other(JSONValue)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        service = try values.decodeIfPresent(String.self, forKey: .service)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        guard values.contains(.payload), try !values.decodeNil(forKey: .payload) else {
            payload = nil
            return
        }
        // Decode known payloads once. In particular, media bytes must not pass through a
        // generic JSON tree, JSONEncoder and a second JSONDecoder for every file chunk.
        switch type {
        case GlassProtocol.batteryType:
            payload = .battery(try values.decode(GlassBattery.self, forKey: .payload))
        case GlassProtocol.mediaCommandType:
            payload = .command(try values.decode(GlassMediaCommand.self, forKey: .payload))
        case GlassProtocol.mediaLibraryResponseType:
            payload = .library(try values.decode(GlassMediaReply.self, forKey: .payload))
        default:
            payload = .other(try values.decode(JSONValue.self, forKey: .payload))
        }
    }

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        let value: Any
        switch payload {
        case .battery(let battery): value = battery
        case .command(let command): value = command
        case .library(let library): value = library
        case .other(let json): return try JSONDecoder().decode(type, from: JSONEncoder().encode(json))
        case nil: throw GlassProtocol.WireError.malformedMessage
        }
        guard let result = value as? T else { throw GlassProtocol.WireError.malformedMessage }
        return result
    }
}

/// Keeps unrecognized service payloads opaque without coercing strings or numbers.
indirect enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }
}

struct GlassLocation: Encodable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let bearing: Double
    let accuracy: Double

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.verticalAccuracy >= 0 ? location.altitude : 0
        speed = max(0, location.speed)
        bearing = max(0, location.course)
        accuracy = location.horizontalAccuracy
    }
}

struct GlassBattery: Decodable {
    let level: Int
    let isCharging: Bool
}

struct GlassWiFi: Encodable {
    let ssid: String
    let password: String
}

struct GlassNotification: Encodable {
    let action: String
    let id: Int32
    let packageName = "com.anotherglass.companion"
    let appName = "AnotherGlass"
    let postedTime: Int64
    let isOngoing = false
    let title: String
    let text: String
    let deliveryMode: String
    let isGroupConversation = false
    let messages: [String] = []

    init(id: Int32, title: String = "", text: String = "", action: String = "Posted", sound: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.action = action
        postedTime = Int64(Date().timeIntervalSince1970 * 1000)
        deliveryMode = sound ? "Sound" : "Silent"
    }
}

struct GlassMediaState: Encodable {
    var playbackState = "None"
    var title: String?
    var artist: String?
    var album: String?
    let sourceApp = "Music"
    let sourcePackage = "com.apple.Music"
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var actionsMask: Int64 = 0
    var lastUpdatedMs = Int64(Date().timeIntervalSince1970 * 1000)
}

struct GlassMediaCommand: Decodable {
    let command: String
    let seekToMs: Int64?
}
