import Observation
import SwiftUI

/// Отдельный @Observable для поисковых флагов и состояния (углубление Offline Search module).
/// Раньше флаги + логика были в монолите AppState (bloated interface).
/// Теперь маленький interface: флаги + config для pure search.
/// ResultsListView будет биндиться к этому child (минимальное изменение).
/// Reuse pure SearchConfig + search() из Models.
@Observable
@MainActor
final class SearchState {
    var searchText: String = ""
    var matchCase: Bool = false
    var wholeWord: Bool = false
    var searchAuthors: Bool = false

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Для передачи в pure search func (Models/StoredComment.swift).
    var config: SearchConfig {
        SearchConfig(matchCase: matchCase, wholeWord: wholeWord, searchAuthors: searchAuthors)
    }
}
