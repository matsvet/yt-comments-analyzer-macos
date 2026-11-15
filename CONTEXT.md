# CONTEXT.md

Internal context and glossary for YT Comments Analyzer (for AI agents, developers). Next to CLAUDE.md.

This supplements CLAUDE.md with domain terms and architectural decisions (previously implicit). Created as part of architecture improvements (see review report).

## Domain Glossary
Terms discovered/extracted from code (Models/, State/, Services/, Views/, tests), CLAUDE.md, README.md, and the architecture review. Use these exact terms.

- **Video** (videoId as ключ, optional title?, fetchedAt, [StoredComment]): the unit persisted per video as cache file.
- **StoredComment** (flat representation): "a thread root has `isTopLevel == true` and `threadId == id`; replies point to the root via `threadId`. There is no nested tree." (exact from CLAUDE.md). Low-level data type.
- **Thread** (root + replies, navigation unit): explicit concept for "a root comment and its replies". Used for selection/highlight/scroll in detail view.
- **Library** (cached videos по mtime): list of LibraryEntry from CommentStore.listLibrary(), newest first in sidebar. Graceful fallback title to videoId for old entries.
- **Offline Search** (matcher с matchCase/wholeWord/searchAuthors): fully offline because of upfront full fetch (roots + all replies). Results can include replies when query non-empty.
- **Thread navigation** (selectedThreadId + root/replies): mechanism: results list shows roots (or matches), tap sets selectedThreadId + optional highlightedCommentId, detail renders via root/replies. Also used in export and LLM prompt sampling.
- **OnDemandSummary** (LLM session-only): generated only on explicit user action (sparkles button in ResultsListView), stored in private in-memory summaryCache (per videoId, lifetime of current load), never written to persistent .json caches. Uses LLMClient.
- **Cache per videoId** (CommentStore): one JSON per videoId in ~/Library/Application Support/YTCommentsAnalyzer/<videoId>.json . VideoComments wraps title + fetchedAt + comments list.
- **Data Compatibility** (MANDATORY RULE): "All changes, new features, UI improvements, and modifications requested by the user **must apply only to newly created/saved data**. Do not add any logic that "backfills", "upgrades", "repairs", or "migrates" old cached data... Use graceful fallbacks for missing fields (e.g. show videoId if title is absent) - but **never** trigger network calls, saves, or refreshes to populate missing data from old entries. Old data remains as-is." (from CLAUDE.md). Applies to all adapters/fakes too.
- **Graceful fallback**: e.g. `title ?? videoId`, `current.title ?? current.videoId` in UI, exports, prompts. For old caches without new fields.
- **flat comments list always (no nested tree)**: core invariant of StoredComment + VideoComments.comments. API fetches to this flat form upfront for offline search.
- Other: SortOrder (likes/newest/oldest), YouTubeError, LLMError, full upfront fetch for offline search.

## Implemented Improvements (2026-11-15): analysis v2

- OnDemandSummary now processes every unique loaded StoredComment using CommentCorpus batches; short snapshots use a direct summary request. CommentAnalysis owns retrieval, query planning, full extraction, reduction, grounded final answers, verification, count routing, and bounded RAM caches.
- CommentCorpus supplies stable numeric source IDs, native word normalization/BM25, diverse Thread retrieval, complete text partitioning, and exact-quote validation.
- CommentChatState keeps per-Video conversations and cancellation. AppState orchestrates on-demand runs and UI progress. SummaryView exposes coverage, sources, cancellation and a forced full-scan toggle.
- Full summary and query notes are RAM-only; no old JSON is migrated, enriched or rewritten. Content changes, configuration and account changes isolate cached analysis.
- ChatGPT subscription transport, OAuth/Keychain and explicit reasoning effort are supported alongside API/Ollama; no automatic billing fallback.
- See [analysis-v2.md](docs/analysis-v2.md) for current flow, budgets, evidence checks and limitations. Older architecture descriptions below remain historical context.

