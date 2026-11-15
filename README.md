# TermAI

A coding agent for iPhone, in the spirit of Claude Code. Point it at any gateway that speaks the OpenAI-compatible or the Anthropic Messages API (base URL, API key, model IDs). On your servers it runs commands over SSH and reads, edits and searches the files of a project folder. Without a server it works in an on-device workspace. It can also fetch URLs.

The screen is laid out like the desktop AI apps: a sidebar with your sessions, a composer with a **+** menu and a model picker with reasoning effort, and chips for the environment, the folder, permissions and the context window. The terminal themes keep the classic CLI look.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Download `TermAI-unsigned.ipa` from the [**latest** release](../../releases/tag/latest), which every successful build on `main` replaces. The same IPA is also attached to each **Build** run under *Actions*.
2. Sign and install it with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The release also has simulator screenshots of each theme, the home screen, the sidebar, an approval and the settings. When a build fails, the workflow opens an issue with the compiler errors.

## Use

First launch: tap **Add a gateway** (or the gear in the sidebar) and fill in the base URL and API key. `/setup` does the same step by step in the input line.

### The panels

| Where | What |
| --- | --- |
| ☰ sidebar | new session, search, your recent sessions (long-press to delete), the active gateway, settings |
| home screen | the folder and environment the session will use, and the last session to pick up |
| **+** | add photos or files, open a folder, slash commands, run a command yourself |
| model chip | the models of every gateway, **Effort** (Auto, Low, Medium, High, Extra, Max), refresh the model list |
| environment chip | This iPhone, or one of your SSH environments, or a new one |
| folder chip | recent folders on the SSH environment, open another, close it |
| permissions chip | *Ask before acting* or *Bypass permissions* |
| ring | how full the context window is; tap for the numbers |

Photos go to the model as images (it needs to be a vision model). Text files up to 200 KB are put into the prompt; other files are copied into the workspace's `Inbox/` folder.

### Gateways

Each gateway in Settings has:

- **API format**: *OpenAI-compatible* (`/chat/completions`: OpenAI, OpenRouter, LiteLLM, Ollama, most proxies) or *Anthropic Messages* (`/messages`). `api.anthropic.com` picks Anthropic by itself.
- **Base URL** and **API key**, with the auth scheme: `Authorization: Bearer <key>` or an `x-api-key` header (the Anthropic default).
- **Custom headers** sent with every request (routing, tenant, `HTTP-Referer`, …).
- **Stream idle timeout**: how long to wait for the next bytes of an answer (default 300 s).
- **Model discovery**: fills the model picker from the gateway's `/models` at launch. A model list typed in by hand overrides it; its first entry is the default.
- **Default effort**, the **context window** (e.g. `200k`, `1m`; default 128k) and, for the Anthropic format, **max output tokens** (default 32000).

Effort is sent as `reasoning_effort` (`low`, `medium`, `high`, `xhigh` for Extra, `max`); OpenRouter gets its `reasoning` object instead, and the Anthropic format gets `output_config.effort`. Auto sends nothing, which is the safe choice for models that do not reason. *Always start with the default model* (Settings › Agent) resets model and effort for each new session.

In the Anthropic format the app sends `anthropic-version: 2023-06-01` unless a custom header sets another, converts tool calls, tool results and images to Anthropic blocks, and passes thinking blocks back during a tool-use loop as the API requires.

### Commands

| Input | What it does |
| --- | --- |
| plain text | send a prompt to the agent |
| `!uptime` | run a command on the selected SSH host yourself |
| `/model [id]` | list or switch models |
| `/effort [auto\|low\|medium\|high\|extra\|max]` | reasoning effort |
| `/profile [name]` | list or switch API profiles |
| `/host [name\|off]` | list or switch SSH hosts |
| `/cd [path\|off]` | set the project folder on the SSH host (see below) |
| `/approve [ask\|auto]` | whether tool calls need your OK |
| `/compact` | summarize the session so a long task keeps fitting the model's context |
| `/theme [id]` | `desktop`, `dark`, `crt-green`, `crt-amber`, `light` |
| `/system [text\|reset]` | custom system prompt |
| `/new`, `/sessions [n]`, `/retry` | session control |
| `/copy`, `/export`, `/clear` | copy the last answer, share as Markdown, clear the screen |

