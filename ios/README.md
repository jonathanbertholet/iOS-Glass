# AnotherGlass for iPhone

Native SwiftUI companion for Google Glass Explorer Edition, including the late-2013 revision. This replaces AnotherGlass's Android **phone** application. Glass still runs the Explorer Android APK from `glass-xe`.

The source targets iOS 17 and later. Use an Xcode version that supports your phone's installed OS. No third-party iOS packages, cloud account, private APIs, or jailbreak are required for the implemented features.

The Explorer APK was previously compiled and installed on an Explorer running Android 4.4.4 (API 19, build XRH35). The refreshed iPhone UI is compiled as an unsigned device app; installation requires your own signing team. No functional tests have been run; testing is left to the owner. End-to-end transport and phone behavior remain unconfirmed. See the [developer README](../README.md) for build commands, architecture, and development guidance.

## Features and limits

| Android feature | iPhone port |
| --- | --- |
| Wi-Fi host | Implemented with Network.framework, TCP 9090, existing JSON Lines protocol |
| Bluetooth LE companion | Implemented as an iPhone GATT peripheral and Explorer GATT central; uses iOS Bluetooth peripheral background mode without GPS |
| Explorer connection QR | Implemented; emits `IPv4|iPhone`, understood by the existing Glass scanner |
| Phone GPS → Glass | Implemented with Core Location, explicitly enabled and approved per connection |
| Background GPS | Opt-in Core Location background activity session; subject to iOS lifecycle and permission rules |
| Glass battery | Implemented; the bundled Glass changes resend the initial battery state |
| Notification cards | Compose and send text cards, then remove them from the current session |
| Music controls | Implemented for Apple's Music app using its system player; does not control arbitrary third-party players |
| Wi-Fi credentials | Send on an existing connection, or use the new offline Wi-Fi QR support in the bundled Explorer APK |
| Glass media library | Live paginated photo/video gallery from Glass's local media index, with thumbnails and change notifications |
| Media downloads | Original file downloads, offline gallery, local video playback, Save to Photos, and Share / Save to Files |
| Android Bluetooth RFCOMM | Not ported; this serial transport cannot be replaced directly with Core Bluetooth or an unregistered External Accessory session |
| All-app notification forwarding | Not implemented; requires a separate accessory integration described below |
| Automatic relaunch / endless background server | Not provided by iOS; start the companion while the app is open |

## Install on iPhone

1. Open [AnotherGlass.xcodeproj](AnotherGlass.xcodeproj) in Xcode.
2. Select the **AnotherGlass** app target → **Signing & Capabilities**, choose your own team, and change the bundle identifier if Xcode requires it. No development team or signing identity is committed to this repository.
3. Connect your iPhone, select it as the destination, and enable Developer Mode if iOS requests it.
4. Build and install from Xcode when you are ready. Accept **Local Network** access in the app. Location and Media & Apple Music are requested only when you enable their sharing switches.

The Xcode project is included. Its source specification is `project.yml`; if you change the specification, regenerate it with `xcodegen generate` from this folder. Project generation does not build or run the app.

## Install the Explorer Glass app

Keep the Glass on its existing firmware for this port. Firmware flashing and factory reset are not part of installation. If the Glass is still at initial setup or on a pre-KitKat release, its firmware/setup state must be resolved before installing this APK; the project's Explorer minimum API is 19. Record its current firmware before making firmware decisions.

The Glass build uses the upstream Gradle setup, JDK 17, the repository's declared Android SDK, and the included `glass-xe/libs/gdk.jar`. Initialize the upstream submodule if needed because Gradle configures its Enterprise module too:

```sh
git submodule update --init --recursive
./gradlew :glass-xe:assembleDebug
```

With USB debugging enabled on Glass, install the resulting APK from your Mac:

```sh
adb install -r glass-xe/build/outputs/apk/debug/glass-xe-debug.apk
```

The application ID is `com.damn.anotherglass.host`; it differs from the Java package of its activities. If updating an APK signed by someone else gives a signature mismatch, sign this build with that key or decide whether to remove the old app first. Removing it clears that app's data; the installer above does not uninstall anything.

The shared JSON module uses Gson 2.10.1 for API 19 compatibility; newer Gson versions require newer Android. The serializer retains the same lenient JSON Lines format. To open the connection chooser directly over USB, use:

```sh
adb shell am start -n com.damn.anotherglass.host/com.damn.anotherglass.glass.host.StartActivity
```

The APK must be built from this checkout to get the media library/gallery, offline Wi-Fi setup, initial battery reporting, Wi-Fi reconnect handling, and card removal. It now declares read-only shared-storage access for gallery browsing. A recent upstream JSON-protocol APK can support the core connection/GPS/cards/Music messages, but the gallery service and those fixes are local to this port. Old Java ObjectStream APKs are incompatible.

