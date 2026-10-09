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
under way or starting within 15 minutes. On the home page, Up next lists the rest of today; once
nothing is left of it but all-day events, it lists tomorrow's instead, or the next day within a
week that has any, under the day's name, with today's all-day events in a small line above.

**Quick Calendar.** Add an event by typing it: in the input box (the Quick Ask shortcut, then ⌘2
or the mode chip, or start the line with `+`), type "Dentist tomorrow 3pm", "call mum friday
9:30", "Standup 15:00–15:30", "gym 7am for 90 min", "lunch at Nando's at 1", "interview 12 Oct
10:30", "meet at half 3" or "flight Oct 3" (all day). It is read on this Mac by rules, not by a
model, and never sent anywhere. Under the field a preview shows what was read, each part a chip
to change it: the day, the time (an hour typed without am or pm is taken as the likelier and
marked "?": the evening for dinner or drinks, and after "tonight" 12 is midnight and 1 to 4 the
small hours), the length (an hour unless Settings says otherwise) and All day. A time already
past today with no day typed is taken as tomorrow's; one typed in another zone ("3pm PT") keeps
its moment. Beneath are blanks for Location (a place read from "at …" is filled in and marked as
a guess) and Notes, and the calendar chip beside the field picks the calendar, your default one
unless Settings says otherwise. If the event overlaps another, or leaves less than the travel
time to get to its place, a line says so; it is only a warning. Return moves on to Location, then
Notes; only Add, ⌘Return or Return in Notes writes, and only the event shown. "Added to Work ·
Undo" follows for eight seconds, and Undo takes the event away again only if nothing has changed
it since. In Ask mode, a line that reads as an event rather than a question offers "Add “Dentist”
tomorrow 15:00 to Calendar? ⌘↩"; taking it moves to Event mode for a look first, and Return still
asks.

Left without a place, a timed event that isn't online is asked about later on a card, "Add a
place for Dentist?": two hours after adding it (1 to 4 in Settings, or half an hour before it
starts if that is sooner; not at all if that would be within a quarter of an hour). Click the
card's field to type the place, then Add, which sets that event's place and nothing else; Not
now asks once more an hour later (or a quarter of an hour before it starts), and Don't ask lets
it be. The card is never shown once the event has started, and is dropped without a word if the
event was deleted, moved or given a place meanwhile. What Islet keeps for this, so it outlasts a
restart, is only the event's identifiers and times, never its title, place or notes; turning
Quick Calendar off forgets it, and Ask about missing details in Settings turns the cards off.