## Current Architectural Decisions
- **Single source of truth**: @Observable @MainActor final class AppState. All state (current VideoComments?, library, searchText + 3 bool flags, sortOrder, selectedThreadId/highlightedCommentId, showSummary, LLM config+status, summary/session cache, etc.). Passed to SwiftUI via .environment(state) in YTCommentsApp + read via @Environment(AppState.self) in all Views. No other singletons.
- **UI layout**: NavigationSplitView in ContentView (3 columns: sidebar / ResultsListView / detail). detail conditionally shows SummaryView (if showSummary) or ThreadDetailView. Custom overlays for settings (to preserve Cmd+Q etc).
- **Data flow (no auto refresh)**: paste URL -> AppState.fetch() -> api.fetchAll (progress) + fetchVideoTitle -> VideoComments -> store.save -> current= -> views. openVideo uses store.load only (skips net). New saves get full data; old untouched.
- **Search and nav are fully offline**: YouTubeAPI fetches *all* top-level + *all* replies upfront (paginated + fallback to comments list). Then searchResults / thread assembly on the flat list.
- **Summary is on-demand only**: never auto, never persisted to caches (only RAM summaryCache + current summary var). Reset on new current.
- **Persistence**: CommentStore (JSON per videoId, atomic write, list by mtime + embedded title metadata). UserDefaults for apiKey + typeSize + llm* keys. No schema version/migrations (per Data Compatibility).
- **Seams and testability (post-improvements)**: AppState takes injected any VideoCache + any CommentFetcher (defaults to real). LLMClient still internal. No seams were present originally for data.
- **Modules structure**: Models/ for Codable value types (StoredComment, VideoComments, now also Thread/SearchConfig). Services/ for pure (YouTubeAPI, CommentStore, etc). State/ for AppState (orchestrator). Views/ thin (read state, minimal logic).
- **Conventions**: Russian for user strings/comments. @MainActor hops for async updates. No 3rd party. After *any* edit: mandatory Post-Change Deployment (./build_app.sh + install to /Applications + cleanup).
- **Deletion test consideration**: design so removing core logic from one place (e.g. AppState) does not force duplication elsewhere.

## Implemented Improvements (2026-06-18)
These directly address the friction points, candidates, and top recommendation from the architecture review (before/after mass/bouncing diagrams, using glossary).

**1. Introduced seam for Store + YouTubeAPI (top recommendation from review)**

Previously: hard-coded `private let store = CommentStore(); private let api = YouTubeAPI()` inside AppState (god object). No seam. Deletion test failed (removing AppState orchestration logic would scatter FS/net calls everywhere; tests like SearchTests forced to construct real AppState and mutate .current because no fakes). Low locality (orchestration + impl mixed), low leverage (impossible to isolate fetch/open/delete/save/list without real disk + network + quota), poor AI-navigability and testability.

Changes (surgical, followed patterns):
- Added small interfaces: `protocol VideoCache` (in CommentStore.swift) and `protocol CommentFetcher` (in YouTubeAPI.swift).
- Updated AppState: changed to `private let store: any VideoCache; private let api: any CommentFetcher`; init now accepts them with defaults `= CommentStore()`, `= YouTubeAPI()`. Existing `AppState()` and `AppState()` in app entry continue to work (real adapters).
- Real + test: at least 2 adapters possible. Added InMemoryVideoCache (class for mutability under let) and InMemoryCommentFetcher (struct) in SearchTests.swift. Updated sampleState() and font test to inject them (exercises the seam).
- Call sites inside AppState (fetch, openVideo, delete, refreshLibrary) unchanged in body (now go through seam property).
- Respects Data Compatibility strictly (in-mem adapter does simple dict, no backfills/repairs; old JSON untouched).

Wins (per glossary):
- Now a *real* seam (2 adapters).
- locality: orchestration logic stays concentrated in AppState; impl details behind interface.
- leverage: tests can now substitute fakes for fetch/save without side effects (future tests for delete/fetch can use InMemory* and assert calls or state).
- deletion test improved: AppState no longer "leaks" concrete stores; can remove AppState and still have testable data ports via protocols.
- AI-navigability: when reading, see the seam immediately in init and privates.

**2. Deepened the Thread navigation module**

