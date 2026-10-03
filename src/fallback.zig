// SPDX-License-Identifier: BSD-2-Clause

//! Which of several fonts draws each part of a run of text.
//!
//! A text font has no emoji, and an emoji font has no letters. Given the
//! text's own font first and the ones to fall back on after it, `Glyphs`
//! walks the text a cluster at a time - an emoji sequence is one cluster,
//! see `emoji` - and says which font draws it and with which glyphs:
//!
//!   * a cluster that wants to be an emoji goes to the first fallback that
//!     has its first character, and its own font only when none does;
//!   * anything else stays in its own font, and goes to a fallback only when
//!     its own font has no glyph for it;
//!   * a cluster drawn by a fallback, or made of more than one character, has
//!     the font's `ccmp` substitutions run over it - which is what puts a
//!     family, a flag or a skin tone back together into one glyph;
//!   * a joiner or a selector no font has a glyph for is dropped rather than
//!     drawn as a box.
//!
//! Which fonts to pass, and in what order, is the caller's: this chooses
//! between them and never goes looking for one.

const std = @import("std");
const testing = std.testing;

const Font = @import("Font.zig");
const cmap = @import("cmap.zig");
const emoji = @import("emoji.zig");
const gsub = @import("gsub.zig");
const sfnt = @import("sfnt.zig");

/// One glyph of the text, and which font it is in.
pub const Placed = struct {
    /// Which of the fonts: 0 is the text's own, the rest the fallbacks in
    /// the order they were given.
    face: u8,
    glyph: u16,
    /// The bytes of the text it draws. Every glyph of one cluster has the
    /// same range - a ligature draws the whole of it.
    start: u32,
    end: u32,
};

const features = [_]u32{ sfnt.tag("ccmp"), sfnt.tag("liga") };

pub const Glyphs = struct {
    faces: []const *const Font,
    text: []const u8,
    at: usize = 0,
    pending: gsub.Glyphs = .{},
    taken: usize = 0,
    face: u8 = 0,
    start: u32 = 0,
    end: u32 = 0,

    pub fn init(faces: []const *const Font, text: []const u8) Glyphs {
        return .{ .faces = faces, .text = text };
    }

    pub fn next(self: *Glyphs) ?Placed {
        while (self.taken >= self.pending.len) {
            if (self.at >= self.text.len or self.faces.len == 0) return null;
            self.fill();
        }
        defer self.taken += 1;
        return .{ .face = self.face, .glyph = self.pending.items[self.taken], .start = self.start, .end = self.end };
    }

    /// The next cluster's glyphs.
    fn fill(self: *Glyphs) void {
        const start = self.at;
        const end = emoji.clusterEnd(self.text, start);
        self.at = end;
        const cluster = self.text[start..end];
        self.face = faceFor(self.faces, cluster);
        self.start = @intCast(start);
        self.end = @intCast(end);
        self.pending = .{};
        self.taken = 0;

        const font = self.faces[self.face];
        var at: usize = 0;
        var characters: usize = 0;
        // The glyphs a font gives its joiners and selectors: what is left of
        // them once the substitutions have used what they needed draws
        // nothing, and is dropped.
        var hidden: [8]u16 = undefined;
        var hidden_count: usize = 0;
        while (at < cluster.len) {
            const d = emoji.decode(cluster, at);
            at += d.len;
            characters += 1;
            const glyph = font.glyphFor(d.cp);
            if (emoji.isInvisible(d.cp)) {
                if (glyph == cmap.notdef) continue;
                if (hidden_count < hidden.len) {
                    hidden[hidden_count] = glyph;
                    hidden_count += 1;
                }
            }
            if (!self.pending.append(glyph)) break;
        }
        if (self.face != 0 or characters > 1) {
            if (font.gsub) |table| table.apply(&self.pending, &features) catch {};
        }
        if (hidden_count == 0) return;
        var kept: usize = 0;
        for (self.pending.slice()) |glyph| {
            if (std.mem.indexOfScalar(u16, hidden[0..hidden_count], glyph) != null) continue;
            self.pending.items[kept] = glyph;
            kept += 1;
        }
        self.pending.len = kept;
    }
};

