# Islet

A Dynamic Island for the Mac notch.

On the iPhone, the island is the one piece of the screen that is always about what is
happening right now: music playing, a timer running, AirPods connecting. Islet does the
same with the MacBook's camera notch. It rests as the notch itself, widens either side of
the camera while something is going on, and opens into a card when the pointer rests on it.

## What it shows

**Now Playing.** Whatever the Mac is playing — Music, Spotify, a browser — with the artwork
left of the camera and a waveform on the right, tinted with the cover's colour while the accent
is Feature colours (otherwise it takes the accent). Opened, it is a player: artwork, a
scrolling title, a scrubber you can drag, and the controls, with shuffle and repeat where the
player reports them. The button at the end of the controls lists the Mac's outputs as the Sound
menu does — its speakers, AirPods with each bud's and the case's battery, a display, USB or
HDMI — with the volume above them, and moves the sound to the one you click; macOS lets only
its own Sound menu and Sound settings list AirPlay receivers, so for those the last row opens
Sound settings. On macOS 27, under AirPods that have them sit their listening modes
(Transparency, Adaptive, Noise Cancellation, and Off once the AirPods have been seen allowing
it) and, while something they can spatialize plays, Spatialize Stereo or Spatial Audio: Off,
Fixed or Head Tracked. Both follow changes made from the stem, Control Center or an iPhone, and
change only when you click one; Noise Cancellation and Adaptive wait for both AirPods to be in.
A song change gets a moment's banner. On macOS 15 and later, once Islet may record system audio
(the permission the Sound Mixer asks for), the waveform follows the music itself, bass on the
left and cymbals on the right, in time with what you hear; macOS shows its purple recording
indicator while it listens. Without that, or with "Waveform follows the music" off, the bars
dance on Core Animation as before.

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
down beside the notch in the Clock app's orange (or the accent: see Appearance); opened, it
pauses and cancels. When it ends the island rings, with the last length one click away.

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

**Pomodoro.** Twenty-five minutes of focus, a five-minute break, and after every fourth focus a
fifteen-minute one, each length and the count set in Settings. Start it from the home page,
`islet://pomodoro/start` or the Start Pomodoro action in Shortcuts, and end it with Stop
Pomodoro. While it runs, the phase's symbol sits left of the camera, red for focus (or the
accent) and green for a break, with the time left on the right, or "Ready" when the next phase
waits for your click; beside music it waits in the bubble as a draining ring, and the song keeps
the island. Opened, it says which focus of the cycle it is ("Focus 2 of 4"), and pauses, skips
or stops; a pause holds the time left. Drag the bar under the time left to move through the phase, on to skip
ahead or back for more time; the phase holds still while you drag, and if you let go at its end
it finishes as if its time had run out. As each phase ends a sound plays and a word shows beside the notch, or in a
row under the music: "Focus done — 5 minute break", "Break over — Back to it". Breaks start by
themselves and the next focus waits for your click, unless you change either in Settings. The
home tile counts the focus sessions you finished today, from nought again at midnight. Phases
end at the time they said, even if the Mac slept through it, but a focus never starts by itself
while the Mac is asleep, and none that came and went then is counted. If you ask, a focus
session turns on Focus with the shortcut chosen in Focus's settings and turns it off for the
break. The shortcut toggles, so this needs the Focus feature on, with Full Disk Access, to see
what it will do: a Focus that was already on is left as it was. It can also keep the Mac
awake with a power assertion of its own, "Islet: Pomodoro", given back as the focus ends or
pauses. A session survives quitting Islet, or a restart: it is picked back up when Islet next
opens, with the time in between caught up as after sleep, so a focus that ran out meanwhile is
counted if it ended today, a break after it carries on, and a focus that should have started
more than a minute ago waits for your click. The sound and the word for a change that came due
while Islet was closed play only if it came in the minute before Islet opened. A Focus turned
on for a focus still running as Islet quits stays on, and is kept if that focus is still running
at the next launch, or turned off then if not; for a focus paused, Islet turns its Focus off as
it quits, and back on when you resume. The Mac is kept awake again for a focus still running.
Stopping the session, or turning Pomodoro off, ends it for good.

