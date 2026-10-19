import XCTest

/// Departure reminders step 4: the travel-time rules (`TravelTimeService`, `TravelRules`) with fake maps and a fake
/// location. No network, no MapKit, no Core Location: the real ones are tried on the iPhone.
final class TravelTimeTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let taipei101 = GeoPoint(latitude: 25.033964, longitude: 121.564468)
    private let taipeiStation = GeoPoint(latitude: 25.047675, longitude: 121.517055)   // about 5 km from Taipei 101
    private let hsinchuStation = GeoPoint(latitude: 24.8015, longitude: 120.9716)      // about 65 km
    private let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)

    private func time(_ zone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func service(_ maps: FakeMapsLookup, now: Date = Date(timeIntervalSince1970: 0)) -> TravelTimeService {
        TravelTimeService(maps: maps, now: { now })
    }

    private func assertThrows(_ expected: TravelTimeError, file: StaticString = #filePath, line: UInt = #line,
                              _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TravelTimeError, expected, file: file, line: line)
        }
    }

    // MARK: The owner's example

    /// 「今天 5 點要到台北 101 開會，想提早 30 分鐘到」: public transport 22 minutes → leave 15:58, get ready 15:48.
    func testTaipei101ByTransitLeavesAt1558() async throws {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(1_320)])
        let start = time(taipei, 2026, 10, 19, 17, 0)
        let arriveBy = time(taipei, 2026, 10, 19, 16, 30)
        let estimate = try await service(maps, now: time(taipei, 2026, 10, 19, 14, 0))
            .estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: arriveBy)

        XCTAssertEqual(estimate.minutes, 22)
        XCTAssertEqual(estimate.mode, .transit)
        XCTAssertFalse(estimate.isEstimate)
        XCTAssertEqual(estimate.placeName, "台北 101")
        XCTAssertEqual(estimate.start, taipeiStation)
        XCTAssertEqual(estimate.destination, taipei101)

        let plan = DeparturePlanner.plan(start: start, arriveEarlyMinutes: 30, travelMinutes: estimate.minutes,
                                         travelMode: estimate.mode, isEstimate: estimate.isEstimate)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 15, 58))
        XCTAssertEqual(DeparturePlanner.readyReminder(for: plan), time(taipei, 2026, 10, 19, 15, 48))

        let routes = await maps.routes
        XCTAssertEqual(routes, [.init(start: taipeiStation, destination: taipei101, mode: .transit,
                                      arriveBy: arriveBy)])
    }

    /// The spec's stand-in: a `TravelTimeProviding` fake that always answers 22 minutes by public transport.
    func testFakeTravelTimeGivesTheSpecExample() async throws {
        let travel: any TravelTimeProviding = FakeTravelTime(result: .success(22))
        let estimate = try await travel.estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: nil)
        let plan = DeparturePlanner.plan(start: time(taipei, 2026, 10, 19, 17, 0), arriveEarlyMinutes: 30,
                                         travelMinutes: estimate.minutes, travelMode: estimate.mode,
                                         isEstimate: estimate.isEstimate)
        XCTAssertEqual(plan.departAt, time(taipei, 2026, 10, 19, 15, 58))
    }

    func testFakeLocationFeedsTheService() async throws {
        let location: any LocationProviding = FakeLocation(result: .success(taipeiStation))
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(1_320)])
        let here = try await location.currentLocation()
        let estimate = try await service(maps).estimate(to: "台北 101", from: .current(here), mode: nil, arriveBy: nil)
        XCTAssertEqual(estimate.start, taipeiStation)

        let denied: any LocationProviding = FakeLocation(result: .failure(.noPermission))
        await assertThrows(.noPermission) { _ = try await denied.currentLocation() }
    }

    // MARK: The way of travelling

    func testNearbyWithoutAModeUsesPublicTransport() async throws {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(1_200)])
        let estimate = try await service(maps).estimate(to: "台北 101", from: .current(taipeiStation), mode: nil,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.mode, .transit)
        let modes = await maps.routes.map(\.mode)
        XCTAssertEqual(modes, [.transit])
    }

    func testBeyondFortyKilometresWithoutAModeDrives() async throws {
        let maps = FakeMapsLookup(places: ["新竹車站": hsinchuStation], seconds: [.driving: .success(3_600)])
        let estimate = try await service(maps).estimate(to: "新竹車站", from: .current(taipei101), mode: nil,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.mode, .driving)
        XCTAssertFalse(estimate.isEstimate, "driving is the rule beyond 40 km, not a stand-in")
        let modes = await maps.routes.map(\.mode)
        XCTAssertEqual(modes, [.driving])
    }

    func testTheFortyKilometreLine() {
        let origin = GeoPoint(latitude: 25, longitude: 121.5)
        let under = TravelRules.distanceMeters(origin, GeoPoint(latitude: 25.35, longitude: 121.5))   // 38.9 km
        let over = TravelRules.distanceMeters(origin, GeoPoint(latitude: 25.36, longitude: 121.5))    // 40.03 km
        XCTAssertEqual(TravelRules.defaultMode(distanceMeters: under), .transit)
        XCTAssertEqual(TravelRules.defaultMode(distanceMeters: over), .driving)
        XCTAssertEqual(TravelRules.defaultMode(distanceMeters: 40_000), .transit)
    }

    func testTheUsersModeIsKeptEvenBeyondFortyKilometres() async throws {
        let maps = FakeMapsLookup(places: ["新竹車站": hsinchuStation], seconds: [.transit: .success(4_800)])
        let estimate = try await service(maps).estimate(to: "新竹車站", from: .current(taipei101), mode: .transit,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.mode, .transit)
        XCTAssertEqual(estimate.minutes, 80)
    }

    func testWalkingIsAskedForAsWalking() async throws {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.walking: .success(3_900)])
        let estimate = try await service(maps).estimate(to: "台北 101", from: .current(taipeiStation), mode: .walking,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.mode, .walking)
        XCTAssertEqual(estimate.minutes, 65)
    }

    func testNoPublicTransportRouteFallsBackToDrivingAsAnEstimate() async throws {
        let maps = FakeMapsLookup(places: ["露營地": GeoPoint(latitude: 24.9, longitude: 121.6)],
                                  seconds: [.transit: .failure(TravelTimeError.routeUnavailable),
                                            .driving: .success(5_400)])
        let estimate = try await service(maps).estimate(to: "露營地", from: .current(taipei101), mode: nil,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.mode, .driving)
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertEqual(estimate.minutes, 90)
        let modes = await maps.routes.map(\.mode)
        XCTAssertEqual(modes, [.transit, .driving])
    }

    func testAModeTheUserAskedForIsNeverSwapped() async {
        let maps = FakeMapsLookup(places: ["露營地": GeoPoint(latitude: 24.9, longitude: 121.6)],
                                  seconds: [.transit: .failure(TravelTimeError.routeUnavailable),
                                            .driving: .success(5_400)])
        await assertThrows(.routeUnavailable) {
            _ = try await self.service(maps).estimate(to: "露營地", from: .current(self.taipei101), mode: .transit,
                                                     arriveBy: nil)
        }
        let modes = await maps.routes.map(\.mode)
        XCTAssertEqual(modes, [.transit])
    }

    func testABusyMapServiceIsNotTurnedIntoADrive() async {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101],
                                  seconds: [.transit: .failure(TravelTimeError.temporarilyUnavailable),
                                            .driving: .success(600)])
        await assertThrows(.temporarilyUnavailable) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
        let modes = await maps.routes.map(\.mode)
        XCTAssertEqual(modes, [.transit])
    }

    func testNoDrivingRouteEitherIsRouteUnavailable() async {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101],
                                  seconds: [.transit: .failure(TravelTimeError.routeUnavailable),
                                            .driving: .failure(TravelTimeError.routeUnavailable)])
        await assertThrows(.routeUnavailable) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
    }

    // MARK: Too far

    func testMoreThanAbout300KilometresIsTooFarWithoutAskingForARoute() async {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.driving: .success(600)])
        await assertThrows(.tooFar) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.london), mode: nil,
                                                     arriveBy: nil)
        }
        let routes = await maps.routes
        XCTAssertTrue(routes.isEmpty)
    }

    func testTheThreeHundredKilometreLine() async throws {
        let origin = GeoPoint(latitude: 25, longitude: 121.5)
        let near = GeoPoint(latitude: 27.69, longitude: 121.5)   // 299.1 km
        let far = GeoPoint(latitude: 27.71, longitude: 121.5)    // 301.3 km
        let maps = FakeMapsLookup(places: ["near": near, "far": far], seconds: [.driving: .success(14_400)])
        let estimate = try await service(maps).estimate(to: "near", from: .current(origin), mode: nil, arriveBy: nil)
        XCTAssertEqual(estimate.minutes, 240)
        await assertThrows(.tooFar) {
            _ = try await self.service(maps).estimate(to: "far", from: .current(origin), mode: nil, arriveBy: nil)
        }
    }

    func testMoreThan24HoursOfTravelIsTooFar() async throws {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101],
                                  seconds: [.walking: .success(86_400), .driving: .success(86_401)])
        let walk = try await service(maps).estimate(to: "台北 101", from: .current(taipeiStation), mode: .walking,
                                                     arriveBy: nil)
        XCTAssertEqual(walk.minutes, 1_440)
        await assertThrows(.tooFar) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.taipeiStation),
                                                     mode: .driving, arriveBy: nil)
        }
    }

    func testStraightLineDistance() {
        let paris = GeoPoint(latitude: 48.8566, longitude: 2.3522)
        XCTAssertEqual(TravelRules.distanceMeters(london, paris), 343_557, accuracy: 1_000)
        XCTAssertEqual(TravelRules.distanceMeters(taipei101, taipeiStation), 5_014, accuracy: 50)
        XCTAssertEqual(TravelRules.distanceMeters(taipei101, taipei101), 0, accuracy: 0.001)
        XCTAssertEqual(TravelRules.distanceMeters(taipei101, hsinchuStation),
                       TravelRules.distanceMeters(hsinchuStation, taipei101), accuracy: 0.001)
        // Opposite sides of the Earth: half the circumference, no NaN.
        let antipode = TravelRules.distanceMeters(GeoPoint(latitude: 0, longitude: 0),
                                                  GeoPoint(latitude: 0, longitude: 180))
        XCTAssertEqual(antipode, 20_015_114, accuracy: 1_000)
    }

    // MARK: Places

    func testATypedStartingPointIsLookedUpFirstAndTheDestinationNearIt() async throws {
        let maps = FakeMapsLookup(places: ["台北車站": taipeiStation, "台北 101": taipei101],
                                  seconds: [.transit: .success(1_320)])
        let estimate = try await service(maps).estimate(to: "台北 101", from: .typed("  台北車站 "), mode: nil,
                                                         arriveBy: nil)
        XCTAssertEqual(estimate.start, taipeiStation)
        let searches = await maps.searches
        XCTAssertEqual(searches, [.init(query: "台北車站", near: nil, place: .start),
                                  .init(query: "台北 101", near: taipeiStation, place: .destination)])
    }

    func testTheDestinationIsLookedUpNearTheCurrentLocation() async throws {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(1_320)])
        _ = try await service(maps).estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: nil)
        let searches = await maps.searches
        XCTAssertEqual(searches, [.init(query: "台北 101", near: taipeiStation, place: .destination)])
    }

    func testAPlaceOnTwoLinesIsSearchedAsOneLine() async throws {
        let maps = FakeMapsLookup(places: ["台北 101, 信義路五段 7 號": taipei101], seconds: [.transit: .success(60)])
        _ = try await service(maps).estimate(to: "台北 101\n 信義路五段  7 號\n", from: .current(taipeiStation),
                                             mode: nil, arriveBy: nil)
        let queries = await maps.searches.map(\.query)
        XCTAssertEqual(queries, ["台北 101, 信義路五段 7 號"])
    }

    func testAnUnknownDestinationOrStartSaysWhich() async {
        let maps = FakeMapsLookup(places: ["台北車站": taipeiStation], seconds: [.transit: .success(60)])
        await assertThrows(.placeNotFound(.destination)) {
            _ = try await self.service(maps).estimate(to: "不存在的地方", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
        await assertThrows(.placeNotFound(.start)) {
            _ = try await self.service(maps).estimate(to: "台北車站", from: .typed("不存在的起點"), mode: nil,
                                                     arriveBy: nil)
        }
    }

    func testABlankPlaceIsNotSentToTheMapService() async {
        let maps = FakeMapsLookup(places: [:], seconds: [:])
        await assertThrows(.placeNotFound(.destination)) {
            _ = try await self.service(maps).estimate(to: " \n\t ", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
        await assertThrows(.placeNotFound(.start)) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .typed("\n "), mode: nil, arriveBy: nil)
        }
        let searches = await maps.searches
        XCTAssertTrue(searches.isEmpty)
    }

    // MARK: Time

    func testTheArrivalTimeIsAskedAboutOnlyWhenItIsAhead() async throws {
        let now = time(taipei, 2026, 10, 19, 14, 0)
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(1_320)])
        let travel = service(maps, now: now)
        let later = time(taipei, 2026, 10, 19, 16, 30)
        let earlier = time(taipei, 2026, 10, 19, 13, 30)
        _ = try await travel.estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: later)
        _ = try await travel.estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: earlier)
        _ = try await travel.estimate(to: "台北 101", from: .current(taipeiStation), mode: nil, arriveBy: nil)
        let asked = await maps.routes.map(\.arriveBy)
        XCTAssertEqual(asked, [later, nil, nil])

        XCTAssertEqual(TravelRules.arrivalDate(later, now: now), later)
        XCTAssertNil(TravelRules.arrivalDate(now, now: now))
        XCTAssertNil(TravelRules.arrivalDate(earlier, now: now))
        XCTAssertNil(TravelRules.arrivalDate(nil, now: now))
    }

    func testMinutesAreRoundedUp() {
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 22 * 60), 22)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 21 * 60 + 1), 22)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 21 * 60 + 59.9), 22)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 0.4), 1)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 0), 0)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: -90), 0)
        XCTAssertEqual(TravelRules.wholeMinutes(seconds: 1e300), Int(Int32.max))
        XCTAssertNil(TravelRules.wholeMinutes(seconds: .nan))
        XCTAssertNil(TravelRules.wholeMinutes(seconds: .infinity))
    }

    func testANonsenseTimeFromTheMapServiceIsTemporarilyUnavailable() async {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101], seconds: [.transit: .success(.nan)])
        await assertThrows(.temporarilyUnavailable) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
    }

    // MARK: Errors

    func testMapKitErrorCodes() {
        let search = TravelRules.MapsStep.search(.destination)
        // 4 placemarkNotFound, 5 directionsNotFound
        XCTAssertEqual(TravelRules.error(mapKitCode: 4, during: search), .placeNotFound(.destination))
        XCTAssertEqual(TravelRules.error(mapKitCode: 5, during: .search(.start)), .placeNotFound(.start))
        XCTAssertEqual(TravelRules.error(mapKitCode: 4, during: .directions), .routeUnavailable)
        XCTAssertEqual(TravelRules.error(mapKitCode: 5, during: .directions), .routeUnavailable)
        for code in [1, 2, 3, 6, 99] {   // unknown, serverFailure, loadingThrottled, decodingFailed, anything new
            XCTAssertEqual(TravelRules.error(mapKitCode: code, during: search), .temporarilyUnavailable, "\(code)")
            XCTAssertEqual(TravelRules.error(mapKitCode: code, during: .directions), .temporarilyUnavailable, "\(code)")
        }
        XCTAssertEqual(TravelRules.error(mapKitCode: nil, during: search), .temporarilyUnavailable)       // no network
        XCTAssertEqual(TravelRules.error(mapKitCode: nil, during: .directions), .temporarilyUnavailable)
    }

    func testCoreLocationErrorCodes() {
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 1), .noPermission)              // denied
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 0), .temporarilyUnavailable)    // locationUnknown
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: 2), .temporarilyUnavailable)    // network
        XCTAssertEqual(TravelRules.locationError(coreLocationCode: nil), .temporarilyUnavailable)
    }

    func testOtherFailuresBecomeTemporarilyUnavailableButCancellationStays() async {
        let maps = FakeMapsLookup(places: ["台北 101": taipei101],
                                  seconds: [.transit: .failure(URLError(.notConnectedToInternet))])
        await assertThrows(.temporarilyUnavailable) {
            _ = try await self.service(maps).estimate(to: "台北 101", from: .current(self.taipeiStation), mode: nil,
                                                     arriveBy: nil)
        }
        XCTAssertTrue(TravelRules.normalized(CancellationError()) is CancellationError)
        XCTAssertEqual(TravelRules.normalized(TravelTimeError.tooFar) as? TravelTimeError, .tooFar)
        XCTAssertEqual(TravelRules.normalized(URLError(.timedOut)) as? TravelTimeError, .temporarilyUnavailable)

        let cancelled = FakeMapsLookup(places: ["台北 101": taipei101],
                                       seconds: [.transit: .failure(CancellationError())])
        do {
            _ = try await service(cancelled).estimate(to: "台北 101", from: .current(taipeiStation), mode: nil,
                                                      arriveBy: nil)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testARecentAccurateLocationIsReused() {
        XCTAssertTrue(TravelRules.isRecent(ageSeconds: 0, accuracyMeters: 65))
        XCTAssertTrue(TravelRules.isRecent(ageSeconds: 120, accuracyMeters: 1_000))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 121, accuracyMeters: 65))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 10, accuracyMeters: 1_001))
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: 10, accuracyMeters: -1), "a negative accuracy is not valid")
        XCTAssertFalse(TravelRules.isRecent(ageSeconds: -5, accuracyMeters: 65), "a fix from the future is not trusted")
    }
}