Previously (see review diagram): concept of Thread scattered. StoredComment.swift had only flat invariant docs; AppState had root(for:)/replies(for:)/selectThread + selected*/highlighted ids; ResultsListView had onTap + isActive + replyContext using isTopLevel/threadId; ThreadDetailView had if selected + root/replies + scroll; CommentRow had isTopLevel checks. 5 modules/files to understand one domain idea. Shallow (interface size ≈ impl size, duplicated knowledge). Bouncing between files. Deletion test bad: delete root/replies from AppState and the logic "leaks" into all Views + tests.

Changes (smallest effective, edited only needed, no new source files):
- Added deep value type to logical existing file: `struct Thread { let root: StoredComment; let replies: [StoredComment] }` + `extension Thread { static func from(comments: [StoredComment], threadId: String) -> Thread? }` (with exact invariant comments) in Models/StoredComment.swift.
- In AppState: added `func thread(for:)` (the deeper small interface), made `root(for:)` and `replies(for:)` thin delegates to `Thread.from(...)`. selectThread kept (it manages the id-based selection state, tied to UI).
- Updated callers that assemble full thread: ThreadDetailView now does `if let th = state.thread(for: threadId)` then uses th.root / th.replies (instead of separate calls). ResultsListView.replyContext uses `state.thread(for:)` for root author.
- Other call sites (AppState commentsAsTxt/buildSummary, tests using root/replies, isActive in list) continue via the delegating methods (minimal breakage).
- Kept isTopLevel usage in StoredComment consumers where inherent to single comment display (e.g. "ответ" badge, totalReplyCount) - would require larger unrelated changes.

Wins (per glossary + review):
- Deep module: small interface (Thread + one factory), large implementation (invariant enforcement, assembly, sort).
- locality: the entire "what is a Thread and how to get its parts from flat list" is now in *one* module.
- leverage: Views and future code get `Thread` without knowing flat details or duplicating filters; tests can construct/use `Thread.from(list, id)` directly.
- deletion test: now passes better - the thread concept is concentrated; removing the from() would break in one place (not scatter).
- Before/after matches review: bouncing diagram eliminated for the core assembly.

**3. Deepened the Offline Search module**

Previously (review mass diagram): searchResults (computed) + makeMatcher (with regex/wholeWord/case) + private fields + the 3 flags buried inside large AppState. Interface bloated (searchText, matchCase, wholeWord, searchAuthors, isSearching, searchResults, sortedTopLevels + sort). Shallow (impl visible/equal to surface). SearchTests had to construct full AppState() then mutate flags + .current to test. Low locality for search bugs. No seam for matcher.

