import CoreGraphics
import XCTest
@testable import HandbeanCore

// Failure inventory: other conversation, replayed receipt, moved window,
// deadline at the boundary, stop then delayed input; all refuse before input.
final class ComputerLeaseTests: XCTestCase {
    func testOnlyTargetSelectionNeedsNativeConsent() {
        XCTAssertEqual(ComputerConsentPolicy.requirement(for: "list"), .none)
        XCTAssertEqual(ComputerConsentPolicy.requirement(for: "observe"), .none)
        XCTAssertEqual(ComputerConsentPolicy.requirement(for: "stop"), .none)
        XCTAssertEqual(ComputerConsentPolicy.requirement(for: "select"), .targetSelection)

        for action in ["click", "type", "key", "scroll"] {
            XCTAssertEqual(ComputerConsentPolicy.requirement(for: action), .activeLease)
        }

        XCTAssertFalse(
            ComputerConsentPolicy.mayClearAuthorization(
                requestedSession: "foreign",
                leaseOwner: "owner"
            )
        )
        XCTAssertTrue(
            ComputerConsentPolicy.mayClearAuthorization(
                requestedSession: "owner",
                leaseOwner: "owner"
            )
        )
        XCTAssertTrue(
            ComputerConsentPolicy.mayClearAuthorization(
                requestedSession: "expired",
                leaseOwner: nil
            )
        )
    }

    func testGlobalOwnerAndStopInvalidateDelayedInput() throws {
        var lease = ComputerLease()
        try lease.claim(session: "a", now: 0)
        XCTAssertThrowsError(try lease.claim(session: "b", now: 1))
        XCTAssertThrowsError(try lease.renew(session: "b", now: 1))
        let generation = lease.generation
        lease.stop(session: "b")
        XCTAssertTrue(lease.valid(session: "a", generation: generation, now: 1))
        lease.stop(session: "a")
        XCTAssertFalse(lease.valid(session: "a", generation: generation, now: 1))
        try lease.claim(session: "b", now: 1)
        XCTAssertFalse(lease.valid(session: "a", generation: generation, now: 1))
    }

    func testIdleExpiryInvalidatesOldAuthorizationAndFreesGlobalLease() throws {
        var lease = ComputerLease()
        try lease.claim(session: "old", now: 0)
        let oldGeneration = lease.generation

        XCTAssertTrue(lease.valid(session: "old", generation: oldGeneration, now: 119.9))
        XCTAssertFalse(lease.valid(session: "old", generation: oldGeneration, now: 120))

        try lease.claim(session: "new", now: 120)
        let newGeneration = lease.generation
        XCTAssertEqual(try lease.renew(session: "new", now: 200), newGeneration)
        XCTAssertTrue(lease.valid(session: "new", generation: newGeneration, now: 319.9))
        XCTAssertFalse(lease.valid(session: "new", generation: newGeneration, now: 320))
    }

    func testFreshOneUseObservationAndAsymmetricRetinaMapping() throws {
        var lease = ComputerLease()
        try lease.claim(session: "a", now: 0)
        let rect = CGRect(x: -300, y: 45, width: 600, height: 400)
        let receipt = lease.observe(rect: rect, pixels: CGSize(width: 1200, height: 800), now: 100)
        XCTAssertThrowsError(try lease.consume(receipt: receipt, rect: CGRect(x: -299, y: 45, width: 600, height: 400), now: 101))
        let next = lease.observe(rect: rect, pixels: CGSize(width: 1200, height: 800), now: 100)
        let snapshot = try lease.consume(receipt: next, rect: rect, now: 101)
        XCTAssertEqual(try snapshot.point(x: 400, y: 150), CGPoint(x: -100, y: 120))
        XCTAssertThrowsError(try snapshot.point(x: 1200, y: 10))
        XCTAssertThrowsError(try lease.consume(receipt: next, rect: rect, now: 102))
        let expired = lease.observe(rect: rect, pixels: CGSize(width: 1200, height: 800), now: 100)
        XCTAssertThrowsError(try lease.consume(receipt: expired, rect: rect, now: 130))
    }

    func testPointerAdmissionKeepsProductionClosedAndScopesAcceptanceToFixture() {
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "click",
                verificationOnly: false,
                receiveProbe: false,
                controlAcceptance: false
            ),
            .unsupported
        )
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "click",
                verificationOnly: true,
                receiveProbe: true,
                controlAcceptance: false
            ),
            .receiveProbe
        )
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "scroll",
                verificationOnly: true,
                receiveProbe: false,
                controlAcceptance: true
            ),
            .controlAcceptance
        )
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "click",
                verificationOnly: false,
                receiveProbe: false,
                controlAcceptance: true
            ),
            .invalid
        )
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "type",
                verificationOnly: true,
                receiveProbe: false,
                controlAcceptance: true
            ),
            .invalid
        )
        XCTAssertEqual(
            ComputerPointerAdmission.resolve(
                action: "click",
                verificationOnly: true,
                receiveProbe: true,
                controlAcceptance: true
            ),
            .invalid
        )
    }
}
