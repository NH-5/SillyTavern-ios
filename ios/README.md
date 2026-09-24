# SillyTavern for iPhone and iPad

For physical iPhone installation, follow the [中文安装指南](INSTALL_ON_IPHONE.md).

This iOS app runs the repository's SillyTavern Node.js server **on the device** and opens it in `WKWebView` at `http://127.0.0.1:8000/`. It does not require a computer or a remote SillyTavern server. AI generation still needs a configured provider or an API reachable from the phone.

## Build

Requirements: Xcode with the iOS SDK, an iOS 16 or newer device (or an Apple silicon simulator), Node.js 20 or newer, and npm. The checked-in project is `SillyTavern.xcodeproj`.

From the repository root:

```sh
bash ios/setup-runtime.sh
bash ios/prepare-bundle.sh
open ios/SillyTavern.xcodeproj
```

In Xcode, select the **SillyTavern** target, set your signing team and a unique bundle identifier, select your iPhone, then Run. Re-run `ios/prepare-bundle.sh` after changing server or web files. `ios/setup-runtime.sh` downloads the pinned [NodeMobile 24.21.0-0 release](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.21.0-0) and verifies its SHA-256 digest. The generated `ios/Vendor` and `ios/Bundle` directories are ignored by Git.

The app listens only on `127.0.0.1`. Its config and user data live in `Library/Application Support/SillyTavern` in the app container. The web bundle is prepared at build time so the phone does not have to run Webpack. `prepare-bundle.sh` copies only files tracked by Git, so local chats and secrets under `public/` do not enter the app package.

## Verify the server package on a Mac

```sh
node ios/smoke-test.mjs
```

This starts the packaged server with temporary data, checks the health route, page, JavaScript bundle and settings API, then stops the process. It checks the package and server behavior on macOS; it cannot replace an iOS simulator or device run.

The project has also been built with Xcode 27 for both `iphoneos` and `iphonesimulator` with code signing disabled. On iOS 27 iPhone 17e and iPhone 12 Pro simulators, the app started the local server, created its config and data in Application Support, and displayed the SillyTavern welcome screen. Repeat the run on a physical iPhone before relying on device-specific features.

## Current platform limits

- iOS suspends the app when it leaves the foreground, so the local server is available while the app is active.
- This build uses the full mobile Node runtime. Its iOS WebAssembly implementation is interpreted and lacks SIMD and threads. Features depending on those capabilities, especially on-device transformers and some image codecs, require device testing or separate native implementations.
- Server extensions that invoke a system `git` executable or spawn child processes cannot work unchanged in the iOS sandbox.
- App Store distribution needs a separate review of downloaded extensions and runtime code against Apple's review rules.
