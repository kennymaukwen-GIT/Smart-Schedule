import MapKit

/// `MapsLookup` with Apple's MapKit, for 「該出發了」 (docs/SETTINGS.md §7.11): a place search, then an "arrive by"
/// travel-time estimate that accounts for expected traffic. What goes to Apple: the destination text, the starting
/// point (the iPhone's location or the text the user typed) and the time to arrive. Nothing comes back into storage,
/// chat history, Gemini or the Smart Schedules server.
///
/// The app target only: MapKit and Core Location never reach the extensions (scripts/validate_schema.py check 14).
/// The rules around it are pure and tested (`TravelTimeService`, `TravelRules` in Shared/Departure/TravelTime.swift).
struct AppleMapsLookup: MapsLookup {
    @MainActor
    func findPlace(_ query: String, near: GeoPoint?, place: TravelPlace) async throws -> FoundPlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        if let near {
            // A hint, not a limit: places near the start come first, a famous place far away is still found.
            request.region = MKCoordinateRegion(center: near.coordinate,
                                                latitudinalMeters: TravelRules.searchRegionMeters,
                                                longitudinalMeters: TravelRules.searchRegionMeters)
        }
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            throw Self.mapped(error, during: .search(place))
        }
        guard let item = response.mapItems.first else { throw TravelTimeError.placeNotFound(place) }
        return FoundPlace(name: item.name, point: GeoPoint(Self.coordinate(of: item)))
    }

    @MainActor
    func travelSeconds(from start: GeoPoint, to destination: GeoPoint, mode: TravelMode,
                       arriveBy: Date?) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = Self.mapItem(at: start)
        request.destination = Self.mapItem(at: destination)
        request.transportType = Self.transportType(for: mode)
        if let arriveBy { request.arrivalDate = arriveBy }
        do {
            // The ETA call, not calculate(): only the ETA supports public transport.
            return try await MKDirections(request: request).calculateETA().expectedTravelTime
        } catch {
            throw Self.mapped(error, during: .directions)
        }
    }

    private static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .transit: .transit
        case .driving: .automobile
        case .walking: .walking
        }
    }

    private static func mapItem(at point: GeoPoint) -> MKMapItem {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        if #available(iOS 26.0, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    /// A MapKit failure as a `TravelTimeError` (`TravelRules.error(mapKitCode:during:)`); cancellation stays as it is.
    private static func mapped(_ error: Error, during step: TravelRules.MapsStep) -> Error {
        if error is CancellationError { return error }
        return TravelRules.error(mapKitCode: (error as? MKError)?.errorCode, during: step)
    }
}

extension TravelTimeService {
    /// The travel-time service on the iPhone: Apple's MapKit.
    static func appleMaps() -> TravelTimeService {
        TravelTimeService(maps: AppleMapsLookup())
    }
}
