# Mimo Clean Phase 2 FLEX artifact

This directory builds a temporary, unsigned DJI Mimo 2.6.1 inspection IPA on Codemagic macOS.
It exists only to open the official FLEX explorer with a three-finger single tap and identify the
real Live View UIKit hierarchy before any clean-UI work begins.

## Boundaries

- The DJI IPA is downloaded at build time from DJI's official OTA service and is never committed.
- The fixed official IPA SHA-256 is verified before extraction or injection.
- FLEX and `insert_dylib` are built from their pinned public source commits.
- The loader contains no DJI private class names, hooks, swizzling, networking, video, decoder,
  renderer, FPS, or PTS code.
- The only existing app file modified after Watch removal is the main executable, which receives
  one `LC_LOAD_DYLIB` for `@executable_path/Frameworks/FLEXLoader.dylib`.
- `PlugIns/DJIBackgroundDownloadExtension.appex` is preserved.

Generated IPA, extracted app, cloned sources, build products, signing material, and reports under
the artifact directory are ignored by Git.

## Codemagic

Run the manual workflow named **DJI Mimo 2.6.1 FLEX inspection IPA** (`mimo-flex-build`). It emits:

- `DJI_Mimo_2.6.1_FLEX.ipa`
- `DJI_Mimo_2.6.1_FLEX.sha256.txt`
- `phase2-build-report.txt`

The supplied manifest token may expire. The build first tries the specified manifest URL; when DJI
returns `Invalid plistToken`, it loads the same official DJI OTA iPhone page and extracts its newly
issued `service-adhoc.dji.com/ios/plist/...` URL. The package is accepted only from a `djicdn.com`
host and only when its SHA-256 exactly matches the pinned official IPA.

## Install

The artifact is intentionally unsigned. Re-sign it with the same Sideloadly settings that passed
the no-Watch baseline. Keep `DJIBackgroundDownloadExtension.appex`; let Sideloadly consistently
rewrite nested bundle identifiers and sign the app, extension, every framework, and
`FLEXLoader.dylib`. Do not enable plugin removal for the background extension.

After installation, connect the Nano, open Live View, and single-tap with three fingers to toggle
FLEX. This build is for hierarchy inspection only; do not use FLEX network debugging.
