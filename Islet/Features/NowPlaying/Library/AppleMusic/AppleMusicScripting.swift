import AppKit

/// What macOS says about Islet sending Apple Events to Music.
enum AppleMusicAccess: Equatable, Sendable {
    case allowed
    /// The person has not been asked yet.
    case notAsked
    case denied
    /// Music is not open, and macOS only answers about a running app.
    case notRunning
    case failed(OSStatus)

    init(_ status: OSStatus) {
        switch Int(status) {
        case Int(noErr): self = .allowed
        case errAEEventWouldRequireUserConsent: self = .notAsked
        case errAEEventNotPermitted: self = .denied
        case procNotFound: self = .notRunning
        default: self = .failed(status)
        }
    }
}

/// A script that did not work, with AppleScript's error number or one of the
/// scripts' own.
struct AppleMusicScriptError: Error, Equatable {
    let code: Int

    /// The playlist asked for is no longer in the library.
    static let playlistGone = 9001
    /// Playlists came or went while the library was being read.
    static let libraryChanged = 9002
    /// The answer was not in the shape the script returns.
    static let unreadable = 9003

    var message: String {
        switch code {
        case procNotFound, connectionInvalid: "Music isn’t open."
        case errAEEventNotPermitted: AppleMusicScripting.deniedAdvice
        case errAEEventWouldRequireUserConsent: "Allow Islet to control Music first."
        case errAETimeout: "Music didn’t answer in time."
        case Self.playlistGone: "That playlist isn’t in your library any more."
        case Self.libraryChanged: "Your playlists changed while they were loading. Try again."
        case Self.unreadable: "Music’s answer couldn’t be read."
        default: "Music couldn’t do that (error \(code))."
        }
    }

    /// Whether the failure says something about Music running or Islet's
    /// permission, so the library's state is worth reading again.
    var concernsAccess: Bool {
        [procNotFound, connectionInvalid, errAEEventNotPermitted, errAEEventWouldRequireUserConsent].contains(code)
    }
}

/// Talks to the Music app in AppleScript.
///
/// Everything here blocks, on Music or on the person deciding whether Islet may
/// control it, so it all runs on one private serial queue: never on the main thread,
/// and never two scripts at once, which NSAppleScript does not allow. Scripts only
/// run once macOS has already said yes, so the permission prompt can only ever come
/// from `access(askingUser: true)`, and they check Music is open before addressing
/// it, so they never launch it.
enum AppleMusicScripting {
    static let bundleIdentifier = "com.apple.Music"

    static let deniedAdvice = "Allow Islet to control Music in System Settings > Privacy & Security > Automation."

    private static let queue = DispatchQueue(
        label: "com.ayush.Islet.appleMusic", qos: .userInitiated, autoreleaseFrequency: .workItem
    )

