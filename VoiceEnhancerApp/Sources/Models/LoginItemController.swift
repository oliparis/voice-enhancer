import Foundation
import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct MainAppLoginService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Reflect system registration, not a defaults Boolean. Registration can need
/// approval or be revoked in System Settings. Tests inject a service; startup
/// only reads status and never registers the app without a user action.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?
    private let service: LoginItemService

    init(service: LoginItemService? = nil) {
        self.service = service ?? MainAppLoginService()
        refresh()
    }

    var requested: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = service.status }

    func setRequested(_ enabled: Bool) {
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh() // failure must not leave the toggle claiming success
    }
}
