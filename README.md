# ATAK — Kişisel Asistan

A native macOS personal AI assistant, built **without Xcode** — pure SwiftPM, zero third‑party dependencies.

ATAK is not a chat wrapper. It remembers, plans, and actually *does* things: ask it to "add a gym task for tomorrow at 6pm" and it creates the task, then verifies the write before claiming success.

> Türkçe konuşan bir asistan olarak tasarlandı; arayüz ve sistem promptu Türkçedir.
> Mimari dokümanı: [`docs/MIMARI.md`](docs/MIMARI.md) (Türkçe, 16 bölüm).

---

## Why this is interesting

**It was built on a machine with no Xcode.** Only Command Line Tools. That single constraint shaped the whole architecture, and the constraints were *measured*, not assumed:

| Capability | Available under CLT? | Consequence |
|---|---|---|
| SwiftUI, AppKit | ✅ | UI layer is native |
| `@Observable`, most property wrappers | ✅ | — |
| **`@State`** | ❌ macro plugin missing | All view state lives in ViewModels |
| **SwiftData** | ❌ macro plugin missing | Persistence is system SQLite + FTS5 |
| **XCTest** | ❌ not shipped with CLT | Tests use swift‑testing (wired up manually) |
| `xcodebuild`, `.xcodeproj` | ❌ | `.app` bundle assembled and ad‑hoc signed by `make` |

Those turned out to be reasonable trades: SQLite gives full‑text search over notes and memory, and the ViewModel requirement is the architecture the project wanted anyway.

## Architecture

```
Views + ViewModels          SwiftUI, theme tokens, no colour constants
        │
AgentRuntime                budgeted tool loop, cancellable
        │
Risk / Permissions          risk levels, consent gates
        │
AI providers · Tools · Memory
        │
SQLite (WAL + FTS5) · Keychain · Speech · AVFoundation
```

**Concurrency:** Swift 6 strict mode. The database is an `actor`; rows never escape it as reference types — repositories return `Sendable` structs.

### Not locked to one AI provider

```
GeminiProvider              Google Gemini
OpenAICompatibleProvider    one implementation → Groq, OpenRouter, Ollama (local), Mistral, DeepSeek
AnthropicProvider           Claude
```

Each speaks streaming SSE and tool calling, normalised behind a single `AIProvider` protocol. Switching providers is one click; API keys live **only in the Keychain**, never in the database, a file, or logs.

Model names are discovered live from the provider (`Fetch models`) rather than hardcoded — providers retire model IDs without warning, and a stale constant is a silent outage.

### Agent loop

Budgeted and cancellable (5 iterations, 8 tool calls, 120 s). When the budget is hit, ATAK reports how far it got instead of failing silently. Tools available today:

`create_task` · `list_tasks` · `complete_task` · `create_note` · `search_notes` · `create_project`

Every write is read back before ATAK claims it succeeded.

### Turkish full‑text search

SQLite FTS5's `remove_diacritics` cannot fold Turkish **ı** (it is a distinct letter, not an accented *i*), so "çalışma" indexed as "calısma" and searching "calisma" found nothing. Normalisation happens in Swift (`TurkishText.fold`) and is stored in a dedicated column.

### Voice

Push‑to‑talk (⌘M) via `SFSpeechRecognizer` (on‑device when supported), replies spoken with `AVSpeechSynthesizer`. Continuous listening is off by default — the mic opens only when you start it.

## Build

Requires macOS 14+, Swift 6.0+, Command Line Tools. **No Xcode needed.**

```bash
make run       # build, bundle, ad-hoc sign, launch
make test      # 100 tests
make smoke     # headless start-up + DB + FTS5 round trip
make install   # copy to /Applications
```

Build output goes to `~/Library/Developer/ATAK/`, deliberately outside iCloud‑synced folders — the file provider stamps `com.apple.FinderInfo` on build products and `codesign` rejects them.

Data lives in a single file: `~/Library/Application Support/ATAK/atak.db`.

## Status

**v0.1 — working.** Chat with tool use, tasks, projects, notes with FTS5 search, voice in/out, two themes, multi‑provider AI, Privacy Mode. 100 tests green.

Not yet: calendar (EventKit), documents/PDF, focus timer, long‑term memory UI, automations. See [`docs/MIMARI.md`](docs/MIMARI.md) §15 for the roadmap.

## License

MIT — see [LICENSE](LICENSE).
