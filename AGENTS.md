# Notes for coding agents

TermAI is an iOS SwiftUI app (iOS 17, Swift 5 language mode) with its logic in the `TermKit` Swift package.

- `TermKit/Sources/TermCore` has no UI and must keep building on Linux: Foundation only, no UIKit or SwiftUI, no `Process`.
- `TermKit/Sources/TermSSH` wraps Citadel 0.11.1 (pinned on purpose).
- `App/` is the SwiftUI app; `project.yml` generates the Xcode project with XcodeGen. The app icon is drawn by `scripts/make_icon.py` in CI.
- Views used from another file must not have `private` stored properties, so their memberwise initializers stay internal.
- `AppModel` is split by area: `AppModel.swift` (state, input), `+Run` (agent runs, approval, SSH), `+Commands` (slash commands, setup), `+Panels` (settings, chats, attachments, demo), `+Terminal` (the Terminal tab), `+Connectors` (MCP connectors). Its members stay internal, not `private`, so every extension can reach them.
- Run `swift test --package-path TermKit` after changing TermCore. CI runs it on Linux and macOS, then builds the IPA. A failed build opens an issue titled `CI: … failed on <sha>` with the errors; successful `main` builds replace the `latest` release.
- CI stamps `CFBundleVersion` with the run number and `TermAICommit` with the commit; Settings shows the version and build, and the first-run screen shows `AppInfo.version` with the commit. Each `main` release has `build-info.txt` (version, SDK, strings found in the app binary) and `mcp-live.txt` (DeepWiki through `MCPClient`): read them through the GitHub API to check a build without a device.
- CI steps live in `scripts/ci.sh`; `.github/workflows/build.yml` only calls it. Change the script, not the workflow: the GitHub connection that pushes here cannot write workflow files.
- The chat folds each prompt's work into one group (`TranscriptLayout` in ChatView.swift). Plan updates are tool items titled `update_plan` whose text is `Plan.render`; keep other tool titles meaningful, they are the progress line.
- Saved JSON (profiles, hosts, settings, sessions) must keep loading: add new fields as optionals with defaults.
- Remote file scripts in `RemoteFiles.swift` must stay POSIX sh and work with GNU, BSD and BusyBox tools.
