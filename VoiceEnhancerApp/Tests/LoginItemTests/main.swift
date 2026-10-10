import Foundation
import ServiceManagement

@MainActor
final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0, removals = 0
    var needsApproval = false, fail = false
    func register() throws {
        registrations += 1
        if fail { throw NSError(domain: "test", code: 1) }
        status = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        removals += 1
        if fail { throw NSError(domain: "test", code: 2) }
        status = .notRegistered
    }
}

@main
struct LoginItemTests {
    @MainActor
    static func main() {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(label)") }
        }
        let service = FakeLoginService(), controller = LoginItemController(service: nil)
        // The real controller above only reads status; tests never register it.
        expect(controller.errorMessage == nil, "status read does not change registration")
        let fake = LoginItemController(service: service)
        expect(service.registrations == 0 && !fake.requested, "startup does not register a login item")
        fake.setRequested(true)
        expect(fake.requested && fake.status == .enabled, "successful registration is reflected")
        fake.setRequested(false)
        expect(!fake.requested && service.removals == 1, "disable unregisters the service")
        service.needsApproval = true; fake.setRequested(true)
        expect(fake.requested && fake.status == .requiresApproval, "pending approval stays visible as requested")
        service.status = .notRegistered; fake.refresh()
        expect(!fake.requested, "external revocation is reflected")
        service.fail = true; fake.setRequested(true)
        expect(!fake.requested && fake.errorMessage != nil, "failed register does not claim enabled")
        service.status = .enabled; fake.setRequested(false)
        expect(fake.requested && fake.errorMessage != nil, "failed unregister preserves actual enabled status")
        service.fail = false; fake.setRequested(false)
        expect(!fake.requested && fake.errorMessage == nil, "successful retry clears error")
        print("Login item: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
