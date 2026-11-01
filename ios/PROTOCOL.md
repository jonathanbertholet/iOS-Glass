# iPhone ↔ Glass protocol

Based on upstream commit `e8adb488a8cb93a7ef7ed071f4c866ebd7e9feb5`.

The **phone listens**, and Glass connects as a TCP client on port **9090**. No handshake, HTTP, WebSocket, Java object serialization, TLS, or length prefix. Each UTF-8 JSON object ends with a newline. TCP chunk boundaries are not message boundaries. The iPhone reassembles partial lines and handles multiple lines per chunk, with a 256 KiB limit per line and a bounded write backlog.

```json
{"service":"MockGPS","type":"com.damn.anotherglass.shared.gps.Location","payload":{"latitude":50.85,"longitude":4.35,"altitude":30,"speed":0,"bearing":0,"accuracy":5}}
```

| Service | Exact Java payload type | Direction |
| --- | --- | --- |
| `MockGPS` | `com.damn.anotherglass.shared.gps.Location` | iPhone → Glass |
| `Notifications` | `com.damn.anotherglass.shared.notifications.NotificationData` | iPhone → Glass |
| `WiFi` | `com.damn.anotherglass.shared.wifi.WiFiConfiguration` | iPhone → Glass |
| `Media` | `com.damn.anotherglass.shared.media.MediaStateData` | iPhone → Glass |
| `Media` | `com.damn.anotherglass.shared.media.MediaCommandData` | Glass → iPhone |
| `device` | `com.damn.anotherglass.shared.device.BatteryStatusData` | Glass → iPhone |
| `MediaLibrary` | `com.damn.anotherglass.shared.gallery.MediaLibraryRequest` | iPhone → Glass |
| `MediaLibrary` | `com.damn.anotherglass.shared.gallery.MediaLibraryResponse` | Glass → iPhone |

`type` must retain the **Java class name**, even though the sender is Swift: Glass's Gson adapter uses `Class.forName(type)` to decode it. Enum values are case-sensitive strings.

- Location: latitude/longitude in degrees, altitude and accuracy in meters, speed in meters/second, bearing in degrees. Invalid speed/bearing become zero; stale location fixes older than 15 seconds are not forwarded.
- Battery: `level` is 0–100; `isCharging` is Boolean.
- Wi-Fi: `ssid`, `password` strings. Credentials are sent only by explicit UI action.
- Cards: `action` is `Posted` or `Removed`; identify cards by `packageName` plus signed 32-bit `id`. `postedTime` is Unix milliseconds. This port emits non-ongoing text cards with `Silent` delivery mode, without binary attachments. Card removals require the included Explorer stack refresh fix.
- Media: states `None`, `Playing`, `Paused`, `Stopped`, `Buffering`; time fields use milliseconds. `actionsMask` uses Android PlaybackState bits: play 4, pause 2, previous 16, next 32, seek 256, toggle 512. `lastUpdatedMs` is Unix milliseconds.
- Commands: `Play`, `Pause`, `TogglePlayPause`, `Next`, `Previous`, `SeekTo`; the optional `seekToMs` is used only for `SeekTo`. Only commands from an approved connection reach the Music relay.
- JSON byte arrays in upstream use Base64. This initial iPhone implementation does not send artwork, icons, or image cards.

Heartbeat messages have a null type and payload:

```json
{"service":"Ping","type":null,"payload":null}
{"service":"Pong","type":null,"payload":null}
```

Respond to Ping immediately with Pong. The iPhone sends a Ping every 5 seconds and drops a peer after 20 seconds without a decoded message. Glass uses a 15-second socket read timeout. Heartbeats run before local approval so the approval prompt does not cause the Glass timeout. Private payloads and playback commands are gated behind approval. An initial battery update is held until approval. There are no card delivery acknowledgments.

Glass Wi-Fi uses independent blocking reader/writer threads. A bounded 32-message outgoing queue wakes the writer immediately; a five-second idle queue wait emits a heartbeat rather than pacing transfers. Pongs take priority over queued data. JSON text is buffered in 64 KiB character blocks and flushed after each complete line. Socket close wakes blocked I/O on shutdown; queued responses are discarded on reconnect. Both endpoints enable TCP_NODELAY.

A missing/null `service` is a disconnect message. End-of-stream also disconnects. Invalid JSON or an oversized line closes that connection; the host keeps listening.

## Bluetooth LE transport

The new BLE mode uses the same UTF-8 JSON Lines envelopes over a custom GATT service. The iPhone is the peripheral; Glass is the central, using API 18/19 scan and GATT calls. It is separate from the original classic Bluetooth RFCOMM mode.

| GATT attribute | UUID | Direction |
| --- | --- | --- |
| Service | `05f2934c-1e81-4554-bb08-44aa761afbfc` | iPhone advertises |
| RX characteristic | `b4e1cb2c-f87d-49bb-a02a-a5eb6b0af001` | Glass writes to iPhone, with response |
| TX characteristic | `b4e1cb2c-f87d-49bb-a02a-a5eb6b0af002` | iPhone notifies Glass |
| Client configuration descriptor | `00002902-0000-1000-8000-00805f9b34fb` | Glass enables notifications |

