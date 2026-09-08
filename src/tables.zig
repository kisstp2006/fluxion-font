// SPDX-License-Identifier: BSD-2-Clause

//! The small fixed tables: how big the design grid is, how tall a line is,
//! how wide each glyph is, and how many there are.
//!
//! Each of these is a handful of fields at known offsets, and the only reason
//! they are worth wrapping rather than reading inline is that the offsets are
//! not memorable and getting one wrong gives a plausible-looking wrong answer
//! rather than an error. `hhea` puts the ascender at 4 and the number of
//! horizontal metrics at 34, with twenty-four bytes of things nobody reads in
//! between.
//!
//! **Everything here is in font units**, not pixels. A font is drawn on a
//! grid whose size it chooses - `Head.units_per_em`, almost always 1000 or
//! 2048 - and turning those into pixels is one multiplication that belongs at
//! the point of use, because it depends on the size being drawn at. See
//! `Font.scaleFor`.

const std = @import("std");
const testing = std.testing;

const sfnt = @import("sfnt.zig");

const Error = sfnt.Error;
const File = sfnt.File;
const View = sfnt.View;

/// `head`: the design grid, and how to read `loca`.
pub const Head = struct {
    /// How many units the em square is across. The number every other
    /// measurement in the font is in terms of.
    units_per_em: u16,
    /// The bounding box of every glyph together, in font units. Useful for
    /// sizing an atlas cell before any glyph has been looked at.
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    /// Whether `loca` holds two-byte or four-byte offsets. The one field in
    /// this table that another table cannot be read without.
    long_loca: bool,

    /// The number the specification says is at offset 12 of every `head`
    /// table ever written. Checked, because a file where this is wrong is not
    /// a font whatever else it claims.
    const magic: u32 = 0x5F0F3CF5;

    /// Read it out of a font.
    pub fn read(file: File) Error!Head {
        return parse(try file.required(.head));
    }

    pub fn parse(table: View) Error!Head {
        if (try table.int(u32, 12) != magic) return error.Malformed;

        const units = try table.int(u16, 18);
        // Zero would make every scale a division by zero, and the
        // specification puts the floor at 16.
        if (units < 16) return error.Malformed;

        const format = try table.int(i16, 50);
        if (format != 0 and format != 1) return error.Malformed;

        return .{
            .units_per_em = units,
            .x_min = try table.int(i16, 36),
            .y_min = try table.int(i16, 38),
            .x_max = try table.int(i16, 40),
            .y_max = try table.int(i16, 42),
            .long_loca = format == 1,
        };
    }
};

/// `hhea`: how tall a line is, and how much of `hmtx` is the long form.
pub const Hhea = struct {
    /// How far above the baseline the tallest glyph reaches, in font units.
    /// Positive.
    ascender: i16,
    /// How far below. **Negative**, in every font that gets it right, and a
    /// line height computed as `ascender + descender` rather than
    /// `ascender - descender` is the commonest way to get cramped text.
    descender: i16,
    /// Extra space between one line's descender and the next line's
    /// ascender. Usually small and often zero.
    line_gap: i16,
    /// The widest advance in the font.
    advance_width_max: u16,
    /// How many glyphs have an advance width of their own in `hmtx`. The rest
    /// share the last one - which is how a monospaced font stores one width
    /// for thousands of glyphs.
    metric_count: u16,

    /// Read it out of a font.
    pub fn read(file: File) Error!Hhea {
        return parse(try file.required(.hhea));
    }

    pub fn parse(table: View) Error!Hhea {
        return .{
            .ascender = try table.int(i16, 4),
            .descender = try table.int(i16, 6),
            .line_gap = try table.int(i16, 8),
            .advance_width_max = try table.int(u16, 10),
            .metric_count = try table.int(u16, 34),
        };
    }

    /// Baseline to baseline, in font units.
    pub inline fn lineHeight(self: Hhea) i32 {
        return @as(i32, self.ascender) - @as(i32, self.descender) + @as(i32, self.line_gap);
    }
};

/// `maxp`: how many glyphs there are.
pub const Maxp = struct {
    glyph_count: u16,

    /// Read it out of a font.
    pub fn read(file: File) Error!Maxp {
        return parse(try file.required(.maxp));
    }

    pub fn parse(table: View) Error!Maxp {
        return .{ .glyph_count = try table.int(u16, 4) };
    }
};