// MARK: - Fakes (also for the later departure steps)

/// Apple's map service, scripted: known places by query, and a travel time (or failure) per way of travelling. It
/// records every question, so tests can check what would have gone to Apple.
actor FakeMapsLookup: MapsLookup {
    struct Search: Equatable, Sendable {
        let query: String
        let near: GeoPoint?
        let place: TravelPlace
    }

    struct Route: Equatable, Sendable {
        let start: GeoPoint
        let destination: GeoPoint
        let mode: TravelMode
        let arriveBy: Date?
    }

    private let places: [String: GeoPoint]
    private let seconds: [TravelMode: Result<TimeInterval, Error>]
    private(set) var searches: [Search] = []
    private(set) var routes: [Route] = []

    init(places: [String: GeoPoint], seconds: [TravelMode: Result<TimeInterval, Error>]) {
        self.places = places
        self.seconds = seconds
    }

    func findPlace(_ query: String, near: GeoPoint?, place: TravelPlace) async throws -> FoundPlace {
        searches.append(Search(query: query, near: near, place: place))
        guard let point = places[query] else { throw TravelTimeError.placeNotFound(place) }
        return FoundPlace(name: query, point: point)
    }

    func travelSeconds(from start: GeoPoint, to destination: GeoPoint, mode: TravelMode,
                       arriveBy: Date?) async throws -> TimeInterval {
        routes.append(Route(start: start, destination: destination, mode: mode, arriveBy: arriveBy))
        guard let result = seconds[mode] else { throw TravelTimeError.routeUnavailable }
        return try result.get()
    }
}

/// The spec's FakeTravelTime: a fixed answer (22 minutes by public transport in the examples) or a fixed failure.
struct FakeTravelTime: TravelTimeProviding {
    var result: Result<Int, TravelTimeError>
    var mode: TravelMode = .transit
    var isEstimate = false

    func estimate(to destination: String, from origin: TravelOrigin, mode requested: TravelMode?,
                  arriveBy: Date?) async throws -> TravelEstimate {
        let minutes = try result.get()
        let start: GeoPoint
        if case .current(let point) = origin { start = point } else { start = GeoPoint(latitude: 0, longitude: 0) }
        return TravelEstimate(minutes: minutes, mode: requested ?? mode, isEstimate: isEstimate, placeName: destination,
                              start: start, destination: GeoPoint(latitude: 0, longitude: 0))
    }
}

/// The iPhone's location, fixed: a point, or a failure such as no permission.
struct FakeLocation: LocationProviding {
    var result: Result<GeoPoint, TravelTimeError>

    func currentLocation() async throws -> GeoPoint {
        try result.get()
    }
}
