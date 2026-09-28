import Foundation

// The words Settings search finds each General row and feature by, besides its title
// (and a feature's summary). Kept together so they can be read side by side: a word
// several share, like "volume", ranks each by where it is found, a title first.
//
// Labels are the words on the settings themselves; keywords are what else people
// call them, the apps they concern, and abbreviations.

extension GeneralRow {
    var searchTerms: SettingsSearchTerms {
        switch self {
        case .openAtLogin:
            SettingsSearchTerms(keywords: ["launch at login", "start at login", "startup", "login items", "autostart"])
        case .menuBarIcon:
            SettingsSearchTerms(
                labels: ["Settings stay in the opened island's gear and open when Islet is launched again"],
                keywords: ["menubar", "status item", "status bar", "hide icon"]
            )
        case .quit:
            SettingsSearchTerms(labels: ["Quit"], keywords: ["exit", "close Islet", "stop Islet"])
        case .hover:
            SettingsSearchTerms(
                labels: ["Delay", "Click the island to open it"],
                keywords: ["hover", "mouse", "cursor", "expand", "open on hover", "click to open"]
            )
        case .haptics:
            SettingsSearchTerms(keywords: ["haptics", "haptic", "vibration", "force touch", "tap"])
        case .homeLayout:
            SettingsSearchTerms(
                labels: HomeLayout.allCases.map(\.title),
                keywords: ["home layout", "home page", "pages", "scroll", "tiles"]
            )
        case .displays:
            SettingsSearchTerms(
                labels: DisplayChoice.allCases.map(\.title),
                keywords: ["displays", "monitor", "screen", "external display", "main display", "notch"]
            )
        case .idlePill:
            SettingsSearchTerms(keywords: ["pill", "idle", "external display", "monitor", "always show"])
        case .fullScreen:
            SettingsSearchTerms(
                labels: ["Open by resting the pointer on the notch", "Open by clicking the notch",
                         "On a display without a notch, the middle of the top edge stands in for it"],
                keywords: ["fullscreen", "full-screen", "games", "videos", "hide in full screen"]
            )
        }
    }
}

extension NowPlayingFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show song changes", "Hide after pausing", "Waveform follows the music",
                     "Tint the waveform with the artwork's colour", "Lyrics", "Look up lyrics for every song",
                     "Show the line being sung in the island", "Hinglish", "Hindi lyrics", "Original script",
                     "Look up music videos too", "Music playlists", "Music", "Spotify", "Client ID"],
            keywords: ["music", "song", "media", "player", "spotify", "apple music", "youtube", "podcast",
                       "lyrics", "karaoke", "hinglish", "devanagari", "airpods", "output", "speakers",
                       "headphones", "playlist", "waveform", "album art", "artwork", "color", "tint",
                       "spotify developer dashboard"]
        )
    }
}

extension MixerFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show when several apps play at once", "Reset all app volumes", "System audio recording"],
            keywords: ["volume", "per-app volume", "app volume", "audio", "sound", "loudness", "equaliser"]
        )
    }
}

extension TimerFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Sound when done", "First quick start", "Second quick start", "Third quick start",
                     "Fourth quick start", "Reset Quick Starts to 1, 5, 10 and 25 Minutes"],
            keywords: ["countdown", "stopwatch", "alarm", "pomodoro", "minutes", "presets", "quick start",
                       "preset"]
        )
    }
}

extension KeepAwakeFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Let the display sleep", "Show when the time runs out"],
            keywords: ["caffeinate", "caffeine", "amphetamine", "sleep", "insomnia", "prevent sleep", "awake"]
        )
    }
}

extension BatteryFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show when fully charged", "Show when the charger is removed", "Warn when the battery falls to"],
            keywords: ["charging", "charger", "power", "low battery", "plugged in", "magsafe", "percentage"]
        )
    }
}

extension SystemHUDFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show percentage", "Show the device's name", "Volume", "Brightness"],
            keywords: ["hud", "overlay", "osd", "keyboard backlight", "display brightness", "sound level"]
        )
    }
}

extension CapsLockFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show when it turns off", "Show while on"],
            keywords: ["caps", "capitals", "uppercase", "keyboard"]
        )
    }
}

extension BluetoothFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show when headphones connect", "Show when they disconnect", "Exact battery levels",
                     "macOS's own “Connected” notification"],
            keywords: ["bluetooth", "airpods", "beats", "earbuds", "earphones", "headset", "battery"]
        )
    }
}

extension InputDevicesFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show on the home page", "Show when one connects", "Warn when a battery falls to"],
            keywords: ["magic mouse", "magic keyboard", "magic trackpad", "trackpad", "game controller",
                       "bluetooth", "battery", "peripherals"]
        )
    }
}