The **Today** tile on the home page says how the day stands, "Free until 15:00" or "Busy until
16:00", and how much free time is left, with a "1 clash" badge when two events don't fit. Its +
opens the box in Event mode, and **Summarise** opens the day: free time, travel and events in
order, "Free until 10:30", "10:30 Travel to Main St", "11:00 – 12:00 Dentist · Main St", with
all-day events on a line of their own and a switch to tomorrow. Today's is counted from now, and
both only within your day (8:00 to 22:00 unless Settings says otherwise); gaps shorter than a
quarter of an hour aren't counted as free. Getting to an event with a place takes the travel
time (30 minutes unless Settings says otherwise), unless the event before it is at the same
place; online events and ones with no place need none. Two events clash when they overlap by a
minute or more, or when the gap between them is shorter than the time needed to get to the
second; only timed events that aren't declined, cancelled or shown as free count, in the
calendars Settings checks (all but Birthdays unless you leave some out). Each clash today or
tomorrow is told once on a card while the island is resting ("Only 10 minutes to get from Gym
to Café for Coffee"), unless Tell me about clashes is off; a clash already shown in the box as
the event was typed isn't told again. Typing "summarise my day", "what's on tomorrow", "what do
I have on Friday?", "anything on Wed?", "how's tomorrow looking?" or the like in the box, in
either mode, shows the same summary above the field; "what's on today", "what do I have today"
or "my schedule today" shows the whole of today, its events that are over dimmed among the rest,
with the free time still from now. In Ask mode it joins the conversation, and straight after it
"what about Thurs", "and Friday?", "next Monday", "tmrw?", "the day after" or "yesterday?" sums
up that day the same way. It is recognised by fixed rules before anything is sent anywhere, and
worked out on this Mac: your calendar is never sent to ChatGPT or Claude. A follow-up asked of
On this Mac ("am I free at 3?") is given the summary, so Apple's on-device model can answer it
without anything leaving your Mac; ChatGPT and Claude are told only that a summary was shown
here and stays private, in its place and in that of On this Mac's answers from it, and the box
says so over their answer. "Ask ChatGPT anyway" (or whoever answers) sends only the words you
typed. On this Mac can also read your calendar itself when you ask it about it (see Your
calendar, to On this Mac, under Quick Ask).

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
watching: banners from scripts, Claude Code, ChatGPT and Gemini, what a shortcut hands back,
screenshots and finished downloads, which Focus comes on, a new song and the line being sung. The home page
keeps its tiles where they are, but the clipboard, the shelf, the calendar, the Focus and the
music say only "Hidden", and the island opens on home rather than on the calendar, the music,
downloads, Claude Code, ChatGPT or Gemini, whose tabs still open them. A tile you hid stays gone rather
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
a build finishing, tests passing or failing, Claude Code or ChatGPT done at last. A symbol and a
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
is listed. Click a session, or a banner its hook put up, to bring forward the app it runs in at
that session: the Claude app opens the session itself, and Terminal and iTerm select its tab
(the first time, macOS asks whether Islet may control them, and if you say no the app just comes
forward); VS Code, Cursor and Warp come forward as they are. A Done banner for the session the
Claude app is showing, while the app is in front and the screen unlocked, stays down, since you
can see the reply; the row still updates. The app records only which session it last showed, so
after you leave a session for a chat elsewhere in the app, that session still counts as
showing; sessions in a terminal or an editor always get their Done. Settings → Activities →
Claude Code → Skip Done when the chat is on screen turns this off. It never takes the island from music or a timer, and sits in the bubble beside them
instead, behind the Sound Mixer unless a session is waiting for you. Claude Code tells Islet
all this through hooks, with the script in `Scripts/` (see
[Claude Code hooks](#claude-code-hooks)); without them nothing shows. The hooks say when a turn
starts and ends, but not when you interrupt one, quit Claude Code or close its terminal, nor
when you give a permission, so Islet looks further. A session whose Claude Code has quit is
over, and so is a turn you have interrupted, or one whose transcript and its agents' have been
quiet for ten minutes while Claude waits on nothing (a long build keeps it going). A permission
you give shows as soon as Claude Code uses the tool, or starts the command you allowed, and a
denial once the agent that asked carries on; without the PermissionRequest and tool hooks, it
shows only once the approved command or agent next writes, so for a long command the hand
stays until it is done. A permission Claude asks can be answered in the island itself, with
Allow and Deny on its page (see [Approving from the island](#approving-from-the-island)).

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

**ChatGPT.** While a chat in the ChatGPT app, or a thread in Codex, works on a reply, a speech
bubble breathes left of the camera and the turn's time counts up right of it. While it waits for
your permission the bubble turns orange with a hand at its corner, and while it has asked you
something, with a question mark there instead, never to be taken for Claude Code's, and the time
counts how long it has waited. While agents are at work, how many sits right of the camera in
place of the time, beside a ring that fills as the chat gets on where there is a measure of it
(its plan's steps done, else its agents done), or beside a spinner without one; the ring round
the speech bubble in the bubble beside music fills the same way. Commands left running are not
counted there, as Claude Code's are not, so a chat that once started a server keeps its time.
Opened, there is a row for each chat: its project (or the start of
what you asked, for a plain chat outside a project), what it is doing ("Running swift", "Editing
Store.swift and 2 more") and for how long, with how many follow-ups wait their turn ("2
queued"); what you asked; the turn's steps so far ("14 steps · swift, Store.swift, the computer
+3"); the thread's goal, with a bar of its tokens used where it has a budget, and whether it is
paused, blocked or done; the turn's plan as a checklist with a bar ("3 of 7 done"); each agent
it has sent off, by the task it was given or the nickname Codex gave it, with what it is doing,
how many steps it has taken or how far its own plan has got, and "quiet 12 min" once it has been
silent for ten minutes; and each command it has left running, by its program, with how long it has run.
A command left running is listed until it ends, or until Codex goes, but never keeps a chat on
show by itself: a server can run for days. One you were asked to allow is listed only once Codex
shows it running, since one you declined never ran. A plain chat that uses no tools shows for the few
seconds of its reply, and one with an active goal stays on show while Codex carries on towards
it between the turns it starts itself. Click a chat, or a banner its hook put up, to bring
forward the app it runs in — the ChatGPT app, open at that chat, or the terminal or editor Codex
runs in. Like Claude Code, it
sits in the bubble beside music or a timer, behind the Sound Mixer unless a chat is waiting for
you. ChatGPT tells Islet all this through Codex's hooks, with the script in `Scripts/` (see
[ChatGPT hooks](#chatgpt-hooks)); nothing shows until the hooks are added and you have trusted
them in ChatGPT. The hooks say nothing when a turn fails or you decline a permission, so Islet
looks further: a turn the thread's rollout file says has ended is over, a chat whose Codex has
quit is over, and so is a turn quiet for ten minutes (an hour while a tool runs, for a long
build). Its banners, a reply done, a permission or a question, show only while the app it runs
in is not in front, but for a reply in the ChatGPT app: ChatGPT doesn't say which chat it shows,
so its banner stays down only when that chat is the one you last sent a prompt in (a turn
ChatGPT starts by itself towards a goal is no prompt) or last opened from the island, and
ChatGPT has stayed in front, unlocked, since; a reply in another chat gets its banner. Going to
another chat without sending anything still counts as being at the first. Where Islet can't tell
— the ChatGPT activity turned off, or ChatGPT already in front as Islet starts — a reply gets no
banner while the app is in front. Settings → Activities → ChatGPT → Skip Done when the chat is
on screen turns this off, and every reply in the app then gets a banner. A permission ChatGPT
asks while you're in another app can be answered in the island too (see [Approving from the
island](#approving-from-the-island)).

**Gemini.** While one of Gemini's agents in Google Antigravity works on a conversation, a wand
breathes left of the camera and the run's time counts up right of it, or, once the agent has
written its task list, a ring fills as the list gets done. When an agent asks you a question,
waits for you to allow a tool, or stops to wait on you, the wand turns orange with a question
mark at its corner, and the time counts how long it has waited; when one stops on an error, or
because Antigravity's quota has run out, it shows a warning and "Error" or "Quota" for a few
minutes. Opened, there is a row for each
conversation: Antigravity's title for it (or its workspace, with Settings → Activities → Gemini →
Show what you asked off), the workspace and the model, what the agent is doing ("Running npm",
"Editing Store.swift") and for how long, the tools it has used so far ("11 steps · npm,
Settings.tsx, theme.ts"), the subagents it has sent off and what each is doing, and its task
list as a checklist with a bar ("2 of 4 done"), from where it has got to. Banners say when an
agent finishes, has a question, waits for your approval or needs your input, reaches its step
limit, stops on an error or runs out of quota ("Gemini quota reached"); a run you stop yourself
gets none, and a subagent's only for an error or its quota. Antigravity has no measure of quota
left that Islet could read without signing in as you, so that banner is all there is.
Click a conversation, or a banner, to bring Antigravity forward: it can't be asked from outside
to open a conversation, so you pick it there. A finish in the conversation Antigravity has in
front, while it is in front and the screen unlocked, puts up no banner; Islet tells by
Antigravity's window title, which it reads through Accessibility, so without Accessibility for
Islet every finish gets its banner. Settings → Activities → Gemini → Skip Done when the chat is
on screen turns this off. A wait gets its banner only while Antigravity isn't in front. Like
Claude Code and ChatGPT it sits in the bubble beside music or a timer, behind the Sound Mixer
unless a conversation is waiting for you. Antigravity tells Islet all this through its hooks,
with the script in `Scripts/` (see [Antigravity hooks](#antigravity-hooks)); nothing shows until
the hook is added. Nothing can be approved or denied from the island: the hook only tells. The
hooks say when the model is called, when each tool finishes and when the agent stops, but not
while a question or a tool waits on you, nor always when you stop an agent yourself, so Islet
also reads Antigravity's list of conversations: a step waiting on you there makes the
conversation wait (and puts up its banner), a conversation the list says is idle is over half a
minute after its last event, one quiet for ten minutes is over (an hour while the list says it
runs, background tasks and all), and a wait is let go after two hours.

**Sound Mixer.** Every app playing sound, each with its own volume (0–150%) and a mute, in
the opened island and on the home page. When two apps play at once, the mixer takes the
bubble beside the island, unless a Claude Code, ChatGPT or Gemini session is waiting for you. macOS has
no per-app volume, so Islet makes one with Core Audio process taps (macOS 14.2 or later): the
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
straight to where it's needed, open it, show it in Finder, or delete it. Drag the file out
(into an upload field, say) and the card stays until you delete or close it, for up to ten
minutes, stepping aside while another card, a new download or anything else that starts
meanwhile (a timer, a call) needs the island, and coming back after; nothing is deleted when
you let go, as the browser may still be reading the file. Delete asks first, its button turning
into Delete and Cancel, and the card keeps asking, wherever the pointer goes, until you answer.
A click anywhere outside the island, or Escape once Islet has Accessibility access, counts as
Cancel, and the card goes back to its buttons. Only Delete deletes the file, for good: it isn't
put in the Trash. It deletes only the card's own file, and only while it is still the file that
finished, so one moved, replaced or changed since is kept, and the card says so. A folder (an
app, or an archive Safari has opened) has no Delete, and nor does a download still under way.
Browsers tell Finder how a download is going by publishing its progress, which is how Finder
draws the bar under the file's icon, and Islet listens the same way; a browser that publishes
nothing (Firefox) is followed by the size of its partial file. Browsers also tell the Dock when
a download finishes, so one too quick to see still gets its card. Nothing runs while nothing is
downloading: a download that stops for a minute (paused, or waiting for you to keep a file
Chrome has warned about) leaves the island, and comes back the moment it moves again. Islet
only watches: it can't pause or cancel another app's download, and one that fails or is
cancelled just goes. Safari's own download folder is followed too when it is set to another; a
download another browser saves elsewhere shows only once it has finished. The first time, macOS
asks whether Islet may see your Downloads folder.

A PDF you save from Print gets the same card, saying Saved rather than Downloaded: ⌘P, then PDF
› Save as PDF in any app (Safari, Preview, Notes, Mail, Pages, TextEdit), or Save as PDF in the
print preview of Brave, Chrome, Edge or Arc, and Firefox's Save to PDF. It shows wherever in
your home folder you save it (the Desktop, Documents, Downloads, iCloud Drive or a folder of
your own), usually about two seconds after it is written and longer for a long document, and
each time you save it under the same name, after deleting it or choosing Replace. Nothing tells
other apps a PDF has been printed, so Islet asks Spotlight to say when a PDF is written.
Spotlight already knows what wrote it and when it was made, put in its folder and downloaded,
which rules most out; one that the Mac's print engine or a browser's wrote is then read for the
PDF's own creation date; Spotlight tells of none in a folder macOS hasn't let Islet see, so
reading one never has macOS ask. Only PDFs just made there count: not downloads (which show
once, as downloads), moves, duplicates, unzipped files or files synced down from iCloud or
Dropbox, which all arrive in their folder after they were made; not a copy of one shown, or a
new file of a PDF made more than an hour before; not a PDF edited and saved again in Preview, or
one made before Islet started; not the PDFs apps keep for themselves in the Library folder, the
Trash, hidden or temporary folders; and not a batch of more than three at once (a folder
copied), whose card goes if one went up before the rest were heard of. A new file of a PDF
printed within the hour, by a copy that makes one (`cp` does) or a script, can look just printed
and show. A PDF with a password to open doesn't show, as nothing can be read of it, nor does a
print that takes more than five minutes to write. Spotlight tells Islet only of folders macOS
lets it see, and without asking: Settings › Downloads has a button to be asked about the
Desktop, Documents and iCloud Drive, which then says what macOS decided about each. macOS asks
only once, so a folder refused there is turned on in Privacy & Security › Files & Folders, which
the row opens; with Full Disk Access there is nothing to ask, and the row says so. Your
Downloads folder (and Safari's) is also watched directly, and a new PDF there is read, so
Brave's Save as PDF, which saves there, shows within a second, and still shows with Spotlight
turned off; elsewhere, nothing is seen while Spotlight is off. A live Spotlight query costs
nothing while nothing is saved. Turn it off with Show PDFs saved from Print.

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
thumbnail: click its picture to mark it up in Preview. The switch turns the thumbnail off only
while Islet is running: quit Islet (or should it crash or be forced to quit) and screenshots
float in the bottom-right corner as usual again, until Islet next starts. Should Islet crash, a
small helper of its own, ThumbnailKeeper, puts the thumbnail back; it waits beside Islet while
the switch is on, and costs nothing meanwhile. Turn Show Floating Thumbnail back on in the
Screenshot app and Islet turns its switch off rather than undo it; with the switch off, Islet
leaves that setting alone. Turn on Delete after copying and Copy on the card also deletes the
screenshot once its picture is on the clipboard, to paste wherever it's wanted: deleted for
good, not put in the Trash, so it can't be got back. Islet reads the picture back from the
clipboard before it deletes anything, deletes only the screenshot the card was made for, and
keeps one that has changed or moved since, or that is on the Drop Zone shelf; the card says when
it has kept one. A screenshot copied to the clipboard (with Control held down) makes no file, so
Islet doesn't see it. The first time, macOS asks whether Islet may see the folder screenshots
are saved to (the Desktop, unless you've chosen another).

**Clipboard History.** The last dozen things you copied — text, links, pictures and files —
on the home page, newest first, each with the app it came from and when; click one and it is
on the clipboard again, ready to paste, or drag it into another app: text as text, a link as a
link, a picture as a picture file (written only as you drop it, in a folder only you can open,
and removed a quarter of an hour later), files as the files themselves (of several, the first
still there). A drag copies nothing, and the island closes as it leaves, so what it covered can
take the drop. The tile's arrow opens a page with all of them, where a pin keeps one at the
top, across restarts too, and Keep Open in the header holds the island open, whatever the
pointer does, to drag out one item after another. Click it again, press Escape or click the
notch to let go; choosing another page, the island closing, the Mac sleeping or locking, or
five minutes with the pointer away lets go too. macOS says nothing when something is copied, so
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

**Quick Ask.** A quick question without opening a chat app: press ⌥⇧Space in any app (or click
the Ask tile on the home page, or run the Open Quick Ask action from Shortcuts) and a box opens in
the island on the display under the pointer, ready to type. Return asks; Shift- or Option-Return
starts a new line; Escape, ⌘W, a click outside or the shortcut again closes it. The answer comes
into the island as it is written, a follow-up goes on from the conversation so far for as long
as the island stays open (the box closed and opened again meanwhile or not), and Copy puts it on
the clipboard (marked as passing, so clipboard histories — Islet's own too — leave it out). The
app you were in stays in front the whole time, its menu bar and all, and has the keyboard back
when the box closes. The shortcut can be changed or turned off in Settings; it takes over the
non-breaking space ⌥⇧Space would otherwise type.

To read an answer while you work, click Keep Open in the box's header (there once something has
been asked or added, in either mode). The island then stays open on the box whatever the pointer
does: a click in another app gives that app the keyboard and leaves the box, its draft and the
conversation where they are, and an answer still coming keeps coming. A click on the field, or
the shortcut, takes the keyboard back for a follow-up, which goes on from the conversation as
ever; the shortcut again hands it back rather than closing the box. Click Keep Open again, press
Escape or ⌘W in the box, or click the notch to let go, and the island closes as usual, the
conversation with it; choosing another page, the Mac sleeping or locking, or half an hour with
the pointer away lets go too (Escape pressed in the other app is that app's). The first time an
answer shows while you're heading for another app, the header says so, once.

Three can answer, chosen from the chip beside the field and remembered: **On this Mac**, Apple's
on-device model (macOS 26 or later, with Apple Intelligence on), which is the fastest and sends
nothing anywhere; **ChatGPT**, through the command line tool inside the ChatGPT app, signed in as
the app is; and **Claude**, through the command line tool inside the Claude app. Claude's app
keeps its sign-in to itself, so Settings › Quick Ask › Connect Claude shows the command to run
once in Terminal (`claude setup-token`) and takes the token it prints, which Islet keeps in its
own keychain item. Until you choose, the first that can answer does, in that order; under an
answer from this Mac, one click asks ChatGPT (or Claude) the same question. What goes wrong is
said in a line with what might help: the app not installed, not signed in, a usage limit and
when it resets, offline, busy, Apple's model refusing or too full (with Start afresh to ask
again without the earlier questions), no word from the tool for 20 seconds, or no whole answer
after 90. Another provider is suggested only when one is offered beside it.

**Look at my screen.** The eye beside the field (or ⇧⌘S while typing) takes one picture, then
and only then, for your next question: the front window of the app you were in, or the whole
display the island is on (held, the eye offers the choice, which Settings › Quick Ask keeps too).
Islet's own windows are never in it. It's shown over the field before anything is sent, with what
it is of and where it will go — "Stays on this Mac" for On this Mac, "Sent to ChatGPT (or Claude)
with your question" — and ✕ to take it away. It goes with that one question, made no larger than
1600 pixels on its longest side: On this Mac is handed it in memory (Apple's model sees pictures
on macOS 27), Claude's tool gets it on its standard input beside the question, and ChatGPT's tool,
which only takes a file, gets a private one in its run's own folder that goes as soon as ChatGPT
has read it. A provider that can't see pictures says so and offers one that can, in one click; the
picture is never quietly left behind. Follow-ups don't send it again: ChatGPT and Claude are told
in words that an earlier question came with one (press the eye again for a fresh look), and On
this Mac, whose conversation stays in memory, still has it. The day summed up never takes it. The
picture needs Screen Recording, which macOS asks for the first time you press the eye and never
otherwise; while it's off the box says how to turn it on, with a button to the right pane of System
Settings.

**Your calendar, to On this Mac.** Ask "am I available today at 8?", "when's my first class
tomorrow?" or "anything on Friday afternoon?" and On this Mac looks it up: Apple's model is given
a tool that reads the calendars Quick Calendar checks, for a day or up to 31 at once, and gets back
short lines — each event's title, time, place and calendar, all-day ones, clashes, the free time in
your day, the travel time Quick Calendar allows before an event with a place (said as travel time),
and whether a time you asked about is free. Its instructions say what day and time it is as you ask
and in which time zone, so "today", "tomorrow morning" and "this Friday" are the right days; an hour
said without am or pm ("at 8") is checked for the morning and the evening, and the answer covers
both unless it's clear which you meant. Asked what's on a day, today included, it gives the whole
day and says which events are over; asked what's left today, only what's still to come; asked
what's next, that one event. The tool only reads: nothing it can do adds, changes or deletes an
event (adding one is still only Quick Calendar's Add), and what it reads stays with Apple's model
on this Mac. With calendar access off it says so, and the box offers the button to allow it. A
question like that meant for ChatGPT or Claude isn't sent: the box says your calendar stays on this
Mac and offers Ask Apple's model in one click, or asking them the question alone anyway. An answer
made from your calendar is never passed on to them in a follow-up (they're told only that there was
one), and ChatGPT or Claude isn't offered under it. Settings › Quick Ask › Let Apple's model read
your calendar turns it off (it's on unless you do, since nothing leaves the Mac).

Islet keeps nothing. Your questions and their answers stay in memory while the island is open,
for follow-ups, and are gone when it closes — nothing is saved, logged, or put on the clipboard
unless you press Copy. On this Mac answers with Apple's on-device model; nothing leaves your
Mac. ChatGPT and Claude send your question to OpenAI or Anthropic through their app's own
command-line tool, with no history or session saved on this Mac, no tools, and none of your
hooks, plugins or MCP servers; what OpenAI and Anthropic keep is up to their own privacy
policies. Your calendar is never sent to ChatGPT or Claude; after your day is summed up in the
box, or On this Mac answers from your calendar, they're told only that it was, and On this Mac
alone is given it, for a follow-up. A
picture of your screen is taken only when you press the eye, is never written anywhere but that
private file for ChatGPT's tool or logged, and is forgotten with the conversation. Quick
questions to ChatGPT count towards the same usage as the ChatGPT app. Each question to ChatGPT
or Claude runs its tool afresh in an empty folder of its own, which goes as it finishes, with
the question on its standard input rather than its command line, only the environment it needs,
and a model given no tools at all — no shell, no files, no web — so an answer can't act. The one
thing that can't be left out: a global `AGENTS.md` of your own in `~/.codex` would go with each
question to ChatGPT.

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
is full the rest go on the other. A single other activity goes right, and left only when the
menu bar has no room for it there, as when macOS shows its pill for a shared screen or the
camera beside the notch. On the left they
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
VoiceOver has the same as actions. To keep one there whenever it is going on, say your music,
drag it to the top of Settings → General → What Stays in the Island; the last item in those
menus and in the opened island's "…" menu, Choose What Stays in the Island…, opens Settings
there. The list has the activities of the features that are on, in the order the island takes
them, the first marked In the island and the rest In a bubble. That order decides from then on,
for the bubbles too, and Reset goes back to Islet's own. Only a chosen activity, or a preview on
screen for a moment, goes before it.

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

**Colours that move.** The island's fill can also be a gradient, down from the camera housing,
across or corner to corner, or colours fading slowly one into the next, round and round. Both
take a palette (Rainbow, Sunset, Ocean, Aurora, Ember, Night, Pastel, or two to six colours of
your own) and a tone: Deep, under white words, or Bright, under black ones. The words never
change colour as the fill moves, so every colour the fill passes through is darkened or
lightened until full ink reads at 7:1 on it, and the island keeps the room a plain one has for
cards, secondary words and colours that mean something; Settings shows the colours as they are
drawn and names those that were moved. A ring of colour can run round the island's edge like a
strip of lights, over any fill — a black island with a rainbow ring, say — either steady in one
colour or with colours travelling round it, with a thickness, a glow and a brightness. It runs
round the bubbles beside the island too, and under a notch it runs down from the menu bar,
round the island and back up; at rest the island is the notch and has none. Only colours move,
never brightness, and slowly: the quickest fill takes 3 seconds from one colour to the next and
the quickest ring 5 seconds a lap. Core Animation moves them, so Islet itself does nothing while
they do, and they hold still whenever nothing shows them, the screen sleeps or locks, the
screen is shared or recorded (unless you say otherwise), and with Reduce Motion or Low Power
Mode on. The ring never reaches under what the island shows, and never draws outside it.

**Saving energy.** In Low Power Mode, or on battery if you choose (Settings › General › Save
energy: In Low Power Mode, On battery, or Never), nothing in the island moves for long. The
Now Playing waveform stands still, as uneven bars while music plays and low ones while it is
paused, and stops listening to the music altogether, so macOS's recording indicator goes; the
spinners stand as an arc from the top, as with Reduce Motion, and the breathing marks of
Claude Code and ChatGPT are drawn whole; the island's colours are drawn still; lyrics change
line by line, a line too long cut short rather than scrolled; a long title in the player stays
put, cut short; the timer's ring moves once a second; and the player's clocks are redrawn only
as they turn over. The island changes within a moment of Low Power Mode or the power source
changing, and the clipboard, the countdowns and everything else keep their pace.

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
| `activity` | `claudeCode`, `chatGPT` or `gemini`: the banner is news of the Claude Code, ChatGPT or Gemini activity, so while that holds the island, one beside the notch takes its place rather than going in a row under it; anything else is ignored |
| `session` | With `activity`, the session the banner is news of, by the id its hook was given (letters, digits, `.`, `-` and `_`, up to 128): a click on the banner opens that session as a click on its row does, if Islet has a session by that id for that activity, and otherwise opens the island; resting the pointer on it does not open the island, so it stays to be clicked |
| `event` | `done`, with `session`: the banner says a reply finished, and stays down while that session's chat is on screen (see Claude Code, ChatGPT and Gemini above) |

Spaces go in as `%20` (a `+` stays a plus), and a `#` as `%23`, since a bare one ends the
query. Titles are cut at 60 characters and subtitles at 120, and a colour that would not show
on the island's colour is darkened or lightened, keeping its hue, only as far as it must be to
stand out. Nothing in a banner can be clicked, whatever the URL says: a banner naming a session
opens it only as its row would, from what Islet already knows of it, never from the URL. Banners that come faster
than one a second, or more than five in ten seconds, wait their turn, and only the newest of
those waiting is shown, so a script stuck in a loop cannot keep the island flickering. While
something is already in the island — music, a video, a timer — a banner beside the notch goes
in a slim row under it instead, as the volume does, so what was there stays in sight, unless
the banner is news of what is there (`activity`), as a song change is of the music. With the
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
script in [Claude Code hooks](#claude-code-hooks) does that and more, and the one in
[ChatGPT hooks](#chatgpt-hooks) does the same for ChatGPT, as the one in
[Antigravity hooks](#antigravity-hooks) does for Gemini.

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
Activities → Claude Code copies them too). After updating Islet, copy the script again before
adding hooks it did not have: an older copy would keep in its log everything the
PermissionRequest and tool hooks hand it, commands and their output too, so while one is
installed Settings leaves those hooks out of what it copies.

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" start" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" prompt" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 600,
      "command": "/bin/bash -p \"/Users/you/.claude/hooks/islet-notify.sh\" permission --timeout 600" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" notification" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "timeout": 10, "async": true,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" tool" }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "timeout": 10, "async": true,
      "command": "bash \"$HOME/.claude/hooks/islet-notify.sh\" tool" }] }],
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

The PermissionRequest hook names the script by its whole path, your home folder's in place of
`/Users/you` (Copy Hooks fills it in), and runs it through `bash -p`, which takes no shell
functions from the environment Claude Code was started in; its long timeout is how long the
island may wait for your answer. Each hook hands the script its kind of event. SessionStart and
SessionEnd make and delete the session's file, UserPromptSubmit marks it working, Notification says when Claude needs your
permission or an answer, and Stop marks it done. PermissionRequest notes each permission asked
(the tool, the agent that asked, and for a command a fingerprint, never the command); it prints
nothing, so the asking stays Claude Code's, unless you answer it in the island
([Approving from the island](#approving-from-the-island)); the session shows "Needs permission" only once
Claude Code's Notification says it is still waiting, a few seconds on. Claude Code says nothing
when you answer, so the next word from that tool or agent does: PostToolUse or
PostToolUseFailure once the tool has been used, the agent stopping or carrying on (all a denial
leaves), or for the session's own, the turn ending; and Islet sees an allowed command running,
long before it finishes. The session is then working again, or done if its turn has ended. The
tool hooks come after every tool call, so they run without Claude Code waiting (`async`), and
end at once for a session with nothing asked. Without the PermissionRequest hook, "Needs
permission" lasts until the turn ends, as it did before. Claude Code sends no event when a
background workflow finishes, but Stop and SubagentStop list the session's background tasks —
workflows, agents sent off in the background, commands left running — and SubagentStop comes
often while workflows run, so the list stays current, and a workflow gone from it gets its
banner. The script keeps no command line: a command Claude Code describes by the command alone
is kept by the name of the program it runs. If you copied the script before background agents
and commands showed, copy it again to see them; workflows' progress needs no new copy. Claude
Code waits for UserPromptSubmit's hooks before it sends the prompt, so the script is quick,
prints nothing and always succeeds. Its banners are news of the Claude Code activity
(`activity=claudeCode`), so while that holds the island, "Needs permission" takes its place for
a moment rather than going in a row under its own raised hand; if yours go in the row, copy the
script again. Each names its session (`session=`), and the Done card says it is one
(`event=done`); the session's file keeps the Claude app's own id for it and the terminal it runs
in, which is how a click finds it. Copy the script again for banners that open their session. It needs `jq`, part of macOS from 15 on (`brew install jq` before that). It keeps
the last 200 events other than agents stopping and tools used in
`~/.claude/hooks/islet-hook-log.jsonl`, to show what each carries (a prompt by its length
alone), and `ISLET_NOTIFY_DRY=1` prints its banners instead of showing them. Its header lists
what each session's file holds. The workflows the earlier script kept in
`~/.claude/hooks/islet-workflows` are moved over at each session's next event, and the folder
goes once they have all been, or are a day old.

### ChatGPT hooks

`Scripts/chatgpt-hook.sh` is a hook script for Codex, which the ChatGPT app runs on. It puts up
banners — a reply finished (a card with its start), ChatGPT waiting for permission or asking a
question — while the app it runs in is not in front (a reply in the ChatGPT app goes to Islet
either way, which decides), each naming its chat so a click opens it, and keeps a small file for each chat in
`~/Library/Application Support/Islet/ChatGPT/Sessions`, which the ChatGPT activity follows. Copy
it into Codex's hooks folder:

```bash
mkdir -p ~/.codex/hooks
cp Scripts/chatgpt-hook.sh ~/.codex/hooks/islet-notify.sh
```

and add these hooks to `~/.codex/hooks.json` (Settings → Activities → ChatGPT copies them too).
If the file is there already, add each event's entry at the end of that event's list, so the
hooks you have already trusted stay trusted:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" start" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" prompt" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "timeout": 10, "async": true,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" tool-start" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" permission" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "timeout": 10, "async": true,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" tool-end" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" stop" }] }],
    "Interrupt": [{ "hooks": [{ "type": "command", "timeout": 3,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" interrupt" }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" agent-start" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "timeout": 10,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" agent-stop" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "timeout": 3,
      "command": "bash \"$HOME/.codex/hooks/islet-notify.sh\" end" }] }]
  }
}
```

Codex runs no new or changed hook until you trust it: in the ChatGPT app, in Settings → Hooks
(Reload hooks, then Trust beside each of Islet's; the composer's Review hooks does the same), or
with `/hooks` in Codex. Trust all would trust every other new or changed hook too, not only
Islet's. Islet never edits `~/.codex` and never trusts anything for you; until you have,
Settings says it has not heard from ChatGPT yet. If the ChatGPT app offers to import your setup
from Claude Code, leave its hooks out: Islet's Claude Code hooks would then run for every chat
too, which would show each chat twice and put up each banner twice.

The ChatGPT app runs these hooks, and so does the `codex` it bundles; the Homebrew `codex` 0.44
has none. Codex's `notify` setting is left alone. Other apps that use `~/.codex`, such as
ChatGPT for Chrome, run the same hooks, and their chats show too.

Each hook hands the script its kind of event. SessionStart and SessionEnd make and delete the
chat's file, UserPromptSubmit marks it working, PreToolUse and PostToolUse say which tool is
under way and carry the turn's plan, PermissionRequest and a question put to you mark it
waiting, Stop and Interrupt mark it done, and SubagentStart and SubagentStop follow its agents.
The two tool events run in the background, since they come with every tool; one arriving late or
out of order never undoes a later event. From the same events the script keeps the turn's steps
so far (`history`), the commands the chat has left running (`shells`), how far each agent's own
plan has got, and the folder Codex keeps its files in (`codexHome`); a prompt that steers a turn
under way carries it on, and a turn Codex starts by itself to carry on towards a goal counts as
a new one. The script keeps no command, patch, question, tool input or output, what was typed
into a command left running, agent's message, reply or plan steps, or model, only the program a
command runs and the first file a patch changes; nor a plain chat's folder, which ChatGPT names
after its prompt. What no hook says, Islet reads for itself, read-only: the end of a command
left running from the thread's rollout file (its id alone, and whether the call's output begins by
saying it is still running), and from Codex's own databases in
that folder, the thread's goal (its objective's first words, its state and what it has used) and
how many follow-ups wait in its queue, never their words. Codex waits for most of the hooks, so
the script is quick, prints nothing (but an answer given in the island) and always succeeds. It needs `jq`, part of macOS from 15 on
(`brew install jq` before that). It keeps the last 200 or so events other than tools' in
`.hook-log.jsonl` beside the chats' files, a prompt and a reply by their length alone, and
`ISLET_NOTIFY_DRY=1` prints its banners instead of showing them. Its header lists what each
chat's file holds. A new version of the script is installed by copying it over the old one; the
hooks' lines stay as they are, since a changed hook has to be trusted again (only the longer wait
for approving from the island changes one, if you choose it).

### Antigravity hooks

`Scripts/antigravity-hook.sh` is a hook script for Google Antigravity, where Gemini's agents
run. It puts up banners — an agent finished (a card with the conversation's title), stopped to
wait on you, reached its step limit, stopped on an error or ran out of quota — each naming its
conversation, and keeps a small file for each conversation in
`~/Library/Application Support/Islet/Gemini/Sessions`, which the Gemini activity follows. It
is for Antigravity, not Gemini CLI, whose hooks are different. Copy it into a folder of its own
in `~/.gemini`:

```bash
mkdir -p ~/.gemini/hooks
cp Scripts/antigravity-hook.sh ~/.gemini/hooks/islet-antigravity.sh
```

and add Islet's hook to `~/.gemini/config/hooks.json` (Settings → Activities → Gemini shows it
and copies it, and says whether it is set up). The file is one JSON object, a key for each named
hook; if it is there already, put `"islet"` inside its braces beside the others. Islet never
writes to `~/.gemini`: you add the hook yourself, and Islet only reads there. Reading
Antigravity's list of conversations, a SQLite database Antigravity keeps open, SQLite marks the
reader's place in the database's shared-memory index (its `-shm` file), as it does for any
reader; nothing in the database or in Antigravity's settings changes.

```json
{
  "islet": {
    "PreInvocation": [
      { "type": "command", "timeout": 5,
        "command": "/bin/bash ~/.gemini/hooks/islet-antigravity.sh invocation" }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command", "timeout": 5,
          "command": "/bin/bash ~/.gemini/hooks/islet-antigravity.sh tool" }
      ] }
    ],
    "Stop": [
      { "type": "command", "timeout": 5,
        "command": "/bin/bash ~/.gemini/hooks/islet-antigravity.sh stop" }
    ]
  }
}
```

Each hook hands the script its kind of event. PreInvocation, before each call to the model,
marks the conversation working (and starts a new run after the last one stopped); PostToolUse,
after each tool, counts it and keeps what sort of tool it was; Stop marks the run done, waiting
for you (when the agent's last tool was `notify_user` waiting on you), at its step limit,
stopped by you (no banner), stopped on an error, or out of quota (an error that says
`RESOURCE_EXHAUSTED`, quota, a rate limit or a 429 status), or still going in the background,
when Antigravity says background tasks are not done. It reads how a run stopped by the
documentation's words (`model_stop`, `max_steps_exceeded`, `error`) or by the names Antigravity
gives its reasons (`EXECUTOR_TERMINATION_REASON_MAX_INVOCATIONS` and the like). A question
(`ask_question`) or a tool waiting for your leave sends no event until you answer, so Islet
learns of those from Antigravity's list of conversations instead. A subagent's run, one a
conversation sends off, is kept with the conversation that sent it off (`parentConversationId`)
and listed under it, and gets a banner only for an error or its quota, naming that conversation.
The script keeps no command, file contents, folder, question, message, prompt or
reply: only the program a command runs, the name of the file a tool wrote or read, an MCP
server's name or the tool's own, and the first 120 characters of an error that stopped the
agent. Each conversation's title comes from Antigravity's list of conversations
(`~/.gemini/antigravity/conversation_summaries.db`), and its task list from the `task.md` among
its own files (`~/.gemini/antigravity/brain/<conversation>/`), both read-only and only inside
`~/.gemini`; from the list, only each conversation's title, the start of it, how its run stands
and whether a step of it waits on you, and on what.

The script only tells: it never changes what Antigravity does. Antigravity takes a hook's
standard output as its answer, and the script prints exactly the answer Antigravity's
documentation gives for leaving things as they are, before it reads anything: `{}` for
PostToolUse (which "expects an empty JSON object"), PreInvocation (nothing to inject) and Stop
(only `"decision": "continue"` would keep the agent going). It isn't on PreToolUse: every
decision the documentation gives a PreToolUse hook (`allow`, `deny`, `ask`, `force_ask`) overrules
Antigravity's own, and it gives none that leaves it be; should you put the script there anyway
it prints nothing, and Settings says so. It always exits 0, within three seconds at most (a
watchdog ends it, well inside the hook's five), reads the whole event however large, and keeps
only its first megabyte. It needs `jq`, part of macOS from 15 on (`brew install jq` before that).
It keeps the last 200 or so events in `.hook-log.jsonl` beside the conversations' files, by the
names of what each carries, never their values but a tool's name and how a run stopped, which
says what a new version of Antigravity sends; `ISLET_NOTIFY_DRY=1` writes its banners to standard
error instead of showing them. Its header lists what each conversation's file holds. A new version
of the script is installed by copying it over the old one.

### Approving from the island

When Claude Code or ChatGPT asks permission (to run a command, write or edit a file, fetch a
page or use a tool from an MCP server), the island can show the request on the agent's page and
take your answer there. It shows what is asked in full: the command or the file's new content
line by line, numbered, with `↩` where a long line wraps; every setting the tool was given; the
folder, the app and any subagent asking, with the branch and when the session started; and the
agent's own words about it, never taken for Islet's. A hand stands beside the notch with
"Allow?" ("Answer?" where Allow isn't offered; for ChatGPT, the seconds left), and the island
opens on the
request by itself once, unless you're presenting, the screen is locked, the app that asks is in
front or you're already using the island; it closes after 12 seconds unless you move the pointer
into it. Several requests queue behind the one shown ("1 of 3", and a row of those waiting that
brings each forward); while the pointer is in the island the one in front never changes under
it. Nothing makes a sound, and the card never takes the keyboard.

- **Answer in the app** brings the app that asked forward, where its own prompt is waiting.
  Claude's prompt shows at the same moment and still works; answering there takes the card away.
- **Deny** tells the agent no, as the app would. It's there only while Islet can sign answers
  (see below).
- **Allow** works only for a click of yours on it: the card must have been on screen a moment,
  you must have moved onto Allow from outside it and rested there (a pointer already on Allow
  when the card comes must leave it first), and seen the whole request (a long one says "Scroll
  to read it all" until you have). A click another program makes, or one through a window
  over the island, is refused. VoiceOver and Switch Control get the card's buttons too, with the
  whole request read out first. There is no Always allow: each request is answered once.

Allow isn't offered, only Deny and Answer in the app, for a request that writes to a place that
runs things or approves them (shell start-up files, `~/Library/LaunchAgents`, git hooks,
`~/.claude`, `~/.codex`, Islet's own folder, however the disk would spell them, `~/.CLAUDE` or
`~/.zſhrc`, and through any linked folder) or writes through a link leading out of the project,
holds characters you couldn't see (shown as their code, such as `‹U+202E›`), fetches an address
that could be read two ways (with a backslash, or a name and `@` before the host), carries a
setting the island has no layout for, or comes from an app that doesn't take its prompt away
once answered. While Presentation Mode is on or the screen is shared, the card says only that
the agent needs permission. Questions an agent asks you, and plans to approve, are always left
to the app.

**Setting it up.** Copy the new script over the old one (as in
[Claude Code hooks](#claude-code-hooks) and [ChatGPT hooks](#chatgpt-hooks)), then in Settings →
Activities → Claude Code (or ChatGPT) click **Set Up** beside Approvals key. Islet keeps a
signing key in your login keychain and writes its public half to `islet-approvals.pub` beside
the hook script; the hook takes only answers signed with it, so a program that can write into
Islet's folder still can't answer for you. The first Set Up always makes a new key, in place of
anything already in the keychain under its name, and setting up the other agent writes out
the same key only. Islet signs only while each file holds its own key: if one changed, Settings
says so, the island offers only Answer in the app, and **Reset Key** makes a new one. For Claude Code, paste Copy
Hooks' PermissionRequest entry in place of the old one, whose 10-second timeout lets a request
stay only about 9 seconds; new sessions pick it up, and nothing needs trusting.

ChatGPT asks in the app only once the hook gives up, so a request waits in the island only
briefly, and not at all while you're away, locked, presenting or in ChatGPT; one you haven't
looked at in the island for 12 seconds while you work in another app goes back to ChatGPT
then. Claude Code in a terminal is treated the same way, waiting at most 30 seconds, until it
is known whether its own prompt shows while the hook waits. With the hook line
as it is, it waits 8 seconds and needs no new trust. To wait longer (15, 30 or 60 seconds,
Settings → ChatGPT → Wait in the island), paste **Copy Line**'s PermissionRequest entry in place
of Islet's in `~/.codex/hooks.json` and trust it once more in ChatGPT, since a changed line has
to be:

```json
{
  "hooks": {
    "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 90,
      "statusMessage": "Waiting for your answer in Islet",
      "command": "/bin/bash -p \"/Users/you/.codex/hooks/islet-notify.sh\" permission --timeout 90" }] }]
  }
}
```

Anything your shell's start-up files print when an app runs a hook gets in the way of the
answer, so keep them quiet for scripts. Turn **Approve from the island** off in either agent's
settings to leave every request to its app again; the hook then waits for nothing. An earlier
test build may have left an item called "Islet approvals key" in your login keychain; it isn't
used, and you can delete it in Keychain Access. After setting up, a Keychain prompt about the
approvals key is unexpected: deny it and reset the key.

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
- `Islet/Input/` — the input box: the one page of the opened island that is typed in, its
  modes (a feature registers one with `InputCenter`), the shortcut that opens it, and the
  Shortcuts action.
- `Islet/Support/` — views and helpers shared by every feature, and the island's colours:
  `IslandTheme`, the `.island…` styles, `SystemHue` and `FeatureTint`; the fills and ring in
  `IslandLook`, and the one clock their motion keeps time by in `IslandMotion`.
- `Islet/Settings/` — the Settings window and its search. The search finds a feature by its
  title and summary with nothing more; the other words it goes by, its settings' labels and
  other names for it, are in `SettingsSearchTerms.swift` beside every other feature's. A
  section added to the General tab is found once it is a `GeneralRow`.
- `ThumbnailKeeper/` — a small tool of its own, built into Islet's `Contents/Helpers`, that
  puts macOS's screenshot thumbnail back should Islet go without doing so itself. It shares
  two files with Islet (`Islet/Features/Screenshots/FloatingThumbnailHolders.swift` and
  `ScreenshotSettingsStore.swift`) and nothing else.
- `Vendor/mediaremote-adapter/` — see below.

**Typing in the island.** The island's panel is a non-activating panel that never has the
keyboard, except while something in it is being typed in, and then only because the person asked:
the shortcut, a click on a field or a tile that opens one, the Shortcuts action. Hovering, a
banner, a card appearing, an activity or an `islet://` URL never takes the keyboard (a URL can
show the input page; a click in its field then types). A page asks for the keyboard with
`IslandViewModel.beginTyping(in:client:)` — through `IslandManager.beginTyping`, which ends typing
in any other island first — and the window controller sets `IslandPanel.takesKeys` and makes the
panel key. The app in front stays in front: Islet is never activated, so the menu bar,
`frontmostApplication` and everything that watches them are unchanged. While typing, the island
stays open wherever the pointer goes. Typing ends on Escape, Close, the shortcut, a click outside,
a change of page, the island closing, a full-screen app taking the display, the panel losing the
keyboard (⌘Tab) or the feature stopping; the flag goes off and, if the panel still has the
keyboard, it is ordered out and straight back in, which hands the keyboard back to the app in
front. The client is told why (`TypingEnd`, logged as a word, never what was typed) and forgets
what was typed. The input box keeps its conversation while the island stays open, to go on from
when it is opened there again, and forgets it as the island closes
(`IslandViewModel.didCloseNotification`), or at once when typing ends because the island is
going, the feature stopped or the box moved to another display. Meanwhile the panel lets only
the Edit menu's key equivalents through (copy, paste, cut, select all, undo, redo), handles its
own (⌘Return, ⌘1…, ⌘W) and swallows every other ⌘ key, so none reaches Islet's own menu: ⌘Q
never quits Islet from the box (`KeyEquivalentRule`).

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

The input box, Quick Ask and Quick Calendar use the roles above and no new ones: the chips beside
the field are `.islandWashed` in the feature's colour, the field is `.islandPrimary` with its
placeholder in `.islandText`, a code block and the preview's chips and blanks lie on
`.islandSurface`, Keep Open in the box's header is the clipboard's own button in the mode's
colour, with its hint in `.islandText`, Add is `filledButton(.quickCalendar)`, a clash (the Today
tile's badge, the Day page's marker, the clash card) is marked in `.islandHue(.warning)`, and free
time in `.islandHue(.success)`.

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