**Battery.** The iPhone's charging flash when you plug in — "Charging" on one side, the
level and a green battery on the other — and warnings as the battery runs low. Full charge,
Low Power Mode and unplugging can be announced too.

**Volume & Brightness.** Replaces the system overlay with a slim bar in the island, naming the
device being changed ("AirPods Max", "Built-in Retina Display"), the way macOS does. While the
island is showing something else, such as a song or a timer, the bar joins it in a slim row
underneath instead of taking its place. Needs Accessibility (called Device Control and Data
Access from macOS 27), so it is off until you turn it on.

**Caps Lock.** Pressing Caps Lock flashes a word either side of the camera, as the iPhone does
for its Ring/Silent switch: the Caps Lock symbol and name on the left, a green "On" (or one in
the accent) or a grey "Off" on the right, never over another alert such as a timer's. Its symbol
can stay beside the notch while it is on, too. macOS says nothing when Caps Lock changes, so
Islet watches the modifier keys, which needs the same Accessibility permission as Volume &
Brightness; until it has it, the island shows nothing for Caps Lock pressed in other apps.

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

**Wi-Fi & VPN.** A word beside the notch when the connection changes: "Offline" once the Mac
has had no way out for three seconds (a drop that ends sooner says nothing, and one that keeps
coming back has to last longer), "Back online" when it returns, "Joined" when Wi-Fi moves to
another network, Wi-Fi turning off or on (on, once it has joined a network), and a VPN
connecting or disconnecting, given time to reconnect first. Over music or a timer it rides in
a row underneath, a Focus that asks for quiet drops it, and nothing stays up at rest. Waking
on another network names it; waking where the Mac slept says nothing. macOS names Wi-Fi
networks only to apps with Location access, which Islet has once you have allowed it, as
Weather asks when it uses this Mac's own location; this never asks. Without it the banners say
"Wi-Fi", and a change of network goes unsaid. A VPN counts once it carries all of the Mac's
traffic, by the name System Settings gives it where Islet can read that. Settings picks which
of these show.

**Calendar.** Your next event counts down beside the notch from ten minutes before it starts,
with a Join button when there is a Zoom, Meet, Teams, Webex, FaceTime or Slack huddle link in
its URL, location or notes, Outlook's Safe Links and Google's redirects looked through. From
five minutes before a call until ten minutes in, a green camera (or one in the accent) sits
beside the countdown, and until five minutes in the call takes the island over from music. Rest
the pointer on the camera a moment, then click to join, in the Zoom or Teams app where it is
installed. The **Join Meeting** action in Shortcuts and `islet://calendar/join` join the call
under way or starting within 15 minutes.

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

