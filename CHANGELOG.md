# Changelog

## 0.4.0

- Liquid Glass (iOS 26 SDK, Xcode 26): glass composer, chips, approval card, sidebar, home cards, terminal bar; material fallback on iOS 17-25.
- Files attach again: system document picker that copies the file in (iCloud included), one sheet router, menus present after they close, reading off the main thread, PDF text, errors shown.
- Chat and Terminal are separate tabs. The terminal runs your own commands over SSH (keeps the folder between commands) or file commands on This iPhone, with a key row; "Ask the agent" sends the last output to the chat.
- Manage connectors: remote MCP servers (Streamable HTTP, bearer token, headers), presets DeepWiki, Context7, GitHub; their tools are offered to the agent, read-only ones run without asking.
- Markdown in answers, home launch cards, Settings is a tab.
- Each CI build has its own build number (the run number) and shows it with the commit at the bottom of the home screen. The release adds a versioned IPA, `build-info.txt` (strings checked in the binary) and a live MCP check against DeepWiki.

## 0.3.0

Desktop-style panels and gateway settings.

- **New layout**: a header with the session title, a sidebar with new session, search, recent sessions and the active gateway, and a home screen with the folder, the environment and the last session.
- **Composer**: a rounded input with a **+** menu (photos, files, folder, slash commands, run a command), the model picker with an **Effort** submenu, a send/stop button, and chips for the environment, the folder, permissions and a context ring.
- **Gateways**: auth scheme (Bearer or `x-api-key`), custom headers, stream idle timeout, model discovery from `/models`, a model list that overrides it, a default effort, and *Always start with the default model*.
- **Effort** (`/effort`): sent as `reasoning_effort`, as OpenRouter's `reasoning` object, or as `output_config.effort` in the Anthropic format; Auto sends nothing.
- **Anthropic format**: a gateway can speak Anthropic's `/messages` instead of `/chat/completions`, with tool use, images, thinking blocks kept through tool calls, `anthropic-version` (overridable by a custom header) and a max output tokens setting. `api.anthropic.com` picks it automatically.
- **Attachments**: photos go to vision models as images, text files are inlined, other files land in `Inbox/`.
- **Desktop Dark** theme, now the default; the terminal themes keep the monospaced CLI look.
- CI regenerates the app icon, publishes each `main` build as the **latest** release, and opens an issue with the errors when a build fails.
- Settings, gateways and sessions from 0.1 and 0.2 load unchanged.

## 0.2.0

Claude Code-style tools.

- **Project folder on the SSH host** (`/cd <path>`, or *Project folder* in the host settings). File tools work there and commands start there. `AGENTS.md` / `CLAUDE.md` from the folder go into the system prompt.
- **`edit_file`**: exact-snippet replacement with a uniqueness check, `replace_all`, and a red/green diff in the transcript and in the approval prompt.
- **`grep`** (regex, glob filter, ignore case) and **`glob`** (`**/*.swift`, `{a,b}`, `[!x]`), locally and on the host (ripgrep when present, `grep -E` otherwise).
- **`read_file` with `offset` / `limit`** returns numbered lines for long files.
- **Context management**: `ctx N%` in the usage line, a per-profile context window, automatic shortening of old tool output, and `/compact` to continue from a summary.
- **Reasoning display**: `reasoning_content` / `reasoning` deltas show as a collapsible `✻ thinking` block.
- **Background grace**: a run keeps going for about 30 seconds after you leave the app.
- Settings and sessions from 0.1 load unchanged.

## 0.1.0

First version: OpenAI-compatible streaming chat, agent loop, SSH commands, on-device workspace files, web fetch, approvals, themes, sessions.
