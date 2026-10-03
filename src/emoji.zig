// SPDX-License-Identifier: BSD-2-Clause

//! Where one emoji ends: the characters that are drawn as one picture.
//!
//! An emoji is often several characters. A heart in colour is the heart and
//! a presentation selector after it; a thumbs-up with a skin tone is two; a
//! family is people joined by zero-width joiners; a flag is a pair of
//! regional letters; a keycap is a digit, a selector and an enclosing
//! square; England's flag is a black flag followed by tag letters. A caret
//! stepping through one of them a character at a time lands inside it, and a
//! renderer drawing each on its own draws the pieces - so both need to know
//! where the cluster ends.
//!
//! The rule here is Unicode's emoji sequence grammar, simplified to what a
//! font draws: a character, then any presentation selectors, skin tones,
//! enclosing keycaps and tag characters after it; and while a joiner follows,
//! the joiner and the next such run. Regional indicators go in pairs. It is
//! not the whole of grapheme clustering - combining accents are their own
//! business - and it does not need to be: it is the part emoji are.

const std = @import("std");
const testing = std.testing;

pub const zero_width_joiner: u21 = 0x200D;
pub const text_presentation: u21 = 0xFE0E;
pub const emoji_presentation: u21 = 0xFE0F;
pub const enclosing_keycap: u21 = 0x20E3;

/// A skin tone: what follows a person to colour them.
pub fn isModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