**Presentation Mode.** While you share or record your screen, are on a call, or play a slideshow
in Keynote or PowerPoint, the island holds back what would show your own things to everyone
watching: banners from scripts and Claude Code, what a shortcut hands back, screenshots and
finished downloads, which Focus comes on, a new song and the line being sung. The home page
keeps its tiles where they are, but the clipboard, the shelf, the calendar, the Focus and the
music say only "Hidden", and the island opens on home rather than on the calendar, the music,
downloads or Claude Code, whose tabs still open them. A tile you hid yourself stays gone rather
than saying "Hidden", and one held back can still be moved or hidden while you edit the page. On
a call the calendar's Join camera stays beside the notch and still joins it: it says only which
service the call is on, while the event's title waits on the calendar's page. A banner that
comes in as a share starts waits until the share counts, then is held back, or shows a moment
late if the share was over at once. The volume, the brightness and the Mac's battery warnings
still show, and the island still opens when you rest the pointer on it. A crossed-out eye beside
the notch says it is on; click it for why — "Screen shared by Zoom", "On a call in FaceTime" —
how many alerts it has held back so far, and Turn Off Until This Ends. When presenting ends the
island says how many messages and files it held back, once, rather than bring them all back;
songs and Focus changes aren't counted. The screen counts as shared while any app but Islet
captures it: the Sound Mixer's and the waveform's recording of what the Mac plays never counts,
nor does a screenshot's moment of capture, since the screen must stay captured for three
seconds. An app that captures the screen all the time, as DisplayLink's driver does for a
monitor on a dock, would keep it on for good, so DisplayLink doesn't count, and the card offers
Don't Turn On for any other such app; Settings list them. A call is the camera in use, or a call
app — FaceTime, Zoom, Teams, Webex, Slack, Discord, Skype, WhatsApp, Signal, Telegram — or a
browser using the microphone. A slideshow is Keynote or PowerPoint in front with the menu bar
hidden, a window over a whole display, or PowerPoint's slide show window. Settings turn off each
of these, and each kind of thing held back; device and network names ("Alex's AirPods", the
Wi-Fi or VPN just joined) show unless you hide them too. The **Presentation Mode** action in
Shortcuts and `islet://presentation/toggle` turn it on by hand, until you turn it off: do that
for AirPlay to a TV or a projector, which doesn't count as sharing on an administrator account,
since macOS leaves it unmarked (on other accounts Islet can't tell it from sharing, and it does
count). Which app shares the screen is named from the system log, as for the privacy dots, so
with the screen or call trigger on, Islet watches the sensors and reads the log even while
Camera, Microphone & More is off; on other accounts the card says "Screen being shared", and no
app can be left out.

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
so. Past what the island can hold, the list scrolls, the line at its foot fading to show there
is more; a session that starts waiting for you brings it back to the top, where that session
is listed. Click a session to bring forward the app it runs in — Terminal, iTerm, VS Code or the
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

**The others get bubbles.** As on the iPhone, when several things are running the
most important one keeps the island and each of the others buds off into a circle of its own,
in the island's order (below): the first to its right, the next to its left, and so on in turn,
each side taking as many as the menu bar leaves room for (four at most in all), and once one side
is full the rest go on the other. A single other activity only ever goes right. On the left they
stop short of the front app's menus, which Islet finds through Accessibility and looks at again
as you switch app; without it, or with the menus reaching the notch, they all go right, short of
any menus that run on past it. Settings → General → Bubble placement keeps them to the right
only. Each is drawn through a blur and an alpha threshold while it is close to the island or the
bubble before it, so a neck of the island's colour joins them, stretches and snaps as the bubble
springs out — and forms again when it merges back; the others slide along to make room or close
the gap. Where neither side leaves room for the next bubble, that activity folds into the
island instead, as a small circle at its left end, so long as that costs none of the bubbles
beside it. Any still left over are counted: a small "+2" bubble after the others, or, with no
room for that, a little "+2" on the folded circle or the last bubble. Clicking a bubble opens the
island on that activity, and clicking the count opens the home page, with a tab for each. macOS 27
draws the whole menu bar as one window, so there Islet finds the icons through Accessibility
when it has it, and otherwise folds rather than risk covering them.

**Choose what holds the island.** Until you say otherwise, what matters most goes first: a
timer, then a meeting about to start, music, a shortcut or a download, then things in the
background, the newest first among equals. Right-click a bubble, the circle folded into the
island or an activity's tab in the opened island and choose Show in Island to keep that activity
in the island until it ends; right-click the island and choose Let Islet Choose to go back.
VoiceOver has the same as actions. Settings → General → Island Order lists the activities of the
features that are on, in the order the island takes them; drag one to another place and that
order decides from then on, for the bubbles too, and Reset goes back to Islet's own. Only a
chosen activity, or a preview on screen for a moment, goes before it.

**Rest the pointer on it to open it.** The island stretches sideways a beat before it drops,
with a small squash and rebound, and its content arrives out of a blur. There is a tab for
each running activity and one for the home page. It closes when the pointer leaves or on a
click anywhere else; a two-finger swipe down opens it. Clicking works too, if you would rather
it did not open on hover.

