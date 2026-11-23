import SwiftUI

/// Focused value key tracking whether a text input field currently holds keyboard focus,
/// allowing desktop shortcuts like `Space` (Play/Pause) to stand down during text entry.
public struct TextInputFocusKey: FocusedValueKey {
    public typealias Value = Bool
}

public extension FocusedValues {
    /// Indicates whether a Studio or Library text input currently has keyboard focus.
    var isTextInputFocused: Bool? {
        get { self[TextInputFocusKey.self] }
        set { self[TextInputFocusKey.self] = newValue }
    }
}

public extension View {
    /// Applies inline navigation bar display mode and dark navigation bar color scheme on iOS,
    /// passing through unchanged on macOS.
    func wfInlineNavigationBarDark() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Applies an always-visible navigation bar drawer search bar on iOS and standard toolbar search on macOS.
    func wfSearchable(text: Binding<String>, prompt: Text) -> some View {
        #if os(iOS)
        self.searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
        #else
        self.searchable(
            text: text,
            prompt: prompt
        )
        #endif
    }

    /// Applies an always-visible navigation bar drawer search bar on iOS and standard toolbar search on macOS.
    func wfSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        wfSearchable(text: text, prompt: Text(prompt))
    }
}