/// `OS/2`: the metrics a typographer would use, where `hhea` has the ones the
/// original Macintosh needed.
///
/// Optional, and worth reading when it is there. The two disagree often
/// enough that a renderer which wants text to sit where a designer intended
/// should prefer these - `Font.lineHeight` does, and falls back to `hhea`.
pub const Os2 = struct {
    typo_ascender: i16,
    typo_descender: i16,
    typo_line_gap: i16,
    /// Whether `typo_*` are the ones the designer meant. Bit 7 of `fsSelection`,
    /// added in version 4, and a font that sets it is asking to be believed.
    use_typo_metrics: bool,

    /// Read it out of a font, or null.
    ///
    /// Null covers both a font without the table and one whose table is too
    /// short or too old to hold the fields worth reading - neither is an
    /// error, and both mean the same thing to a caller: fall back to `hhea`.
    pub fn read(file: File) Error!?Os2 {
        const table = try file.table(.os2) orelse return null;
        return parse(table) catch null;
    }

    pub fn parse(table: View) Error!Os2 {
        // Version 0 of this table stops before the typographic metrics.
        const version = try table.int(u16, 0);
        if (version == 0 and table.len() < 78) return error.Malformed;

        const selection = try table.int(u16, 62);
        return .{
            .typo_ascender = try table.int(i16, 68),
            .typo_descender = try table.int(i16, 70),
            .typo_line_gap = try table.int(i16, 72),
            .use_typo_metrics = version >= 4 and (selection & 0x80) != 0,
        };
    }
};

/// `hmtx`: how far the pen moves after each glyph.
///
/// Not parsed into a struct, because it is a table with one entry per glyph
/// and copying it would be copying the font. The two accessors read it in
/// place.
pub const Hmtx = struct {
    table: View,
    /// From `hhea`. Everything at or after this index shares the last
    /// advance.
    metric_count: u16,
    glyph_count: u16,

    /// Read it out of a font.
    ///
    /// Takes the whole file rather than the one table because the shape of
    /// `hmtx` is not in `hmtx`: how much of it is the long form comes from
    /// `hhea`, and how many entries there are altogether comes from `maxp`.
    pub fn read(file: File) Error!Hmtx {
        const hhea = try Hhea.read(file);
        const maxp = try Maxp.read(file);
        return .{
            .table = try file.required(.hmtx),
            .metric_count = hhea.metric_count,
            .glyph_count = maxp.glyph_count,
        };
    }

    /// How far the pen moves after drawing `glyph`, in font units.
    ///
    /// The tail of the table is the reason this is not one read. A font where
    /// most glyphs are the same width - a monospaced one, or one with a large
    /// run of CJK - stores the repeated advance once and then only the left
    /// side bearings, so an index past `metric_count` takes the last advance
    /// rather than reading past the end.
    pub fn advance(self: Hmtx, glyph: u16) Error!u16 {
        if (self.metric_count == 0) return 0;
        const index = @min(glyph, self.metric_count - 1);
        return self.table.int(u16, @as(usize, index) * 4);
    }

    /// How far right of the pen the glyph's outline starts, in font units.
    /// Negative for a glyph that leans left of its origin, which is normal
    /// for an italic `f`.
    pub fn leftSideBearing(self: Hmtx, glyph: u16) Error!i16 {
        if (glyph < self.metric_count) {
            // A long-form entry is four bytes - an advance and a bearing -
            // so the bearing is two bytes into the fourth byte of each, and
            // not two bytes into the second.
            return self.table.int(i16, @as(usize, glyph) * 4 + 2);
        }
        // Past the long-form entries, the short form is one bearing each.
        const tail = @as(usize, self.metric_count) * 4;
        const index = @as(usize, glyph) - self.metric_count;
        return self.table.int(i16, tail + index * 2);
    }
};

test "head reads the design grid and refuses a file that is not one" {
    var bytes: [54]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[12..16], Head.magic, .big);
    std.mem.writeInt(u16, bytes[18..20], 2048, .big);
    std.mem.writeInt(i16, bytes[36..38], -100, .big);
    std.mem.writeInt(i16, bytes[40..42], 1900, .big);
    std.mem.writeInt(i16, bytes[50..52], 1, .big);

    const head = try Head.parse(.{ .bytes = &bytes });
    try testing.expectEqual(2048, head.units_per_em);
    try testing.expectEqual(-100, head.x_min);
    try testing.expectEqual(1900, head.x_max);
    try testing.expect(head.long_loca);

    // The magic number is the one field worth checking, because a file that
    // gets it wrong is not a font whatever its first four bytes said.
    var broken = bytes;
    std.mem.writeInt(u32, broken[12..16], 0xDEADBEEF, .big);
    try testing.expectError(error.Malformed, Head.parse(.{ .bytes = &broken }));
}

