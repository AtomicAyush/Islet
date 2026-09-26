# Islet

A Dynamic Island for the Mac notch.

On the iPhone, the island is the one piece of the screen that is always about what is
happening right now: music playing, a timer running, AirPods connecting. Islet does the
same with the MacBook's camera notch. It rests as the notch itself, widens either side of
the camera while something is going on, and opens into a card when the pointer rests on it.

## What it shows

**Now Playing.** Whatever the Mac is playing — Music, Spotify, a browser — with the artwork
left of the camera and a waveform on the right, tinted with the cover's colour. Opened, it
is a player: artwork, a scrolling title, a scrubber you can drag, and the controls, with
shuffle and repeat where the player reports them. The button at the end of the controls lists
the Mac's outputs as the Sound menu does — its speakers, AirPods with each bud's and the case's
battery, a display, USB or HDMI — with the volume above them, and moves the sound to the one
you click; macOS lets only its own Sound menu and Sound settings list AirPlay receivers, so for
those the last row opens Sound settings. A song change gets a moment's banner. On macOS 15 and
later, once Islet may record system audio (the permission the Sound Mixer asks
for), the waveform follows the music itself, bass on the left and cymbals on the right, in time
with what you hear; macOS shows its purple recording indicator while it listens. Without that,
or with "Waveform follows the music" off, the bars dance on Core Animation as before.

Video gets its own look — YouTube in a browser, the TV app, QuickTime, IINA, VLC: a 16:9
thumbnail and a progress ring beside the notch, and 15-second jumps in the player.

With a music app that has a library, the player also opens **Up Next** (tap a track to jump
to it) and **Playlists** (tap one to switch, or its **+** to add the song playing to it), and
a heart at the start of the controls saves the song:

- *Spotify* needs a one-time sign-in through a Spotify app of your own, since Spotify only
  lets registered apps read your queue: create one at
  [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) with the Web
  API, add the redirect URI `islet://nowplaying/spotify-callback`, paste its client ID in
  Settings → Activities → Now Playing, and click Connect. Spotify requires the app's owner
  to have Premium. Spotify's Jam has no public API, so the Jam button brings Spotify
  forward. The heart adds the song to Liked Songs, and **+** sits beside your own playlists
  and ones you collaborate on. Both need permissions a sign-in from before they arrived was
  not given, so if you connected Spotify earlier, the player asks you to reconnect the first
  time you open it on a Spotify song, and Settings offers it too from then on. Spotify would
  put a song in a playlist twice; Islet only holds back a second add of its own while the
  playlist is otherwise unchanged.
- *Music* asks once for permission to control Music. It offers playlists, and a star for
  Favourites; Music does not expose Up Next to other apps, and adding to playlists is left
  to Music, since a song streamed from Apple Music has to be in your library first.

**Timer.** Start one from the opened island (or `islet://timer/start?minutes=5`) and it counts
down beside the notch in the Clock app's orange; opened, it pauses and cancels. When it ends
the island rings, with the last length one click away.

**Battery.** The iPhone's charging flash when you plug in — "Charging" on one side, the
level and a green battery on the other — and warnings as the battery runs low. Full charge,
Low Power Mode and unplugging can be announced too.

**Volume & Brightness.** Replaces the system overlay with a slim bar in the island, naming the
device being changed ("AirPods Max", "Built-in Retina Display"), the way macOS does. While the
island is showing something else, such as a song or a timer, the bar joins it in a slim row
underneath instead of taking its place. Needs Accessibility (called Device Control and Data
Access from macOS 27), so it is off until you turn it on.

**Headphones.** AirPods and other headphones connecting, as a card with a battery ring for
each earbud and the case. Connections are read from CoreAudio, so they need no permission;
exact levels (and the only levels for AirPods Max) come over Bluetooth once you allow it.
macOS shows its own "Connected" notification for them from a source it hides from System
Settings; Islet can install a profile that turns it off.

**Calendar.** Your next event counts down beside the notch from ten minutes before it
starts, with a Join button when there is a Zoom, Meet, Teams, Webex or FaceTime link.

**Camera, Microphone & more.** A green dot beside the notch while the camera is in use, an
orange one while only a microphone is — as on the iPhone — and a purple one while an app
records the screen or what the Mac plays. Turn on Location in Settings for an arrow while an
app gets the Mac's location (it is off at first: a single look-up lights it for about twelve
seconds). The home page says what is in use and which app is using it — "Microphone · Zoom",
"Screen · QuickTime Player" — as does a click on any of these dots or the arrow, and Islet can
name the app for a moment as it starts. Whether a
sensor is in use comes from the system itself and needs no permission. The microphone's app
comes from Core Audio; the rest of the names, and location and recorded sound at all, come from
the system log, which macOS only shows to administrator accounts. On any other account only
microphone apps are named, the camera and screen show as in use (screen mirroring can light the
purple dot there), and recorded sound and location aren't shown. The Sound Mixer records what
the Mac plays to set each app's volume, which macOS marks with its own purple dot; Islet never
lights a dot for it.

