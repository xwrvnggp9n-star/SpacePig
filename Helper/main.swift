import Foundation
import os

let helperLog = Logger(subsystem: HelperConstants.helperIdentifier, category: "helper")

// Root never downloads cloud placeholders while it runs.
BulkScanner.disableDatalessMaterialization()

let listenerDelegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()
IdleMonitor.shared.start()
helperLog.info("helper started, version \(HelperInfo.version, privacy: .public)")
dispatchMain()
