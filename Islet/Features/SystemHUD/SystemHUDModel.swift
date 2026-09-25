import AppKit
import Observation

/// The volume and brightness changes the keys ask for, and the level to show for
/// the last one. Knows nothing about the island: it says whether it will act on a
/// key, and calls `onChange` once the change is made and the level is up to date.
@MainActor
@Observable
final class SystemHUDModel {
    enum Kind: Equatable {
        case volume, brightness
    }

    private(set) var kind: Kind = .volume
    /// 0...1. While muted, the level sound will come back at.
    private(set) var level: Double = 0
    /// Volume only.
    private(set) var isMuted = false
    /// What is being changed: the output device, or the display.
    private(set) var deviceName: String?

    /// Called after a real change (or reading) lands in `kind`, `level` and `isMuted`.
    @ObservationIgnored var onChange: () -> Void = {}

    /// macOS's sixteen notches, and the quarter notches Option-Shift gives.
    static let step = 1.0 / 16
    static let fineStep = 1.0 / 64

    @ObservationIgnored private let output = AudioOutput()
    /// Bumped by `stop()`, so volume results still on their way are dropped.
    @ObservationIgnored private var generation = 0
    /// The brightness last asked for. The panel fades to a new level rather than
    /// jumping, so reading it back while a key repeats would lose steps.
    @ObservationIgnored private var pendingBrightness: (level: Double, at: Date)?

    /// The click macOS plays when "Play feedback when volume is changed" is on.
    private static let feedbackSound = NSSound(
        contentsOf: URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"),
        byReference: true
    )

    func start() {
        output.startFollowing()
    }

    func stop() {
        output.stopFollowing()
        generation &+= 1
        pendingBrightness = nil
    }

    /// Sets what the HUD shows without touching any hardware (previews use it).
    func display(_ kind: Kind, level: Double, muted: Bool = false, device: String? = nil) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
        isMuted = muted
        deviceName = device
    }

    // MARK: Volume

    /// Moves the volume a step. Returns false, at once, if the output has no volume
    /// the Mac can set.
    func stepVolume(by delta: Double, playsFeedback: Bool) -> Bool {
        guard output.canSetVolume else { return false }
        output.stepVolume(by: delta, report: volumeReport { reading in
            guard playsFeedback, !reading.isMuted else { return }
            Self.feedbackSound?.stop()
            Self.feedbackSound?.play()
        })
        return true
    }

    /// Mutes or unmutes the output. Returns false, at once, if it can do neither.
    func toggleMute() -> Bool {
        guard output.canMute else { return false }
        output.toggleMute(report: volumeReport())
        return true
    }

    /// Reads the current volume without changing it.
    func showVolume() {
        output.read(report: volumeReport())
    }

    /// Where a volume result lands: in the level, then `then`. Results still on their
    /// way when the feature stops are dropped.
    private func volumeReport(
        then: @escaping @MainActor (AudioOutput.Reading) -> Void = { _ in }
    ) -> @MainActor (AudioOutput.Reading?) -> Void {
        let issued = generation
        return { [weak self] reading in
            guard let self, let reading, self.generation == issued else { return }
            self.display(.volume, level: reading.level, muted: reading.isMuted, device: reading.deviceName)
            self.onChange()
            then(reading)
        }
    }

    // MARK: Brightness

    /// Moves the built-in display's brightness a step. Returns false if there is no
    /// built-in display to change (the lid is closed, or DisplayServices is missing).
    func stepBrightness(by delta: Double) -> Bool {
        guard let panel = DisplayBrightness.builtIn,
              let current = DisplayBrightness.level(of: panel) else { return false }
        let pending = pendingBrightness.flatMap { Date().timeIntervalSince($0.at) < 0.5 ? $0.level : nil }
        let next = Self.stepped(pending ?? current, by: delta)
        guard DisplayBrightness.setLevel(next, of: panel) else { return false }
        pendingBrightness = (next, Date())
        display(.brightness, level: next, device: Self.displayName(of: panel))
        onChange()
        return true
    }

    /// Reads the current brightness without changing it.
    func showBrightness() {
        guard let panel = DisplayBrightness.builtIn,
              let current = DisplayBrightness.level(of: panel) else { return }
        display(.brightness, level: current, device: Self.displayName(of: panel))
        onChange()
    }

    /// "Built-in Retina Display", as System Settings calls it.
    private static func displayName(of display: CGDirectDisplayID) -> String {
        NSScreen.screens.first { $0.displayID == display }?.localizedName ?? "Built-in Display"
    }

    /// One step from `level`, landing on the step grid the way macOS does, so a
    /// level set elsewhere (say 0.53) does not stay off the notches for good.
    nonisolated static func stepped(_ level: Double, by delta: Double) -> Double {
        let step = abs(delta)
        guard step > 0 else { return level }
        return min(max(((level + delta) / step).rounded() * step, 0), 1)
    }
}
