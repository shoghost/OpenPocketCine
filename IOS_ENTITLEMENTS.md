# OpenPocketCine iOS entitlements

## Declared signing entitlement

| Key                                                   | Value  | API                             | Free-signing impact                                                                                                                              |
| ----------------------------------------------------- | ------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `com.apple.developer.networking.HotspotConfiguration` | `true` | `NEHotspotConfigurationManager` | A free provisioning profile may not authorize it; this is the only declared entitlement that can block AltStore signing or automatic Wi-Fi join. |

Source: `ios/OpenPocketCine/OpenPocketCine.entitlements`.

Apple describes Hotspot Configuration as the entitlement that permits an app to configure Wi-Fi
networks through `NEHotspotConfigurationManager` and notes that provisioning-profile capabilities vary
by program membership:

- [Hotspot Configuration entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration)
- [Supported iOS capabilities by membership](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

## Privacy and networking declarations that are not entitlements

- `NSBluetoothAlwaysUsageDescription`: BLE scan, pair, and Nano Wi-Fi credential retrieval.
- `NSLocalNetworkUsageDescription`: direct local traffic to Nano `192.168.2.1`.
- `NSAppTransportSecurity/NSAllowsLocalNetworking`: local-network HTTP/network access.
- `NSPhotoLibraryAddUsageDescription`: user-selected media export.

No Network Extension, Personal VPN, multicast, Access Wi-Fi Information, camera, microphone, push,
background-mode, or app-group entitlement is present in the current target.

## Free-signing fallback boundary

Removing only Hotspot Configuration does not remove BLE or UDP capability. A later fallback build can let
the user join the Nano SSID in iOS Settings and continue after detecting a `192.168.2.x` address. The
current connection code still calls `NEHotspotConfigurationManager.apply`, so that fallback needs a small
explicit bypass before it is usable. It is not part of the unsigned-build phase.
