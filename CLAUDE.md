# CLAUDE.md

Project-specific instructions for all agents (Grok, Claude, Cursor, and others) working in this repository.

This is the **single canonical instruction file**. Claude Code (claude.ai/code) discovers it automatically by convention. Grok and all other agents must also follow the rules in this file. Do not create or maintain parallel AGENTS.md / Claude.md or similar files (to avoid conflicting instructions and double bookkeeping).

## Commands

- `swift run YTComments` – run the app in development (uses SwiftPM, no Xcode needed).
- `swift build -c release` – release build; binary lands in `.build/release/YTComments`.
- `./build_app.sh` – wraps the release binary into `YT Comments Analyzer.app` at the repo root, ad-hoc signed. **After any code changes, you must always run this + install the result to /Applications** (see the "Post-Change Deployment Rule (MANDATORY)" section below).
- `swift test` – run the full test suite.
- `swift test --filter SearchTests` – run a single test file. Use `--filter SearchTests/testName` for one method.

Swift Package: `Package.swift` declares one executable target `YTComments` (`Sources/YTComments`) and one test target `YTCommentsTests` (`Tests/YTCommentsTests`). Tools 6.0, `swiftLanguageModes: [.v5]`, minimum macOS 14.

## Post-Change Deployment Rule (MANDATORY)

**This rule is non-negotiable and applies to every task (bugfix, feature, refactor, UI change, documentation/instruction files update, etc.).**

After making **any** modifications to the code, the agent must **automatically** (without being explicitly asked) do the following as the **very last step**:

1. Rebuild the release macOS application bundle:
   ```bash
   ./build_app.sh
   ```
   (This runs `swift build -c release` and assembles `YT Comments Analyzer.app` in the repo root with ad-hoc signing.)

2. Install the updated app to the user's macOS Applications folder (replacing any previous version):
   ```bash
   rm -rf "/Applications/YT Comments Analyzer.app"
   cp -R "YT Comments Analyzer.app" /Applications/
   ```

3. Remove the local bundle from the project directory to keep the workspace clean:
   ```bash
   rm -rf "YT Comments Analyzer.app"
   ```

### Why this is required
The canonical way to use this app is via the signed `.app` bundle in `/Applications`. The user expects an up-to-date, ready-to-launch version there immediately after requesting any change. Do not leave the task "complete" until the app has been rebuilt and deployed to Applications.

Always prefer `./build_app.sh` over manual `swift build` when preparing a user-facing version.

Optionally also run `swift test` before the build if the changes affect logic, to prevent shipping broken builds.

This rule ensures consistency across all agents and sessions for this specific project. Never skip the rebuild + install + cleanup step.

## Data Compatibility During Development (MANDATORY RULE)

This project is in early development stage. **No migrations, backfills, data upgrades, schema migrations, or automatic fixes for legacy/old data are allowed.**

- All changes, new features, UI improvements, and modifications requested by the user **must apply only to newly created/saved data**.
- Do not add any logic that "backfills", "upgrades", "repairs", or "migrates" old cached data (e.g. videos saved before a certain feature was implemented).
- When displaying or processing data, use graceful fallbacks for missing fields (e.g. show videoId if title is absent) - but **never** trigger network calls, saves, or refreshes to populate missing data from old entries.
- Old data remains as-is. New saves will include the new fields/behavior.
- This keeps the codebase clean and avoids accumulating migration code during active development.
- If the user later decides to support legacy data, it will be an explicit, separate task (not implicit in other changes).

Examples of forbidden patterns during dev:
- On open: "if this old cache lacks title -> fetch and save it"
- Any automatic "repair" or "enrich" of previously saved JSON files.
- Adding conditions like "if old entry misses X, compute X and persist".

This rule takes precedence. When implementing any user request, ensure it does not introduce such migration behavior for old data.

## Architecture

### Analysis v2 (current)

The older summary/LLM descriptions below are historical. Current implementation is
`CommentCorpus` (stable sources, BM25, complete partitions) + `CommentAnalysis`
(actor: planning, full extraction/reduction, quote and semantic verification,
counting, bounded RAM caches). `CommentChatState` manages conversations and
`AppState` manages on-demand summary progress/cancellation. Both use `LLMClient`:
ChatGPT subscription via OAuth/Keychain + Responses API, or API/Ollama. No new
runtime dependencies, no background analysis on opening caches, no JSON migrations.
See `docs/analysis-v2.md` for the current algorithms, limits and Mermaid diagrams.


