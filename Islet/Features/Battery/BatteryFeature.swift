import SwiftUI

/// Placeholder until the feature is implemented.
@MainActor
final class BatteryFeature: Feature {
    let id = "battery"
    let title = "Battery"
    let symbol = "battery.100percent.bolt"
    let summary = "A charging flash when you plug in, and a warning when the battery runs low."

    func start() {}
    func stop() {}
}
