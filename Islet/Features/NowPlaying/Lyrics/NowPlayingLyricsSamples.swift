import Foundation

/// Made-up lyrics for the previews' made-up songs, written for Islet. They go through
/// the same reading as LRCLIB's, so the previews show what a real song would: an
/// intro, a chorus written once for each time it is sung, a short pause that is
/// bridged, a long line that scrolls in the island, and an instrumental break.
enum NowPlayingLyricsSamples {
    /// "Midnight Drive" by Neon Harbour, timed.
    static var midnightDrive: LyricsResult { .synced(LyricsText.synced(midnightDriveLRC)) }

    /// "Paper Planes Over Lisbon", with no times, to show plain lyrics.
    static var paperPlanes: LyricsResult { .plain(LyricsText.plain(paperPlanesText)) }

    private static let midnightDriveLRC = """
    [ti:Midnight Drive]
    [ar:Neon Harbour]
    [length:03:42]
    [00:14.20]Streetlights blinking out along the bay
    [00:18.60]Radio murmurs something far away
    [00:23.10]Your hand is drawing circles on the glass
    [00:27.40]We let the exits and the hours pass
    [00:31.80]Salt on the wind and static in the air
    [00:36.20]Nobody waiting for us anywhere
    [00:40.50][01:37.80]So turn it up and let the engine hum
    [00:44.90][01:42.20]The morning's never going to come
    [00:49.30][01:46.60][02:37.60]Midnight drive, the coastline burning bright
    [00:53.70][01:51.00][02:42.00]Chasing every harbour light
    [00:58.10][01:55.40][02:46.40]Hold on tight, we're weightless in the night
    [01:02.60][01:59.90][02:50.90]On a midnight drive
    [01:07.00]
    [01:09.00]Neon on the water, painted lines
    [01:13.40]Every mile a secret, yours and mine
    [01:17.80]We counted all the stars the city lost behind the hills and never found again
    [01:24.60]Your laughter folding into the refrain
    [01:29.00]The dashboard glowing like a fading ember
    [01:33.40]A song we'll only half remember
    [02:04.30]
    [02:20.00]And if the road runs out before the dawn
    [02:24.40]We'll build another one and carry on
    [02:28.80]Just you and me and all the open sky
    [02:33.20]No need to ask the reasons why
    [02:55.30]On a midnight drive
    [02:59.80]
    """

    private static let paperPlanesText = """
    Paper planes over Lisbon
    Folded from the letters that I never sent
    Tram bells ringing down the hill
    Every window open, every wall a friend

    Catch one if it finds you
    Read it by the river when the light is low
    All the things I meant to say
    Drifting on the wind wherever paper goes
    """
}
