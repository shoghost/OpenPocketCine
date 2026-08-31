# Mimo Clean Phase 3 Clean UI artifact

This directory builds a temporary, unsigned DJI Mimo 2.6.1 Clean UI IPA on Codemagic macOS.
A three-finger single tap toggles the DJI Live View between normal and Clean UI. No Clean button,
status label, control panel, or FLEX Explorer gesture is displayed.

## Boundaries

- The DJI IPA is downloaded at build time from DJI's official OTA service and is never committed.
- The fixed official IPA SHA-256 is verified before extraction or injection.
- FLEX and `insert_dylib` are built from their pinned public source commits.
- The loader uses the observed Live View and preview class names only for runtime hierarchy lookup.
  It contains no hooks, swizzling, networking, video, decoder, renderer, FPS, or PTS changes.
- Clean Mode preserves the `DJIGLImageViewCupertino`/`CAEAGLLayer` preview and its ancestor chain,
  classifies sibling branches as KEEP/HIDE/UNKNOWN, and suppresses only HIDE branches with
  reversible `UIView.hidden` changes.
- The only existing app file modified after Watch removal is the main executable, which receives
  one `LC_LOAD_DYLIB` for `@executable_path/Frameworks/FLEXLoader.dylib`.
- `PlugIns/DJIBackgroundDownloadExtension.appex` is preserved.

Generated IPA, extracted app, cloned sources, build products, signing material, and reports under
the artifact directory are ignored by Git.

## Codemagic

First run **DJI Mimo Clean UI preflight** (`mimo-clean-preflight`). It downloads and
builds only the pinned public FLEX source, then compiles and links the real arm64
iPhoneOS `FLEXLoader.dylib`; it never downloads, extracts, injects, or packages DJI
Mimo. Run the full workflow only after this preflight passes.

Then run the manual workflow named **DJI Mimo 2.6.1 Clean UI IPA** (`mimo-flex-build`). It emits:

- `DJI_Mimo_2.6.1_CleanUI.ipa`
- `DJI_Mimo_2.6.1_CleanUI.sha256.txt`
- `phase3-clean-ui-build-report.txt`

The supplied manifest token may expire. The build first tries the specified manifest URL; when DJI
returns `Invalid plistToken`, it loads the same official DJI OTA iPhone page and extracts its newly
issued `service-adhoc.dji.com/ios/plist/...` URL. The package is accepted only from a `djicdn.com`
host and only when its SHA-256 exactly matches the pinned official IPA.

## Install

The artifact is intentionally unsigned. Re-sign it with the same Sideloadly settings that passed
the no-Watch baseline. Keep `DJIBackgroundDownloadExtension.appex`; let Sideloadly consistently
rewrite nested bundle identifiers and sign the app, extension, every framework, and
`FLEXLoader.dylib`. Do not enable plugin removal for the background extension.

After installation, connect the Nano and open Live View. Three-finger single-tap enables Clean UI;
the next three-finger single-tap restores every hidden DJI view to its original state. FLEX Explorer
activation is disabled. Clean Mode never removes DJI views or changes the preview frame, bounds,
transform, layer, decoder, renderer, or transport.
