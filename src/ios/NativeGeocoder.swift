import CoreLocation
import MapKit

struct NativeGeocoderResult: Encodable {
    var latitude: String?
    var longitude: String?
    var countryCode: String?
    var countryName: String?
    var postalCode: String?
    var administrativeArea: String?
    var subAdministrativeArea: String?
    var locality: String?
    var subLocality: String?
    var thoroughfare: String?
    var subThoroughfare: String?
    var areasOfInterest: [String]?
}

struct NativeGeocoderError {
    var message: String
}

struct NativeGeocoderOptions: Decodable {
    var useLocale: Bool = true
    var defaultLocale: String?
    var maxResults: Int = 1
}

struct BoundingBoxResult: Encodable {
    var minLon: String
    var minLat: String
    var maxLon: String
    var maxLat: String
}

@propertyWrapper
struct StringCodedCoordinate: Encodable {
    var wrappedValue: CLLocationCoordinate2D?

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wrappedValue?.latitude, forKey: .latitude)
        try container.encode(wrappedValue?.longitude, forKey: .longitude)
    }
}

struct SuggestionAddress: Encodable {
    var title: String?
    var subtitle: String?
    @StringCodedCoordinate var coordinate: CLLocationCoordinate2D?

    init(title: String? = nil, subtitle: String? = nil, coordinate: CLLocationCoordinate2D? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
    }
}


@objc(NativeGeocoder) class NativeGeocoder: CDVPlugin, MKLocalSearchCompleterDelegate {
    private lazy var locationManager = CLLocationManager()
    private lazy var geocoder = CLGeocoder()
    private lazy var completer = MKLocalSearchCompleter()
    private lazy var searchResults: [SuggestionAddress] = []
    private lazy var searchRequestInitialized = false
    private var searchCompletion: (([SuggestionAddress]) -> Void)?
    typealias ReverseGeocodeCompletionHandler = ([NativeGeocoderResult]?, NativeGeocoderError?) -> Void
    typealias ForwardGeocodeCompletionHandler = ([NativeGeocoderResult]?, NativeGeocoderError?) -> Void
    private static let MAX_RESULTS_COUNT = 5

    // MARK: - REVERSE GEOCODE
    @objc(reverseGeocode:) func reverseGeocode(_ command: CDVInvokedUrlCommand) {
        locationManager.requestWhenInUseAuthorization()

        var pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)

