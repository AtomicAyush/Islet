import AppKit
import SwiftUI

/// A shortcut's icon as Shortcuts draws it: a white symbol on a tile of one of its
/// fifteen colours.
struct ShortcutIcon: Hashable, Sendable {
    /// An SF Symbol this Mac can draw.
    var symbol: String
    /// Which of `ShortcutPalette.entries` the tile is.
    var colour: Int

    init(symbol: String, colour: Int) {
        self.symbol = symbol
        self.colour = colour
    }

    /// The icon from the two numbers the Shortcuts database keeps for it.
    init(glyph: Int?, colourValue: Int64?) {
        self.init(symbol: ShortcutGlyphs.symbol(for: glyph), colour: ShortcutPalette.index(for: colourValue))
    }
}

/// The colours Shortcuts offers for an icon, in the order its picker shows them.
///
/// The database keeps a colour as the value it was stored with, packed as RGBA —
/// Shortcuts' original palette, which today's tiles no longer draw (the stored yellow
/// comes out lime, the stored black a slate grey). So a value is looked up, not
/// decoded: each entry pairs the stored value with the tile colour Shortcuts draws for
/// it now, in Display P3, since two of them are brighter than sRGB can show. A value
/// not in the palette takes the entry nearest it.
enum ShortcutPalette {
    struct Entry: Sendable {
        var name: String
        var stored: UInt32
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(.displayP3, red: red, green: green, blue: blue) }
    }

    static let entries: [Entry] = [
        Entry(name: "Red", stored: 0xFF43_51FF, red: 0.906, green: 0.380, blue: 0.408),
        Entry(name: "Orange", stored: 0xFD66_31FF, red: 0.941, green: 0.514, blue: 0.396),
        Entry(name: "Tangerine", stored: 0xFE99_49FF, red: 0.922, green: 0.647, blue: 0.341),
        Entry(name: "Yellow", stored: 0xFEC4_18FF, red: 0.941, green: 0.733, blue: 0.251),
        Entry(name: "Lime", stored: 0xFFD4_26FF, red: 0.396, green: 0.761, blue: 0.380),
        Entry(name: "Teal", stored: 0x19BD_03FF, red: 0.165, green: 0.780, blue: 0.659),
        Entry(name: "Cyan", stored: 0x55DA_E1FF, red: 0.243, green: 0.675, blue: 0.941),
        Entry(name: "Blue", stored: 0x1B9A_F7FF, red: 0.231, green: 0.498, blue: 0.969),
        Entry(name: "Navy", stored: 0x3871_DEFF, red: 0.259, green: 0.357, blue: 0.722),
        Entry(name: "Grape", stored: 0x7B72_E9FF, red: 0.471, green: 0.302, blue: 0.722),
        Entry(name: "Purple", stored: 0xDB49_D8FF, red: 0.675, green: 0.455, blue: 0.863),
        Entry(name: "Pink", stored: 0xED46_94FF, red: 0.902, green: 0.537, blue: 0.808),
        Entry(name: "Gray Blue", stored: 0x0000_00FF, red: 0.502, green: 0.537, blue: 0.576),
        Entry(name: "Gray Green", stored: 0xB4B2_A9FF, red: 0.553, green: 0.635, blue: 0.561),
        Entry(name: "Gray Brown", stored: 0xA9A9_A9FF, red: 0.635, green: 0.545, blue: 0.431),
    ]

    static let red = 0, orange = 1, tangerine = 2, yellow = 3, lime = 4, teal = 5, cyan = 6, blue = 7
    static let navy = 8, grape = 9, purple = 10, pink = 11, grayBlue = 12, grayGreen = 13, grayBrown = 14

    /// The entry for a stored colour. Values are sometimes stored sign-extended, so
    /// only their low 32 bits count. With none stored, the slate Shortcuts gives a tile
    /// with no colour of its own.
    static func index(for value: Int64?) -> Int {
        guard let value else { return grayBlue }
        let packed = UInt32(truncatingIfNeeded: value)
        if let exact = entries.firstIndex(where: { $0.stored == packed }) { return exact }
        func channels(_ value: UInt32) -> (Int, Int, Int) {
            (Int(value >> 24 & 0xFF), Int(value >> 16 & 0xFF), Int(value >> 8 & 0xFF))
        }
        let (r, g, b) = channels(packed)
        let distances = entries.map { entry in
            let (er, eg, eb) = channels(entry.stored)
            return (r - er) * (r - er) + (g - eg) * (g - eg) + (b - eb) * (b - eb)
        }
        return distances.indices.min { distances[$0] < distances[$1] } ?? grayBlue
    }

    static func color(_ index: Int) -> Color {
        entries.indices.contains(index) ? entries[index].color : entries[grayBlue].color
    }
}

