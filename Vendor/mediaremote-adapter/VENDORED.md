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