While you type, a key row has `esc`, `/`, `!`, history `↑ ↓`, `tab` (complete a command), `^C` (stop the current run) and `paste`.

### Working on a project

Pick the SSH environment in the environment chip (or `/host web1`), then open a folder in the folder chip (or `/cd ~/app`). From then on:

- `read_file`, `write_file`, `edit_file`, `list_files`, `glob` and `grep` act on that folder on the host, and `ssh_exec` commands start there. The folder chip shows its name.
- `edit_file` replaces an exact snippet, like Claude Code's Edit tool. The approval prompt shows the change as a red/green diff before anything is written.
- `grep` uses ripgrep when the host has it and `grep -E` otherwise. Nothing needs to be installed on the server: the tools use `sh`, `base64`, `find` and `grep`.
- An `AGENTS.md` or `CLAUDE.md` in the folder is added to the system prompt.

`/cd off` goes back to the on-device workspace.

### Long sessions

The ring under the input and the usage line under each answer (`ctx N%`) show the share of the model's context window the last request used. Set the window per gateway in Settings. As a run nears the limit, older tool output in the request is shortened automatically. From 85% on, TermAI suggests `/compact`, which asks the model for a handoff summary and continues from it.

Models that stream their reasoning as `reasoning_content` or `reasoning` (DeepSeek and OpenRouter, for example) show it as a dim `✻ thinking` block. Tap it to expand. It is never sent back to the model.

If you switch apps mid-run, iOS gives the run about 30 seconds of background time to finish.

### Endpoints

| Provider | Base URL |
| --- | --- |
| OpenAI | `https://api.openai.com/v1` |
| Anthropic (Anthropic format, chosen automatically) | `https://api.anthropic.com/v1` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| DeepSeek | `https://api.deepseek.com/v1` |
| Mistral | `https://api.mistral.ai/v1` |
| Groq | `https://api.groq.com/openai/v1` |
| xAI | `https://api.x.ai/v1` |
| Ollama / LM Studio on your network | `http://<computer>:11434/v1` / `http://<computer>:1234/v1` |

## Safety model

- **Approval.** In the default `ask` mode every SSH command, file write, edit and web request waits for `y` / `n` / `a` (always, for this session). Edits and new files are shown before you decide. Reading, listing and searching files does not ask.
- **Secrets.** API keys, passwords and private keys are stored in the iOS Keychain (this device only). They are never written to the JSON settings files.
- **Host keys.** The first connection to a host records its key (the fingerprint is printed); later connections are refused if the key changes.
- **Workspace.** Without a project folder, file tools are confined to the app's Documents folder, visible in Files › On My iPhone › TermAI. With a project folder they act on the host with your SSH user's permissions, like any SSH session. Approvals are the guard there.
- **Network.** The app talks only to the endpoints and hosts you configure. Plain-`http` endpoints are allowed for LAN servers such as Ollama; the app warns when an API key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, streaming client, agent loop, tools (no UI, builds on Linux)
    Tools.swift         the tool set the model sees
    TextTools.swift     exact-text edits, line numbering, glob patterns
    RemoteFiles.swift   file tools on an SSH host (POSIX sh scripts)
    Context.swift       context budget and /compact
    Anthropic.swift     the Anthropic Messages format
  Sources/TermSSH   SSH connection on top of Citadel
App/                SwiftUI app
  TerminalView.swift    main screen and transcript
  Panels.swift          header, home screen, sidebar, environment and folder menus
  Composer.swift        input box, + menu, model and effort menu, chips, approvals
  SettingsView.swift    gateways, environments, agent, appearance
  AppModel*.swift       state and actions, split by area
project.yml         XcodeGen project definition
scripts/            app icon, CI failure reports
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

The remote file tools are tested by running their scripts through the local `/bin/sh`, so CI exercises them on both GNU (Linux) and BSD (macOS) tools.

Two tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &
TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```