Changes:
- Added to Models/StoredComment.swift (alongside data it operates on): `struct SearchConfig { matchCase, wholeWord, searchAuthors }` + pure `func search(comments: [StoredComment], config: SearchConfig, query: String) -> [StoredComment]` (implements exact old matcher logic + fields helper + empty->tops) + `func topLevelComments(in:)`.
- In AppState (surgical remove/replace): deleted makeMatcher + old fields entirely. Updated `searchResults` to `let config = SearchConfig(...); let base = search(comments:..., config: config, query: ...); return sorted(base)`. Updated `sortedTopLevels` to delegate `topLevelComments(in: ...)` then sorted. (The 3 bools + searchText + sortOrder + isSearching stay in AppState because they are directly @Bindable from ResultsListView toggles/picker and isSearching used for labels/counts. This was the minimal change that still shrinks the *implementation* and exposes pure module.)
- No sort inside search (per review's suggested signature; sort stays with SortOrder in AppState).

Wins:
- Deep: tiny public interface for search (config + one func), rich pure impl inside (regex, case, wholeWord, fields, empty handling).
- locality: all offline search matching logic in one place (easy to find/fix/enhance).
- leverage: one interface used by searchResults + (via empty) sortedTops; direct calls possible e.g. `search(flatList, config, "foo")` from tests or future semantic wrapper. Shrinks AppState surface for callers of search.
- test surface: SearchTests now transitively exercise, and can add direct `search(...)` calls without full state (improves over "construct full AppState").
- deletion test: search knowledge no longer distributed in AppState's god methods.
- Prepares future (e.g. semantic search can return same [StoredComment] from other module).
- Matches review exactly.

Other:
- Updated SearchTests to exercise the new seam in sample construction.
- All changes respect Data Compatibility (no old data touched) and other CLAUDE rules.
- No new source files created for the modules (types added to existing Models/StoredComment.swift, protocols to Services/*.swift per "never create files unless absolutely necessary").
- CONTEXT.md created (required explicitly).

These changes make the codebase higher depth, better locality/leverage, real seams, improved deletion tests, and more AI-navigable - directly per the review recommendations and glossary.

## Future Notes / ADRs (minimal)
- If adding semantic search: implement as another pure func returning [StoredComment] compatible with the search interface (leverage from the deepened module).
- When (if ever) supporting legacy data: explicit separate task, not side-effect of other work.
- Prefer deepening before new features that would otherwise bloat AppState further.

## Ongoing: Splitting the AppState monolith (grill session outcome, 2026-06-18+)
**Context (from user + architecture review):** Главная боль — всё сконцентрировано в одном @Observable AppState (god-object). UI flags, domain, orchestration, LLM, nav, search — один интерфейс, все Views на @Environment(AppState.self). Даже после extraction Thread/Search и data seams (2026-06-18) концентрация состояния не уменьшилась. "Всё сконцентрировано в веб-стейте. И у нас ничего не поменялось."

**Решение (grill + план, surgical):** Продолжаем углубление. Вводим child @Observable modules (в State/) — AppState становится тонким оркестратором (let children, delegation, coordination). Сохраняем @Environment совместимость через forwarding properties + @Bindable на children где бинды.

Реализованные в этой итерации (пример подхода, можно grill'ить дальше):
- **FontScale** (State/FontScale.swift): полный вынос (typeSize, методы, scale, font(for:), persist, Key). Низкий риск, изолирован. AppState делегирует. Нет изменений во Views.
- **SearchState** (State/SearchState.swift): флаги search + isSearching + config. Reuse SearchConfig/search. Forwarding в AppState + @Bindable child в ResultsListView (минимально). searchResults использует child.config.
- **SheetState** (State/SheetState.swift): showSettings/showSummary (UI routing). Forwarding.

AppState теперь имеет:
let font = FontScale()
let search = SearchState()
let sheets = SheetState()
... + forwarding для совместимости + children в init (для тестов можно инжектить).

**Wins (глоссарий):** 
- depth: дети имеют маленькие интерфейсы (FontScale — только шрифт; SearchState — только поиск).
- locality: font/search/sheets логика в своих модулях.
- leverage: легче тестировать/заменять (InMemory для children).
- deletion test: удалить font logic — только в FontScale.
- seam: дети можно заменять.

**Дальше (из grill/плана):** VideoSession (current + nav + loading + summary + export), LibraryState, LLMState. Полная оркестрация в AppState. Обновить больше Views на children. После всех — deploy.

**Constraints:** Data Compatibility (никаких backfill в новых children), Post-Change Deployment (выполнено в конце), surgical (только must, reuse Thread/SearchConfig/seams, не трогать CLAUDE.md), @MainActor, 25 тестов.

(Grill продолжится: можно выбирать следующий child или альтернативы вроде нескольких @Environment.)

(End of CONTEXT.md. Edit only when architecture changes.)
## Comment-grounded chat (2026-10-22)

- `CommentChatState` is an @Observable @MainActor child of AppState. It owns the draft, turns, cancellation and per-video in-memory sessions. Switching videos cancels pending work; late responses cannot update another conversation. Nothing is written to video JSON caches.
- `CommentChatContext` searches the current video's full local comment pool using question terms, recent questions and source continuity. It builds a bounded excerpt set, including thread context; it is lexical retrieval, not exhaustive or semantic search.
- `LLMClient.Message` supports multi-turn OpenAI-compatible requests. Chat requests use JSON object responses, validate referenced source numbers and return a fixed insufficient-evidence message when sources are absent. The model has no web tools; grounding instructions constrain answers to supplied comments.
- `SummaryView` combines the existing summary with a conversation and fixed composer. Source cards open existing Thread navigation. Summaries remain separate from evidence and never count as a primary source. Video playback/transcripts are not loaded.
