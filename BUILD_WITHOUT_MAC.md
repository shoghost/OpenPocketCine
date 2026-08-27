# Build OpenPocketCine iOS without a local Mac

This phase leaves the OpenPocketCine UI and Nano protocol unchanged. Codemagic supplies the macOS and
Xcode host; Windows is used for GitHub, triggering the build, downloading the artifact, and AltStore.

## Audited iOS project

| Item                   | Value                                                                     |
| ---------------------- | ------------------------------------------------------------------------- |
| Project source         | `ios/project.yml` (XcodeGen)                                              |
| Generated project      | `ios/OpenPocketCine.xcodeproj`                                            |
| Workspace              | None                                                                      |
| App target             | `OpenPocketCine`                                                          |
| Test target            | `OpenPocketCineTests`                                                     |
| Shared scheme          | `OpenPocketCine`                                                          |
| Bundle identifier      | `com.opencapture.openpocketcine`                                          |
| Test bundle identifier | `com.opencapture.openpocketcine.tests`                                    |
| Deployment target      | iOS 17.0                                                                  |
| Device families        | iPhone and iPad (`1,2`)                                                   |
| Swift mode             | iOS shell Swift 5; portable core Swift tools 6.0                          |
| Package dependencies   | Local `OpenPocketViewCore` package only; no remote Swift packages         |
| Info.plist             | `ios/OpenPocketCine/Info-Frameio.plist` plus generated build-setting keys |
| Entitlements           | `ios/OpenPocketCine/OpenPocketCine.entitlements`                          |

The repository does not commit an Xcode project. Codemagic installs XcodeGen and generates it before
testing or building.

## What the workflow proves

The root `codemagic.yaml` workflow `ios-unsigned` performs these gates on a Codemagic Apple Silicon
macOS machine:

1. validates the Info.plist and entitlements plist;
2. generates `ios/OpenPocketCine.xcodeproj`;
3. compiles and tests the portable Swift package with `swift test`;
4. boots an available iPhone Simulator and runs the `OpenPocketCineTests` scheme;
5. builds Release for `generic/platform=iOS` with all code signing disabled;
6. copies `OpenPocketCine.app` into `Payload/OpenPocketCine.app` and zips an unsigned IPA;
7. publishes the IPA, raw app bundle, XCTest result bundle, and Xcode logs as downloadable artifacts.

The resulting IPA is not installable as-is. An IPA is only a ZIP container; the executable remains
unsigned. AltStore/AltServer must apply a development signature and provisioning profile before iOS will
launch it.

## GitHub and Codemagic setup from Windows

1. Fork or create a GitHub repository for your OpenPocketCine branch.
2. Commit and push `codemagic.yaml` and this guide. Do not commit Apple IDs, passwords, certificates,
   provisioning profiles, camera credentials, or Frame.io secrets.
3. Create a Codemagic account and add the GitHub repository.
4. Select this branch, then choose **Check for configuration file**. Codemagic requires
   `codemagic.yaml` at the repository root.
5. Start **OpenPocketCine iOS unsigned IPA** manually.
6. No environment-variable group, Apple ID, App Store Connect key, certificate, or provisioning profile
   is required for this workflow.
7. All five build scripts must pass. In particular, do not treat the IPA packaging step alone as a
   successful compile.
8. Open the completed build's **Artifacts** section and download:

   ```text
   build/OpenPocketCine-unsigned.ipa
   ```