**Arrange the home page.** Right-click it and choose Edit Home Page: the tiles wiggle, drag one
to another place (over a page's dot to take it to that page) or click its minus to hide it, and
bring hidden ones back from the Hidden menu at the top left. Click Done (or press Escape, once
Islet has Accessibility access). The island stays open meanwhile, with the pointer away for up
to a minute. Settings → General → Home Tiles lists every tile of the features that are on, to
drag into order, switch off or bring back, and Reset puts them all back where their features
put them. A tile you have never placed goes beside its usual neighbours, and keeps that place.

**Alerts take it over for a moment.** Plugging in a charger, AirPods connecting, a timer
finishing: the island widens or drops into a card, then gives itself back. While music, a video
or a timer is showing, an alert beside the notch — an app starting on the camera or using your
location, a banner from a script — joins it in a slim row underneath instead, as the volume
does, so the music stays in sight; only a card, or a new song's own banner, takes its place.
Changing the volume puts its row in front, and the alert waits, its time held, until the volume
has gone. The row hangs below the menu bar, over the top of the window beneath, so resting the
pointer there does not open the island (a click on it does), and a wide one takes in the
bubbles it would push over the menu bar's icons until it has gone.

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

**Its colours are yours.** Settings › General › Appearance picks the island's colour and one
accent. The island can be any colour, light ones included: on a light island words and symbols
turn black. On a display with a notch the island stays black at rest, because there it is the
notch; once it shows something it takes the colour, and the camera housing stays a black shape
at its top. The accent is what symbols, rings, progress and selected things are drawn in:
"Feature colours" (the default) keeps each feature's own, and a preset, Mono (the island's own
black or white) or any colour you pick replaces them all. Colours that mean something — the
camera and microphone lights, a low battery, a failure, a Focus, Presentation Mode, a network
coming and going, a Pomodoro break, a banner's or a calendar's own colour — never take the
accent, though an event whose calendar has no colour of its own is drawn in it. Every colour is
kept as chosen where it reads, and otherwise darkened or lightened, never shifted in hue, just
enough to stand out: 4.5:1 for words, 3:1 for symbols. On a mid-tone island, a grey or a system
blue, where even the island's own black or white only just reads, coloured words that would
come out all but black are drawn plainly in it instead, and the symbol beside them keeps the
colour. A light island has a hairline edge, so it still shows against a light menu bar, and a
file's icon lies on a faint plate there, so a white page still shows. Black with Feature colours
looks exactly as the island always has.

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
| `islet://open?edit=1` | Opens it on the home page, arranging its tiles |
| `islet://close` | Closes it |
| `islet://island/pin?id=timer` | Keeps an activity that is running in the island, as Show in Island does (ids as for `focus=`) |
| `islet://island/unpin` | Lets Islet choose what the island shows again |
| `islet://timer/start?minutes=5` | Starts a timer (`seconds=` works too) |
| `islet://timer/pause`, `/resume`, `/cancel` | |
| `islet://keepAwake/start?minutes=60` | Keeps the Mac awake for an hour (`hours=`, `seconds=` too, up to a day); with no length, until turned off |
| `islet://keepAwake/toggle`, `/extend`, `/stop` | Starts it (taking the same lengths) or stops it; adds 15 minutes (or `minutes=`); stops it |
| `islet://pomodoro/start?minutes=50` | Starts a focus of 50 minutes (1 to 120; with no length, as in Settings), or carries on |
| `islet://pomodoro/pause`, `/resume`, `/skip`, `/stop` | As the opened island's buttons do |
| `islet://pomodoro/toggle` | Pauses a session running, or starts or resumes one |
| `islet://pomodoro/forward?minutes=5` | Moves the phase on 5 minutes (1 to 120; with no length, one), finishing it at its end |
| `islet://pomodoro/back?minutes=5` | Gives the phase 5 more minutes (1 to 120; with no length, one), up to its whole length |
| `islet://preview?feature=battery&index=0` | Runs a feature's preview |
| `islet://nowPlaying/toggle`, `/next`, `/previous` | Controls the player |
| `islet://focus/toggle` | Turns Focus on or off with the shortcut picked in Settings |
| `islet://micMute/toggle`, `/mute`, `/unmute` | Mutes or unmutes the microphone for every app |
| `islet://presentation/on`, `/off`, `/toggle` | Turns Presentation Mode on until turned off, or off until what turned it on ends |
| `islet://weather/refresh` | Fetches the forecast now |
| `islet://calendar/join` | Joins the video call under way or starting within 15 minutes |
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
| `tint` | `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray` or `white`, or hex as `ff9500` or `%23ff9500` (`colour` and `color` work too); `white` is the island's own ink, black on a light island, whatever the accent; with none the symbol is a highlight like a feature's, the island's ink under Feature colours and otherwise the accent |
| `duration` | Seconds, from 1 to 30: 4 beside the notch and 6 for a card if left out |
| `style` | `compact`, beside the notch, or `card` |
| `sound` | One of the Mac's alert sounds (`Glass`, `Ping`, `Basso` and the rest of /System/Library/Sounds); silent without |
| `interruption` | `passive` lets a Focus that asks for quiet hold it back, as it does a song change |

