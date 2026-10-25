import os.log
import LoopKitUI
import GlookoServiceKit
import GlookoServiceKitUI

/// Principal class Loop's PluginManager instantiates (Info.plist `NSPrincipalClass`).
class GlookoServiceKitPlugin: NSObject, ServiceUIPlugin {
    private let log = OSLog(subsystem: "com.loopkit.GlookoService", category: "GlookoServiceKitPlugin")

    public var serviceType: ServiceUI.Type? { GlookoService.self }

    override init() {
        super.init()
        os_log("Instantiated", log: log, type: .default)
    }
}
