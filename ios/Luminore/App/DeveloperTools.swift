import Foundation

enum DeveloperTools {
    static let unlockTapCount = 5

    /// Debug builds only. This used to key off `CFBundleVersion == "1"`, which
    /// would have shipped the gem editor in the first release build.
    static var isEnabledForCurrentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
