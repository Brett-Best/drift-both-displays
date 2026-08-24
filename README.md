# Drift on Both Displays

A source-only patch for Apple's Drift screen saver on a dual-display Mac where
Drift renders on the built-in display but leaves the external display black.

The repository intentionally contains **no Apple executable or resources**.
At build time it copies the locally installed Drift extension, converts that
private copy into a loadable bundle, and wraps it in a native sandboxed screen
saver extension.

## Actual bug

On the Studio Display host, Apple's `Drift.FlowView.prepareToAnimate` receives a
valid window whose `screen` property is `nil`. Apple's preparation path records
itself as prepared and exits before creating the Metal orchestrator, `MTKView`,
or display link. Its later lifecycle methods do not retry preparation.

The loader fixes that narrow failure by:

1. Deferring preparation until the host window and nonzero view size exist.
2. Matching the view dimensions against the live `NSScreen` list.
3. Temporarily making the real host window report the matched screen and
   backing scale while Apple's original preparation code executes.
4. Restoring the host window's original class immediately afterwards.
5. Retrying preparation from `startAnimation` when no orchestrator exists.

Apple's renderer, shaders, animation code, options controller, and resources
remain unchanged.

## Why this is a native extension

An earlier `.saver` wrapper rendered on both displays but macOS classified it
as a legacy screen saver and removed Apple's Options UI. This version retains:

```text
NSExtensionPointIdentifier = com.apple.screensaver
ScreenSaverConfigurationSheetViewControllerClass = Drift.FlowConfigurationViewController
SSEHasConfigureSheet = true
```

The extension is sandboxed and embedded in a small UI-less container app so
PlugInKit registers it as a native screen saver.

## Tested environment

- macOS 27 beta 6, build `26A5416b`
- Apple M2 Pro
- Built-in Retina Display: 1728 x 1117, CoreGraphics display ID 1
- Studio Display: 2560 x 1440, CoreGraphics display ID 3
- Xcode 27 command-line tools

The Mach-O header converter is intentionally version-sensitive and refuses to
modify a binary whose expected bytes differ.

## Build

```sh
./build.sh
```

The generated archive is written to:

```text
build/Drift Both Displays Dev2.app.zip
```

The build copies Drift from:

```text
/System/Library/ExtensionKit/Extensions/Drift.appex
```

Generated Apple-derived bundles are excluded by `.gitignore`.

## Install and register

```sh
./install.sh
```

The installer refuses to overwrite an existing installation. It validates the
archive, installs the app under `~/Applications`, registers the containing app
with LaunchServices, registers the embedded extension with PlugInKit, and then
prints the registered extension record.

After installation, select **Drift (Both Displays)** in System Settings. The
native Drift options sheet should remain available.

## Advanced selection helper

`scripts/make_selection_plist.py` creates a modified *copy* of a wallpaper
`Index.plist` with a specified screen-saver URL. It never edits the live store
itself.

## Verification

```sh
pluginkit -m -A -D -v \
  -i com.brettbest.ScreenSaver.DriftNativeClone.Dev2.Extension

/usr/bin/log show --last 5m --style compact \
  --predicate 'process == "DriftNativeLauncher" AND eventMessage CONTAINS "DriftDirectClone"'
```

A successful two-display launch includes both:

```text
prepared targetDisplay=1 reportedDisplay=1 ... orchestrator=<non-null>
prepared targetDisplay=3 reportedDisplay=0 ... orchestrator=<non-null>
```

See [docs/technical-notes.md](docs/technical-notes.md) for the lifecycle and
runtime-hook details.