Glass writes at most 20 bytes per ATT operation and waits for each write callback. iPhone notification chunks respect `maximumUpdateValueLength`, with `updateValue` backpressure handled through `peripheralManagerIsReady(toUpdateSubscribers:)`. Fragments are reassembled until newline; a GATT packet is not a complete JSON message. The BLE send backlog/frame limit is 64 KiB. One central is selected per host, with manual app approval before private data or Music commands are routed.

Glass initiates Ping while idle at 5-second intervals and accepts traffic as a sign of life, with a 45-second receive timeout. A GATT write wakes the iPhone using `bluetooth-peripheral` background mode, and the app replies to Ping from the event callback. No background Swift timer, location service, audio playback, or network extension is required for that event-driven response. The iPhone's additional heartbeat timer is not relied on to run while suspended. Glass scans/retries with a bounded duty cycle until the user stops its service.

MediaLibrary requests are disabled over BLE so thumbnail/original traffic cannot block control messages. Select Wi-Fi on both sides for gallery browsing and original downloads. Discovery after a broken BLE link may need the iPhone app reopened because of iOS background-advertising restrictions. There is no approved-session restoration across app-process termination in this version.

## Media library extension

This requires the updated Explorer APK. Android supplies read-only access to indexed shared-storage photos and videos through `MediaStore.Files`. Records resolve by numeric media ID, not a caller-provided path. Resolved files must remain under shared external storage after canonicalization and must still be indexed as an image or video. No deletion or arbitrary filesystem listing is implemented.

Requests have a unique `requestId` and one of these case-sensitive `operation` values:

- `List`: optional `beforeId` cursor and `pageSize` (clamped to 1–48). Lists indexed photo/video files by descending Android ID. Replies include `items`, `hasMore`, and optional `nextBeforeId`.
- `Thumbnail`: `mediaId` and `revision`. Replies contain JPEG thumbnail `data` as Base64, up to 160 KiB decoded. The UI handles unavailable thumbnails without blocking original downloads.
- `Read`: `mediaId`, `revision`, `offset`, and `length` (clamped to 1–98,304 bytes). Replies contain Base64 `data`, the exact `offset`, and `totalBytes`. The iPhone pipelines up to four 96 KiB chunks, matches replies by request ID, and writes them in offset order to a temporary file. Publication happens only after all bytes and metadata have been saved.

Each list item contains string `id`, `name`, `kind` (`Photo` or `Video`), `mimeType`, byte `size`, `modifiedTimeMs` (Unix milliseconds), and `revision`. Revision combines file modification time and size; it is checked on each read to reject common mid-transfer changes. This is a consistency check, not a cryptographic digest or authentication mechanism. Original bytes are transferred without transcoding.

Replies echo `requestId`, `operation`, and `mediaId` when applicable. Optional `error` contains a displayable failure message. Default numeric/Boolean response fields are emitted even when not used by that operation. The iPhone matches request IDs, validates offsets/chunk sizes/total length, uses a 25-second timeout for each sent request, and cancels outstanding work on disconnect or download cancellation. The four-chunk window includes completed out-of-order replies, so both in-flight reads and the reorder buffer remain bounded (384 KiB of decoded file data across that window). At most one metadata request shares the connection; unrelated thumbnails wait until the original transfer ends. Requests waiting in the local queue do not start a timeout until sent.

Glass does file and thumbnail work on a bounded single-worker queue so its RPC handler stays responsive. It reuses one resolved original and open file handle across chunks, revalidating size/modification-time revision on every read and resolving the index again after a media-index change. The handle closes on file change/error, connection invalidation, service shutdown, or 30 seconds of inactivity. The iPhone decodes known payloads directly, scans only newly appended bytes for line boundaries, and updates visible download progress at most ten times per second plus completion. These are implementation optimizations; the JSON envelope, Base64 encoding, 96 KiB read limit and 256 KiB line bound are unchanged.

Glass sends an unsolicited response with `requestId: ""` and `operation: "Changed"` when its shared image/video index changes, debounced by 600 ms. The foreground gallery schedules a list refresh when dirty; it does not continuously fetch unchanged pages. Library requests are sent only through the approved companion connection. The inherited Wi-Fi transport is still unencrypted.

## QR payloads

Connection QR: `IPv4` or `IPv4|label`, as expected by Glass's StartActivity. The iPhone emits `IPv4|iPhone`.

Wi-Fi QR: standard ZXing `WIFI:T:WPA;S:SSID;P:password;;`, or `T:nopass` for open networks. Backslash, semicolon, comma, colon, and double quote are escaped with backslash. The bundled Explorer StartActivity recognizes these offline QR codes and opens its existing WiFiActivity; older APKs only accept IP codes. WEP and enterprise EAP QR codes are deliberately rejected by this bootstrap path.