/// Which SF Symbol Shortcuts draws for a shortcut's glyph number.
///
/// The Shortcuts database keeps a shortcut's icon as two numbers, a glyph and a colour,
/// and Shortcuts turns the glyph into a symbol through a private framework that other
/// apps cannot call. This table was taken once from that framework on macOS 26.6: 836
/// glyph numbers, in two ranges. Some of the symbols it names are private to Apple's
/// apps (the default glyph's stack of apps, the Music and Podcasts marks, the emoji
/// faces), and NSImage will not draw them for anyone else; each of those is swapped
/// here for a public symbol that reads as the same thing, and one that macOS 14 has.
///
/// A symbol newer than the Mac it runs on, or a glyph number from a later Shortcuts,
/// falls back to the public look-alike of Shortcuts' own default.
enum ShortcutGlyphs {
    /// Shortcuts' default glyph (0xF000), as near as a public symbol comes to it.
    static let fallback = "square.2.layers.3d.fill"

    /// The symbol for `glyph`, one this Mac can draw.
    static func symbol(for glyph: Int?) -> String {
        guard let glyph, let number = UInt16(exactly: glyph), let name = symbols[number],
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return fallback }
        return name
    }

    static let symbols: [UInt16: String] = [
        0xE800: "ellipsis", 0xE801: "arrowshape.turn.up.backward.fill", 0xE802: "ticket.fill", 0xE803: "dollarsign",
        0xE804: "lifepreserver.fill", 0xE805: "arrow.triangle.2.circlepath", 0xE806: "hand.thumbsup.fill",
        0xE807: "house.fill", 0xE808: "wineglass.fill", 0xE809: "camera.fill", 0xE80A: "video.fill",
        0xE80B: "bubble.left.and.bubble.right.fill", 0xE80C: "point.3.filled.connected.trianglepath.dotted",
        0xE80D: "square.grid.4x3.fill", 0xE80E: "airplane", 0xE80F: "gift.fill", 0xE811: "envelope.fill",
        0xE812: "bolt.fill", 0xE814: "globe", 0xE815: "person.3.fill", 0xE816: "message.fill", 0xE817: "clock.fill",
        0xE818: "location.fill", 0xE819: "star.fill", 0xE81A: "moon.fill", 0xE81B: "books.vertical.fill",
        0xE81C: "internaldrive.fill", 0xE81E: "xmark.circle.fill", 0xE81F: "tag.fill", 0xE820: "scissors",
        0xE821: "cross.fill", 0xE822: "bell.fill", 0xE823: "arrowshape.turn.up.forward.fill",
        0xE824: "shoeprints.fill", 0xE825: "pawprint.fill", 0xE826: "arrow.2.squarepath", 0xE828: "building.2.fill",
        0xE82A: "briefcase.fill", 0xE82C: "laptopcomputer", 0xE82D: "figure", 0xE82E: "film.fill",
        0xE830: "exclamationmark.triangle.fill", 0xE831: "arrow.down.right.and.arrow.up.left", 0xE832: "trash.fill",
        0xE833: "flame.fill", 0xE834: "magnifyingglass", 0xE835: "list.bullet", 0xE836: "keyboard.fill",
        0xE837: "yensign", 0xE838: "sterlingsign", 0xE839: "eurosign", 0xE83C: "car.fill", 0xE840: "football.fill",
        0xE841: "hourglass", 0xE842: "flag.fill", 0xE843: "icloud.fill", 0xE844: "eyeglasses", 0xE845: "pills.fill",
        0xE846: "creditcard.fill", 0xE847: "infinity", 0xE848: "bitcoinsign", 0xE849: "book.fill",
        0xE84A: "trophy.fill", 0xE84B: "sun.max.fill", 0xE84D: "mappin.and.ellipse", 0xE84E: "doc.text.fill",
        0xE84F: "hand.raised.fill", 0xE850: "headphones", 0xE851: "hammer.fill", 0xE852: "folder.fill",
        0xE853: "pencil", 0xE854: "cup.and.saucer.fill", 0xE855: "fork.knife", 0xE857: "music.note",
        0xE859: "heart.fill", 0xE85A: "umbrella.fill", 0xE85B: "figure.pool.swim", 0xE85D: "key.fill",
        0xE85F: "doc.text", 0xE860: "drop.fill", 0xE861: "battery.100", 0xE862: "lightbulb.fill", 0xE863: "snowflake",
        0xE864: "lock.fill", 0xE865: "lock.open.fill", 0xE866: "keyboard.fill", 0xE867: "gamecontroller.fill",
        0xE869: "dot.radiowaves.up.forward", 0xE86A: "phone.fill", 0xE86B: "gear", 0xE86C: "cart.fill",
        0xE86D: "mic.fill", 0xE86E: "speaker.fill", 0xE873: "shuffle", 0xE874: "play.fill", 0xE875: "square.fill",
        0xE876: "square", 0xE877: "wand.and.stars.inverse", 0xE878: "eurosign", 0xE879: "dollarsign",
        0xE87A: "yensign", 0xE87B: "bitcoinsign", 0xE87C: "circle.dotted", 0xE87D: "graduationcap.fill",
        0xE87E: "arrow.3.trianglepath", 0xE87F: "cylinder.split.1x2.fill", 0xE881: "paintbrush.fill",
        0xE882: "paintbrush.fill", 0xE883: "laptopcomputer", 0xE884: "laptopcomputer", 0xE885: "cube.fill",
        0xE886: "globe", 0xE887: "bookmark.fill", 0xE888: "paintbrush.fill", 0xE889: "link",
        0xE88A: "paintbrush.fill", 0xE88B: "doc.text.fill", 0xE88C: "pencil", 0xE88D: "person.2.fill",
        0xE88E: "person.2.fill", 0xE88F: "photo.fill", 0xE890: "mappin.and.ellipse", 0xE891: "laptopcomputer",
        0xE892: "laptopcomputer", 0xE893: "laptopcomputer", 0xE894: "laptopcomputer", 0xE895: "laptopcomputer",
        0xE897: "magnifyingglass", 0xE898: "person.2.fill", 0xE899: "person.2.fill", 0xE89A: "link", 0xE89B: "globe",
        0xE89C: "photo.fill", 0xE89D: "briefcase.fill", 0xE89E: "briefcase.fill", 0xE89F: "icloud.fill",
        0xE8A0: "icloud.fill", 0xE8A1: "photo.fill", 0xE8A2: "photo.fill", 0xE8A3: "link", 0xE8A4: "link",
        0xE8A5: "bubble.left.and.bubble.right.fill", 0xE8A6: "bubble.left.and.bubble.right.fill",
        0xE8A7: "music.note", 0xE8A8: "music.note", 0xE8A9: "laptopcomputer", 0xE8AA: "gamecontroller.fill",
        0xE8AB: "gamecontroller.fill", 0xE8AC: "link", 0xE8AD: "link", 0xE8AE: "checkmark", 0xE8AF: "person.2.fill",
        0xE8B0: "person.2.fill", 0xE8B1: "message.fill", 0xE8B2: "message.fill", 0xE8B3: "play.rectangle.fill",
        0xE8B4: "play.rectangle.fill", 0xE8B5: "bubble.left.and.bubble.right.fill", 0xE8B6: "person.2.fill",
        0xE8B7: "pencil", 0xE8B8: "play.rectangle.fill", 0xE8B9: "play.rectangle.fill", 0xE8BA: "play.rectangle.fill",
        0xE8BB: "music.note", 0xE8BC: "link", 0xE8BD: "creditcard.fill", 0xE8BE: "doc.richtext", 0xE900: "airplane",
        0xE901: "alarm.fill", 0xE902: "exclamationmark.triangle.fill", 0xE903: "face.smiling.inverse",
        0xE904: "cross.fill", 0xE905: "archivebox.fill", 0xE906: "arrowshape.turn.up.backward.fill",
        0xE907: "arrowshape.turn.up.forward.fill", 0xE908: "staroflife.fill", 0xE909: "atom", 0xE90C: "bandage.fill",
        0xE90D: "barcode", 0xE90E: "chart.bar.fill", 0xE90F: "baseball.fill", 0xE910: "basketball.fill",
        0xE911: "bathtub.fill", 0xE912: "bed.double.fill", 0xE913: "bell.fill", 0xE914: "bicycle",
        0xE915: "binoculars.fill", 0xE916: "bookmark.fill", 0xE917: "books.vertical.fill", 0xE919: "square.fill",
        0xE91A: "square.fill", 0xE91B: "hand.point.up.braille.fill", 0xE91C: "briefcase.fill",
        0xE91D: "building.2.fill", 0xE91E: "bus.fill", 0xE91F: "birthday.cake.fill",
        0xE920: "plus.forwardslash.minus", 0xE921: "calendar", 0xE922: "camera.fill", 0xE923: "carrot.fill",
        0xE924: "cat.fill", 0xE925: "link", 0xE929: "bitcoinsign", 0xE92A: "checkmark", 0xE92C: "chevron.down",
        0xE92D: "square.and.arrow.down.fill", 0xE92E: "eurosign", 0xE92F: "forward.fill", 0xE930: "chevron.backward",
        0xE931: "info", 0xE933: "play.fill", 0xE934: "plus", 0xE935: "sterlingsign", 0xE936: "power",
        0xE937: "questionmark", 0xE938: "backward.fill", 0xE939: "chevron.forward", 0xE93A: "stop.fill",
        0xE93B: "chevron.up", 0xE93C: "square.and.arrow.up", 0xE93D: "xmark", 0xE93E: "yensign",
        0xE93F: "doc.on.clipboard.fill", 0xE940: "clock.fill", 0xE941: "hanger", 0xE942: "cloud.fill",
        0xE943: "cloud.rain.fill", 0xE944: "eyedropper.halffull", 0xE945: "safari.fill",
        0xE946: "point.3.filled.connected.trianglepath.dotted", 0xE947: "creditcard.fill", 0xE948: "crop",
        0xE949: "cube.fill", 0xE94A: "server.rack", 0xE94B: "dice.fill", 0xE94C: "signpost.right.and.left.fill",
        0xE94D: "document.fill", 0xE94E: "doc.text.fill", 0xE94F: "doc.text.fill", 0xE950: "dog.fill",
        0xE951: "quote.bubble.fill", 0xE952: "theatermasks.fill", 0xE954: "dot.radiowaves.forward",
        0xE955: "film.fill", 0xE956: "flame.fill", 0xE957: "fish.fill", 0xE958: "flag.fill", 0xE959: "folder.fill",
        0xE95A: "shoeprints.fill", 0xE95B: "square.grid.2x2.fill", 0xE95C: "apple.logo", 0xE95D: "fuelpump.fill",
        0xE95E: "gamecontroller.fill", 0xE95F: "gear", 0xE960: "gift.fill", 0xE961: "eyeglasses",
        0xE962: "graduationcap.fill", 0xE963: "storefront.fill", 0xE964: "hammer.fill", 0xE966: "bag.fill",
        0xE967: "hand.raised.fill", 0xE968: "internaldrive.fill", 0xE969: "headphones", 0xE96A: "heart.fill",
        0xE96B: "house.fill", 0xE96C: "pawprint.fill", 0xE96D: "hourglass", 0xE96E: "infinity",
        0xE96F: "inhaler.fill", 0xE970: "key.fill", 0xE971: "washer.fill", 0xE972: "lifepreserver.fill",
        0xE973: "lightbulb.fill", 0xE974: "bolt.fill", 0xE975: "doc.text.fill", 0xE976: "doc.text.fill",
        0xE977: "rays", 0xE978: "location.fill", 0xE979: "mappin.and.ellipse", 0xE97A: "lock.fill",
        0xE97B: "wand.and.rays.inverse", 0xE97C: "magnifyingglass", 0xE97D: "envelope.fill",
        0xE97E: "envelope.open.fill", 0xE97F: "figure.stand", 0xE980: "wineglass.fill", 0xE982: "cross.vial.fill",
        0xE983: "text.bubble.fill", 0xE984: "mic.fill", 0xE986: "moon.fill", 0xE987: "motorcycle.fill",
        0xE988: "photo.fill", 0xE989: "mountain.2.fill", 0xE98A: "arrow.up.and.down.and.arrow.left.and.right",
        0xE98B: "play.rectangle.fill", 0xE98C: "ticket.fill", 0xE98D: "cup.and.saucer.fill", 0xE98E: "music.note",
        0xE98F: "richtext.page.fill", 0xE990: "stove.fill", 0xE991: "paintbrush.fill", 0xE992: "paperclip",
        0xE993: "p.square.fill", 0xE994: "pawprint.fill", 0xE995: "peacesign", 0xE996: "pencil",
        0xE997: "person.3.fill", 0xE998: "person.2.fill", 0xE999: "person.fill", 0xE99B: "figure.dance",
        0xE99C: "hand.raised.fill", 0xE99D: "figure.hiking", 0xE99E: "figure.roll",
        0xE99F: "figure.strengthtraining.traditional", 0xE9A0: "figure.run", 0xE9A1: "figure.skiing.crosscountry",
        0xE9A2: "figure.snowboarding", 0xE9A3: "figure.pool.swim", 0xE9A4: "figure.walk", 0xE9A6: "phone.fill",
        0xE9A7: "pills.fill", 0xE9A8: "antenna.radiowaves.left.and.right", 0xE9A9: "printer.fill",
        0xE9AA: "puzzlepiece.fill", 0xE9AB: "qrcode", 0xE9AC: "arrow.3.trianglepath", 0xE9AD: "arrow.2.squarepath",
        0xE9AE: "paperplane.fill", 0xE9AF: "sailboat.fill", 0xE9B0: "scissors", 0xE9B1: "screwdriver.fill",
        0xE9B2: "externaldrive.connected.to.line.below.fill", 0xE9B3: "tshirt.fill", 0xE9B4: "cart.fill",
        0xE9B5: "shower.fill", 0xE9B6: "arrow.down.right.and.arrow.up.left",
        0xE9B7: "arrow.down.right.and.arrow.up.left", 0xE9B8: "shuffle", 0xE9B9: "slider.horizontal.3",
        0xE9BA: "face.smiling.inverse", 0xE9BB: "snowflake", 0xE9BC: "paperplane.fill", 0xE9BD: "soccerball",
        0xE9BF: "speaker.wave.1.fill", 0xE9C0: "stairs", 0xE9C1: "star.fill", 0xE9C3: "stethoscope",
        0xE9C4: "stopwatch.fill", 0xE9C5: "sun.max.fill", 0xE9C6: "arrow.triangle.2.circlepath",
        0xE9C7: "syringe.fill", 0xE9C8: "tag.fill", 0xE9C9: "circle.circle", 0xE9CB: "tv.fill",
        0xE9CC: "tennisball.fill", 0xE9CD: "t.square.fill", 0xE9CE: "thermometer.medium", 0xE9CF: "message.fill",
        0xE9D0: "camera.filters", 0xE9D1: "hand.thumbsup.fill", 0xE9D3: "trash.fill", 0xE9D4: "trophy.fill",
        0xE9D5: "umbrella.fill", 0xE9D6: "lock.open.fill", 0xE9D7: "fork.knife", 0xE9D8: "play.rectangle.fill",
        0xE9D9: "applewatch", 0xE9DA: "drop.fill", 0xE9DB: "wifi", 0xE9DE: "wrench.fill",
        0xF000: "square.2.layers.3d.fill", 0xF002: "book.closed.fill", 0xF004: "map.fill", 0xF006: "car.2.fill",
        0xF007: "bolt.car.fill", 0xF008: "bus.doubledecker.fill", 0xF009: "tram.fill", 0xF00A: "tram.tunnel.fill",
        0xF00C: "gauge", 0xF00D: "speedometer", 0xF00E: "barometer", 0xF00F: "network",
        0xF010: "rectangle.stack.fill", 0xF011: "square.stack.fill", 0xF012: "square.stack.3d.down.right.fill",
        0xF013: "photo.fill.on.rectangle.fill", 0xF014: "photo.on.rectangle.angled", 0xF015: "camera.aperture",
        0xF016: "paperplane.fill", 0xF018: "note", 0xF019: "note.text", 0xF01A: "note.text.badge.plus",
        0xF01B: "arrow.up.message.fill", 0xF01C: "plus.message.fill", 0xF01E: "speaker.wave.2.fill",
        0xF01F: "speaker.wave.3.fill", 0xF020: "speaker.slash.fill", 0xF021: "speaker.fill",
        0xF022: "tv.and.hifispeaker.fill", 0xF023: "earpods", 0xF024: "airpods", 0xF025: "airpodspro",
        0xF026: "hifispeaker.fill", 0xF027: "headphones", 0xF028: "radio.fill", 0xF029: "hearingdevice.ear.fill",
        0xF02A: "appletv.fill", 0xF02B: "homepod.fill", 0xF02C: "applewatch.radiowaves.left.and.right",
        0xF02E: "iphone", 0xF02F: "iphone.radiowaves.left.and.right", 0xF030: "apps.iphone", 0xF031: "ipad",
        0xF032: "ipad.landscape", 0xF033: "ipod", 0xF035: "figure.run", 0xF036: "figure.run", 0xF037: "person.fill",
        0xF038: "person.fill", 0xF039: "arrow.triangle.turn.up.right.diamond.fill", 0xF03A: "arrow.turn.up.right",
        0xF03B: "airplayaudio", 0xF03C: "airplayvideo", 0xF03D: "dot.radiowaves.left.and.right",
        0xF03E: "music.note.list", 0xF03F: "music.note", 0xF040: "music.note.list", 0xF041: "waveform.path",
        0xF042: "livephoto.play", 0xF043: "livephoto", 0xF044: "slowmo", 0xF045: "timelapse",
        0xF046: "calendar.badge.plus", 0xF047: "calendar.badge.exclamationmark", 0xF048: "timer", 0xF049: "timer",
        0xF04A: "square.and.pencil", 0xF04B: "plus.square.fill.on.square.fill", 0xF04D: "moon.fill",
        0xF04E: "sun.max.fill", 0xF04F: "sun.max.fill", 0xF050: "dial.low.fill", 0xF051: "dial.high.fill",
        0xF052: "qrcode.viewfinder", 0xF053: "camera.viewfinder", 0xF054: "wallet.pass.fill",
        0xF055: "circle.lefthalf.filled", 0xF058: "nosign", 0xF059: "command", 0xF05A: "command", 0xF05B: "command",
        0xF05C: "brain.filled.head.profile", 0xF05D: "brain.fill", 0xF05E: "face.smiling.inverse",
        0xF05F: "face.smiling.inverse", 0xF060: "face.smiling.inverse", 0xF061: "face.smiling.inverse",
        0xF062: "face.smiling.inverse", 0xF063: "face.smiling.inverse", 0xF064: "face.smiling.inverse",
        0xF065: "face.smiling.inverse", 0xF066: "face.smiling.inverse", 0xF067: "face.smiling.inverse",
        0xF068: "face.smiling.inverse", 0xF069: "face.smiling.inverse", 0xF06A: "face.smiling.inverse",
        0xF06B: "hand.thumbsup.fill", 0xF06C: "hand.raised.fill", 0xF06D: "hand.raised.fill",
        0xF06E: "hand.raised.fill", 0xF06F: "facemask.fill", 0xF070: "puzzlepiece.extension.fill",
        0xF071: "takeoutbag.and.cup.and.straw.fill", 0xF072: "pawprint.fill", 0xF073: "pawprint.fill",
        0xF074: "pawprint.fill", 0xF075: "pawprint.fill", 0xF076: "hare.fill", 0xF077: "pawprint.fill",
        0xF078: "pawprint.fill", 0xF079: "pawprint.fill", 0xF07A: "pawprint.fill", 0xF07B: "pawprint.fill",
        0xF07C: "pawprint.fill", 0xF07D: "gamecontroller.fill", 0xF07E: "face.smiling.inverse",
        0xF07F: "face.smiling.inverse", 0xF080: "face.smiling.inverse", 0xF081: "face.smiling.inverse",
        0xF082: "folder.fill", 0xF083: "folder.fill.badge.gearshape", 0xF084: "rectangle.grid.2x2.fill",
        0xF085: "rectangle.grid.2x2.fill", 0xF086: "rectangle.split.2x1.fill", 0xF087: "rectangle.split.3x1.fill",
        0xF088: "rectangle.split.3x1.fill", 0xF089: "heart.fill", 0xF08A: "heart.fill",
        0xF08B: "star.leadinghalf.filled", 0xF08D: "sparkles", 0xF08E: "arrow.up.message.fill",
        0xF08F: "quote.bubble.fill", 0xF090: "hand.raised.slash.fill", 0xF091: "hand.raised.slash.fill",
        0xF092: "waveform", 0xF093: "checklist", 0xF094: "character.textbox", 0xF095: "xmark", 0xF096: "eraser.fill",
        0xF097: "scribble.variable", 0xF098: "pencil.and.scribble", 0xF099: "clipboard.fill",
        0xF100: "list.bullet.clipboard.fill", 0xF101: "richtext.page.fill", 0xF102: "text.page.fill",
        0xF103: "append.page.fill", 0xF104: "apple.terminal.fill", 0xF105: "calendar.badge.clock",
        0xF106: "calendar.badge.minus", 0xF107: "calendar.badge.checkmark", 0xF108: "note.text",
        0xF109: "menucard.fill", 0xF110: "magazine.fill", 0xF111: "photo.artframe", 0xF112: "figure.wave",
        0xF113: "dumbbell.fill", 0xF114: "sportscourt.fill", 0xF115: "tennis.racket", 0xF116: "skateboard.fill",
        0xF117: "duffle.bag.fill", 0xF118: "apple.logo", 0xF119: "dot.radiowaves.left.and.right",
        0xF120: "flag.2.crossed.fill", 0xF121: "flag.checkered.2.crossed", 0xF122: "x.squareroot",
        0xF123: "flashlight.on.fill", 0xF124: "flashlight.slash", 0xF125: "paintpalette.fill",
        0xF126: "mail.stack.fill", 0xF127: "mail.fill", 0xF128: "gearshape.fill", 0xF129: "gearshape.2.fill",
        0xF130: "signature", 0xF131: "wallet.pass.fill", 0xF132: "metronome.fill", 0xF133: "numbers",
        0xF134: "pianokeys.inverse", 0xF135: "paintbrush.pointed.fill", 0xF136: "applescript.fill",
        0xF137: "scroll.fill", 0xF138: "scanner.fill", 0xF139: "handbag.fill", 0xF140: "suitcase.rolling.fill",
        0xF141: "homekit", 0xF142: "building.columns.fill", 0xF143: "lamp.desk.fill", 0xF144: "lamp.ceiling.fill",
        0xF145: "fan.floor.fill", 0xF146: "fan.fill", 0xF147: "fan.ceiling.fill", 0xF148: "lamp.floor.fill",
        0xF149: "powerplug.fill", 0xF150: "balloon.fill", 0xF151: "sailboat.fill", 0xF152: "fireworks",
        0xF153: "party.popper.fill", 0xF154: "popcorn.fill", 0xF155: "frying.pan.fill", 0xF156: "sofa.fill",
        0xF157: "torus", 0xF158: "desktopcomputer", 0xF159: "finder", 0xF160: "watch.analog",
        0xF161: "applewatch.side.right", 0xF162: "mediastick", 0xF163: "tv", 0xF164: "shazam.logo.fill",
        0xF165: "guitars.fill", 0xF166: "moped.fill", 0xF167: "scooter", 0xF168: "stroller.fill", 0xF169: "comb.fill",
        0xF170: "horn.fill", 0xF171: "tortoise.fill", 0xF172: "hare.fill", 0xF173: "dog.fill", 0xF174: "cat.fill",
        0xF175: "lizard.fill", 0xF176: "bird.fill", 0xF177: "ant.fill", 0xF178: "ladybug.fill", 0xF179: "function",
        0xF180: "percent", 0xF181: "teddybear.fill", 0xF182: "leaf.fill", 0xF183: "textformat.characters",
        0xF184: "crown.fill", 0xF185: "movieclapper.fill", 0xF186: "textformat", 0xF187: "film.stack.fill",
        0xF188: "textformat.size", 0xF189: "textformat.superscript", 0xF190: "textformat.subscript", 0xF191: "sum",
        0xF192: "compass.drawing", 0xF193: "angle", 0xF194: "bold.italic.underline", 0xF195: "characters.lowercase",
        0xF196: "characters.uppercase", 0xF197: "vision.pro", 0xF198: "battery.25percent",
        0xF199: "battery.100percent.bolt", 0xF200: "xmark", 0xF201: "arrow.left", 0xF202: "arrow.right",
        0xF203: "arrow.up", 0xF204: "arrow.down", 0xF205: "medical.thermometer.fill", 0xF206: "calendar.and.person",
        0xF207: "calendar", 0xF208: "person.crop.badge.magnifyingglass.fill", 0xF209: "book.fill",
        0xF210: "figure.run.treadmill", 0xF211: "figure.walk.treadmill", 0xF212: "figure.ice.skating",
        0xF213: "degreesign.celsius", 0xF214: "degreesign.farenheit", 0xF215: "fire.extinguisher.fill",
        0xF216: "wallet.bifold.fill", 0xF217: "house.badge.wifi.fill", 0xF218: "key.2.on.ring.fill",
        0xF219: "wheelchair", 0xF220: "helmet.fill", 0xF221: "coat.fill", 0xF222: "jacket.fill",
        0xF223: "heart.text.clipboard.fill", 0xF224: "humidity.fill", 0xF225: "sparkles", 0xF226: "moon.haze.fill",
        0xF227: "moon.stars.fill", 0xF228: "cloud.hail.fill", 0xF229: "cloud.sleet.fill", 0xF230: "cloud.bolt.fill",
        0xF231: "cloud.bolt.rain.fill", 0xF232: "cloud.sun.fill", 0xF233: "cloud.sun.rain.fill",
        0xF234: "cloud.sun.bolt.fill", 0xF235: "cloud.moon.fill", 0xF236: "cloud.moon.rain.fill",
        0xF237: "cloud.moon.bolt.fill", 0xF238: "wind", 0xF239: "wind.snow", 0xF240: "tornado",
        0xF241: "thermometer.sun.fill", 0xF242: "thermometer.snowflake", 0xF243: "sunset.fill",
        0xF244: "sunrise.fill", 0xF245: "airplane.departure", 0xF246: "airplane.arrival", 0xF247: "cablecar.fill",
        0xF248: "lightrail.fill", 0xF249: "ferry.fill", 0xF251: "truck.box.fill", 0xF252: "ev.charger.fill",
        0xF253: "road.lanes", 0xF254: "flag.pattern.checkered", 0xF255: "arcade.stick.console.fill",
        0xF256: "gearshift.layout.sixspeed", 0xF257: "formfitting.gamecontroller.fill", 0xF258: "gamecontroller.fill",
        0xF259: "personalhotspot", 0xF260: "bolt.horizontal.fill", 0xF261: "antenna.radiowaves.left.and.right",
        0xF262: "cable.connector", 0xF263: "bonjour", 0xF264: "cable.connector", 0xF265: "cable.connector",
        0xF266: "cable.connector", 0xF267: "cable.connector", 0xF268: "cable.connector", 0xF269: "cable.connector",
        0xF270: "cable.connector", 0xF271: "cable.connector", 0xF272: "cable.connector", 0xF273: "cable.connector",
        0xF274: "antenna.radiowaves.left.and.right", 0xF275: "oven.fill", 0xF276: "microwave.fill",
        0xF277: "refrigerator.fill", 0xF278: "toilet.fill", 0xF279: "lightbulb.led.fill",
        0xF280: "lightbulb.led.wide.fill", 0xF281: "figure.archery", 0xF282: "figure.basketball",
        0xF283: "figure.climbing", 0xF284: "figure.cooldown", 0xF285: "figure.core.training",
        0xF286: "figure.curling", 0xF287: "figure.elliptical", 0xF288: "figure.fencing", 0xF289: "figure.gymnastics",
        0xF290: "figure.highintensity.intervaltraining", 0xF291: "figure.hockey", 0xF292: "figure.ice.hockey",
        0xF293: "figure.indoor.cycle", 0xF294: "figure.outdoor.cycle", 0xF295: "figure.outdoor.rowing",
        0xF296: "figure.skateboarding", 0xF297: "figure.ice.skating", 0xF298: "figure.stair.stepper",
        0xF299: "medal.fill", 0xF300: "fossil.shell.fill", 0xF301: "move.3d", 0xF302: "hat.cap.fill",
        0xF303: "book.and.wrench.fill", 0xF304: "key.radiowaves.forward.fill", 0xF305: "apple.intelligence",
        0xF306: "hand.point.up.left.fill", 0xF307: "hand.tap.fill", 0xF308: "hand.draw.fill",
        0xF309: "shippingbox.fill", 0xF310: "engine.combustion.fill", 0xF311: "pc", 0xF312: "bell.badge.fill",
        0xF313: "bell.badge.waveform.fill", 0xF314: "bell.slash.fill", 0xF315: "bell.and.waves.left.and.right.fill",
        0xF316: "swatchpalette.fill", 0xF317: "mug.fill", 0xF318: "oilcan.fill", 0xF319: "newspaper.fill",
        0xF320: "accessibility.fill", 0xF321: "megaphone.fill", 0xF322: "firewall.fill", 0xF323: "basket.fill",
        0xF324: "level.fill", 0xF325: "lock.shield.fill", 0xF326: "fireplace.fill", 0xF327: "cabinet.fill",
        0xF328: "dryer.fill", 0xF329: "sink.fill", 0xF330: "pin.fill", 0xF331: "shoe.fill",
        0xF332: "square.stack.3d.up.fill", 0xF333: "dpad.fill", 0xF334: "waterbottle.fill", 0xF335: "sdcard.fill",
        0xF336: "simcard.fill", 0xF337: "esim.fill", 0xF338: "scalemass.fill", 0xF339: "banknote.fill",
        0xF340: "hockey.puck.fill", 0xF341: "australian.football.fill", 0xF342: "american.football.fill",
        0xF343: "beach.umbrella.fill", 0xF344: "suit.spade.fill", 0xF345: "suit.diamond.fill",
        0xF346: "suit.club.fill", 0xF347: "shower.handheld.fill", 0xF348: "signpost.right.fill",
        0xF349: "macpro.gen3.fill", 0xF350: "macpro.gen2.fill", 0xF351: "macpro.gen1.fill",
        0xF352: "homepod.mini.fill", 0xF353: "homepod.2.fill", 0xF354: "suv.side.fill", 0xF355: "car.side.fill",
        0xF356: "convertible.side.fill", 0xF357: "horn.blast.fill", 0xF358: "cross.case.fill",
        0xF359: "ivfluid.bag.fill", 0xF360: "hat.widebrim.fill", 0xF361: "globe.desk.fill",
        0xF362: "cup.and.heat.waves.fill", 0xF363: "network", 0xF364: "app.connected.to.app.below.fill",
        0xF365: "wrench.adjustable.fill", 0xF366: "mustache.fill", 0xF367: "flipphone", 0xF368: "siri",
        0xF369: "app.fill", 0xF370: "car.fill", 0xF371: "text.append", 0xF372: "creditcard.fill",
        0xF373: "plus.forwardslash.minus", 0xF374: "figure.mind.and.body", 0xF375: "wind", 0xF376: "sparkles",
        0xF377: "apple.meditate", 0xF378: "brain.head.profile", 0xF379: "calendar", 0xF380: "newspaper.fill",
        0xF381: "heart.text.square.fill", 0xF382: "doc.richtext.fill", 0xF383: "rectangle.on.rectangle.angled",
        0xF384: "tablecells.fill", 0xF385: "beziercurve", 0xF386: "road.lanes.curved.left",
        0xF387: "road.lanes.curved.right", 0xF388: "point.topleft.down.to.point.bottomright.curvepath",
        0xF389: "point.bottomleft.forward.to.point.topright.scurvepath", 0xF390: "sparkle", 0xF391: "arrow.up.right",
        0xF392: "arrow.up.left", 0xF393: "text.insert", 0xF394: "text.quote", 0xF395: "text.alignleft",
        0xF396: "text.aligncenter", 0xF397: "text.alignright", 0xF398: "text.justify",
        0xF400: "suitcase.rolling.and.suitcase.fill", 0xF401: "pet.carrier.fill", 0xF402: "airplane.landed",
        0xF403: "airplane.cloud", 0xF404: "airplane.ticket.fill", 0xF405: "airplaneseat",
        0xF406: "figure.walk.suitcase.rolling", 0xF407: "apple.classical.pages.fill", 0xF408: "text.square.filled",
        0xF409: "character.text.justify", 0xF410: "graph.2d", 0xF411: "plus.forwardslash.minus",
        0xF412: "circle.fill", 0xF413: "capsule.portrait.fill", 0xF414: "rectangle.fill",
        0xF415: "rectangle.portrait.fill", 0xF416: "oval.fill", 0xF417: "oval.portrait.fill", 0xF418: "triangle.fill",
        0xF419: "diamond.fill", 0xF420: "octagon.fill", 0xF421: "hexagon.fill", 0xF422: "pentagon.fill",
        0xF423: "seal.fill", 0xF424: "rhombus.fill", 0xF425: "shield.fill",
    ]
}
