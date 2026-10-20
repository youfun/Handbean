public enum ComputerConsentRequirement: Equatable, Sendable {
    case none
    case targetSelection
    case activeLease
}

public enum ComputerConsentPolicy {
    public static func requirement(for action: String) -> ComputerConsentRequirement {
        switch action {
        case "select":
            .targetSelection
        case "click", "type", "key", "scroll":
            .activeLease
        default:
            .none
        }
    }

    public static func mayClearAuthorization(requestedSession: String?, leaseOwner: String?) -> Bool {
        requestedSession == nil || leaseOwner == nil || requestedSession == leaseOwner
    }
}
