import AppKit

/// Carries the island's controls to Spotify or Music while the island follows the
/// player's own notifications rather than MediaRemote, whose commands would go to
/// whichever app macOS thinks is playing.
///
/// These are the Apple Events AppleScript sends for `playpause`, `next track`,
/// `previous track` (Music's `back track`) and `set player position`, built
/// directly: NSAppleScript cannot
/// run two scripts at once, and the Music library runs its own on another queue.
/// They are addressed to the running process, so a command can never relaunch a
/// player that has quit.
///
/// Each blocks — on the player, or on the person answering the Automation prompt
/// macOS shows the first time Islet controls that app — so they run one at a time
/// on a private serial queue. Once refused, a command simply fails; macOS does not
/// ask again, and nothing here retries.
enum NowPlayingPlayerControl {
    private static let queue = DispatchQueue(
        label: "com.ayush.Islet.playerControl", qos: .userInitiated, autoreleaseFrequency: .workItem
    )
    /// Long enough for a busy player; short enough that a hung one does not hold up
    /// the controls queued behind it for long.
    private static let timeout: TimeInterval = 5

    /// Calls `completion`, on the private queue, with whether the player took it.
    static func send(
        _ command: NowPlayingCommand, to player: NowPlayingBroadcastPlayer,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { completion(perform(command, on: player)) }
    }

    private static func perform(_ command: NowPlayingCommand, on player: NowPlayingBroadcastPlayer) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first,
              let event = event(for: command, to: player, process: app.processIdentifier),
              permission(for: event, to: player) == noErr,
              let reply = try? event.sendEvent(options: .waitForReply, timeout: timeout)
        else { return false }
        // An error the player raised comes back in the reply.
        let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        return error == noErr
    }

    /// Whether Islet may send this event to the player, asking the person if they
    /// have not decided yet. Blocks while the prompt is up.
    private static func permission(for event: NSAppleEventDescriptor, to player: NowPlayingBroadcastPlayer) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(address, event.eventClass, event.eventID, true)
        }
    }

    /// The event for a command, or `nil` for one the island never sends to these
    /// players: they report no shuffle, repeat or jumps of their own, so those
    /// controls are not offered.
    static func event(
        for command: NowPlayingCommand, to player: NowPlayingBroadcastPlayer, process: pid_t
    ) -> NSAppleEventDescriptor? {
        let target = NSAppleEventDescriptor(processIdentifier: process)
        func event(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor.appleEvent(
                withEventClass: eventClass, eventID: eventID, targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
            )
        }
        // Each app's own suite: Spotify's `spfy`, Music's `hook`.
        let suite = code(player == .spotify ? "spfy" : "hook")

        switch command {
        case .togglePlayPause:
            return event(suite, code("PlPs"))
        case .next:
            return event(suite, code("Next"))
        case .previous:
            // Music's `back track` restarts the song first, as the system's Previous
            // does; Spotify's `previous track` already behaves that way.
            return event(suite, code(player == .spotify ? "Prev" : "Back"))
        case .seek(let seconds):
            // set player position to <seconds>
            let property = NSAppleEventDescriptor.record()
            property.setDescriptor(
                NSAppleEventDescriptor(typeCode: DescType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass)
            )
            property.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
            property.setDescriptor(
                NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm)
            )
            property.setDescriptor(NSAppleEventDescriptor(typeCode: code("pPos")), forKeyword: AEKeyword(keyAEKeyData))
            guard let position = property.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { return nil }
            let set = event(AEEventClass(kAECoreSuite), AEEventID(kAESetData))
            set.setParam(position, forKeyword: AEKeyword(keyDirectObject))
            set.setParam(NSAppleEventDescriptor(double: max(0, seconds)), forKeyword: AEKeyword(keyAEData))
            return set
        case .jumpBack, .jumpForward, .shuffle, .repeatMode:
            return nil
        }
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