Spaces go in as `%20` (a `+` stays a plus), and a `#` as `%23`, since a bare one ends the
query. Titles are cut at 60 characters and subtitles at 120, and a colour that would not show
on the island's colour is darkened or lightened, keeping its hue, only as far as it must be to
stand out. Nothing in a banner can be clicked, whatever the URL says. Banners that come faster
than one a second, or more than five in ten seconds, wait their turn, and only the newest of
those waiting is shown, so a script stuck in a loop cannot keep the island flickering. While
something is already in the island — music, a video, a timer — a banner beside the notch goes
in a slim row under it instead, as the volume does, so what was there stays in sight. With the
island open, a banner shows in its header, and a card comes as a compact one instead. While
Presentation Mode is on they are held back, sounds and all, and counted. Settings → Activities
→ Show in Islet turns them all off.

`open -g` hands the URL over without bringing anything to the front:

```bash
open -g "islet://banner?title=Build%20finished&subtitle=12%20s&symbol=hammer.fill&tint=orange"
```

In Shortcuts, the **Show in Islet** action puts up the same banner, with title, subtitle,
symbol, colour, style and duration as fields (a colour of Default is none, as a URL without a
`tint`). It runs in the background, starting Islet if it is not running, and fails with a reason
if Show in Islet is turned off.

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
- `Islet/Home/` — the opened island's home page: its tiles, its pages, and arranging them.
- `Islet/Support/` — views and helpers shared by every feature, and the island's colours:
  `IslandTheme`, the `.island…` styles, `SystemHue` and `FeatureTint`.
- `Islet/Settings/` — the Settings window and its search. The search finds a feature by its
  title and summary with nothing more; the other words it goes by, its settings' labels and
  other names for it, are in `SettingsSearchTerms.swift` beside every other feature's. A
  section added to the General tab is found once it is a `GeneralRow`.
- `Vendor/mediaremote-adapter/` — see below.

**Colours in the code.** Island views never write `.white`, `.black` or a colour literal, and
never read UserDefaults for a colour. The theme (`IslandTheme`) is worked out once when the
preferences change and put in the environment at `IslandRootView` and in Settings; views ask it
for a colour by what the colour is for, through the `.island…` shape styles in
`Support/IslandStyles.swift`:

- words: `.islandPrimary`, `.islandText(0.55)` — today's opacity, raised only as far as 4.5:1
  needs;
- symbols, rings and meaningful strokes: `.islandGraphic(0.6)` (3:1);
- tracks, dividers and hover washes: `.islandDecorative(0.2)` (no floor);
- cards, chips and rows: `.islandSurface(0.12)`, with what sits on them measured against it,
  e.g. `.islandText(0.55, on: .surface(0.12))`; a wash of a colour with words on it (a lit
  tile) is only as strong as `theme.readableWash(0.2, of: colour, over: base)` allows;
- a feature's highlights: `.islandAccent(.timer)`, or `.islandAccentText(.timer)` for coloured
  words;
- colours that mean something: `.islandHue(.failure)` (see `Support/SystemHue.swift`); a colour
  someone chose: `.islandFitted(colour)`; words on a filled button: `.islandOnFill(fill)` over
  `.islandFill(fill)`;
