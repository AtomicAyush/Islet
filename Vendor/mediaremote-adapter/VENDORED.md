# mediaremote-adapter (vendored)

Upstream: https://github.com/ungive/mediaremote-adapter
Commit:   73f14ab1568371e6e3c44063f21c34c5e2712c4d (2026-09-04)
Licence:  BSD 3-Clause, see LICENSE

Only the framework sources (plus the one test header they include) and the Perl
entry point are kept; the test client and the CMake project are not.
`Scripts/build-mediaremote-adapter.sh` compiles the framework during the Xcode
build, so no prebuilt binary is checked in.

Since macOS 15.4, MediaRemote only answers entitled Apple processes. The adapter
gets around that by having `/usr/bin/perl` (which is entitled) load this
framework and print now-playing updates as JSON lines on stdout.

## Local changes

- `src/adapter/expect.m` (new), `include/MediaRemoteAdapter.h`, `bin/mediaremote-adapter.pl`:
  an `expect BUNDLE_ID` function, and a `--to=BUNDLE_ID` option on `send`, `seek`,
  `shuffle` and `repeat` that runs it first. `expect` exits 0 when that app is the
  one MediaRemote currently delivers commands to (a browser also matches the helper
  process playing its web media), 10 when another app is, and 11 when none is or
  MediaRemote does not answer; with `--to`, nothing is sent unless it exits 0, and the
  script exits 12 if the framework has no `adapter_expect`.

  MediaRemote resolves an untargeted command when it arrives, to the app it has
  elected as now playing: the one that most recently started playing, which it keeps
  while that app is paused, even as another plays on. Its targeted calls
  (`MRMediaRemoteSendCommandToApp`, `…ToClient`, `…ToPlayer`) cannot get round that
  from here: mediaremoted (macOS 26.6) redirects a targeted command to the elected
  app unless the client holds entitlement bit 0x2 — perl has 0x200 on macOS 26 and 0xFC00200 on macOS 27, never 0x2 — or the target is
  Apple's own Music, Podcasts or Books, and logs "missing entitlement needed to
  send command … to arbitrary apps. Sending to NowPlayingApp instead". So Islet checks
  that the app it shows is the elected one straight before sending, instead.
- `src/adapter/sessions.m` (new), `include/MediaRemoteAdapter.h`,
  `bin/mediaremote-adapter.pl`: a `sessions` function, which reports every
  now-playing session MediaRemote knows, not only the elected one the stream
  follows: `{"type":"session","id":ID,"diff":BOOL,"payload":{…}}` per session, ID
  being `PID/BUNDLE_ID`, with the stream's keys plus `elected`, diffed as the stream
  diffs; `{"type":"sessionEnded","id":ID}` once one is gone; and
  `{"type":"sessionsListed"}` after each reading that changed anything, and after
  the first in any case, so a reader takes the list whole and knows when it is
  empty. It lists them with `MRMediaRemoteGetNowPlayingClients` and reads each one's
  information and playback state for its player path
  (`MRMediaRemoteGetNowPlayingInfoForPlayer`, `…GetPlaybackStateForPlayer`, the
  client's active player); these answer perl, as the stream's calls do, and a plain
  executable gets nothing. It reads them all again on the per-player notifications
  (`kMRMediaRemotePlayerNowPlayingInfoDidChange…`, `…PlayerIsPlayingDidChange…`,
  `…PlayerPlaybackStateDidChange…`), which are posted for every player and not only
  the elected one's; when the elected app changes; and when an application quits.
  Every 10 seconds, while anything is listed, it also looks without artwork, and
  reads in full only if something changed that no notification told of or a session
  still waits for its artwork. Listing the clients once after registering is also
  what gets the non-elected players' information notifications, not only their play
  and pause ones. When MediaRemote names a session's artwork but has not handed over
  the image yet, as on the first reading after a session appears, it reads once more
  half a second later. A client whose process has gone is left out, and a listing
  MediaRemote fails or does not answer within 2 seconds is not reported as an empty
  one. Islet runs it as a process of its own beside the stream: those functions'
  signatures were only checked on macOS 26 and 27 (26A428), so when one of them or
  `-[MRPlayerPath initWithOrigin:client:player:]` is missing, or throws, it exits
  with 13 (`kMRAExitCannotListSessions`), and if one crashes it goes alone; either
  way the stream carries on. Checked on macOS 27 with a YouTube video in Safari and
  Spotify: both are listed, whichever is elected. It only reads: a command still
  reaches the elected application alone, as `expect` checks.
