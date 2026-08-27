import UserNotifications
import PinchosCore

struct ItemNotification: Equatable, Sendable {
    let event: ItemNotificationEvent
    let itemName: String
    let body: String
}

@MainActor
protocol ItemNotificationSink: AnyObject {
    func send(_ notification: ItemNotification)
}

@MainActor
final class SystemItemNotificationSink: ItemNotificationSink {
    private enum AuthorizationState {
        case unknown
        case granted
        case denied
    }

    private let centerProvider: () -> UNUserNotificationCenter?
    private var center: UNUserNotificationCenter?
    private var authorizationState: AuthorizationState = .unknown

    init(centerProvider: @escaping () -> UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }) {
        self.centerProvider = centerProvider
    }

    func send(_ notification: ItemNotification) {
        switch authorizationState {
        case .granted:
            guard let center = notificationCenter() else { return }
            deliver(notification, using: center)
        case .denied:
            return
        case .unknown:
            guard let center = notificationCenter() else {
                authorizationState = .denied
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.authorizationState = granted ? .granted : .denied
                    guard granted else { return }
                    guard let center = self.notificationCenter() else { return }
                    self.deliver(notification, using: center)
                }
            }
        }
    }

    private func deliver(_ notification: ItemNotification, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Pinchos: \(notification.itemName)"
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "pinchos.\(notification.event.rawValue).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    private func notificationCenter() -> UNUserNotificationCenter? {
        if let center {
            return center
        }
        guard let center = centerProvider() else { return nil }
        self.center = center
        return center
    }
}