        if let latitude = command.arguments[0] as? Double,
            let longitude = command.arguments[1] as? Double {

            if (geocoder.isGeocoding) {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Geocoder is busy. Please try again later.")
                self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
                return
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            var options = NativeGeocoderOptions(useLocale: true, defaultLocale: nil, maxResults: 1)
            if let optionsDict = command.arguments[2] as? NSDictionary {
                let useLocaleOption = optionsDict.value(forKey: "useLocale") as? Bool ?? true
                let defaultLocaleOption = optionsDict.value(forKey: "defaultLocale") as? String
                let maxResultsOption = optionsDict.value(forKey: "maxResults") as? Int ?? 1
                options.useLocale = useLocaleOption
                options.defaultLocale = defaultLocaleOption
                options.maxResults = maxResultsOption
            }

            reverseGeocodeLocationHandler(location, options: options, completionHandler: { [weak self] (resultObj, error) in
                if let error = error {
                    pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.message)
                } else {
                    if let encodedResult = try? JSONEncoder().encode(resultObj),
                        let result = try? JSONSerialization.jsonObject(with: encodedResult, options: .allowFragments) as? [Dictionary<String,Any>] {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
                    } else {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Invalid JSON result")
                    }
                }

                self?.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            })
        }
        else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Expected two non-empty double arguments.")
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
        }
    }

    private func reverseGeocodeLocationHandler(_ location: CLLocation, options: NativeGeocoderOptions, completionHandler: @escaping ReverseGeocodeCompletionHandler) {
        let geocoderOptions = getNativeGeocoderOptions(from: options)

        if #available(iOS 11, *) {
            var locale: Locale?
            if let defaultLocaleString = geocoderOptions.defaultLocale {
                locale = Locale.init(identifier: defaultLocaleString)
            } else if (geocoderOptions.useLocale == false) {
                locale = Locale.init(identifier: "en_US")
            }

            geocoder.reverseGeocodeLocation(location, preferredLocale: locale, completionHandler: { [weak self] (placemarks, error) in
                self?.createReverseGeocodeResult(placemarks, error, maxResults: geocoderOptions.maxResults, completionHandler: { (resultObj, error) in
                    completionHandler(resultObj, error)
                })
            })
        } else {
            // fallback for < iOS 11
            geocoder.reverseGeocodeLocation(location, completionHandler: { [weak self] (placemarks, error) in
                self?.createReverseGeocodeResult(placemarks, error, maxResults: geocoderOptions.maxResults, completionHandler: { (resultObj, error) in
                    completionHandler(resultObj, error)
                })
            })
        }
    }

    private func createReverseGeocodeResult(_ placemarks: [CLPlacemark]?, _ error: Error?, maxResults: Int, completionHandler: @escaping ReverseGeocodeCompletionHandler) {
        guard error == nil else {
            completionHandler(nil, NativeGeocoderError(message: "CLGeocoder:reverseGeocodeLocation Error"))
            return
        }

        if let placemarks = placemarks {
            let maxResultObjects = placemarks.count >= maxResults ? maxResults : placemarks.count
            var resultObj = [NativeGeocoderResult]()

            for i in 0..<maxResultObjects {
                // https://developer.apple.com/documentation/corelocation/clplacemark
                var latitude = ""
                if let lat = placemarks[i].location?.coordinate.latitude {
                    latitude = "\(lat)"
                }
                var longitude = ""
                if let lon = placemarks[i].location?.coordinate.longitude {
                    longitude = "\(lon)"
                }
                let placemark = NativeGeocoderResult(
                    latitude: latitude,
                    longitude: longitude,
                    countryCode: placemarks[i].isoCountryCode ?? "",
                    countryName: placemarks[i].country ?? "",
                    postalCode: placemarks[i].postalCode ?? "",
                    administrativeArea: placemarks[i].administrativeArea ?? "",
                    subAdministrativeArea: placemarks[i].subAdministrativeArea ?? "",
                    locality: placemarks[i].locality ?? "",
                    subLocality: placemarks[i].subLocality ?? "",
                    thoroughfare: placemarks[i].thoroughfare ?? "",
                    subThoroughfare: placemarks[i].subThoroughfare ?? "",
                    areasOfInterest: placemarks[i].areasOfInterest ?? []
                )
                resultObj.append(placemark)
            }

            completionHandler(resultObj, nil)
        }
        else {
            completionHandler(nil, NativeGeocoderError(message: "Cannot get an address"))
        }
    }


    // MARK: - FORWARD GEOCODE
    @objc(forwardGeocode:)func forwardGeocode(_ command: CDVInvokedUrlCommand) {
        locationManager.requestWhenInUseAuthorization()

        var pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)

        if let address = command.arguments[0] as? String {

            if (geocoder.isGeocoding) {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Geocoder is busy. Please try again later.")
                self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
                return
            }

            var options = NativeGeocoderOptions(useLocale: true, defaultLocale: nil, maxResults: 1)
            if let optionsDict = command.arguments[1] as? NSDictionary {
                let useLocaleOption = optionsDict.value(forKey: "useLocale") as? Bool ?? true
                let defaultLocaleOption = optionsDict.value(forKey: "defaultLocale") as? String
                let maxResultsOption = optionsDict.value(forKey: "maxResults") as? Int ?? 1
                options.useLocale = useLocaleOption
                options.defaultLocale = defaultLocaleOption
                options.maxResults = maxResultsOption
            }

            forwardGeocodeHandler(address, options: options, completionHandler: { [weak self] (resultObj, error) in
                if let error = error {
                    pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.message)
                } else {
                    if let encodedResult = try? JSONEncoder().encode(resultObj),
                        let result = try? JSONSerialization.jsonObject(with: encodedResult, options: .allowFragments) as? [Dictionary<String,Any>] {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
                    } else {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Invalid JSON result")
                    }
                }

                self?.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            })
        }
        else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Expected a non-empty string argument.")
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
        }
    }

    func forwardGeocodeHandler(_ address: String, options: NativeGeocoderOptions, completionHandler: @escaping ForwardGeocodeCompletionHandler) {
        let geocoderOptions = getNativeGeocoderOptions(from: options)

        if #available(iOS 11, *) {
            var locale: Locale?
            if let defaultLocaleString = geocoderOptions.defaultLocale {
                locale = Locale.init(identifier: defaultLocaleString)
            } else if (geocoderOptions.useLocale == false) {
                locale = Locale.init(identifier: "en_US")
            }

            geocoder.geocodeAddressString(address, in: nil, preferredLocale: locale, completionHandler: { [weak self] (placemarks, error) in
                self?.createForwardGeocodeResult(placemarks, error, maxResults: geocoderOptions.maxResults, completionHandler: { (resultObj, error) in
                    completionHandler(resultObj, error)
                })
            })
        } else {
            // fallback for < iOS 11
            geocoder.geocodeAddressString(address, completionHandler: { [weak self] (placemarks, error) in
                self?.createForwardGeocodeResult(placemarks, error, maxResults: geocoderOptions.maxResults, completionHandler: { (resultObj, error) in
                    completionHandler(resultObj, error)
                })
            })
        }
    }

    private func createForwardGeocodeResult(_ placemarks: [CLPlacemark]?, _ error: Error?, maxResults: Int, completionHandler: @escaping ForwardGeocodeCompletionHandler) {
        guard error == nil else {
            completionHandler(nil, NativeGeocoderError(message: "CLGeocoder:geocodeAddressString Error"))
            return
        }

        if let placemarks = placemarks {
            let maxResultObjects = placemarks.count >= maxResults ? maxResults : placemarks.count
            var resultObj = [NativeGeocoderResult]()

            for i in 0..<maxResultObjects {
                if let latitude = placemarks[i].location?.coordinate.latitude,
                    let longitude = placemarks[i].location?.coordinate.longitude {

                    // https://developer.apple.com/documentation/corelocation/clplacemark
                    let placemark = NativeGeocoderResult(
                        latitude: "\(latitude)",
                        longitude: "\(longitude)",
                        countryCode: placemarks[i].isoCountryCode ?? "",
                        countryName: placemarks[i].country ?? "",
                        postalCode: placemarks[i].postalCode ?? "",
                        administrativeArea: placemarks[i].administrativeArea ?? "",
                        subAdministrativeArea: placemarks[i].subAdministrativeArea ?? "",
                        locality: placemarks[i].locality ?? "",
                        subLocality: placemarks[i].subLocality ?? "",
                        thoroughfare: placemarks[i].thoroughfare ?? "",
                        subThoroughfare: placemarks[i].subThoroughfare ?? "",
                        areasOfInterest: placemarks[i].areasOfInterest ?? []
                    )
                    resultObj.append(placemark)
                }
            }

            if (resultObj.count == 0) {
                completionHandler(nil, NativeGeocoderError(message: "Cannot get latitude and/or longitude"))
            } else {
                completionHandler(resultObj, nil)
            }
        }
        else {
            completionHandler(nil, NativeGeocoderError(message: "Cannot find a location"))
        }
    }

    // MARK: - Helper
    private func getNativeGeocoderOptions(from options: NativeGeocoderOptions) -> NativeGeocoderOptions {
        var geocoderOptions = NativeGeocoderOptions()
        geocoderOptions.useLocale = options.useLocale
        geocoderOptions.defaultLocale = options.defaultLocale
        if (options.maxResults > 0) {
            geocoderOptions.maxResults = options.maxResults > NativeGeocoder.MAX_RESULTS_COUNT ? NativeGeocoder.MAX_RESULTS_COUNT : options.maxResults
        } else {
            geocoderOptions.maxResults = 1
        }
        return geocoderOptions
    }

    @objc(addressAutocomplete:)func addressAutocomplete(_ command: CDVInvokedUrlCommand) {
        if let address = command.arguments[0] as? String {
            var resultsLimit = 10
            if let limit = command.arguments[1] as? Int {
                resultsLimit = limit
            }

            getAddressSuggestions(address, completion: {[weak self] (suggestions) in
                var pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)

                if (!suggestions.isEmpty) {
                    var results = suggestions
                    if (suggestions.count > resultsLimit) {
                        results = Array(suggestions[..<resultsLimit])
                    }
                    print("Result count \(results.count)")
                    if let encodedResult = try? JSONEncoder().encode(results),
                       let result = try? JSONSerialization.jsonObject(with: encodedResult, options: .allowFragments) as? [Dictionary<String,Any>] {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
                    } else {
                        pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Invalid JSON result")
                    }

                }
                self?.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            })
        }
    }

    // Override MKLocalSearchCompleterDelegate
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        searchResults = completer.results.compactMap { result in
            let street = result.title
            let subtitle = result.subtitle
            return SuggestionAddress(title: street, subtitle: subtitle)
        }
        searchCompletion?(searchResults)
    }

    // Override MKLocalSearchCompleterDelegate
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        print("Error ", error)
        searchResults = []
        searchCompletion?(searchResults)
    }

    private func initSearchRequest() {
        completer.region = MKCoordinateRegion(.world)

        if #available(iOS 13, *) {
            // completer.resultTypes = [.pointOfInterest, .query, .address]
            completer.resultTypes = [.address, .pointOfInterest]
        } else {
            // fallback for iOS  9.3 - 13
            completer.filterType = .locationsOnly
        }
    }

    private func getAddressSuggestions(_ address: String, completion: @escaping ([SuggestionAddress]) -> Void) {
        completer.delegate = self

        if (!searchRequestInitialized) {
            initSearchRequest()
            searchRequestInitialized = true
        }

        completer.queryFragment = address
        searchCompletion = completion
    }

    @objc(getBoundingBox:)func getBoundingBox(_ command: CDVInvokedUrlCommand) {

        var pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)

        if let address = command.arguments[0] as? String {

            if (geocoder.isGeocoding) {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Geocoder is busy. Please try again later.")
                self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
                return
            }

            var options = NativeGeocoderOptions(useLocale: true, defaultLocale: nil, maxResults: 1)
            if let optionsDict = command.arguments[1] as? NSDictionary {
                let useLocaleOption = optionsDict.value(forKey: "useLocale") as? Bool ?? true
                let defaultLocaleOption = optionsDict.value(forKey: "defaultLocale") as? String
                let maxResultsOption = optionsDict.value(forKey: "maxResults") as? Int ?? 1
                options.useLocale = useLocaleOption
                options.defaultLocale = defaultLocaleOption
                options.maxResults = maxResultsOption
            }

            getBoundingBoxHandler(address, options: options, completion: { [weak self] (resultObj, error) in
                if let error = error {
                    pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.localizedDescription)
                } else {
                    if let placemark = resultObj?[0] {
                        let region = MKCoordinateRegion(center: placemark.location!.coordinate, span: self?.spanForPlacemark(placemark) ?? MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
                        let boundingBox = self?.defineBoundingBox(for: region)
                        if let encodedResult = try? JSONEncoder().encode(boundingBox),
                            let result = try? JSONSerialization.jsonObject(with: encodedResult, options: .allowFragments) as? [Dictionary<String,Any>] {
                            pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
                        } else {
                            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Invalid JSON result")
                        }
                    }
                }

                self?.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            })
        }
        else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Expected a non-empty string argument.")
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
        }
    }

    private func getBoundingBoxHandler (_ address: String, options: NativeGeocoderOptions, completion: @escaping ([CLPlacemark]?, Error?) -> Void){
        let geocoderOptions = getNativeGeocoderOptions(from: options)

        if #available(iOS 11, *) {
            var locale: Locale?
            if let defaultLocaleString = geocoderOptions.defaultLocale {
                locale = Locale.init(identifier: defaultLocaleString)
            } else if (geocoderOptions.useLocale == false) {
                locale = Locale.init(identifier: "en_US")
            }

            geocoder.geocodeAddressString(address, in: nil, preferredLocale: locale, completionHandler: { (placemarks, error) in
                completion(placemarks, error)
            })
        } else {
            // fallback for < iOS 11
            geocoder.geocodeAddressString(address, completionHandler: { (placemarks, error) in completion(placemarks, error) })
        }
    }

    private func spanForPlacemark(_ placemark: CLPlacemark) -> MKCoordinateSpan {
        if placemark.subThoroughfare != nil {
            // Street-level
            return MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)
        } else if placemark.locality != nil {
            // City-level
            return MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        } else if placemark.administrativeArea != nil {
            // Region/state-level
            return MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        } else {
            // Country-level
            return MKCoordinateSpan(latitudeDelta: 10.0, longitudeDelta: 10.0)
        }
    }

    private func defineBoundingBox(for region: MKCoordinateRegion) -> BoundingBoxResult {
        let center = region.center
        let span = region.span

        let minLat = String(format: "%.1f", (center.latitude  - (span.latitudeDelta  / 2.0)))
        let maxLat = String(format: "%.1f",(center.latitude  + (span.latitudeDelta  / 2.0)))
        let minLon = String(format: "%.1f",(center.longitude - (span.longitudeDelta / 2.0)))
        let maxLon = String(format: "%.1f",(center.longitude + (span.longitudeDelta / 2.0)))

        return BoundingBoxResult(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
    }
}
