// SPDX-License-Identifier: BSD-2-Clause

//! The two lookups every OpenType layout table is built on: which glyphs a
//! rule covers, and which class a glyph is in. `gsub` substitutes with them
//! and `gpos` kerns with them.
//!
//! `GSUB` - and `GPOS`, and `GDEF` - never list glyphs inline. A rule says
//! "these glyphs" by pointing at a **coverage** table, and "glyphs of this
//! kind" by pointing at a **class definition**. Both come in two formats: a
//! sorted list for a scattered set, and ranges for a run of consecutive
//! glyph numbers, which is what a font compiler emits for the hundreds of
//! emoji drawn one after another.

const std = @import("std");
const testing = std.testing;

const sfnt = @import("sfnt.zig");

const Error = sfnt.Error;
const View = sfnt.View;

/// A set of glyphs, and each one's place in it.
pub const Coverage = struct {
    table: View,

    pub fn at(parent: View, offset: usize) Error!Coverage {
        return .{ .table = try parent.from(offset) };
    }

    /// The glyph's index in the set, or null when it is not in it. The index
    /// is what a rule uses to find the entry for that glyph.
    pub fn index(self: Coverage, glyph: u16) Error!?u16 {
        const t = self.table;
        switch (try t.int(u16, 0)) {
            1 => {
                const count = try t.int(u16, 2);
                var low: usize = 0;
                var high: usize = count;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const value = try t.int(u16, 4 + middle * 2);
                    if (value < glyph) {
                        low = middle + 1;
                    } else if (value > glyph) {
                        high = middle;
                    } else return @intCast(middle);
                }
                return null;
            },
            2 => {
                const count = try t.int(u16, 2);
                var low: usize = 0;
                var high: usize = count;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const at_ = 4 + middle * 6;
                    const first = try t.int(u16, at_);
                    const last = try t.int(u16, at_ + 2);
                    if (last < glyph) {
                        low = middle + 1;
                    } else if (first > glyph) {
                        high = middle;
                    } else {
                        // A range numbered from near the top runs past
                        // 65535 in no font that works - only in one made
                        // to crash a reader, so the cast is checked.
                        const start = try t.int(u16, at_ + 4);
                        return std.math.cast(u16, @as(u32, start) + glyph - first) orelse error.Malformed;
                    }
                }
                return null;
            },
            else => return null,
        }
    }
};

/// Which class each glyph is in. A glyph the table does not name is in
/// class zero.
pub const ClassDef = struct {
    table: View,

    pub fn at(parent: View, offset: usize) Error!ClassDef {
        return .{ .table = try parent.from(offset) };
    }

    pub fn class(self: ClassDef, glyph: u16) Error!u16 {
        const t = self.table;
        switch (try t.int(u16, 0)) {
            1 => {
                const first = try t.int(u16, 2);
                const count = try t.int(u16, 4);
                if (glyph < first or glyph - first >= count) return 0;
                return t.int(u16, 6 + @as(usize, glyph - first) * 2);
            },
            2 => {
                const count = try t.int(u16, 2);
                var low: usize = 0;
                var high: usize = count;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const at_ = 4 + middle * 6;
                    const first = try t.int(u16, at_);
                    const last = try t.int(u16, at_ + 2);
                    if (last < glyph) {
                        low = middle + 1;
                    } else if (first > glyph) {
                        high = middle;
                    } else return t.int(u16, at_ + 4);
                }
                return 0;
            },
            else => return 0,
        }
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a coverage list says where in it a glyph is" {
    // Format 1: three glyphs, sorted.
    const list: View = .{ .bytes = &.{ 0, 1, 0, 3, 0, 5, 0, 9, 0, 40 } };
    const coverage: Coverage = .{ .table = list };
    try testing.expectEqual(@as(?u16, 0), try coverage.index(5));
    try testing.expectEqual(@as(?u16, 2), try coverage.index(40));
    try testing.expectEqual(@as(?u16, null), try coverage.index(6));
}

test "a coverage range counts on from where the range starts" {
    // Format 2: glyphs 10 to 19 are indices 0 to 9, 30 to 31 are 10 and 11.
    const ranges: View = .{ .bytes = &.{ 0, 2, 0, 2, 0, 10, 0, 19, 0, 0, 0, 30, 0, 31, 0, 10 } };
    const coverage: Coverage = .{ .table = ranges };
    try testing.expectEqual(@as(?u16, 4), try coverage.index(14));
    try testing.expectEqual(@as(?u16, 11), try coverage.index(31));
    try testing.expectEqual(@as(?u16, null), try coverage.index(20));
}

test "a coverage range that counts past the last index is malformed, not a crash" {
    // Glyphs 0 to 100, numbered from 65500: glyph 99 would be index 65599.
    const ranges: View = .{ .bytes = &.{ 0, 2, 0, 1, 0, 0, 0, 100, 0xFF, 0xDC } };
    const coverage: Coverage = .{ .table = ranges };
    try testing.expectEqual(@as(?u16, 65535), try coverage.index(35));
    try testing.expectError(error.Malformed, coverage.index(99));
}

test "a glyph a class table does not name is in class zero" {
    // Format 1 from glyph 5: classes 1, 2, 3.
    const listed: ClassDef = .{ .table = .{ .bytes = &.{ 0, 1, 0, 5, 0, 3, 0, 1, 0, 2, 0, 3 } } };
    try testing.expectEqual(@as(u16, 2), try listed.class(6));
    try testing.expectEqual(@as(u16, 0), try listed.class(4));
    try testing.expectEqual(@as(u16, 0), try listed.class(8));

    // Format 2: 100 to 120 are class 7.
    const ranged: ClassDef = .{ .table = .{ .bytes = &.{ 0, 2, 0, 1, 0, 100, 0, 120, 0, 7 } } };
    try testing.expectEqual(@as(u16, 7), try ranged.class(110));
    try testing.expectEqual(@as(u16, 0), try ranged.class(121));
}