/// A regional indicator letter. Two of them are a country's flag.
pub fn isRegional(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// A tag character: the letters after a black flag that name a subdivision.
pub fn isTag(cp: u21) bool {
    return cp >= 0xE0020 and cp <= 0xE007F;
}

/// What stays with the character before it.
fn extends(cp: u21) bool {
    return cp == text_presentation or cp == emoji_presentation or cp == enclosing_keycap or isModifier(cp) or isTag(cp);
}

/// Whether a character draws nothing and takes no room - a joiner, a
/// selector, a direction mark - and should be dropped rather than drawn as a
/// box when a font has no glyph for it.
pub fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFEFF, 0xFFA0 => true,
        0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F => true,
        0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

/// One character, and how many bytes it took. Invalid UTF-8 is one byte that
/// stands for itself, so nothing that walks text this way gets stuck on it.
pub fn decode(text: []const u8, at: usize) struct { cp: u21, len: usize } {
    const length = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (at + length > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[at..][0..length]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = length };
}

/// Where the cluster starting at `start` ends, in bytes.
pub fn clusterEnd(text: []const u8, start: usize) usize {
    if (start >= text.len) return text.len;
    const first = decode(text, start);
    var at = start + first.len;
    if (isRegional(first.cp)) {
        if (at < text.len and isRegional(decode(text, at).cp)) at += decode(text, at).len;
        return at;
    }
    while (at < text.len) {
        const next = decode(text, at);
        if (extends(next.cp)) {
            at += next.len;
            continue;
        }
        if (next.cp == zero_width_joiner) {
            at += next.len;
            // A joiner joins the character after it, whatever it is; a
            // joiner at the end joins nothing and stays with what it follows.
            if (at < text.len) at += decode(text, at).len;
            continue;
        }
        break;
    }
    return at;
}

/// Where the cluster that ends at `end` starts. What a caret moving left, or
/// a backspace, wants.
pub fn clusterStart(text: []const u8, end: usize) usize {
    if (end == 0) return 0;
    // Clusters are short; walking forward from a little way back finds the
    // boundary without walking backwards through the grammar. The way back
    // starts on a character, and if that character is in the middle of a
    // cluster, the walk is moved back further until it is not.
    var from = end;
    var steps: usize = 0;
    while (from > 0 and steps < 64) : (steps += 1) {
        from -= 1;
        while (from > 0 and text[from] & 0xC0 == 0x80) from -= 1;
        if (!isContinuation(text, from)) break;
    }
    var at = from;
    var start = from;
    while (at < end) {
        start = at;
        at = clusterEnd(text, at);
    }
    return start;
}

/// Whether the character at `at` belongs to the one before it.
fn isContinuation(text: []const u8, at: usize) bool {
    const here = decode(text, at).cp;
    if (extends(here) or here == zero_width_joiner) return true;
    if (at == 0) return false;
    var before = at - 1;
    while (before > 0 and text[before] & 0xC0 == 0x80) before -= 1;
    const previous = decode(text, before).cp;
    // After a joiner, and the second of a pair of regional letters - which
    // only counting from the start of the run of them can say, so any
    // regional letter counts and the forward walk sorts out the pairs.
    return previous == zero_width_joiner or (isRegional(here) and isRegional(previous));
}

/// Whether a cluster asks to be drawn as an emoji: what follows its first
/// character makes an emoji sequence of it, or it is a flag, or it is one of
/// the characters that are emoji unless asked otherwise. A digit on its own
/// is a digit; a digit, a selector and a keycap are a key; a grinning face is
/// a face, and a heart is a heart until a selector says to colour it.
pub fn wantsEmoji(cluster: []const u8) bool {
    if (cluster.len == 0) return false;
    const first = decode(cluster, 0);
    if (isRegional(first.cp)) return true;
    if (first.len >= cluster.len) return isEmojiByDefault(first.cp);
    return decode(cluster, first.len).cp != text_presentation;
}

/// The characters drawn as emoji with no selector after them - Unicode's
/// `Emoji_Presentation` - near enough: in the planes above the first, the
/// emoji blocks as a whole, and below them the short list of symbols that
/// became emoji.
pub fn isEmojiByDefault(cp: u21) bool {
    return switch (cp) {
        0x231A...0x231B, 0x23E9...0x23EC, 0x23F0, 0x23F3, 0x25FD...0x25FE, 0x2614...0x2615 => true,
        0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5 => true,
        0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A...0x270B => true,
        0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF => true,
        0x2B1B...0x2B1C, 0x2B50, 0x2B55 => true,
        0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F1E6...0x1F1FF, 0x1F201, 0x1F21A, 0x1F22F => true,
        0x1F232...0x1F236, 0x1F238...0x1F23A, 0x1F250...0x1F251, 0x1F300...0x1F5FF, 0x1F600...0x1F64F => true,
        0x1F680...0x1F6FF, 0x1F7E0...0x1F7F0, 0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF => true,
        else => false,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn clusters(text: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (n += 1) {
        const end = clusterEnd(text, at);
        out[n] = text[at..end];
        at = end;
    }
    return out[0..n];
}

test "an emoji sequence is one cluster, and plain text is one a character" {
    var out: [16][]const u8 = undefined;
    const text = "a❤️👍🏽👨‍👩‍👧🇭🇺🇩🇪#️⃣b";
    const found = clusters(text, &out);
    try testing.expectEqual(@as(usize, 8), found.len);
    try testing.expectEqualStrings("a", found[0]);
    try testing.expectEqualStrings("❤️", found[1]);
    try testing.expectEqualStrings("👍🏽", found[2]);
    try testing.expectEqualStrings("👨‍👩‍👧", found[3]);
    try testing.expectEqualStrings("🇭🇺", found[4]);
    try testing.expectEqualStrings("🇩🇪", found[5]);
    try testing.expectEqualStrings("#️⃣", found[6]);
    try testing.expectEqualStrings("b", found[7]);
}

test "a cluster ends where it ends whichever side it is found from" {
    const text = "x👨‍👩‍👧🇭🇺🇩🇪y🏴󠁧󠁢󠁳󠁣󠁴󠁿";
    var at: usize = 0;
    while (at < text.len) {
        const end = clusterEnd(text, at);
        try testing.expectEqual(at, clusterStart(text, end));
        at = end;
    }
    try testing.expectEqual(@as(usize, 0), clusterStart(text, 0));
}

test "a joiner at the end stays with what it follows" {
    try testing.expectEqual(@as(usize, 7), clusterEnd("👨\u{200D}", 0));
    try testing.expectEqual(@as(usize, 1), clusterEnd(&.{ 0xFF, 'a' }, 0));
}

test "a digit is a digit until it is a keycap" {
    try testing.expect(!wantsEmoji("1"));
    try testing.expect(wantsEmoji("😀"));
    try testing.expect(!wantsEmoji("❤"));
    try testing.expect(wantsEmoji("❤️"));
    try testing.expect(wantsEmoji("1️⃣"));
    try testing.expect(!wantsEmoji("❤\u{FE0E}"));
    try testing.expect(wantsEmoji("🇭🇺"));
    try testing.expect(isInvisible(0x200D) and isInvisible(0xFE0F) and !isInvisible('a'));
}
