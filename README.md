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
those the last row opens Sound settings. On macOS 27, under AirPods that have them sit their
listening modes (Transparency, Adaptive, Noise Cancellation, and Off once the AirPods have been
seen allowing it) and, while something they can spatialize plays, Spatialize Stereo or Spatial
Audio: Off, Fixed or Head Tracked. Both follow changes made from the stem, Control Center or an
iPhone, and change only when you click one; Noise Cancellation and Adaptive wait for both AirPods
to be in. A song change gets a moment's banner. On macOS 15 and later, once Islet may record
system audio (the permission the Sound Mixer asks for), the waveform follows the music itself,
bass on the left and cymbals on the right, in time with what you hear; macOS shows its purple
recording indicator while it listens. Without that, or with "Waveform follows the music" off, the
bars dance on Core Animation as before.

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
  put a song in a playlist twice, so Islet looks in the playlist first, whoever added to it:
  a playlist known to have the song is ticked, and adding to one that has it asks first, as
  it does when a playlist is too long to look through or Spotify doesn't answer.
- *Music* asks once for permission to control Music. It offers playlists, and a star for
  Favourites; Music does not expose Up Next to other apps, and adding to playlists is left
  to Music, since a song streamed from Apple Music has to be in your library first.

Every song also gets a **Lyrics** button, with words from [LRCLIB](https://lrclib.net), a
free, open collection: timed lyrics light up as they are sung (click a line to play from
there; − and + fix lyrics that run early or late, and are remembered), and untimed ones show
marked "Not synced". The line being sung also shows in a slim row under the island, karaoke
style, whenever there are timed lyrics, without opening anything; the panel's microphone
turns it off. Lyrics written in Devanagari show in Hinglish — "dil", "pyaar", "zindagi" —
unless you pick the original script in Settings. Nothing is sent until you first tap Lyrics
(or turn on "Look up lyrics for every song" in Settings); after that, each track's title,
artist, album and length go to lrclib.net, and nothing else. That covers any audio reporting
a title and artist, which in a music app or a browser can include a podcast, but never the
Podcasts or Books apps or other podcast and audiobook apps, and videos only if you turn that
on in Settings → Activities → Now Playing (for titles like "Artist - Song"). Answers are
kept in Application Support/Islet/Lyrics, so a track played again sends nothing.

**Timer.** Start one from the opened island (or `islet://timer/start?minutes=5`) and it counts
down beside the notch in the Clock app's orange; opened, it pauses and cancels. When it ends
the island rings, with the last length one click away.

**Keep Awake.** Keeps the Mac from sleeping for fifteen minutes, an hour, two, or until you turn
it off, started from the home page, `islet://keepAwake/start?minutes=60` or the Keep Mac Awake
action in Shortcuts. While it runs, a cup sits left of the camera and the time left counts down
on the right (∞ until turned off). Beside music or a timer it waits in the bubble instead, and
with both it steps out of sight until one of them ends; the opened island's cup tab and the home
page still show it. Opened, it adds fifteen minutes or stops. It holds a power assertion, as
Amphetamine and `caffeinate` do, named "Islet: Keep Awake" in `pmset -g assertions`, which keeps
the display on too unless you turn on Let the display sleep in Settings. It ends at the time it
said, even if the Mac slept through that with its lid closed, and it cannot stop the Mac
sleeping when you close the lid: macOS decides that, and stays awake with the lid closed only
when power and an external display are attached. It sits alongside Amphetamine and the like: the
Mac stays awake while any of them asks, and stopping one leaves the rest as they were. Stopping
it, turning it off or quitting Islet lets the Mac sleep again, and a session is never picked
back up when Islet next opens.

**Battery.** The iPhone's charging flash when you plug in — "Charging" on one side, the
level and a green battery on the other — and warnings as the battery runs low. Full charge,
Low Power Mode and unplugging can be announced too.

**Volume & Brightness.** Replaces the system overlay with a slim bar in the island, naming the
device being changed ("AirPods Max", "Built-in Retina Display"), the way macOS does. While the
island is showing something else, such as a song or a timer, the bar joins it in a slim row
underneath instead of taking its place. Needs Accessibility (called Device Control and Data
Access from macOS 27), so it is off until you turn it on.

**Caps Lock.** Pressing Caps Lock flashes a word either side of the camera, as the iPhone does
for its Ring/Silent switch: the Caps Lock symbol and name on the left, a green "On" or a grey
"Off" on the right, never over another alert such as a timer's. Its symbol can stay beside the
notch while it is on, too. macOS says nothing when Caps Lock changes, so Islet watches the
modifier keys, which needs the same Accessibility permission as Volume & Brightness; until it
has it, the island shows nothing for Caps Lock pressed in other apps.

**Headphones.** AirPods and other headphones connecting, as a card with a battery ring for
each earbud and the case. Connections are read from CoreAudio, so they need no permission;
exact levels (and the only levels for AirPods Max) come over Bluetooth once you allow it.
macOS shows its own "Connected" notification for them from a source it hides from System
Settings; Islet can install a profile that turns it off.

**Mouse & Keyboard.** A Magic Mouse, Keyboard or Trackpad running low gets the iPhone's
low-battery warning: its name left of the camera, and its level and a battery on the right, in
orange at 20% and red at 10% and 5%, each once until it has been charged. The home page can
list each one's level, and a card can show one connecting, as for headphones. The levels are
the ones macOS keeps from each device's own report, so they need no permission. Other makes'
Bluetooth mice, keyboards and game controllers show too where macOS keeps their level; one on
its own USB receiver (Logitech's Unifying or Bolt) tells only its maker's app.

**Calendar.** Your next event counts down beside the notch from ten minutes before it
starts, with a Join button when there is a Zoom, Meet, Teams, Webex or FaceTime link.

**Weather.** The temperature on the home page beside a symbol for the sky, with the day's high
and low and, when rain is on the way, when it should start: "Rain in about 20 min", "Rain
around 3 PM". When rain is due within half an hour and it is dry now, a word beside the notch
says so, "Rain in about 10 min", once for each spell of rain; over music or a timer it rides in
a row underneath, and a Focus that asks for quiet drops it. Forecasts come from
[Open-Meteo](https://open-meteo.com), free and with no account, every fifteen minutes while the
Mac is awake, and the last one stays up, with its age, while it can't be reached. Nothing is
sent until you search for a place in Settings or turn on this Mac's own location, which macOS
asks you about the first time, and which is found roughly and at most once an hour. A search
sends the words you type, with the Mac's language; a forecast sends only the place's
coordinates, rounded to about a kilometre. Islet's own look-ups are left out of its location
arrow. Temperatures follow the Mac's Language & Region settings (Fahrenheit in the US) unless
you pick a scale.

**Camera, Microphone & more.** A green dot beside the notch while the camera is in use, an
orange one while only a microphone is — as on the iPhone — and a purple one while an app
records the screen or what the Mac plays. Turn on Location in Settings for an arrow while an
app gets the Mac's location (it is off at first: a single look-up lights it for about twelve
seconds). Weather and Find My, which look it up on their own, don't light it. "Don't show for
location" lists the apps that use location, as System Settings does, recent ones first, to
leave out others or bring those two back.
The home page says what is in use and which app is using it — "Microphone · Zoom",
"Screen · QuickTime Player" — as does a click on any of these dots or the arrow, and Islet can
name the app for a moment as it starts. Whether a
sensor is in use comes from the system itself and needs no permission. The microphone's app
comes from Core Audio; the rest of the names, and location and recorded sound at all, come from
the system log, which macOS only shows to administrator accounts. On any other account only
microphone apps are named, the camera and screen show as in use (screen mirroring can light the
purple dot there), and recorded sound and location aren't shown. The Sound Mixer records what
the Mac plays to set each app's volume, which macOS marks with its own purple dot; Islet never
lights a dot for it.

**Mic Mute.** One click mutes the microphone for every app at once — a call in Zoom, Teams or
FaceTime, a voice note, dictation — and a red crossed-out microphone stays beside the notch for
as long as it is muted, on the resting island too; click it for Unmute. The home page has the
button, a click on the microphone's dot offers Mute while an app is using it, and the **Mute
Microphone** action in Shortcuts (give the shortcut a key in its details) or
`islet://micMute/toggle` mute from anywhere, with a word beside the notch to say so. Islet mutes
the Mac's input from Sound settings with the microphone's own mute, or, on one without, by
turning its input level right down; it never listens itself, so the app keeps the microphone,
and macOS its orange dot, but hears silence. The mute follows the input to another microphone,
AirPods connecting say, putting the last one back, and the island says so if the new one can't
be muted. Unmuted or turned up somewhere else — its own button, another app, Sound settings —
the red mark goes and the island says so, rather than show a microphone muted that isn't. An
app set to a microphone of its own rather than the Mac's input isn't muted. Quitting Islet
unmutes, `killall Islet` included, and should it crash while muted, it puts the microphone back
as it found it the next time it starts.

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

**Claude Code.** While a Claude Code session works on a reply, a sparkle breathes left of the
camera and the turn's time counts up right of it. While it waits for your permission the
sparkle becomes an orange hand, and while it has asked you something, an orange question mark;
while background workflows run, a ring fills as they get through their phases, with how many
are running beside it when there are several (in the bubble beside music, the ring goes round
the sparkle). Opened, there is a row for each session: its project (or the start of its prompt,
for one outside a project), what it is doing and for how long, what you asked, and its
background work under it: each workflow with the phase it is in ("Implement · 3 of 8 done"), a
bar, the agents at work in it now, any it has given up on or is trying again, and for how long;
each agent sent off in the background with what it is doing ("Editing Store.swift") and how
many steps it has taken, marked quiet once it has written nothing for ten minutes; and each
command left running. A workflow that has ended shows how it ended until Claude Code next says
so. Click a session to bring forward the app it runs in — Terminal, iTerm, VS Code or the
Claude app. It never takes the island from music or a timer, and sits in the bubble beside them
instead, behind the Sound Mixer unless a session is waiting for you. Claude Code tells Islet
all this through hooks, with the script in `Scripts/` (see
[Claude Code hooks](#claude-code-hooks)); without them nothing shows. The hooks say when a turn
starts and ends, but not when you interrupt one, quit Claude Code or close its terminal, nor
when you give a permission, so Islet looks further. A session whose Claude Code has quit is
over, and so is a turn you have interrupted, or one whose transcript and its agents' have been
quiet for ten minutes while Claude waits on nothing (a long build keeps it going). A permission
you give shows once the approved command or agent next writes, so for a long command the hand
stays until it is done.

How far the background work has got comes from the files Claude Code keeps beside the
session's transcript in `~/.claude/projects`: each workflow run's journal of agents started and
finished, the phases its script plans, the record written as a run ends, and each background
agent's own transcript. To find which run is which workflow's, Islet looks through the last few
megabytes of the session's transcript for where Claude started it, and after that only at what
is added; failing that, it goes by the script's name. A workflow run again counts only what the
new try has done, and the agents finished before it. Islet reads these files every few seconds
while the work goes on, only what has been added since it last looked, and never writes there.
Where they are missing, or not as expected, a workflow shows as before, by its name and what it
was started to do.

**Sound Mixer.** Every app playing sound, each with its own volume (0–150%) and a mute, in
the opened island and on the home page. When two apps play at once, the mixer takes the
bubble beside the island, unless a Claude Code session is waiting for you. macOS has no
per-app volume, so Islet makes one with Core Audio process taps (macOS 14.2 or later): the
first time you move a slider, macOS asks to let Islet record system audio, which is how it
passes the app's sound through at the level you set.

**Drop Zone.** Drag files — or pictures straight from a web page — toward the notch and the
island opens onto two targets: AirDrop, and a shelf that keeps them for later. A picture
from Safari, Chrome or another browser, Google Images results included, arrives as an
ordinary image file under the name the site gave it; the shelf keeps its own copy and
deletes it when the picture comes off the shelf. Ordinary links and text selections leave
the island shut. Shelved files show on the home page and drag back out wherever they are
needed; right-click one to save a copy to Downloads.

**Downloads.** While Safari, Chrome, Arc, Firefox or another browser downloads into your
Downloads folder, the file's icon sits left of the camera and a ring fills right of it (a
spinner while the server hasn't said how big the file is), with a count when several are under
way. Opened, it says how much has come, how fast, and how long is left. When one finishes, a
card holds the file for a few seconds, and for as long as the pointer rests on it: drag it
straight to where it's needed, open it, or show it in Finder. Browsers tell Finder how a
download is going by publishing its progress, which is how Finder draws the bar under the
file's icon, and Islet listens the same way; a browser that publishes nothing (Firefox) is
followed by the size of its partial file. Browsers also tell the Dock when a download finishes,
so one too quick to see still gets its card. Nothing runs while nothing is downloading: a
download that stops for a minute (paused, or waiting for you to keep a file Chrome has warned
about) leaves the island, and comes back the moment it moves again. Islet only watches: it
can't pause or cancel another app's download, and one that fails or is cancelled just goes.
Safari's own download folder is followed too when it is set to another; a download another
browser saves elsewhere shows only once it has finished. The first time, macOS asks whether
Islet may see your Downloads folder.

**File Copies.** While Finder copies something big (to an external drive, a network share,
another folder), moves it to another disk or duplicates it, what it is copying sits left of the
camera and a ring fills right of it, with a count when several copies are under way. Opened, it
says where the copy is going, how much is done, how fast and how long is left, and has a Stop
button when the copy allows one, which Islet only ever uses when you click it. Copies of 50 MB
or more come up once they have been going a second (pick another size in Settings), smaller
ones when they will take more than a few seconds, and one that's over in a moment never shows;
a copy that finishes shows a tick as it goes. Finder tells other apps how a copy is going the
way browsers tell it how a download is, naming the folder the copy goes into, and an app can
only listen at particular folders, hearing about copies into each and into the folders directly
inside it. So Islet listens at your home folder; its Desktop, Documents, Downloads, Movies,
Music and Pictures; Applications; iCloud Drive; the folder where apps such as Dropbox keep
theirs; the top of every disk; and any deeper folder once something starts being written there,
which the Mac's own record of file changes says. Nothing in those folders is listed or read: to
say where a copy is going, Islet asks only for the path of the folder Finder names. Copies into
the rest of the Library folder, the Trash or hidden folders are left alone, and so are
downloads, which Downloads shows.

**Screenshots.** Take a screenshot and it comes up in a card for a few seconds, as on the
iPhone, and stays while the pointer rests on it: drag the picture straight into another app, or
copy it, put it on the Drop Zone shelf, show it in Finder or move it to the Trash (only ever on
your click). Islet knows a screenshot by the tag macOS gives it, through Spotlight and by
watching the folder the Screenshot app saves to, so a picture that isn't one, or an old
screenshot moved there, never shows. macOS holds each new screenshot in its floating thumbnail
for about five seconds before saving it, so the card comes after that. Turn on Show screenshots
here at once in Islet's Screenshots settings (or turn off Show Floating Thumbnail under Options
in the Screenshot app, ⇧⌘5) and it comes the moment it is taken, the card standing in for the
thumbnail: click its picture to mark it up in Preview. Islet changes that setting only when you
click the switch. A screenshot copied to the clipboard (with Control held down) makes no file,
so Islet doesn't see it. The first time, macOS asks whether Islet may see the folder screenshots
are saved to (the Desktop, unless you've chosen another).

**Clipboard History.** The last dozen things you copied — text, links, pictures and files —
on the home page, newest first, each with the app it came from and when; click one and it is
on the clipboard again, ready to paste. The tile's arrow opens a page with all of them, where a
pin keeps one at the top, across restarts too. macOS says nothing when something is copied, so
Islet glances at the clipboard's change count twice a second and reads the clipboard only once
the count has moved. macOS 27 asks before an app reads what other apps copy, so the first copy
puts an Allow button on the tile: click it and allow Islet when macOS asks, then turn Islet on
under Privacy & Security › Paste from Other Apps; until then nothing new is kept. Left out are
anything an app marks as secret or passing, as apps do after the conventions at nspasteboard.org,
and anything copied while 1Password, Bitwarden, Passwords, Keychain Access or another password
manager is in front; a password manager's browser extension that marks nothing looks like the
browser. Files are kept as references, never copied. The history lives in memory unless you ask
Settings to keep it between launches (pictures over 2 MB, unless pinned, stay in memory only),
and it can clear itself when the Mac locks.

**Hidden Menu Bar Icons.** On a MacBook, menu bar icons that don't fit beside the notch (when
the app in front has a long menu, say) end up behind the camera or out of the menu bar
altogether, where you can neither see nor click them. As the island opens, a tile on the home
page shows the ones out of sight, each with its app's icon, or for Wi-Fi, Bluetooth, the clock
and the system's other items the symbol closest to theirs; click one and Islet presses it, as a
click in the menu bar would, to open its menu. Icons switched off in System Settings are left
out: Islet tells them from the ones pushed out by whether the menu bar has room for them. The
tile's arrow opens a page with all of them and their names, and Settings can list the icons
that fit as well. Islet finds them through Accessibility, the permission the volume and
brightness keys use, and looks as the island opens (and when Islet starts or comes to the
front); without it, the tile says so. The pictures are the apps' own icons rather than what
the menu bar draws, which Islet could only get by recording the screen.

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
finishing: the island widens or drops into a card, then gives itself back. While music, a video
or a timer is showing, an alert beside the notch — an app starting on the camera or using your
location, a banner from a script — joins it in a slim row underneath instead, as the volume
does, so the music stays in sight; only a card, or a new song's own banner, takes its place.
Changing the volume puts its row in front, and the alert waits, its time held, until the volume
has gone. The row hangs below the menu bar, over the top of the window beneath, so resting the
pointer there does not open the island (a click on it does), and a wide one takes the second
activity's bubble in until it has gone, rather than push it over the menu bar's icons.

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
Calendar, Location and Full Disk Access permission against the signature, and an ad-hoc one
changes with every build.

## Scripting

Islet answers `islet://` URLs, so Shortcuts, scripts and the terminal can drive it:

| URL | Does |
|---|---|
| `islet://open` | Opens the island on the screen under the pointer |
| `islet://open?focus=timer` | Opens it on a particular activity (or `home`) |
| `islet://close` | Closes it |
| `islet://timer/start?minutes=5` | Starts a timer (`seconds=` works too) |
| `islet://timer/pause`, `/resume`, `/cancel` | |
| `islet://keepAwake/start?minutes=60` | Keeps the Mac awake for an hour (`hours=`, `seconds=` too, up to a day); with no length, until turned off |
| `islet://keepAwake/toggle`, `/extend`, `/stop` | Starts it (taking the same lengths) or stops it; adds 15 minutes (or `minutes=`); stops it |
| `islet://preview?feature=battery&index=0` | Runs a feature's preview |
| `islet://nowPlaying/toggle`, `/next`, `/previous` | Controls the player |
| `islet://focus/toggle` | Turns Focus on or off with the shortcut picked in Settings |
| `islet://micMute/toggle`, `/mute`, `/unmute` | Mutes or unmutes the microphone for every app |
| `islet://weather/refresh` | Fetches the forecast now |
| `islet://shortcuts/run?name=Morning%20Lights` | Runs a shortcut (`id=` takes the identifier `shortcuts list --show-identifiers` prints) |
| `islet://banner?title=Build%20finished` | Puts up a banner of your own (below) |
| `islet://banner/dismiss` | Takes it down |
| `islet://open?focus=clipboard` | Opens the island on the clipboard history |
| `islet://clipboard/clear` | Clears the clipboard history, pinned items apart |
| `islet://open?focus=hiddenMenuBarIcons` | Opens the island on the menu bar icons the notch hides |
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
cannot keep the island flickering. While something is already in the island — music, a video,
a timer — a banner beside the notch goes in a slim row under it instead, as the volume does, so
what was there stays in sight. With the island open, a banner shows in its header, and a card
comes as a compact one instead. Settings → Activities → Show in Islet turns them all off.

`open -g` hands the URL over without bringing anything to the front:

```bash
open -g "islet://banner?title=Build%20finished&subtitle=12%20s&symbol=hammer.fill&tint=orange"
```

In Shortcuts, the **Show in Islet** action puts up the same banner, with title, subtitle,
symbol, colour, style and duration as fields. It runs in the background, starting Islet if it
is not running, and fails with a reason if Show in Islet is turned off.

A Stop hook in `~/.claude/settings.json` whose command is
`open -g 'islet://banner?title=Claude%20finished&symbol=checkmark.circle.fill&tint=green'`
flashes the island whenever Claude Code finishes, after every reply, short ones too. The hook
script in [Claude Code hooks](#claude-code-hooks) does that and more.

And a test run can say how it went:

```bash
swift test && open -g "islet://banner?title=Tests%20passed&symbol=checkmark.circle.fill&tint=green" \
           || open -g "islet://banner?title=Tests%20failed&symbol=xmark.octagon.fill&tint=red&sound=Basso"
```

### Claude Code hooks

`Scripts/claude-code-hook.sh` is a hook script for Claude Code. It puts up banners — a reply
finished (a card with its start), Claude waiting for permission or for an answer, a background
workflow finished — and keeps a small file for each session in
`~/Library/Application Support/Islet/Claude Code/Sessions`, which the Claude Code activity
follows. Copy it into Claude Code's hooks folder:

```bash
mkdir -p ~/.claude/hooks
cp Scripts/claude-code-hook.sh ~/.claude/hooks/islet-notify.sh
```

and add these hooks to `~/.claude/settings.json`, beside any you have already (Settings →
Activities → Claude Code copies them too):

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" start" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" prompt" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" notification" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" stop" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" subagent" }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" task" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" end" }] }]
  }
}
```

Each hook hands the script its kind of event. SessionStart and SessionEnd make and delete the
session's file, UserPromptSubmit marks it working, Notification says when Claude needs your
permission or an answer, and Stop marks it done. Claude Code sends no event when a background
workflow finishes, but Stop and SubagentStop list the session's background tasks — workflows,
agents sent off in the background, commands left running — and SubagentStop comes often while
workflows run, so the list stays current, and a workflow gone from it gets its banner. The
script keeps no command line: a command Claude Code describes by the command alone is kept by
the name of the program it runs. If you copied the script before background agents and
commands showed, copy it again to see them; workflows' progress needs no new copy. Claude Code
waits for UserPromptSubmit's hooks before it sends the prompt, so the script is quick, prints
nothing and always succeeds. It needs `jq`, part of
macOS from 15 on (`brew install jq` before that). It keeps the last 200 events other than
agents stopping in `~/.claude/hooks/islet-hook-log.jsonl`, to show what each carries (a
prompt by its length alone), and `ISLET_NOTIFY_DRY=1` prints its banners instead of showing
them. Its header lists what each session's file holds. The workflows the earlier script kept in
`~/.claude/hooks/islet-workflows` are moved over at each session's next event, and the folder
goes once they have all been, or are a day old.

## Layout of the code

- `Islet/Island/` — the window, the notch measurements, the shape, and the state machine
  that decides what the island shows and how big it is.
- `Islet/Activities/` — `ActivityCenter`, the single source of truth every window renders,
  and the contracts features publish through: live activities, banners, home widgets and
  the pages they open, indicators and the drop target.
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

Weather data by [Open-Meteo.com](https://open-meteo.com) (CC BY 4.0), with place names from
its geocoding API, which draws on GeoNames.

The idea of putting an island in the notch, and a good deal of what not to do, comes from
[boring.notch](https://github.com/TheBoredTeam/boring.notch). Islet is its own code.
