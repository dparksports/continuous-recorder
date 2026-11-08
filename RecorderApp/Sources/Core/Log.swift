import Foundation
import os

/// Thin, centralised logging. Everything the recorder does should be traceable from
/// Console.app / Xcode's console by filtering on subsystem `com.example.recorderapp`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.recorderapp"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let power = Logger(subsystem: subsystem, category: "power")
}
