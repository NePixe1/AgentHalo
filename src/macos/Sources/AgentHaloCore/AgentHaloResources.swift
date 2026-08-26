import Foundation

public enum AgentHaloResources {
    public static let bundleName = "AgentHaloMac_AgentHaloCore.bundle"

    public static var bundle: Bundle {
        resolve(
            packagedResourcesDirectory: Bundle.main.resourceURL,
            fallback: .module
        )
    }

    public static func resolve(
        packagedResourcesDirectory: URL?,
        fallback: @autoclosure () -> Bundle
    ) -> Bundle {
        guard let packagedResourcesDirectory,
              let packaged = Bundle(
                url: packagedResourcesDirectory.appendingPathComponent(
                    bundleName,
                    isDirectory: true
                )
              ) else {
            return fallback()
        }
        return packaged
    }
}
