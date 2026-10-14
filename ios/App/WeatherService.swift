import CoreLocation
import Fit3Kit
import Foundation

/// Previsão do Open-Meteo (grátis, sem chave) para a cidade digitada ou para a localização do iPhone.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    @Published private(set) var forecast: BandWeather.Forecast?
    @Published private(set) var status: String?

    var enabled: Bool { UserDefaults.standard.object(forKey: "weather.enabled") as? Bool ?? true }
    var city: String { (UserDefaults.standard.string(forKey: "weather.city") ?? "").trimmingCharacters(in: .whitespaces) }

    private let manager = CLLocationManager()
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var refreshing: Task<BandWeather.Forecast?, Never>?
    /// Cidade digitada quando a previsão em cache foi buscada ("" = localização).
    private var cachedQuery: String

    override init() {
        cachedQuery = UserDefaults.standard.string(forKey: "weather.cachedQuery") ?? ""
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let data = UserDefaults.standard.data(forKey: "weather.cache") {
            forecast = try? JSONDecoder().decode(BandWeather.Forecast.self, from: data)
        }
    }

    func requestLocationPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Previsão com no máximo `maxAge` segundos; se não der para atualizar, devolve a última que houver.
    @MainActor
    func current(maxAge: TimeInterval) async -> BandWeather.Forecast? {
        if let fc = forecast, cachedQuery == city, Date().timeIntervalSince(fc.updatedAt) < maxAge { return fc }
        if let running = refreshing { return await running.value }
        let task = Task { @MainActor in await self.fetch() }
        refreshing = task
        let result = await task.value
        refreshing = nil
        return result ?? forecast
    }

    @MainActor
    private func fetch() async -> BandWeather.Forecast? {
        let query = city
        do {
            var lat = 0.0, lon = 0.0
            var name = "", region = "", country = ""
            if !query.isEmpty {
                let (data, _) = try await URLSession.shared.data(from: BandWeather.geocodeURL(name: query))
                guard let place = try BandWeather.parsePlace(data) else {
                    status = "Cidade não encontrada: \(query)"
                    return nil
                }
                lat = place.latitude
                lon = place.longitude
                name = place.name
                region = place.admin1 ?? ""
                country = place.country ?? ""
            } else {
                guard let location = await currentLocation() else {
                    status = "Sem localização: permita o acesso nos Ajustes ou digite uma cidade."
                    return nil
                }
                lat = location.coordinate.latitude
                lon = location.coordinate.longitude
                (name, region, country) = await placeName(location)
            }
            let (data, _) = try await URLSession.shared.data(from: BandWeather.forecastURL(latitude: lat, longitude: lon))
            let fc = try BandWeather.parseOpenMeteo(data, city: name, region: region, country: country)
            forecast = fc
            cachedQuery = query
            status = nil
            UserDefaults.standard.set(query, forKey: "weather.cachedQuery")
            UserDefaults.standard.set(try? JSONEncoder().encode(fc), forKey: "weather.cache")
            Logbook.shared.add("Clima: \(fc.city) \(Int(fc.temperature.rounded()))°C")
            return fc
        } catch {
            status = "Falha ao buscar o clima: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Localização

    @MainActor
    private func currentLocation() async -> CLLocation? {
        if let last = manager.location, Date().timeIntervalSince(last.timestamp) < 3600 { return last }
        let auth = manager.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else { return manager.location }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finishLocation(nil) }
        }
    }

    private func finishLocation(_ location: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        for waiter in waiters { waiter.resume(returning: location ?? manager.location) }
    }

    @MainActor
    private func placeName(_ location: CLLocation) async -> (String, String, String) {
        let place = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first
        return (place?.locality ?? place?.subAdministrativeArea ?? "Minha localização",
                place?.administrativeArea ?? "", place?.country ?? "")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finishLocation(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(nil)
    }
}
