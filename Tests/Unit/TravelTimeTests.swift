import XCTest

/// Departure reminders: the location rules (`TravelRules`, `GeoPoint`) and a fake location for the later steps. No
/// Core Location: the real one is tried on the iPhone. Travel times come from Google (DepartureRoutesTests).
final class TravelTimeTests: XCTestCase {
    func testPointsThatAreNotPlacesAreRefused() {
        XCTAssertFalse(GeoPoint(latitude: .nan, longitude: 121.5).isValid)
        XCTAssertFalse(GeoPoint(latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(GeoPoint(latitude: 0, longitude: -180.5).isValid)
        XCTAssertFalse(GeoPoint(latitude: 0, longitude: .infinity).isValid)
        XCTAssertTrue(GeoPoint(latitude: -90, longitude: 180).isValid)
        XCTAssertTrue(GeoPoint(latitude: 25.033964, longitude: 121.564468).isValid)  // Taipei 101
    }

    func testCoreLocationErrorCodes() {
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 1), .noPermission)              // denied
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 0), .temporarilyUnavailable)    // locationUnknown
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 2), .temporarilyUnavailable)    // network
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: nil), .temporarilyUnavailable)
    }

    /// ScheduleAssistant's catch-all sends an error's description to Gemini, which must never learn why a departure
    /// couldn't be worked out (docs/SETTINGS.md §7.11): every reason looks the same.
    func testEveryReasonLooksTheSameAsAGenericError() {
        let all: [TravelTimeError] = [.noPermission, .temporarilyUnavailable]
        let errors = all.map { $0 as NSError }
        XCTAssertEqual(Set(errors.map { $0.domain }), ["SmartSchedule.TravelTime"])
        XCTAssertEqual(Set(errors.map { $0.code }), [0])
        XCTAssertEqual(Set(all.map { $0.localizedDescription }).count, 1)
    }

    func testARecentAccurateLocationIsReused() {
        XCTAssertTrue(TravelRules.isRecent(ageSeconds: 0, accuracyMeters: 65))
        XCTAssertTrue(TravelRules.isRecent(ageSeconds: 120, accuracyMeters: 1_000))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 121, accuracyMeters: 65))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 10, accuracyMeters: 1_001))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 10, accuracyMeters: -1), "a negative accuracy is not valid")
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: -5, accuracyMeters: 65), "a fix from the future is not trusted")
    }

    func testTheFakeLocationGivesItsPointOrItsFailure() async throws {
        let taipeiStation = GeoPoint(latitude: 25.047675, longitude: 121.517055)
        let here = try await FakeLocation(result: .success(taipeiStation)).currentLocation()
        XCTAssertEqual(here, taipeiStation)
        do {
            _ = try await FakeLocation(result: .failure(.noPermission)).currentLocation()
            XCTFail("expected noPermission")
        } catch {
            XCTAssertEqual(error as? TravelTimeError, .noPermission)
        }
    }
}

// MARK: - Fakes (also for the later departure steps)

/// The iPhone's location, fixed: a point, or a failure such as no permission.
struct FakeLocation: LocationProviding {
    var result: Result<GeoPoint, TravelTimeError>

    func currentLocation() async throws -> GeoPoint {
        try result.get()
    }
}