test "head refuses an em square that would divide by zero" {
    var bytes: [54]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[12..16], Head.magic, .big);
    std.mem.writeInt(u16, bytes[18..20], 0, .big);
    try testing.expectError(error.Malformed, Head.parse(.{ .bytes = &bytes }));
}

test "head refuses a loca format it cannot read" {
    var bytes: [54]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[12..16], Head.magic, .big);
    std.mem.writeInt(u16, bytes[18..20], 1000, .big);
    std.mem.writeInt(i16, bytes[50..52], 2, .big);
    try testing.expectError(error.Malformed, Head.parse(.{ .bytes = &bytes }));
}

test "a line height is ascender minus descender, because descender is negative" {
    var bytes: [36]u8 = @splat(0);
    std.mem.writeInt(i16, bytes[4..6], 1900, .big);
    std.mem.writeInt(i16, bytes[6..8], -500, .big);
    std.mem.writeInt(i16, bytes[8..10], 100, .big);
    std.mem.writeInt(u16, bytes[34..36], 3, .big);

    const hhea = try Hhea.parse(.{ .bytes = &bytes });
    try testing.expectEqual(1900, hhea.ascender);
    try testing.expectEqual(-500, hhea.descender);
    try testing.expectEqual(3, hhea.metric_count);

    // 1900 + 500 + 100. Adding the descender instead of subtracting it would
    // give 1500, and the text would overlap.
    try testing.expectEqual(2500, hhea.lineHeight());
}

test "hmtx shares the last advance with every glyph past the long form" {
    // Three long entries, then two bearings on their own: five glyphs whose
    // last three are all as wide as the third.
    var bytes: [16]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[0..2], 600, .big);
    std.mem.writeInt(i16, bytes[2..4], 30, .big);
    std.mem.writeInt(u16, bytes[4..6], 700, .big);
    std.mem.writeInt(i16, bytes[6..8], -10, .big);
    std.mem.writeInt(u16, bytes[8..10], 800, .big);
    std.mem.writeInt(i16, bytes[10..12], 5, .big);
    std.mem.writeInt(i16, bytes[12..14], 40, .big);
    std.mem.writeInt(i16, bytes[14..16], 50, .big);

    const hmtx: Hmtx = .{ .table = .{ .bytes = &bytes }, .metric_count = 3, .glyph_count = 5 };

    try testing.expectEqual(600, try hmtx.advance(0));
    try testing.expectEqual(700, try hmtx.advance(1));
    try testing.expectEqual(800, try hmtx.advance(2));
    // The whole point: these are not in the table, and share the last one.
    try testing.expectEqual(800, try hmtx.advance(3));
    try testing.expectEqual(800, try hmtx.advance(4));

    // The bearings, though, are all stored, and the tail ones come from
    // after the long-form entries.
    try testing.expectEqual(30, try hmtx.leftSideBearing(0));
    try testing.expectEqual(-10, try hmtx.leftSideBearing(1));
    try testing.expectEqual(40, try hmtx.leftSideBearing(3));
    try testing.expectEqual(50, try hmtx.leftSideBearing(4));
}

test "an hmtx with no metrics at all answers zero rather than reading" {
    const hmtx: Hmtx = .{ .table = .empty, .metric_count = 0, .glyph_count = 0 };
    try testing.expectEqual(0, try hmtx.advance(0));
}

test "maxp is one useful number" {
    var bytes: [6]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], 1234, .big);
    try testing.expectEqual(1234, (try Maxp.parse(.{ .bytes = &bytes })).glyph_count);
}

test "OS/2 typographic metrics, and whether the font asks for them" {
    var bytes: [96]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[0..2], 4, .big);
    std.mem.writeInt(u16, bytes[62..64], 0x0080, .big);
    std.mem.writeInt(i16, bytes[68..70], 1600, .big);
    std.mem.writeInt(i16, bytes[70..72], -400, .big);
    std.mem.writeInt(i16, bytes[72..74], 0, .big);

    const os2 = try Os2.parse(.{ .bytes = &bytes });
    try testing.expectEqual(1600, os2.typo_ascender);
    try testing.expectEqual(-400, os2.typo_descender);
    try testing.expect(os2.use_typo_metrics);

    // Version 3 has the fields but not the bit that asks for them.
    std.mem.writeInt(u16, bytes[0..2], 3, .big);
    try testing.expect(!(try Os2.parse(.{ .bytes = &bytes })).use_typo_metrics);
}
