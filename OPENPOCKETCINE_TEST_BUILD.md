# OpenPocketCine Test

`OpenPocketCineTest` is a second iOS application target that shares the production source tree and
the same `OpenPocketViewCore` package. It does not copy or fork the Nano implementation.

| Property | Production | Diagnostics |
| --- | --- | --- |
| Target / scheme | `OpenPocketCine` | `OpenPocketCineTest` |
| Display name | OpenPocketCine | OpenPocketCine Test |
| Bundle identifier | `com.opencapture.openpocketcine` | `com.opencapture.openpocketcine.test` |
| Diagnostic condition | absent | `OPENPOCKETCINE_DIAGNOSTICS` |
| Codemagic workflow | `ios-unsigned` | `ios-test-unsigned` |
| Artifact | `OpenPocketCine-unsigned.ipa` | `OpenPocketCineTest-unsigned.ipa` |

The distinct bundle identifier gives each application its own container, Documents directory, and
standard `UserDefaults`, so Test logs and preferences do not modify the production app. Both targets
use the same Bluetooth, Local Network, Hotspot Configuration entitlement, Manual Wi-Fi fallback,
datalink, decoder, and Streaming Mode sources.

Only the Test target compiles the frame-pacing hooks. Its Documents directory exposes
`control-live.log` and `live-frame-pacing.csv` through Files.app/USB file sharing.

## Codemagic and AltStore

Select **OpenPocketCine Test iOS unsigned IPA** (`ios-test-unsigned`) in Codemagic. Download
`build/OpenPocketCineTest-unsigned.ipa`, then sign/install it with AltStore. Its bundle identifier
does not collide with the production IPA, so both can remain installed. With free signing,
Hotspot Configuration may still be stripped; the existing Manual Wi-Fi fallback is shared unchanged.
