import os

/// Islet's own log lines, under the com.ayush.Islet subsystem, for tracing what the
/// island did and why without a debugger:
/// `/usr/bin/log show --last 1h --predicate 'subsystem == "com.ayush.Islet"'`.
enum IslandLog {
    static let island = Logger(subsystem: "com.ayush.Islet", category: "Island")
    static let app = Logger(subsystem: "com.ayush.Islet", category: "App")
}