extension CalendarFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show an event", "Minutes before it starts", "Show Join button for video calls", "Calendar access",
                     "Join beside the notch"],
            keywords: ["events", "meetings", "schedule", "agenda", "zoom", "google meet", "teams", "facetime",
                       "reminder"]
        )
    }
}

extension WeatherFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Temperature", "Warn before rain starts", "Use this Mac's location", "Location access",
                     "Place", "Search for a city", "City name"],
            keywords: ["rain", "forecast", "temperature", "celsius", "fahrenheit", "umbrella", "open-meteo", "city",
                       "town", "where"]
        )
    }
}

extension PrivacyFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Camera", "Microphone", "Screen & system audio", "Location", "Say which app",
                     "Don't show for location", "Show all apps that can use location"],
            keywords: ["privacy", "indicator", "orange dot", "green dot", "purple dot", "webcam", "mic",
                       "screen recording", "location services", "recording", "ignore", "find my"]
        )
    }
}

extension MicMuteFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show on the home page", "Mute with a key", "Microphone"],
            keywords: ["mute", "unmute", "microphone", "mic", "push to talk", "keyboard shortcut", "calls"]
        )
    }
}

extension FocusFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show while on", "Announce Focus changes", "Quiet minor alerts during Focus",
                     "Toggle Focus with", "Make a shortcut with the Set Focus action set to toggle Do Not Disturb",
                     "Open Shortcuts", "Full Disk Access"],
            keywords: ["do not disturb", "dnd", "sleep", "work", "personal", "silence", "notifications"]
        )
    }
}

extension ShortcutsFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show shortcut runs in the island", "Show runs started outside Islet", "Home tile",
                     "Shortcuts are made and changed in the Shortcuts app", "Open Shortcuts", "Full Disk Access"],
            keywords: ["automation", "workflows", "siri", "run shortcut", "favourites", "favorites"]
        )
    }
}

extension BannerFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            keywords: ["banner", "notification", "scripts", "url scheme", "islet://banner", "alert", "message"]
        )
    }
}

extension ClaudeCodeFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show what you asked", "Hooks", "Last heard from Claude Code"],
            keywords: ["hooks", "agents", "subagents", "workflows", "terminal", "sessions", "prompt", "coding"]
        )
    }
}

extension DropZoneFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Keep files on the shelf between launches"],
            keywords: ["airdrop", "shelf", "drag and drop", "drop", "files", "tray", "share"]
        )
    }
}

extension DownloadsFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show finished downloads", "Follows downloads into"],
            keywords: ["safari", "chrome", "firefox", "browser", "progress", "download folder"]
        )
    }
}

extension FileCopiesFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show copies of"],
            keywords: ["finder", "copy", "copying", "move", "transfer", "progress", "files", "size"]
        )
    }
}

extension ScreenshotsFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show screenshots here at once", "Screenshots are saved to"],
            keywords: ["screen capture", "screencap", "capture", "floating thumbnail", "markup", "cmd shift 4"]
        )
    }
}

extension ClipboardFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Remember", "Keep history between launches", "Clear when the Mac locks", "Clear everything copied"],
            keywords: ["copy", "paste", "pasteboard", "history", "copied", "pinned", "password manager"]
        )
    }
}

extension HiddenMenuBarIconsFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Also show icons that fit"],
            keywords: ["menu bar", "menubar", "status items", "bartender", "ice", "notch", "overflow"]
        )
    }
}

extension NetworkFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Going offline and coming back", "Joining another Wi-Fi network", "Wi-Fi turning on or off",
                     "A VPN connecting or disconnecting"],
            keywords: ["wifi", "wi-fi", "wireless", "network", "internet", "connection", "offline", "online",
                       "vpn", "ethernet", "ssid", "hotspot"]
        )
    }
}

extension PresentationFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Turn on while", "The screen is shared or recorded", "A call is on",
                     "Keynote or PowerPoint plays a slideshow", "Turn on yourself", "Messages from scripts and tools",
                     "Files and the clipboard", "Calendar and Focus", "Songs and lyrics", "Device and network names",
                     "Don't turn on for"],
            keywords: ["presentation", "presenting", "screen sharing", "share screen", "zoom", "meet", "teams", "facetime",
                       "call", "keynote", "powerpoint", "slideshow", "privacy", "hide", "held back", "displaylink"]
        )
    }
}

extension PomodoroFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Start breaks by themselves", "Start focus sessions by themselves", "Sound at each change",
                     "Turn on Focus while focusing", "Keep the Mac awake while focusing"],
            keywords: ["pomodoro", "tomato", "focus session", "break", "short break", "long break", "study", "work",
                       "productivity", "timer", "cycle", "25 minutes"]
        )
    }
}