/// Which font draws a cluster. See the top of the file.
pub fn faceFor(faces: []const *const Font, cluster: []const u8) u8 {
    const first = emoji.decode(cluster, 0).cp;
    const wanted = emoji.wantsEmoji(cluster);
    if (!wanted and faces[0].has(first)) return 0;
    for (faces[1..], 1..) |font, k| {
        if (font.has(first)) return @intCast(k);
    }
    return 0;
}

/// How wide a run of UTF-8 is at `pixels_per_em`, each glyph in the font
/// that draws it, kerned within a font.
pub fn measure(faces: []const *const Font, pixels_per_em: f32, text: []const u8) Font.Error!f32 {
    var total: f32 = 0;
    var previous: ?Placed = null;
    var glyphs: Glyphs = .init(faces, text);
    while (glyphs.next()) |placed| {
        const font = faces[placed.face];
        const scale = font.scaleFor(pixels_per_em);
        if (previous) |before| {
            if (before.face == placed.face) total += @as(f32, @floatFromInt(try font.kern(before.glyph, placed.glyph))) * scale;
        }
        total += @as(f32, @floatFromInt(try font.advance(placed.glyph))) * scale;
        previous = placed;
    }
    return total;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn read(path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20)) catch null;
}

test "letters stay in their font and an emoji goes to the one that has it" {
    const text_bytes = read("C:/Windows/Fonts/segoeui.ttf") orelse return error.SkipZigTest;
    defer testing.allocator.free(text_bytes);
    const emoji_bytes = read("C:/Windows/Fonts/seguiemj.ttf") orelse return error.SkipZigTest;
    defer testing.allocator.free(emoji_bytes);

    const own: Font = try .init(text_bytes);
    const colour: Font = try .init(emoji_bytes);
    const faces = [_]*const Font{ &own, &colour };

    // A family is joined by the font's own rules: Segoe UI Emoji draws its
    // people side by side, a glyph each, and drops the joiners between them;
    // and it has no flags, so a flag stays its two letters.
    const Expect = struct { text: []const u8, face: u8, most: usize };
    for ([_]Expect{
        .{ .text = "a", .face = 0, .most = 1 },
        .{ .text = "😀", .face = 1, .most = 1 },
        .{ .text = "👍🏽", .face = 1, .most = 1 },
        .{ .text = "👨‍👩‍👧", .face = 1, .most = 3 },
        .{ .text = "🇭🇺", .face = 1, .most = 2 },
        .{ .text = "❤️", .face = 1, .most = 1 },
        .{ .text = "1", .face = 0, .most = 1 },
    }) |expect| {
        var glyphs: Glyphs = .init(&faces, expect.text);
        var count: usize = 0;
        while (glyphs.next()) |placed| : (count += 1) {
            try testing.expectEqual(expect.face, placed.face);
            try testing.expect(placed.glyph != cmap.notdef);
            try testing.expectEqual(@as(u32, 0), placed.start);
            try testing.expectEqual(@as(u32, @intCast(expect.text.len)), placed.end);
        }
        try testing.expect(count >= 1 and count <= expect.most);
    }

    // A whole line measures as its parts.
    const parts = try measure(&faces, 20, "a") + try measure(&faces, 20, "😀");
    try testing.expectApproxEqAbs(parts, try measure(&faces, 20, "a😀"), 0.01);
}

test "with only its own font, a character it lacks is its box and a joiner is nothing" {
    const text_bytes = read("C:/Windows/Fonts/segoeui.ttf") orelse return error.SkipZigTest;
    defer testing.allocator.free(text_bytes);
    const own: Font = try .init(text_bytes);
    const faces = [_]*const Font{&own};

    // The two people are boxes; the joiner, if the font draws it at all,
    // takes no room.
    var glyphs: Glyphs = .init(&faces, "👨\u{200D}👩");
    var boxes: usize = 0;
    while (glyphs.next()) |placed| {
        if (placed.glyph == cmap.notdef) {
            boxes += 1;
        } else try testing.expectEqual(@as(u16, 0), try own.advance(placed.glyph));
    }
    try testing.expectEqual(@as(usize, 2), boxes);
}