**Focus.** While Do Not Disturb, Sleep, Work or a Focus of your own is on, its symbol stays
beside the notch in its colour, the home tile says which and until when, and song changes go
unannounced. macOS shows a banner of its own for every Focus change, so Islet's iPhone-style
"On" and "Off" banner is off unless you turn it on in Settings. macOS keeps which Focus is on in a database only apps with Full Disk Access
may read, so this needs Full Disk Access; until it has it, the home tile says so. Nor can
other apps turn Focus on or off, so clicking the tile runs a shortcut of yours: make one with
the Set Focus action set to toggle Do Not Disturb, and pick it in Settings. Click the Focus's
symbol for which Focus is on and until when, with Turn Off for Do Not Disturb once that
shortcut is picked.

**Shortcuts.** While a shortcut runs, its icon sits left of the camera and a spinner right of
it, as on the iPhone; a tick or a cross shows as it ends, and the island gives itself back.
Opened, it says which shortcut is running and for how long, and offers Stop for one Islet
started. Pin up to six shortcuts to the home page and click one to run it; text a shortcut
hands back comes up in a card, to read or copy. Runs started anywhere else — the Shortcuts
app, the menu bar, Spotlight, Siri, an automation — show too: Islet notices them in
Shortcuts' database, which, like the shortcuts' icons, needs Full Disk Access. Without it the
island shows only the runs Islet starts, and shortcuts by name on a plain tile. macOS still
shows its own indicator in the menu bar while a shortcut runs, whoever started it (Islet
included), and has no setting to hide it; it goes a few seconds after the shortcut ends.