- in a home tile or an indicator card, measured against it: `.islandText(0.55, on: .homeTile)`,
  `.islandText(0.55, on: .indicatorCard)`; a chip, capsule button or plate on a tile or card:
  `.islandSurface(0.12, on: .homeTile)`, with its words measured against
  `IslandBackdrop.homeTile.stacked(0.12)` (where the tile leaves no room for more ink, the chip
  goes the other way, toward white on a light island, so it keeps its shape);
- a symbol or word on a wash of its own colour (a badge's disc, a pill button's capsule, a
  picked tab): `.islandWashed(.accent(.keepAwake, minimum: Contrast.text), wash: 0.2,
  in: Capsule())`, or `theme.onWash(_:wash:on:)` for the two colours, which keeps the wash
  faint enough for the mark to read on it;
- a level's fill inside its track (a volume, a scrubber): `.islandAccent(.nowPlaying,
  on: .track(0.2))`, fitted against the track and against the island along its edges; dimmed
  while muted with `.dimmedLevel(0.35, on: .track(0.2))` rather than an opacity;
- a faint outline in a colour, such as a battery's body: `.islandFaint(ink, 0.4)`, which keeps
  it at 3:1 off the default island;
- a file's icon from the system: `.fileIconBacking(size:)`, a faint plate under it on a light
  island, where Finder's white page would vanish;
- round buttons and progress rings take an ink, the island's own by default:
  `RoundButton(symbol: "play.fill", tint: .accent(.timer))`,
  `ProgressRing(fraction:lineWidth:tint: .accent(.downloads))`.

Each style is fitted as it is drawn, so it is used at full strength: an `.opacity` added after
it (`.islandAccentText(.date).opacity(0.9)`) undoes the fitting and can fall short on a light
island. Words and symbols take their opacity as the argument (`.islandText(0.55)`), where the
floor still applies; where the black island needs today's softer value, the view keeps it for
the default theme only (`theme.isDefault`).

The shell decides what the island is painted in (`IslandRootView`): the chosen colour whenever
it shows something, and, under a notch, black at rest (`IslandLayout.wearsColour`), with the
black theme (`IslandTheme.resting`) in the environment. Views read whichever it is and never
need to know. A model that keeps a colour (an alert, an indicator, a banner) stores an
`IslandInk`, which says what the colour is for, rather than a `Color`, so it follows the island
when the colour changes. An AppKit or Core Animation view in the island is given its colour by
its SwiftUI wrapper, from `@Environment(\.islandTheme)`; only code outside any view asks
`ink.nsColor(in: Prefs.islandTheme)`.

A feature declares its own colour once, in its own folder, as tuned for the black island:

```swift
extension FeatureTint {
    static let timer = FeatureTint.colour(RGB(1.0, 0.62, 0.04))
}
```

A feature whose highlights are white today declares `.neutral`. Under Feature colours it draws in
its own colour, under any other accent it takes that accent, and it is fitted for contrast in
every theme but the default (black with Feature colours), which draws every colour exactly as
given. Only highlights take the accent: symbols, rings, progress and what's selected. A colour
that means something (a privacy light, a battery low or charging, done, failed, a warning, muted,
a Focus) is a `SystemHue`, and a colour someone chose is drawn with `.islandFitted`; both keep
their hue on every island. Three more things a feature may need:

- a meaningful colour of its own: name one of the system's hues once, in its folder
  (`extension SystemHue { static let presentation = SystemHue.teal }`), and draw it with
  `.islandHue(.presentation)`; if an accent could be taken for it beside the notch, where it
  would be a bare dot, add it to `SystemHue.guarded` and give it a `meaning` for the Settings
  caption. A colour of the feature's own that must never take the accent, such as Pomodoro's
  break green, is drawn with `.islandFitted`;
- a level that is fine (a headset's battery): `theme.restingLevel(.headsetLevel)`, which is the
  island's ink instead wherever the accent could be taken for a low battery's red or a
  warning's orange;
- a button filled with the feature's colour: `theme.filledButton(.calendarJoin)` gives its fill
  and its word, black or white, whichever reads.

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