    /// Whether Music is open; safe from any thread.
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Whether Islet may control Music. With `askingUser`, macOS asks the person if
    /// they have not decided yet, and this waits for their answer.
    static func access(askingUser: Bool) async -> AppleMusicAccess {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: AppleMusicAccess(permission(askingUser: askingUser)))
            }
        }
    }

    /// The playlists in the sidebar that have something in them, in Music's order.
    static func playlists() async throws -> [MediaPlaylist] {
        try await onQueue {
            try requireAccess()
            return try playlists(from: run(playlistsSource))
        }
    }

    /// Starts the playlist with this persistent ID from the top.
    static func play(playlistID: String) async throws {
        try await onQueue {
            try requireAccess()
            _ = try run(playSource, arguments: [playlistID])
        }
    }

    // MARK: Running

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Asks macOS about every kind of event at once. Blocks while a prompt is up.
    private static func permission(askingUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(
                address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askingUser
            )
        }
    }

    /// Throws unless Music is open and Islet may already control it: a script's
    /// events would otherwise open Music, or put up the prompt.
    private static func requireAccess() throws {
        guard isRunning else { throw AppleMusicScriptError(code: procNotFound) }
        let status = permission(askingUser: false)
        guard status == noErr else { throw AppleMusicScriptError(code: Int(status)) }
    }

    /// Runs `source`, handing `arguments` to its run handler the way `osascript`
    /// does, so values never have to be spliced into the source.
    private static func run(_ source: String, arguments: [String] = []) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleMusicScriptError(code: AppleMusicScriptError.unreadable)
        }
        let parameters = NSAppleEventDescriptor.list()
        for argument in arguments {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: parameters.numberOfItems + 1)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        // On failure the result is nil despite its type, so check the error first.
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            throw AppleMusicScriptError(code: code ?? AppleMusicScriptError.unreadable)
        }
        return result
    }

    // MARK: Reading the answer

    /// Classes of playlist worth offering: the person's own, their folders, and
    /// Apple Music playlists they have added.
    private static let offeredClasses: Set<FourCharCode> = [
        fourCharCode("cUsP"), fourCharCode("cFoP"), fourCharCode("cSuP"),
    ]
    private static let folderClass = fourCharCode("cFoP")
    /// Special kinds that are the whole library under another name.
    private static let libraryKinds: Set<FourCharCode> = [fourCharCode("kSpL"), fourCharCode("kSpZ")]

    private static func playlists(from reply: NSAppleEventDescriptor) throws -> [MediaPlaylist] {
        guard let fields = Answer(reply).fields, let rows = fields["playlists"]?.items else {
            throw AppleMusicScriptError(code: AppleMusicScriptError.unreadable)
        }
        let current = fields["current"]?.text
        return rows.compactMap { row in
            guard let playlist = row.fields,
                  let id = playlist["id"]?.text, !id.isEmpty,
                  let name = playlist["name"]?.text,
                  playlist["visible"]?.flag == true,
                  let kind = playlist["class"]?.typeCode, offeredClasses.contains(kind),
                  let count = playlist["count"]?.integer, count > 0
            else { return nil }
            if let special = playlist["kind"]?.enumCode, libraryKinds.contains(special) { return nil }

            let songs = count == 1 ? "1 song" : "\(count.formatted()) songs"
            return MediaPlaylist(
                id: id,
                name: name,
                detail: kind == folderClass ? "Folder · \(songs)" : songs,
                isCurrent: id == current
            )
        }
    }

    // MARK: Scripts

    /// Errors that mean no further event will get through, as AppleScript list items.
    private static let fatalErrors = [
        procNotFound, connectionInvalid, errAETimeout, errAEEventNotPermitted, errAEEventWouldRequireUserConsent,
    ].map(String.init).joined(separator: ", ")

    /// Reads each property for every playlist in one event, rather than one event
    /// per playlist per property; only the track counts go one by one. Music is
    /// checked again before each, since an event sent after it quits would reopen it.
    /// A playlist that cannot be counted is left out, but Music quitting, hanging or
    /// withdrawing permission ends the whole read.
    private static let playlistsSource = """
        if application id "\(bundleIdentifier)" is not running then error number \(procNotFound)
        set currentID to ""
        with timeout of 10 seconds
            tell application id "\(bundleIdentifier)"
                try
                    set currentID to persistent ID of current playlist
                end try
                set refs to every playlist
                set theIDs to persistent ID of every playlist
                set theNames to name of every playlist
                set theClasses to class of every playlist
                set theKinds to special kind of every playlist
                set theVisible to visible of every playlist
            end tell
        end timeout
        set total to count refs
        repeat with values in {theIDs, theNames, theClasses, theKinds, theVisible}
            if (count values) is not total then error number \(AppleMusicScriptError.libraryChanged)
        end repeat
        set rows to {}
        repeat with i from 1 to total
            set trackCount to 0
            if item i of theVisible is true then
                if application id "\(bundleIdentifier)" is not running then error number \(procNotFound)
                set aPlaylist to item i of refs
                try
                    with timeout of 10 seconds
                        tell application id "\(bundleIdentifier)" to set trackCount to count tracks of aPlaylist
                    end timeout
                on error message number errorNumber
                    if {\(fatalErrors)} contains errorNumber then error message number errorNumber
                end try
            end if
            set end of rows to {|id|:item i of theIDs, |name|:item i of theNames, |class|:item i of theClasses, |kind|:item i of theKinds, |visible|:item i of theVisible, |count|:trackCount}
        end repeat
        return {|current|:currentID, |playlists|:rows}
        """

    private static let playSource = """
        on run {playlistID}
            if application id "\(bundleIdentifier)" is not running then error number \(procNotFound)
            with timeout of 10 seconds
                tell application id "\(bundleIdentifier)"
                    set matches to every playlist whose persistent ID is playlistID
                    if matches is {} then error number \(AppleMusicScriptError.playlistGone)
                    play item 1 of matches
                end tell
            end timeout
        end run
        """
}

// MARK: - Answers

// Nested rather than extending NSAppleEventDescriptor or declared at file scope, so
// nothing here can clash with another file's helpers of the same name.
extension AppleMusicScripting {
    fileprivate static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// A value in a script's answer, read as the scripts write them.
    fileprivate struct Answer {
        let descriptor: NSAppleEventDescriptor

        init(_ descriptor: NSAppleEventDescriptor) {
            self.descriptor = descriptor
        }

        /// A record's fields by label, lower-cased, since AppleScript does not care
        /// about case. Only labels a script made up itself (`|name|`), which is all
        /// these scripts use; `nil` if this is not a record.
        var fields: [String: Answer]? {
            guard descriptor.descriptorType == DescType(typeAERecord) else { return nil }
            // They arrive as one list of alternating labels and values.
            guard let pairs = descriptor.forKeyword(fourCharCode("usrf")).flatMap({ Answer($0).items }) else {
                return [:]
            }
            var fields: [String: Answer] = [:]
            for index in stride(from: 0, to: pairs.count - 1, by: 2) {
                if let label = pairs[index].descriptor.stringValue {
                    fields[label.lowercased()] = pairs[index + 1]
                }
            }
            return fields
        }

        /// `nil` if this is not a list.
        var items: [Answer]? {
            guard descriptor.descriptorType == DescType(typeAEList) else { return nil }
            return stride(from: 1, through: descriptor.numberOfItems, by: 1).compactMap { index in
                descriptor.atIndex(index).map(Answer.init)
            }
        }

        /// AppleScript's `missing value`.
        var isMissingValue: Bool {
            descriptor.descriptorType == DescType(typeType) && descriptor.typeCodeValue == fourCharCode("msng")
        }

        var text: String? {
            isMissingValue ? nil : descriptor.stringValue
        }

        var integer: Int? {
            guard !isMissingValue, let number = descriptor.coerce(toDescriptorType: DescType(typeSInt32)) else {
                return nil
            }
            return Int(number.int32Value)
        }

        var flag: Bool? {
            descriptor.coerce(toDescriptorType: DescType(typeBoolean))?.booleanValue
        }

        /// A class, such as `user playlist`.
        var typeCode: FourCharCode? {
            descriptor.descriptorType == DescType(typeType) ? descriptor.typeCodeValue : nil
        }

        /// An enumerated value, such as a special kind.
        var enumCode: FourCharCode? {
            descriptor.descriptorType == DescType(typeEnumerated) ? descriptor.enumCodeValue : nil
        }
    }
}
