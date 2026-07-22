import Foundation

/// Features whose protocol shape is understood but whose end-to-end behavior
/// has not yet been confirmed on production hardware. Debug builds keep them
/// reachable for device validation; release builds fail closed until that
/// validation is recorded and these gates are deliberately removed.
enum HardwareValidation {
#if DEBUG
    static let qQuietHours = true
    static let watchWeather = true
#else
    static let qQuietHours = false
    static let watchWeather = false
#endif
}