Native SwiftUI macOS app: fetches YouTube comments via the Data API v3, caches them locally as flat JSON, supports offline search and thread navigation. Supports optional on-demand local (or compatible remote) LLM summarization of the current video's comments.

**Layers (`Sources/YTComments/`):**

- `Models/` - plain `Codable` value types. `StoredComment` is the single flat representation: a thread root has `isTopLevel == true` and `threadId == id`; replies point to the root via `threadId`. There is no nested tree. `VideoComments` wraps the list of comments + optional title + fetchedAt timestamp (the unit persisted per video).
- `Services/` - pure (non-UI) logic:
  - `YouTubeAPI` paginates `commentThreads` and falls back to `comments?parentId=...` when the inline `replies` block is incomplete. All top-level threads and all replies are fetched up front so search is fully offline.
  - `YouTubeDTO` - wire-format decoding only; converted to `StoredComment` via `toStored(...)`.
  - `CommentStore` persists one JSON file per video in `~/Library/Application Support/YTCommentsAnalyzer/<videoId>.json`. Library entries (sidebar) are sorted by file modification time (newest first). When listing, title is read from the cached JSON if present (graceful fallback to videoId for old entries).
  - `VideoIDParser` accepts full URLs or bare IDs.
  - `LLMClient` - thin client for OpenAI-compatible endpoints (`/v1/chat/completions`). Default: local Ollama at http://localhost:11434. Also supports Groq, OpenRouter and similar (user configurable). Used only for the summarization feature; never auto-invoked.
- `State/AppState.swift` - `@Observable @MainActor` single source of truth. Holds current video, library, search/sort flags, font scale controls, full LLM config (llmModel + llmBaseURL + llmAPIKey) + summary/isSummarizing + status fields (llmStatusMessage, isCheckingLLM, availableLLMModels) + private in-memory summaryCache (session-only, per videoId). Orchestrates fetch -> save -> open. Search logic lives here: `searchResults` builds a matcher honoring `matchCase`, `wholeWord`, `searchAuthors`. Persistence keys in UserDefaults:
  - YTCommentsAPIKey
  - YTCommentsTypeSize
  - YTCommentsLLMModel
  - YTCommentsLLMBaseURL
  - YTCommentsLLMAPIKey
  See "Data Compatibility" rule - no auto backfills for old data. Also implements .txt export of the full comment tree for the current video.
- `Views/` - SwiftUI screens hung off `NavigationSplitView` in `ContentView` (sidebar / results list / thread detail). All views read `AppState` via `@Environment(AppState.self)`. SettingsView exposes YouTube API key + complete LLM settings UI (base URL, API key, model, "Check status", "Load models list"). ResultsListView includes the "sparkles" button (in header) that triggers summary generation / shows the summary sheet (on-demand local LLM only).
- `YTCommentsApp.swift` - `@main` entry; `AppDelegate` forces `.regular` activation policy so `swift run` (no bundle) still produces a focused window. Uses custom overlay state (showSettings, showSummary) so global shortcuts like Cmd+Q continue to work.

**Data flow:** user pastes URL/ID -> `AppState.fetch()` -> `YouTubeAPI.fetchAll` (with progress callback) + optional `fetchVideoTitle` -> wrapped in `VideoComments` -> `CommentStore.save` -> assigned to `state.current` -> views re-render (and summary reset from cache if present). Opening a cached video skips the API entirely. No backfilling or migration of data (titles or otherwise) for old caches - see "Data Compatibility During Development" rule. LLM summary (if any) is generated purely on user demand via LLMClient, kept only in RAM (session summaryCache) for the lifetime of the current video load; never persisted into the .json caches.

**Thread navigation:** results list shows roots (or all matches when searching); selecting a row sets `selectedThreadId` + `highlightedCommentId`, and `ThreadDetailView` renders the root plus chronologically sorted replies via `AppState.root(for:)` / `replies(for:)`.

**Quota note (preserved from README):** each API request costs 1 unit; default daily quota is 10000.

## Conventions

- User-facing strings and in-code comments are in Russian - match that style when editing existing files. New code can follow the surrounding file's language.
- Concurrency: `AppState` is `@MainActor`; API/store/LLM calls happen via `async`/`await` with `Task { @MainActor in ... }` hops back for progress updates and state changes. Keep that boundary intact.
- No third-party dependencies; do not add any without a clear reason.
- LLM / summarization feature: processing happens only on explicit user action (e.g. sparkles button). All results (summary) are in-memory / session-scoped only. Never write summaries into the persistent video caches. Default model and endpoint favor fully local Ollama (llama3.1:8b). Respect Data Compatibility at all times.
