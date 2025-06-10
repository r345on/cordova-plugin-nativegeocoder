var cordova = require('cordova');

/**
 * Reverse geocode a given latitude and longitude to find location address.
 * @param {*} success {NativeGeocoderResult[]} Success callback containing array of result objects
 * @param {*} error Error callback
 * @param {*} latitude {number} The latitude
 * @param {*} longitude {number} The longitude
 * @param {*} options {NativeGeocoderOptions} The options
 */
exports.reverseGeocode = function(success, error, latitude, longitude, options) {
    cordova.exec(success, error, "NativeGeocoder", "reverseGeocode", [latitude, longitude, options]);
};

/**
 * Forward geocode a given address to find coordinates.
 * @param {*} success {NativeGeocoderResult[]} Success callback containing array of result objects
 * @param {*} error Error callback
 * @param {*} addressString {string} The address to be geocoded
 * @param {*} options {NativeGeocoderOptions} The options
 */
exports.forwardGeocode = function(success, error, addressString, options) {
    cordova.exec(success, error, "NativeGeocoder", "forwardGeocode", [addressString, options]);
};

/**
 * Suggests possible addresses that match search input.
 * @param {*} success {SuggestionAddress[]} Success callback containing array of result objects
 * @param {*} error Error callback
 * @param {*} addressString {string} The address to search suggestions
 */
exports.addressAutocomplete = function(success, error, addressString) {
    cordova.exec(null, null, "NativeGeocoder", "addressAutocomplete", [addressString]);
};

/*
NativeGeocoderResult:
- latitude
- longitude
- countryCode
- postalCode
- administrativeArea
- subAdministrativeArea
- locality
- subLocality
- thoroughfare
- subThoroughfare
- areasOfInterest

NativeGeocoderOptions:
- useLocale = true
- defaultLocale
- maxResults = 1

SuggestionAddress:
- title
- subtitle
- coordinate
*/
