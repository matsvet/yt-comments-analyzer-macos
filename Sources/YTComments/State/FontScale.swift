import SwiftUI
import Observation

// Кастомный ключ окружения для масштаба шрифтов (перенесён из AppState для инкапсуляции).
// На macOS .dynamicTypeSize не влияет на размер текста, используем свой множитель.
struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// Отдельный @Observable модуль для масштаба шрифта (глубокий, изолированный).
/// Раньше всё было внутри монолита AppState. Теперь — маленький interface (typeSize + методы + scale + font(for:)).
/// Улучшает locality и leverage (лёгко инжектить/тестировать независимо).
/// Уважает существующие UserDefaults key и дефолт.
@Observable
@MainActor
final class FontScale {
    private static let typeSizeKey = "YTCommentsTypeSize"
    static let defaultTypeSize: DynamicTypeSize = .xLarge

    var typeSize: DynamicTypeSize

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.typeSizeKey) as? Int,
           DynamicTypeSize.allCases.indices.contains(stored) {
            typeSize = DynamicTypeSize.allCases[stored]
        } else {
            typeSize = Self.defaultTypeSize
        }
    }

    func increase() { step(1) }
    func decrease() { step(-1) }

    func reset() {
        typeSize = Self.defaultTypeSize
        persist()
    }

    private func step(_ delta: Int) {
        let all = DynamicTypeSize.allCases
        guard let idx = all.firstIndex(of: typeSize) else { return }
        let newIdx = min(max(idx + delta, 0), all.count - 1)
        typeSize = all[newIdx]
        persist()
    }

    private func persist() {
        if let idx = DynamicTypeSize.allCases.firstIndex(of: typeSize) {
            UserDefaults.standard.set(idx, forKey: Self.typeSizeKey)
        }
    }

    var scale: CGFloat {
        switch typeSize {
        case .xSmall:       return 0.80
        case .small:        return 0.88
        case .medium:       return 0.95
        case .large:        return 1.00
        case .xLarge:       return 1.12
        case .xxLarge:      return 1.25
        case .xxxLarge:     return 1.40
        case .accessibility1: return 1.60
        case .accessibility2: return 1.80
        case .accessibility3: return 2.00
        case .accessibility4: return 2.30
        case .accessibility5: return 2.60
        @unknown default:   return 1.00
        }
    }

    /// Возвращает системный шрифт с учётом масштаба. Базовые размеры из NSFont.preferredFont.
    func font(for style: Font.TextStyle) -> Font {
        let s = scale
        let base: CGFloat = switch style {
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .subheadline: 11
        case .body: 13
        case .callout: 12
        case .caption: 10
        case .caption2: 10
        default: 13
        }
        let weight: Font.Weight = (style == .headline ? .bold : .regular)
        return .system(size: base * s, weight: weight)
    }
}