## Background companion without GPS

The iPhone's **Glass** tab now offers **Bluetooth LE** and **Wi-Fi** connection modes. Stop the companion before changing modes. Bluetooth LE uses a new GATT transport; the old **Bluetooth** entry on Glass remains Android's classic serial transport and is not the iPhone mode.

1. Install the updated Explorer APK from this checkout and the updated iPhone app (0.2.0 or later).
2. On iPhone, stop the companion if it is running, select **Bluetooth LE**, and tap **Start companion**. Allow Bluetooth access. Leave **Share GPS** off if you do not want location forwarding.
3. On Glass, open AnotherGlass and choose **iPhone Bluetooth LE**. The updated chooser replaces any previously running connection when you select a new mode.
4. Keep the iPhone app open until the connection appears, then tap **Allow Glass**.
5. You can now switch to other iPhone apps. Core Bluetooth receives Glass's writes in the background and lets the companion respond. Location permission and background GPS are not required for this transport.

This implementation carries cards, Glass battery status, Music controls, Wi-Fi setup messages, and optional GPS over Bluetooth LE. **The gallery and original file transfers remain on Wi-Fi** so that large images cannot block the low-bandwidth companion channel. To use them, stop the iPhone companion, select Wi-Fi, start it, and scan its connection QR from Glass. Downloaded media remains available offline in either mode.

Initial discovery and approval need the iPhone app in the foreground. iOS changes peripheral advertising in the background; an Android central may not rediscover the service there. If the BLE link breaks or you move out of range, reopen the iPhone app for discovery and approve the new connection. Force-quitting the app ends the session. This version does not restore an approved BLE session after iOS terminates the app process. The firmware advertises BLE support, but the new BLE connection/background behavior has not been functionally tested.

