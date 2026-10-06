import Darwin
import Foundation

// The screenshot thumbnail's keeper: puts macOS's floating thumbnail back for an Islet
// that went without doing so itself (a crash, SIGKILL, Force Quit). Islet starts it
// (`FloatingThumbnailKeeper`) as
//
//     ThumbnailKeeper <settings domain> <holders file> <holder> <defaults domain> <switch>
//
// with its standard input a pipe whose other end only Islet holds. It sleeps in a read
// of that pipe, which costs nothing, and wakes only for what Islet says
// (`FloatingThumbnailKeeperNote`) and when the pipe closes. Islet having let go itself
// says so, and the keeper exits touching nothing. The pipe closing before that means
// Islet has gone: the keeper lets go for it, which puts the thumbnail back unless another
// Islet still holds it off, and exits. A thumbnail found back on while Islet held it off,
// and had not begun letting go, was turned on elsewhere, in the Screenshot app, so
// Islet's switch is turned off too, and the next launch leaves it as it was made.
//
// It ignores SIGTERM and the signals a terminal sends, Islet having held them back for it
// until then: it goes when Islet has gone, never before.

let arguments = CommandLine.arguments
// Only with an Islet at the other end of a pipe; started any other way, nothing.
var input = stat()
guard arguments.count == 6, let holder = FloatingThumbnailHolders.Holder(line: arguments[3]),
      fstat(0, &input) == 0, input.st_mode & S_IFMT == S_IFIFO
else { exit(64) }
// Ignored, one held back meanwhile is dropped; then nothing need be held back.
for signal in [SIGTERM, SIGINT, SIGHUP] { Darwin.signal(signal, SIG_IGN) }
var none = sigset_t()
sigemptyset(&none)
sigprocmask(SIG_SETMASK, &none, nil)

var held = false
var byte: UInt8 = 0
while true {
    let count = read(0, &byte, 1)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    switch FloatingThumbnailKeeperNote(rawValue: byte) {
    case .held: held = true
    case .releasing: held = false
    case .released: exit(0)
    case nil: break
    }
}

let settings = ScreenshotSettingsStore.domain(arguments[1])
if held, !settings.thumbnailIsOff() {
    let defaults = arguments[4] as CFString
    CFPreferencesSetAppValue(arguments[5] as CFString, kCFBooleanFalse, defaults)
    _ = CFPreferencesAppSynchronize(defaults)
}
FloatingThumbnailHolders(file: URL(fileURLWithPath: arguments[2])).release(holder) {
    settings.restoreThumbnail()
}
exit(0)
