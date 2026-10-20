public enum ComputerPointerAdmission: Equatable {
    case nonPointer
    case receiveProbe
    case controlAcceptance
    case unsupported
    case invalid

    public static func resolve(
        action: String,
        verificationOnly: Bool,
        receiveProbe: Bool,
        controlAcceptance: Bool
    ) -> Self {
        let pointerAction = action == "click" || action == "scroll"

        guard pointerAction else {
            return receiveProbe || controlAcceptance ? .invalid : .nonPointer
        }
        guard receiveProbe != controlAcceptance else {
            return receiveProbe ? .invalid : .unsupported
        }
        guard verificationOnly else { return .invalid }

        return receiveProbe ? .receiveProbe : .controlAcceptance
    }
}
