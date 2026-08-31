# Mimo Clean streaming HUD artifact

This directory prepares a temporary, unsigned DJI Mimo 2.6.1 streaming-layout IPA on Codemagic
macOS. When the observed Nano Live View appears, Mimo controls are suppressed automatically, the
original preview remains under Mimo's native layout, and a touch-through Kick HUD is shown.
There is no Clean button, three-finger toggle, or FLEX Explorer gesture.

Set the channel once in `MimoKickConfig.m` by replacing `REPLACE_WITH_KICK_CHANNEL` in
`MCKickChannelName`. Until configured, the camera remains operational and the HUD reports
`KICK: SET CHANNEL`.

## Boundaries

- The DJI IPA is downloaded at build time from DJI's official OTA service and is never committed.
- The fixed official IPA SHA-256 is verified before extraction or injection.
- FLEX and `insert_dylib` are built from their pinned public source commits.
- The loader uses the observed Live View and preview class names only for runtime hierarchy lookup.
  It contains no hooks, swizzling, networking, video, decoder, renderer, FPS, or PTS changes.
- Streaming mode preserves the `DJIGLImageViewCupertino`/`CAEAGLLayer` preview and its ancestor
  chain, classifies sibling branches as KEEP/HIDE/UNKNOWN, and suppresses only HIDE branches with
  reversible `UIView.hidden` changes.
- The preview frame and constraints remain under Mimo's control. The tweak does not change its
  bounds, center, transform, layer, aspect ratio, or render path.
- The Kick client mirrors Moblin's current unauthenticated Pusher subscriptions and event set:
  chat/reply, badges, native Kick emotes, subscriptions, gifted subscriptions, rewards, hosts,
  KICKs, message deletion, bans, and viewer status. Kick failures never call DJI code.
- Kick WebSocket reconnects use bounded exponential backoff. Viewer/live status is polled every
  30 seconds, allowing a channel that goes live after app launch to update without restarting Mimo.
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

After installation, connect the Nano and open Live View. The streaming layout is applied
automatically and is restored internally when that Live View controller disappears. FLEX Explorer
activation is disabled. The tweak never removes DJI views or changes the preview bounds, transform,
layer, decoder, renderer, or transport.
