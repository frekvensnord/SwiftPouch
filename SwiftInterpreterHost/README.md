# SwiftInterpreterHost

This is the minimal native iOS host for the `SwiftInterpreterCore` package. It
keeps one stable interpreter project ID in `UserDefaults`, stores project
workspaces under the app's Application Support directory, and presents the
host-side file picker, Reload & Run controls, and native SwiftUI renderer.

The build and test workflow is in
`../.github/workflows/interpreter-ios27.yml`. It runs on GitHub's `xcode-27`
macOS runner, checks for Xcode 27, Swift 6.4, and the iOS 27 SDK, resolves the
package graph, runs core tests, and builds this host for the iOS device SDK; a
local Mac is not required. The workflow references the adjacent
`../SwiftInterpreterCore` package as a local Swift package and uploads the
resolved lockfiles and unsigned host app as artifacts. The first run is pending
until the project is available in a connected GitHub repository. The actual
target is an iPhone 13 running
iOS 27; the app's iOS 26 minimum deployment target supports that runtime. Use
the CI-produced build for device testing, with signing or distribution handled
through the CI path. Set the development team and a unique bundle identifier
in the project settings, and provide signing material through protected CI
secrets if device signing is needed. Use
**Swift-Datei öffnen…** once to link a
`.swift` file; subsequent **Reload & Run** presses read that bookmark again.

The host currently renders the portable view subset implemented by
`SwiftInterpreterCore`. SwiftChat's complete `ContentView` still needs the
additional view, model, state, persistence, security, and networking bridges
tracked in `SwiftInterpreterCore/TARGET_COMPATIBILITY.md`.
