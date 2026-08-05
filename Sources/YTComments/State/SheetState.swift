import Observation

/// Простой child для UI routing (showSettings, showSummary).
/// Выделено из монолита AppState для лучшей locality.
@Observable
@MainActor
final class SheetState {
    var showSettings = false
    var showSummary = false
}
