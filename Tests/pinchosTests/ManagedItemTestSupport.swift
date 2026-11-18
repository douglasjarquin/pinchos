@testable import pinchos

extension ManagedItem {
    /// Refresh Now as a freshly opened menu would request it. Retired or
    /// transitioning items offer no token, so this is a no-op for them, as
    /// the menu would show no Refresh Now.
    @MainActor
    func refreshNow() {
        guard let token = refreshNowToken else { return }
        refreshNow(expecting: token)
    }
}