**Show in Islet.** Banners of your own, from anything that can open a URL or run a shortcut:
a build finishing, tests passing or failing, Claude Code done with a long task. A symbol and a
title beside the notch, with a subtitle on the right, or a card with a few lines under the
title, in the colour you choose. They are text only, with nothing to click, and kept to a pace
you can read; see [Banners from scripts](#banners-from-scripts).

**Sound Mixer.** Every app playing sound, each with its own volume (0–150%) and a mute, in
the opened island and on the home page. When two apps play at once, the mixer takes the
bubble beside the island. macOS has no per-app volume, so Islet makes one with Core Audio
process taps (macOS 14.2 or later): the first time you move a slider, macOS asks to let Islet
record system audio, which is how it passes the app's sound through at the level you set.

**Drop Zone.** Drag files — or pictures straight from a web page — toward the notch and the
island opens onto two targets: AirDrop, and a shelf that keeps them for later. A picture
from Safari, Chrome or another browser, Google Images results included, arrives as an
ordinary image file under the name the site gave it; the shelf keeps its own copy and
deletes it when the picture comes off the shelf. Ordinary links and text selections leave
the island shut. Shelved files show on the home page and drag back out wherever they are
needed; right-click one to save a copy to Downloads.

Every feature can be turned off, and each has previews in the menu bar item, so you can see
what it looks like without waiting for the real thing.

## How it behaves

**It is the notch until something happens.** At rest the island is drawn exactly over the
camera housing — 185 × 32 points on a 14-inch MacBook Pro, measured from the screen's
safe-area inset and the two unobscured corners beside it — so it is invisible. Its top
corners flare out into the menu bar the way the housing's own corners do.

**Live activities sit either side of the camera.** Something ongoing — a song, a timer, a
meeting about to start — shows compactly: a glance on the left of the notch, a glance on the
right, and the camera in the gap. When the two sides differ in width, the island shifts so
the gap stays exactly over the camera.

**A second activity gets the bubble.** As on the iPhone, when two things are running the
more important one keeps the island and the other buds off into a circle beside it. The two
are drawn through a blur and an alpha threshold while they are close, so a neck of black
joins them, stretches and snaps as the bubble springs out — and forms again when it merges
back. Where the menu bar's icons leave no room for the bubble, the second activity folds into
the island instead, as a small circle at its left end. macOS 27 draws the whole menu bar as
one window, so there Islet finds the icons through Accessibility when it has it, and
otherwise folds rather than risk covering them.

**Rest the pointer on it to open it.** The island stretches sideways a beat before it drops,
with a small squash and rebound, and its content arrives out of a blur. There is a tab for
each running activity and one for the home page. It closes when the pointer leaves or on a
click anywhere else; a two-finger swipe down opens it. Clicking works too, if you would rather
it did not open on hover.

**Alerts take it over for a moment.** Plugging in a charger, AirPods connecting, a timer
finishing: the island widens or drops into a card, then gives itself back.

**It never gets in the way of a click.** The island's window is a fixed transparent canvas,
and a transparent window only catches clicks on the pixels it has drawn — so the menu bar
beside the island and whatever is underneath the canvas stay clickable. (Writing
`ignoresMouseEvents` at all, even to `false`, turns that off and makes the whole canvas catch
clicks; Islet never touches it.)

**Other displays.** On a display without a notch the island floats as a pill just below the
top edge, like the iPhone's, and hides when there is nothing to show. It can follow the
notched display, the main display, or appear on all of them, and it steps aside while an app
is full screen. Stepped aside, it still opens when the pointer rests on the notch (on a display
without one, on the middle of the top edge), and hides again once the pointer leaves.

## Building

Requires macOS 14 or later and Xcode 16 or later.

```bash
./install.sh
```

builds a Release copy, signs it with your Apple Development certificate if you have one, and
installs it to `/Applications`. A stable signature matters: macOS remembers Accessibility,
Calendar and Full Disk Access permission against the signature, and an ad-hoc one changes with
every build.

## Scripting

Islet answers `islet://` URLs, so Shortcuts, scripts and the terminal can drive it:

| URL | Does |
|---|---|
| `islet://open` | Opens the island on the screen under the pointer |
| `islet://open?focus=timer` | Opens it on a particular activity (or `home`) |
| `islet://close` | Closes it |
| `islet://timer/start?minutes=5` | Starts a timer (`seconds=` works too) |
| `islet://timer/pause`, `/resume`, `/cancel` | |
| `islet://preview?feature=battery&index=0` | Runs a feature's preview |
| `islet://nowPlaying/toggle`, `/next`, `/previous` | Controls the player |
| `islet://focus/toggle` | Turns Focus on or off with the shortcut picked in Settings |
| `islet://shortcuts/run?name=Morning%20Lights` | Runs a shortcut (`id=` takes the identifier `shortcuts list --show-identifiers` prints) |
| `islet://banner?title=Build%20finished` | Puts up a banner of your own (below) |
| `islet://banner/dismiss` | Takes it down |
| `islet://settings?tab=activities` | Opens Settings on a tab |

```bash
open "islet://timer/start?minutes=25"
```

### Banners from scripts

`islet://banner` puts up a banner. Only `title` is needed:

| Parameter | |
|---|---|
| `title` | Beside the notch, or the card's first line |
| `subtitle` | Right of the notch, in the banner's colour or grey without one; or up to three lines under a card's title |
| `symbol` | An SF Symbol, such as `checkmark.circle.fill`; a bell if macOS has none by that name, or for Apple's logo |
| `tint` | `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray` or `white`, or hex as `ff9500` or `%23ff9500` (`colour` and `color` work too) |
| `duration` | Seconds, from 1 to 30: 4 beside the notch and 6 for a card if left out |
| `style` | `compact`, beside the notch, or `card` |
| `sound` | One of the Mac's alert sounds (`Glass`, `Ping`, `Basso` and the rest of /System/Library/Sounds); silent without |
| `interruption` | `passive` lets a Focus that asks for quiet hold it back, as it does a song change |

Spaces go in as `%20` (a `+` stays a plus), and a `#` as `%23`, since a bare one ends the
query. Titles are cut at 60 characters and subtitles at 120, and a colour too dark to see on
the island's black is lightened until it shows. Nothing in a banner can be clicked, whatever
the URL says. Banners that come faster than one a second, or more than five in ten seconds,
wait their turn, and only the newest of those waiting is shown, so a script stuck in a loop
cannot keep the island flickering. With the island open, a banner shows in its header, and a
card comes as a compact one instead. Settings → Activities → Show in Islet turns them all off.

`open -g` hands the URL over without bringing anything to the front:

```bash
open -g "islet://banner?title=Build%20finished&subtitle=12%20s&symbol=hammer.fill&tint=orange"
```

In Shortcuts, the **Show in Islet** action puts up the same banner, with title, subtitle,
symbol, colour, style and duration as fields. It runs in the background, starting Islet if it
is not running, and fails with a reason if Show in Islet is turned off.

A Stop hook in `~/.claude/settings.json` flashes the island whenever Claude Code finishes. That
is after every reply, short ones too, so you may rather put it in the `.claude/settings.json`
of the projects where it works on long tasks:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "open -g 'islet://banner?title=Claude%20finished&symbol=checkmark.circle.fill&tint=green'"
          }
        ]
      }
    ]
  }
}
```

And a test run can say how it went:

```bash
swift test && open -g "islet://banner?title=Tests%20passed&symbol=checkmark.circle.fill&tint=green" \
           || open -g "islet://banner?title=Tests%20failed&symbol=xmark.octagon.fill&tint=red&sound=Basso"
```

## Layout of the code

- `Islet/Island/` — the window, the notch measurements, the shape, and the state machine
  that decides what the island shows and how big it is.
- `Islet/Activities/` — `ActivityCenter`, the single source of truth every window renders,
  and the contracts features publish through: live activities, banners, home widgets,
  indicators and the drop target.
- `Islet/Features/` — one folder per feature. Each owns its model and views and talks to
  the island only through `ActivityCenter`. The timer is the smallest and the pattern the
  rest follow.
- `Vendor/mediaremote-adapter/` — see below.

## Credits

Now Playing reads the system's media session through
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg
(BSD 3-Clause), vendored as source and compiled during the build. Since macOS 15.4
MediaRemote only answers Apple's own processes; the adapter runs under `/usr/bin/perl`,
which qualifies.

The idea of putting an island in the notch, and a good deal of what not to do, comes from
[boring.notch](https://github.com/TheBoredTeam/boring.notch). Islet is its own code.
