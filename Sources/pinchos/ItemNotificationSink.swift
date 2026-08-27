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

    private let centerProvider: () -> UNUserNotificationCenter
    private var center: UNUserNotificationCenter?
    private var authorizationState: AuthorizationState = .unknown

    init(center: @autoclosure @escaping () -> UNUserNotificationCenter = .current()) {
        self.centerProvider = center
    }

    func send(_ notification: ItemNotification) {
        let center = notificationCenter()
        switch authorizationState {
        case .granted:
            deliver(notification)
        case .denied:
            return
        case .unknown:
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.authorizationState = granted ? .granted : .denied
                    guard granted else { return }
                    self.deliver(notification)
                }
            }
        }
    }

    private func deliver(_ notification: ItemNotification) {
        let center = notificationCenter()
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

    private func notificationCenter() -> UNUserNotificationCenter {
        if let center {
            return center
        }
        let center = centerProvider()
        self.center = center
        return center
    }
}