See [Apple's Core Bluetooth background processing guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

## Connect over Wi-Fi

1. Put iPhone and Glass on the same **2.4 GHz WPA2-compatible Wi-Fi**. Avoid guest networks that isolate clients. For iPhone Personal Hotspot, turn on **Maximize Compatibility** and use a compatible password. Hotspot interoperability with the physical Glass is not established.
2. If Glass needs Wi-Fi credentials, open **Setup → Wi-Fi setup QR code** on iPhone. Enter the SSID and password. On Glass, open **AnotherGlass → Scan Barcode** and scan that Wi-Fi code. This works without an existing phone connection, using the patched Explorer APK.
3. Open the **Glass** tab on iPhone and tap **Start companion**.
4. On Glass, open **AnotherGlass → Scan Barcode** again and scan the **connection** code shown on the Glass tab. This code contains the iPhone address, not the Wi-Fi password.
5. Tap **Allow Glass** on iPhone for the connection you just initiated.
6. Enable **Share GPS** or **Share Music playback** as desired. Create text cards in the **Cards** tab.

Use the explicit connection QR on shared Wi-Fi. Glass's old `Wi-Fi` option tries the network gateway, which is normally the router rather than the iPhone. If iOS does not enumerate the hotspot interface, enable the manual address option in Setup and enter the iPhone's actual hotspot gateway address. `172.20.10.1` is common; use the address for your network rather than assuming it is fixed.

If the connection drops, reopen the iPhone app. The bundled Glass Wi-Fi client has a bounded retry window; reopen AnotherGlass on Glass if it has stopped. The iPhone asks for approval on each new TCP connection. No device identity or cryptographic pairing is implied by an IP address.

## Wi-Fi background behavior

By default, hosting keeps the screen awake while the app is foregrounded. You can disable that in Setup. An open TCP listener by itself does not grant iOS background execution. Use Bluetooth LE for a background companion without GPS; the following option is for people who actually want location forwarding over Wi-Fi.

For GPS use with the phone locked, enable **Setup → Continue GPS in background**, then enable GPS sharing and approve a connection while the app is open. The app holds `CLBackgroundActivitySession` only for this active location feature. It stops location updates on disconnect or when GPS is disabled. It does not request Always location access or run fake audio to keep a socket alive.

iOS can still interrupt the session, and force-quitting the app ends it. Music and cards do not independently keep the app alive. Music app playback may continue separately even when this companion is suspended. See [Apple's background location documentation](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background).

## Browse Glass photos and videos

Install the updated Explorer APK and iPhone app from this checkout. Select **Wi-Fi**, connect and approve Glass, then open the iPhone's **Gallery** tab. **On Glass** reads the photos and videos indexed in Glass's shared media library, including camera captures. It fetches metadata and small thumbnails without first importing originals. The list refreshes on opening, with pull-to-refresh and further pages available. While the gallery is open, Glass media-index change notifications also trigger a refresh.

Tap an item to see its preview, filename, date, and original size. Tap **Download original** to copy its exact file bytes to iPhone. For videos, download first to play the local original. There is a progress indicator and cancellation, with one original transfer at a time. Keep the app open during transfers; these are local RPC downloads, not iOS background URLSession downloads. The current per-file limit is 2 GB. An interrupted transfer does not appear as a completed download, and this version restarts downloads rather than resuming them.

The **Downloaded** segment remains available with Glass disconnected and after restarting the app. Select a downloaded item to **Save to Photos** or **Share / Save to Files**. Saving asks only for add-only access to the iPhone Photos library; browsing Glass does not request access to your existing iPhone photos. Original embedded metadata is retained. Repeated downloads/saves can create additional copies; there is no global deduplication or automatic Photos import. Video playback/import depends on iOS support for the original codec.

Originals are stored in the app's Documents/Glass Media folder, also available under **On My iPhone → AnotherGlass** in Files. Thumbnail/record sidecars are kept separately in Application Support. Downloading, sharing, and saving do **not** delete anything on Glass. The gallery has no remote-delete operation. Private app directories and files absent from Android's shared photo/video index are not exposed.

The linked [glasskit/MyGlass-Companion-iOS repository](https://github.com/glasskit/MyGlass-Companion-iOS) contains an extracted app bundle (compiled `MyGlass` executable and resources), rather than an editable Objective-C/Swift project. It was inspected as a reference; its executable and assets are not included in this port. The new gallery uses this project's Glass-side media service, not the original app's service or credentials.

## Notification forwarding and Bluetooth

The Android phone app relies on notification listener and global media-session APIs. Ordinary iPhone apps do not provide a direct equivalent for this legacy Wi-Fi client.

Apple now documents **Accessory Notifications**, with customer availability restricted to qualifying EU iPhones/accounts. That route requires an AccessorySetupKit accessory reference, data-provider and transport/security extensions, the relevant entitlements, key exchange, and accessory-side HPKE decryption. The existing Explorer client implements none of that. This checkout does not claim automatic notification mirroring or include placeholder extensions that pretend to work. See [Accessory Notifications](https://developer.apple.com/documentation/accessorynotifications) and [Receiving iOS notifications on an accessory](https://developer.apple.com/documentation/AccessoryTransportExtension/receiving-ios-notifications-on-an-accessory).

Android's classic Bluetooth SPP/RFCOMM socket is not a BLE GATT service. The new iPhone **Bluetooth LE** mode implements a separate GATT transport on both devices rather than trying to open that serial socket. Apple's [Bluetooth](https://developer.apple.com/bluetooth/) and [accessory framework guidance](https://developer.apple.com/accessories/) describe the available routes. Calls/audio via system Bluetooth profiles are independent of this app's data transport.

Music uses [`MPMusicPlayerController.systemMusicPlayer`](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/systemmusicplayer), which controls Apple's Music app. Spotify or other players require separate authorized integrations; they are not silently treated as Music.

## Shortcuts and links

Use Shortcuts' **Open URLs** action with an encoded URL such as:

```text
anotherglass://card?title=Reminder&text=Take%20a%20break
```

The app fills the card composer. Tap **Send to Glass** to send it. External links never send a card automatically. There is no Share extension or system notification listener in this version.

## Privacy and protocol

This port is local-only. It has no analytics or backend and does not save card history, locations, or Wi-Fi passwords. Explicit media downloads and their gallery metadata persist on iPhone; thumbnail browsing uses a bounded in-memory cache. The activity log is in memory and omits message contents and credentials. Glass itself saves networks it joins. Saving an original to Photos can also make it eligible for your own iCloud Photos settings.

The inherited protocol is **unencrypted, unauthenticated TCP**. Use a trusted private LAN or personal hotspot. Approval prevents automatic sharing with a random incoming connection, but it does not authenticate hardware or prevent interception by a party able to observe the network. Wi-Fi QR codes contain the password; the UI hides and clears it when leaving the screen. No TLS or pairing claim is made.

BLE also asks for approval before forwarding private payloads or accepting playback commands. It does not add application-level encryption or request encrypted GATT permissions, so do not treat this as cryptographic device pairing. Reconnection requires new approval. Each Bluetooth frame is bounded and fragmented using ATT flow control; GPS is never automatically enabled for background operation.

See [PROTOCOL.md](PROTOCOL.md) for the implemented wire format and [the root MIT license](../LICENSE) for upstream attribution. The same license text is available inside the app.