Codemagic documents root-level YAML workflows and exposes matching artifact paths on the build page.
The workflow uses `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, an empty signing identity, and
an empty development team only for the generic-device build. Simulator tests are unsigned independently.

## App permissions and capabilities

The concise entitlement inventory is also available in `IOS_ENTITLEMENTS.md`.

Runtime privacy keys are not signing entitlements:

| Requirement           | Configuration                                    | Needed for                           |
| --------------------- | ------------------------------------------------ | ------------------------------------ |
| Bluetooth privacy     | `NSBluetoothAlwaysUsageDescription`              | Nano discovery, pairing, credentials |
| Local-network privacy | `NSLocalNetworkUsageDescription`                 | UDP/TCP to `192.168.2.1`             |
| Local networking ATS  | `NSAppTransportSecurity/NSAllowsLocalNetworking` | local HTTP/network access            |
| Add to Photos privacy | `NSPhotoLibraryAddUsageDescription`              | optional media export                |

The repository declares one code-signing entitlement:

```text
com.apple.developer.networking.HotspotConfiguration = true
```

Apple defines this entitlement as permission to call `NEHotspotConfigurationManager` to configure a
Wi-Fi network. It is separate from Bluetooth and local unicast UDP/TCP. No Network Extension, VPN,
multicast, Access Wi-Fi Information, camera, or microphone entitlement is declared by this target.

### Free Apple ID / AltStore risk

Hotspot Configuration is the only material compatibility risk. Capability availability is determined by
the provisioning profile and Apple membership. A free Personal Team/AltStore profile may not authorize
`com.apple.developer.networking.HotspotConfiguration`; depending on the signer, signing can fail, the
entitlement can be omitted, or `NEHotspotConfigurationManager.apply` can fail at runtime. The unsigned
Codemagic build cannot prove this because it deliberately creates no provisioning profile.

Do not add a paid-team certificate or secret merely to make this phase green. First try AltStore signing
and inspect the signed app/profile. If Hotspot Configuration is absent, use the manual-Wi-Fi fallback in
a later phase.

## Manual Wi-Fi fallback assessment

The protocol path can work without Hotspot Configuration:

```text
OpenPocketCine BLE pairing
  -> read Nano SSID and password
  -> user opens iOS Settings and joins that SSID manually
  -> return to OpenPocketCine
  -> detect local 192.168.2.x
  -> open UDP/9004 and LiveView
```

Bluetooth and direct local-network sockets do not themselves need the Hotspot Configuration entitlement.
However, the current `CameraSession` always calls `WiFiJoiner.joinCameraAP(...)` after reading credentials,
even if the user has manually associated. Therefore the fallback is architecturally valid but is not yet
a complete no-code workaround: a later, small implementation phase must skip the
`NEHotspotConfigurationManager.apply` call when `WiFiJoiner.isCameraPathReady()` already proves a
`192.168.2.x` address. That later change can preserve all Nano protocol and UI behavior; it is intentionally
not included now.

## AltStore / AltServer next step

After Codemagic succeeds:

1. Install current AltServer on Windows and current AltStore on the iPhone using the
   [official Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).
2. Keep the iPhone connected by USB for the first installation and trust the computer if prompted.
3. Download `OpenPocketCine-unsigned.ipa` from the Codemagic artifact page to Windows.
4. In AltStore on the iPhone, open **My Apps**, choose **+**, and select the downloaded IPA (move it through
   Files/iCloud Drive if needed). AltStore asks for the Apple account used for free development signing.
   Alternatively, hold **Shift** while clicking the Windows AltServer tray icon and use **Sideload .ipa…**.
5. If signing reports an unsupported entitlement, do not paste credentials into Codemagic. Record the
   exact error and use a later fallback build that omits only Hotspot Configuration and supports manual
   Wi-Fi association.
6. AltStore Classic currently documents a seven-day expiry and a three-active-app limit for free
   accounts, so keep AltServer available for refresh. Treat AltStore's current documentation as
   authoritative because these limits can change.

The next phase begins only after the Codemagic log shows successful core tests, iOS tests, generic-device
build, and artifact packaging, and after the artifact is visible for download. No App Store or TestFlight
upload is configured.

## Expected artifact paths

```text
build/OpenPocketCine-unsigned.ipa
build/ios-device/Build/Products/Release-iphoneos/OpenPocketCine.app
build/OpenPocketCineTests.xcresult
```

If the workflow fails, download `/tmp/xcodebuild_logs/*.log` and the Codemagic script log. The most useful
first distinction is generation failure, Swift compile/test failure, generic-device build failure, or IPA
packaging failure.
