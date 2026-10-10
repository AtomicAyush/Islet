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
        case .appearance:
            SettingsSearchTerms(
                labels: ["Island colour", "Accent", "Feature colours", "Mono", "Custom island colour", "Custom accent",
                         "Back to black and feature colours", "Reset", "Fill", "Solid", "Gradient", "Rotating", "Palette",
                         "Tone", "Deep", "Bright", "Direction", "Down", "Across", "Diagonal", "Speed", "Slow", "Medium",
                         "Fast", "Drawn as", "Ring", "Steady", "Ring colour", "Island's colours", "Thickness", "Thin",
                         "Regular", "Bold", "Glow", "Brightness", "Hold still while the screen is shared or recorded",
                         "Change colour", "Never", "Continuously", "Once an hour", "Once a day", "Colours",
                         "Add a colour", "Add", "Order", "In turn", "Shuffled"]
                    + IslandColourPreset.allCases.map(\.name) + AccentChoice.presets.map(\.name)
                    + IslandPalettePreset.allCases.map(\.name),
                keywords: ["appearance", "colour", "color", "colours", "colors", "theme", "tint", "accent colour",
                           "accent color", "highlight", "light", "dark", "dark mode", "light mode", "background",
                           "notch", "notch colour", "notch color", "colour scheme", "color scheme", "customise",
                           "customize", "rgb", "led", "leds", "light strip", "rainbow", "border", "outline", "edge",
                           "halo", "neon", "ring light", "animated", "animation", "cycle", "colour cycle",
                           "color cycle", "fade", "rotate", "rotation", "chase", "ombre", "reduce motion",
                           "readable", "readability", "legible", "contrast", "hard to read", "shade", "darker",
                           "change color", "every day", "each day", "daily", "every hour", "hourly", "schedule",
                           "scheduled", "midnight", "colour of the day", "color of the day", "shuffle", "random",
                           "rotate between", "list of colours", "list of colors", "playlist"]
            )
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
        case .bubblePlacement:
            SettingsSearchTerms(
                labels: BubblePlacement.allCases.map(\.title) + [
                    "Right of the island, then left, in turn, as the menu bar has room. On the left they keep clear of the app's menus, which needs Accessibility.",
                ],
                keywords: ["bubbles", "left side", "right side", "split", "both sides", "menus", "live activities"]
            )
        case .saveEnergy:
            // Only the choices' titles, not their footnotes: with the waveform, lyrics and
            // the player among the labels, "music" or "lyrics" would find this before Now
            // Playing. "On battery" is a keyword for the same reason: as a label, "low
            // battery" would find this before Battery.
            SettingsSearchTerms(
                labels: SaveEnergy.allCases.filter { $0 != .onBattery }.map(\.title),
                keywords: [SaveEnergy.onBattery.title, "battery", "battery saver", "low power mode", "low power",
                           "power saving", "energy saver", "battery life", "animations", "animation", "waveform",
                           "spinner", "lyrics", "still"]
            )
        case .islandOrder:
            // Of Now Playing's players (`NowPlayingFeature.players`) only Spotify: with
            // "Apple Music" among the labels, "music" would find this before Now Playing.
            SettingsSearchTerms(
                labels: [IslandOrderSection.footer, IslandOrderSection.untilArranged, "In the island", "In a bubble",
                         "Spotify", "Reset"],
                keywords: ["island order", "order", "priority", "pin", "pinned", "main island", "main bubble", "main",
                           "primary", "first", "top", "always", "centre", "center", "favourite", "favorite",
                           "which activity", "choose", "arrange", "reorder", "live activities", "music", "player",
                           "Show in Island", "Keep in Island", "Let Islet Choose"]
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
                     "Colour with the artwork", "Using the accent colour", "Lyrics", "Look up lyrics for every song",
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
            labels: ["Approve from the island", "Open the island for each request", "Approvals key", "Set Up",
                     "Reset Key", "Show what you asked", "Show the git branch", "Skip Done when the chat is on screen",
                     "Hooks", "Last heard from Claude Code", "Show usage limits", "Warn at 80% and 95%",
                     "Usage ring in the compact island", "Refresh Claude usage when it's old", "Last reading",
                     "AI Usage"],
            keywords: ["hooks", "agents", "subagents", "workflows", "terminal", "sessions", "prompt", "coding",
                       "approve", "allow", "deny", "permission", "always allow", "key", "keychain", "done", "finished",
                       "banner", "popup", "notification", "on screen", "chat", "git", "branch", "folder", "repository",
                       "usage", "limits", "rate limit", "quota", "5-hour", "weekly", "plan", "usage tile",
                       "refresh", "stale", "old", "claude app"]
        )
    }
}

