import Foundation
import os

private let logger = Logger(subsystem: "com.relakkes.livezoom", category: "app")

func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("[LiveZoom] \(message)\n".utf8))
}
