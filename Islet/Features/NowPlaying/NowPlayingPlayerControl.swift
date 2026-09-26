import AppKit

/// Carries the island's controls to Spotify or Music whenever the island shows them,
/// however it heard of them: MediaRemote's commands go to whichever app macOS has
/// elected as now playing, which may be another app entirely.
///
/// These are the Apple Events AppleScript sends for `playpause`, `next track`,
/// `previous track` (Music's `back track`) and `set player position`, built
/// directly: NSAppleScript cannot
/// run two scripts at once, and the Music library runs its own on another queue.
/// They are addressed to the running process, so a command can never relaunch a
/// player that has quit.
///
/// Each blocks on the player, so they run one at a time on a private serial queue.
/// None ever waits on the person: the Automation prompt macOS shows the first time
/// Islet controls an app is raised from a queue of its own, and the press that
/// raised it goes the MediaRemote way meanwhile. The prompt can land on another
/// Space, out of sight, and a control waiting on it would hold every control
/// behind it until someone found it. Only a press in the island may raise it: a
/// command from a Shortcut or a script could raise it with nobody looking. Until
/// macOS has said yes, and once refused, a command is unavailable this way, and the
/// caller tries MediaRemote instead.
enum NowPlayingPlayerControl {
    private static let queue = DispatchQueue(
        label: "com.ayush.Islet.playerControl", qos: .userInitiated, autoreleaseFrequency: .workItem
    )
    /// Where the Automation prompt is raised, and waited on for as long as the person
    /// takes. Kept apart from `queue`, so an unanswered prompt holds up no control.
    private static let consentQueue = DispatchQueue(label: "com.ayush.Islet.playerControl.consent", qos: .utility)
    /// Players whose prompt is up, so another press does not queue a second one.
    /// Touched only on `consentQueue`, and on `queue` under `consentLock`.
    private static var askingConsent: Set<String> = []
    private static let consentLock = NSLock()

    /// Long enough for a busy player; short enough that a hung one does not hold up
    /// the controls queued behind it for long.
    private static let timeout: TimeInterval = 5
    /// `errAETimeout`, which the SDK no longer names.
    private static let timedOut = -1712

    /// Calls `completion`, on the private queue, with how it went. `mayPrompt` lets
    /// macOS ask the person, if they have not decided yet.
    static func send(
        _ command: NowPlayingCommand, to player: NowPlayingBroadcastPlayer, mayPrompt: Bool,
        completion: @escaping @Sendable (NowPlayingDelivery) -> Void
    ) {
        queue.async { completion(perform(command, on: player, mayPrompt: mayPrompt)) }
    }

    /// Whether these players have an Apple Event for the command at all.
    static func carries(_ command: NowPlayingCommand) -> Bool {
        switch command {
        case .togglePlayPause, .next, .previous, .seek: true
        case .jumpBack, .jumpForward, .shuffle, .repeatMode: false
        }
    }

    /// Unavailable when the event never left: the player is not running, or Islet may
    /// not automate it (or may not yet, and must not ask). Once it has left, a timeout
    /// or the player's own error is a failure, since the player may yet act on it and a
    /// second way would repeat it.
    private static func perform(
        _ command: NowPlayingCommand, on player: NowPlayingBroadcastPlayer, mayPrompt: Bool
    ) -> NowPlayingDelivery {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first,
              let event = event(for: command, to: player, process: app.processIdentifier),
              permission(for: event, to: player, askingUser: mayPrompt) == noErr
        else { return .unavailable }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: .waitForReply, timeout: timeout)
        } catch {
            return (error as NSError).code == timedOut ? .failed : .unavailable
        }
        // An error the player raised comes back in the reply.
        let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        return error == noErr ? .delivered : .failed
    }

    /// Whether Islet may send this event to the player, never waiting on the person.
    /// An undecided person is `errAEEventWouldRequireUserConsent`; with `askingUser`,
    /// the prompt goes up from `consentQueue`, and this command is left to MediaRemote.
    private static func permission(
        for event: NSAppleEventDescriptor, to player: NowPlayingBroadcastPlayer, askingUser: Bool
    ) -> OSStatus {
        let status = determinePermission(eventClass: event.eventClass, eventID: event.eventID, to: player, asking: false)
        if status == errAEEventWouldRequireUserConsent, askingUser {
            askConsent(eventClass: event.eventClass, eventID: event.eventID, to: player)
        }
        return status
    }

    /// Raises the Automation prompt for the player unless it is already up, and waits
    /// on it off the control queue. The answer is macOS's to keep: the next press
    /// finds it.
    private static func askConsent(eventClass: AEEventClass, eventID: AEEventID, to player: NowPlayingBroadcastPlayer) {
        consentLock.lock()
        let isNew = askingConsent.insert(player.bundleID).inserted
        consentLock.unlock()
        guard isNew else { return }
        consentQueue.async {
            let status = determinePermission(eventClass: eventClass, eventID: eventID, to: player, asking: true)
            NowPlayingRouting.log.notice(
                "Automation prompt for \(player.bundleID, privacy: .public) answered: \(status, privacy: .public)"
            )
            consentLock.lock()
            askingConsent.remove(player.bundleID)
            consentLock.unlock()
        }
    }

    private static func determinePermission(
        eventClass: AEEventClass, eventID: AEEventID, to player: NowPlayingBroadcastPlayer, asking: Bool
    ) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(address, eventClass, eventID, asking)
        }
    }

    /// The event for a command, or `nil` for one these players have no event for
    /// (see `carries`). Their own notifications report no shuffle, repeat or jumps, so
    /// those controls only appear when MediaRemote reports them, and go that way.
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