extension ChatGPTFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Approve from the island", "Open the island for each request", "Approvals key", "Set Up",
                     "Reset Key", "Wait in the island", "Wait longer for ChatGPT", "Copy Line", "Show what you asked",
                     "Show the git branch", "Skip Done when the chat is on screen", "Hooks", "Last heard from ChatGPT",
                     "Show usage limits", "Warn at 80% and 95%", "Usage ring in the compact island", "ChatGPT plan",
                     "AI Usage"],
            keywords: ["chatgpt", "codex", "openai", "gpt", "hooks.json", "hooks", "trust", "approve", "agents",
                       "subagents", "plan", "chats", "prompt", "coding", "progress", "tasks", "terminals",
                       "background commands", "goal", "queued", "allow", "deny", "permission", "always allow",
                       "key", "keychain", "wait", "done", "replied", "banner", "popup", "notification", "on screen",
                       "git", "branch", "folder", "repository", "usage", "limits", "rate limit", "quota", "5-hour",
                       "weekly", "credits", "plus", "usage tile"]
        )
    }
}

extension GeminiFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Show what you asked", "Show the git branch", "Skip Done when the chat is on screen",
                     "Antigravity hooks", "Copy Hooks", "Islet's hook", "Last heard from Gemini", "Gemini CLI hooks",
                     "Islet's Gemini CLI hook", "Last heard from Gemini CLI", "Show usage limits", "Warn at 80% and 95%",
                     "Usage ring in the compact island", "Gemini quota", "AI Usage"],
            keywords: ["gemini", "antigravity", "google", "agents", "agent manager", "hooks.json", "hooks",
                       "gemini cli", "cli", "settings.json", "terminal", "iterm", "tab", "sessions", "prompt",
                       "permission", "approval", "trust", "trusted folders", "plan", "question",
                       "conversations", "tasks", "task list", "progress", "quota", "limit", "error", "done",
                       "finished", "banner", "popup", "notification", "on screen", "accessibility", "coding", "git",
                       "branch", "workspace", "repository", "usage", "limits", "rate limit", "model quota", "usage tile"]
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
            labels: ["Show finished downloads", "Show PDFs saved from Print", "Desktop, Documents and iCloud Drive",
                     "Ask macOS", "Open Privacy Settings…", "Check again", "Follows downloads into"],
            keywords: ["safari", "chrome", "firefox", "browser", "progress", "download folder", "delete", "remove", "trash",
                       "upload", "print", "printed", "printing", "pdf", "save as pdf", "print to pdf", "⌘P", "cmd p",
                       "command p", "brave", "export", "saved", "permission", "access", "privacy", "files and folders",
                       "full disk access", "icloud", "desktop", "documents"]
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
            labels: ["Show screenshots here at once", "Delete after copying", "Screenshots are saved to"],
            keywords: ["screen capture", "screencap", "capture", "floating thumbnail", "markup", "cmd shift 4", "trash",
                       "delete", "copy", "clipboard"]
        )
    }
}

extension ClipboardFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Remember", "Keep history between launches", "Clear when the Mac locks", "Clear everything copied"],
            keywords: ["copy", "paste", "pasteboard", "history", "copied", "pinned", "password manager", "drag",
                       "drag out", "keep open", "stay open"]
        )
    }
}

extension QuickAskFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Answer with", "On this Mac", "ChatGPT", "Claude", "Gemini", "Shortcut", "Connect Claude", "Connect",
                     "Token", "Remove", "Copy", "Ask anything", "Ask", "Ask ChatGPT", "Ask Claude", "Ask Gemini",
                     "Try again", "None",
                     "Look at my screen", "Front window", "Whole display", "Screen Recording", "Open System Settings",
                     "Let Apple's model read your calendar", "Ask Apple's model"],
            keywords: ["ai", "assistant", "chatgpt", "gpt", "openai", "codex", "claude", "anthropic", "haiku",
                       "gemini", "gemini cli", "google", "flash", "flash-lite", "quota",
                       "keep open", "stay open", "stay", "pin", "keep answer", "read while typing", "type elsewhere",
                       "apple intelligence", "on-device", "llm", "question", "chat", "quick question", "hotkey",
                       "keyboard shortcut", "private", "spotlight", "screen", "screenshot", "look", "see", "image",
                       "picture", "window", "display", "vision", "screen capture", "calendar", "free", "busy", "available",
                       "availability", "schedule", "events", "meetings"]
        )
    }
}

extension QuickCalendarFeature {
    var searchTerms: SettingsSearchTerms {
        SettingsSearchTerms(
            labels: ["Add events to", "Default calendar", "Default length", "Ask about missing details", "After",
                     "Travel time", "Your day", "From", "To", "Calendars to check", "All calendars",
                     "Tell me about clashes", "Calendar access", "New event", "Location", "Notes", "All day", "Add",
                     "Undo", "Not now", "Don't ask", "Allow Calendar access", "Today", "Tomorrow", "Summarise",
                     "Show day"],
            keywords: ["schedule", "add event", "new event", "quick add", "meeting", "appointment", "conflict", "clash",
                       "double booked", "overlap", "free time", "free", "busy", "availability", "agenda", "summarise",
                       "summarize", "summary", "day overview", "my day", "travel", "commute", "reminder", "follow up",
                       "location", "place"]
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
