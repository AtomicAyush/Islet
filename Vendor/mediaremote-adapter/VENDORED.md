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
  app unless the client holds entitlement bit 0x2 — perl has 0x200 — or the target is
  Apple's own Music, Podcasts or Books, and logs "missing entitlement needed to
  send command … to arbitrary apps. Sending to NowPlayingApp instead". So Islet checks
  that the app it shows is the elected one straight before sending, instead.
