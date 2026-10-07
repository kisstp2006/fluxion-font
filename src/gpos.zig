// SPDX-License-Identifier: BSD-2-Clause

//! `GPOS`: how far apart two glyphs sit, read for the one job a renderer
//! without a shaper has for it - kerning.
//!
//! Nearly every font made in the last fifteen years keeps its kerning here
//! and not in `kern`. Inter has no `kern` table at all: its `To`, `AV` and
//! `Ty` are pair adjustments in a `GPOS` lookup, and a reader that looks only
//! at `kern` sets them as loosely as `HH`. So this reads exactly that much:
//! the lookups the font's `kern` feature names, of the type that adjusts a
//! pair - type 2, in both its formats, a list of pairs and a grid of classes
//! - and the extension, type 9, that a font compiler wraps them in once the
//! table outgrows sixteen-bit offsets.
//!
//! **Resolved once, asked often.** `Font.kern` is asked about every pair of
//! glyphs a renderer draws and every pair a layout measures - every
//! character of every string, every time one changes. Walking the script
//! list, the feature list and the lookup list each time would be a few
//! hundred bounds-checked reads to answer a question whose answer is zero for
//! almost every pair. So `Kerning.read` walks them once, when the font opens,
//! and keeps where each pair subtable starts; a question afterwards is a
//! coverage search per subtable - five of them, for Inter - and nothing else.
//! Nothing here allocates, then or later.
//!
//! **Every script at once.** A shaper picks one language system by the text's
//! script and language, and asks only that system's features. This is asked
//! about two glyphs and knows neither, so it takes the lookups that *any*
//! language system's `kern` feature names, each of them once. That is less of
//! a compromise than it sounds: a font compiler splits kerning by script -
//! Latin pairs in one lookup, Greek in another, the punctuation every script
//! shares in one they all name - so a Latin pair is only in the coverage of
//! lookups `latn` names anyway, and the union kerns it as `latn` alone would.
//! What is lost is kerning a font keeps for one language: here it applies to
//! every language.
//!
//! **What is not read, and why it does not matter here:**
//!
//! - A lookup's flags. They say which glyphs to step over looking for the
//!   second of a pair - marks, usually - and here the caller names both
//!   glyphs, so there is nothing to step over.
//! - Anything in a pair's values but the first glyph's advance, which is what
//!   horizontal kerning is. Placement shifts, vertical values, the second
//!   glyph's record (where a right-to-left font puts its kerning) and device
//!   tables (a pixel-size nudge, or a variable font's deltas) are stepped
//!   over by their size and not applied.
//! - Feature variations, from version 1.1: the default features are read,
//!   which is what a static font has anyway.
//! - The rest of `GPOS` - marks on bases, cursive attachment, contextual
//!   positioning. That is shaping, and it is not here.
//!
//! **A broken table is no kerning, not an error.** Kerning is the difference
//! between text that looks set and text that looks typed; it is never the
//! difference between text and no text. So a `GPOS` that cannot be walked
//! through when the font opens is as if it were not there - the font falls
//! back on its `kern` table, if it has one - and a pair whose subtable reads
//! past its end is a pair that is not kerned. `Kerning.find` is the one that
//! reports the error, for a tool that validates fonts.

const std = @import("std");
const testing = std.testing;

const layout = @import("layout.zig");
const sfnt = @import("sfnt.zig");

const Coverage = layout.Coverage;
const ClassDef = layout.ClassDef;
const Error = sfnt.Error;
const File = sfnt.File;
const View = sfnt.View;

/// The pair adjustments a font's `kern` feature names, found once.
///
/// What is kept is a list of offsets and a few bits, not a copy of anything:
/// the subtables are read in place each time, like every other table here.
/// It lives inside `Font`, so it is a fixed size - a font that splits its
/// kerning over more than `capacity` subtables keeps the first `capacity`,
/// in lookup order. The two hundred and fifty fonts on the Linux desktop
/// this was written on use between one and seven.
pub const Kerning = struct {
    /// The whole `GPOS` table. Every offset in `subtables` counts from its
    /// start.
    table: View,
    /// Where each pair adjustment subtable starts, in the order the font
    /// lists its lookups, extensions already unwrapped. Thirty-two bits,
    /// because an extension is there precisely to reach past sixty-four
    /// kilobytes.
    subtables: [capacity]u32 = undefined,
    /// Which subtables start a lookup: bit `k` is set when subtable `k` is
    /// the first of its lookup to be kept.
    ///
    /// The boundaries matter because the two levels combine differently.
    /// Inside a lookup, the first subtable that has the pair answers and the
    /// rest are not asked - which is how a font says "these pairs exactly,
    /// and every other pair by class": the list of exceptions comes first and
    /// the class grid after it. Across lookups, every one that has the pair
    /// adds its adjustment to the others'.
    firsts: u64 = 0,
    len: u8 = 0,

    pub const capacity = 64;

    const pair_adjustment: u16 = 2;
    const extension: u16 = 9;

    /// How many distinct lookups the `kern` features may name before the
    /// rest are not looked at. `gsub` stops at the same number.
    const max_lookups = 256;

    /// The kerning out of a font's `GPOS`, or null when there is none to
    /// read: no `GPOS`, no `kern` feature in it, no pair adjustment under
    /// that, or a table too broken to walk.
    ///
    /// No error union, and that is deliberate - see the top of the file. Null
    /// is what a caller does something useful with: falls back to `kern`.
    pub fn read(file: File) ?Kerning {
        const table = (file.table(@enumFromInt(sfnt.tag("GPOS"))) catch return null) orelse return null;
        return parse(table);
    }

    /// The same, given the `GPOS` table itself.
    pub fn parse(table: View) ?Kerning {
        return resolve(table) catch null;
    }

    fn resolve(table: View) Error!?Kerning {
        // Version 1.0 and 1.1 have the same first ten bytes, and 1.1's one
        // addition - feature variations - is not read.
        if (try table.int(u16, 0) != 1) return null;
        const lookups_at = try table.int(u16, 8);
        if (lookups_at == 0) return null;

        var wanted: [max_lookups]u16 = undefined;
        const indices = try kernLookups(table, &wanted);

        const list = try table.from(lookups_at);
        const lookup_count = try list.int(u16, 0);

        var self: Kerning = .{ .table = table };
        for (indices) |index| {
            if (index >= lookup_count) continue;
            const lookup_at = @as(usize, lookups_at) + try list.int(u16, 2 + @as(usize, index) * 2);
            const lookup = try table.from(lookup_at);
            const kind = try lookup.int(u16, 0);
            if (kind != pair_adjustment and kind != extension) continue;

            var first = true;
            for (0..try lookup.int(u16, 4)) |k| {
                var at = lookup_at + try lookup.int(u16, 6 + k * 2);
                if (kind == extension) {
                    // An extension is eight bytes - a format, the type of
                    // what it wraps, and a 32-bit offset to it - and is
                    // otherwise not there: what it points at is read as if
                    // the lookup had held it directly.
                    const wrapper = try table.from(at);
                    if (try wrapper.int(u16, 0) != 1) continue;
                    if (try wrapper.int(u16, 2) != pair_adjustment) continue;
                    const offset = try wrapper.int(u32, 4);
                    // Checked before it is added, so a wild offset is an
                    // error here rather than an overflow on a 32-bit target.
                    if (offset > wrapper.len()) return error.OutOfBounds;
                    at += offset;
                }
                const format = try table.int(u16, at);
                if (format != 1 and format != 2) continue;

                if (self.len == capacity) return self;
                if (first) self.firsts |= @as(u64, 1) << @intCast(self.len);
                first = false;
                // `at` is inside the table, and a table's length came from a
                // 32-bit field in the directory, so this cannot truncate.
                self.subtables[self.len] = @intCast(at);
                self.len += 1;
            }
        }
        if (self.len == 0) return null;
        return self;
    }

    /// The lookups that any language system's `kern` feature names, each
    /// once, sorted - which is the order the specification runs them in.
    fn kernLookups(table: View, out: *[max_lookups]u16) Error![]u16 {
        const scripts_at = try table.int(u16, 4);
        const features_at = try table.int(u16, 6);
        // A null offset is an empty list, not a list at the start of the
        // table - where the version number would read as a count of one.
        if (scripts_at == 0 or features_at == 0) return out[0..0];
        const scripts = try table.from(scripts_at);
        const features = try table.from(features_at);

        var found: Found = .{ .items = out };
        for (0..try scripts.int(u16, 0)) |s| {
            const script = try scripts.from(try scripts.int(u16, 2 + s * 6 + 4));
            const default = try script.int(u16, 0);
            if (default != 0) try found.language(try script.from(default), features);
            for (0..try script.int(u16, 2)) |l| {
                const offset = try script.int(u16, 4 + l * 6 + 4);
                if (offset != 0) try found.language(try script.from(offset), features);
            }
        }

        const lookups = out[0..found.len];
        std.mem.sort(u16, lookups, {}, std.sort.asc(u16));
        return lookups;
    }

    /// The lookup indices collected so far, each once.
    ///
    /// Each kept once as it arrives rather than sorted out at the end,
    /// because the same feature is named by every language of every script
    /// that uses it - Inter's is named seven times - and a list that kept the
    /// repeats would fill with them before it filled with lookups.
    const Found = struct {
        items: *[max_lookups]u16,
        len: usize = 0,

        /// Every lookup a language system's `kern` features name.
        fn language(self: *Found, system: View, features: View) Error!void {
            const required = try system.int(u16, 2);
            if (required != 0xFFFF) try self.feature(features, required);
            for (0..try system.int(u16, 4)) |k| {
                try self.feature(features, try system.int(u16, 6 + k * 2));
            }
        }

        fn feature(self: *Found, features: View, index: u16) Error!void {
            if (index >= try features.int(u16, 0)) return;
            const record = 2 + @as(usize, index) * 6;
            if (try features.int(u32, record) != sfnt.tag("kern")) return;
            const table = try features.from(try features.int(u16, record + 4));
            for (0..try table.int(u16, 2)) |k| self.add(try table.int(u16, 4 + k * 2));
        }

        fn add(self: *Found, index: u16) void {
            if (std.mem.indexOfScalar(u16, self.items[0..self.len], index) != null) return;
            if (self.len == self.items.len) return;
            self.items[self.len] = index;
            self.len += 1;
        }
    };

    /// How much closer `left` and `right` sit than their advances say, in
    /// font units - negative for `AV`, zero for almost everything else.
    ///
    /// No error union, for the reason `cmap.Cmap.lookup` has none: a pair
    /// whose subtable is broken is drawn the way a pair the font does not
    /// kern is drawn, and every caller would otherwise write `catch 0`.
    pub fn kern(self: *const Kerning, left: u16, right: u16) i16 {
        return self.find(left, right) catch 0;
    }

    /// The same, reporting a malformed subtable rather than hiding it. For a
    /// tool that validates fonts; `kern` is the one to draw with.
    pub fn find(self: *const Kerning, left: u16, right: u16) Error!i16 {
        var total: i32 = 0;
        var k: usize = 0;
        while (k < self.len) {
            const found = try self.pairIn(self.subtables[k], left, right);
            k += 1;
            if (found) |value| {
                total += value;
                // This lookup has answered; the rest of its subtables are
                // not asked.
                while (k < self.len and !self.startsLookup(k)) k += 1;
            }
        }
        // Several lookups can each move a pair, and their sum is still a
        // fraction of an em in any font meant to be read. One that is not is
        // held to what the return type can say.
        return @intCast(std.math.clamp(total, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    inline fn startsLookup(self: *const Kerning, k: usize) bool {
        return self.firsts & (@as(u64, 1) << @intCast(k)) != 0;
    }

    /// One subtable's adjustment for a pair, or null when it does not have
    /// the pair - which is not the same as an adjustment of zero. A subtable
    /// that has the pair and moves it by nothing has still answered, and the
    /// lookup's later subtables are not asked.
    fn pairIn(self: *const Kerning, offset: u32, left: u16, right: u16) Error!?i16 {
        const t = try self.table.from(offset);
        const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(left) orelse return null;
        const first: Values = .{ .format = try t.int(u16, 4) };
        const second: Values = .{ .format = try t.int(u16, 6) };

        switch (try t.int(u16, 0)) {
            // Format 1: for each first glyph, the second glyphs it pairs
            // with, sorted, each followed by its two value records.
            1 => {
                if (covered >= try t.int(u16, 8)) return null;
                const set = try t.from(try t.int(u16, 10 + @as(usize, covered) * 2));
                const record = 2 + first.size() + second.size();
                var low: usize = 0;
                var high: usize = try set.int(u16, 0);
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const at = 2 + middle * record;
                    const glyph = try set.int(u16, at);
                    if (glyph < right) {
                        low = middle + 1;
                    } else if (glyph > right) {
                        high = middle;
                    } else return try first.advance(set, at + 2);
                }
                return null;
            },
            // Format 2: a class for each glyph on either side, and a grid of
            // value records with a row per left class and a column per right
            // one. A glyph its class table does not name is in class zero,
            // and class zero has a row and a column like any other - so once
            // the left glyph is covered, every pair has an answer, which is
            // what makes this the fallback a list of exceptions sits in
            // front of.
            2 => {
                const left_class = try (try ClassDef.at(t, try t.int(u16, 8))).class(left);
                const right_class = try (try ClassDef.at(t, try t.int(u16, 10))).class(right);
                const rows = try t.int(u16, 12);
                const columns = try t.int(u16, 14);
                if (left_class >= rows or right_class >= columns) return null;
                const cell = @as(usize, left_class) * columns + right_class;
                return try first.advance(t, 16 + cell * (first.size() + second.size()));
            },
            else => return null,
        }
    }
};

/// What a value record holds, which its format says one bit a field.
///
/// A record is up to eight sixteen-bit fields, in a fixed order, of which
/// only the ones whose bit is set are present - so where any one field is,
/// and how long the record is, are both counts of bits. Getting the length
/// wrong is the mistake that matters: in a list of pairs it puts every record
/// after the first at the wrong place, and the kerning comes out plausible
/// and wrong.
const Values = struct {
    format: u16,

    const x_placement: u16 = 0x0001;
    const y_placement: u16 = 0x0002;
    const x_advance: u16 = 0x0004;

    /// Two bytes for each bit. The top eight bits are reserved and should be
    /// zero; one that is set is counted as a field anyway, as HarfBuzz
    /// counts it, so a record is the length here that Chrome and Firefox
    /// read it at.
    fn size(self: Values) usize {
        return @as(usize, @popCount(self.format)) * 2;
    }

    /// The horizontal advance in the record at `at`, or zero if the record
    /// has none. It comes after the two placements, each of which may or may
    /// not be there.
    fn advance(self: Values, view: View, at: usize) Error!i16 {
        if (self.format & x_advance == 0) return 0;
        const before = @popCount(self.format & (x_placement | y_placement));
        return view.int(i16, at + @as(usize, before) * 2);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// The fixtures are written as sixteen-bit words, so the byte offset of any
// field is twice its place in the list - which is what the comments count in.

/// Words to bytes, big-endian. A negative number is its two's complement.
fn bytesOf(gpa: std.mem.Allocator, words: []const i32) ![]u8 {
    const out = try gpa.alloc(u8, words.len * 2);
    for (words, 0..) |word, k| {
        std.mem.writeInt(u16, out[k * 2 ..][0..2], @truncate(@as(u32, @bitCast(word))), .big);
    }
    return out;
}

/// A tag as the two words it is in the file.
fn tagWords(comptime name: *const [4]u8) [2]i32 {
    const value = sfnt.tag(name);
    return .{ @intCast(value >> 16), @intCast(value & 0xFFFF) };
}

/// A lookup of `kind`, its subtables laid out one after another after the
/// offsets to them. For an extension, each subtable is wrapped in the eight
/// bytes that point at it, which say it is a `wrapped_kind`.
fn testLookup(gpa: std.mem.Allocator, kind: u16, wrapped_kind: u16, subtables: []const []const i32) ![]i32 {
    var out: std.ArrayList(i32) = .empty;
    try out.appendSlice(gpa, &.{ kind, 0, @intCast(subtables.len) });
    const wrapper: usize = if (kind == Kerning.extension) 4 else 0;
    var at: usize = 6 + subtables.len * 2;
    for (subtables) |subtable| {
        try out.append(gpa, @intCast(at));
        at += (wrapper + subtable.len) * 2;
    }
    for (subtables) |subtable| {
        if (kind == Kerning.extension) try out.appendSlice(gpa, &.{ 1, wrapped_kind, 0, 8 });
        try out.appendSlice(gpa, subtable);
    }
    return out.toOwnedSlice(gpa);
}

/// A `GPOS` whose one script, `DFLT`, names one feature, `feature`, which
/// names each of `lookups` in turn.
fn testTable(gpa: std.mem.Allocator, comptime feature: *const [4]u8, lookups: []const []const i32) ![]u8 {
    var words: std.ArrayList(i32) = .empty;
    const n: i32 = @intCast(lookups.len);
    const lookup_list = 42 + 2 * n;
    // Header: version 1.0, then the three lists.
    try words.appendSlice(gpa, &.{ 1, 0, 10, 30, lookup_list });
    // Script list at 10: DFLT, its script at +8.
    const script = tagWords("DFLT");
    try words.appendSlice(gpa, &.{ 1, script[0], script[1], 8 });
    // Script at 18: a default language system at +4, no others.
    try words.appendSlice(gpa, &.{ 4, 0 });
    // Language system at 22: no required feature, feature 0.
    try words.appendSlice(gpa, &.{ 0, 0xFFFF, 1, 0 });
    // Feature list at 30: one feature, its table at +8.
    const name = tagWords(feature);
    try words.appendSlice(gpa, &.{ 1, name[0], name[1], 8 });
    // Feature at 38: every lookup, in order.
    try words.appendSlice(gpa, &.{ 0, n });
    for (0..lookups.len) |k| try words.append(gpa, @intCast(k));
    // Lookup list: the offsets, then the lookups.
    try words.append(gpa, n);
    var at: usize = 2 + lookups.len * 2;
    for (lookups) |lookup| {
        try words.append(gpa, @intCast(at));
        at += lookup.len * 2;
    }
    for (lookups) |lookup| try words.appendSlice(gpa, lookup);
    return bytesOf(gpa, words.items);
}

/// Format 1, with value records long enough that a wrong record length would
/// read the wrong number: the first glyph's records are an X and a Y
/// placement before the advance, the second's an advance and a device table
/// offset. Glyph 10 pairs with 11, 12 and 15; glyph 20 with 11.
const listed = [_]i32{
    1, 14, 0x0007, 0x0044, 2, 22, 60, // format, coverage, formats, two sets
    1, 2, 10, 20, // coverage at 14
    3, // set for glyph 10, at 22: three records of six words
    11, 5, 6, -40, 7, 0, // glyph 11: placed 5, 6, advance -40; then 7, no device
    12, 0, 0, -50, 0, 0, // glyph 12: advance -50
    15, 9, 9, -60, 9, 0, // glyph 15: advance -60
    1, // set for glyph 20, at 60
    11, 0, 0, 30, 0, 0, // glyph 11: advance 30
};

/// Format 2: glyphs 30 and 31 are left class 1 and glyph 32 class 2; glyphs
/// 40 and 41 are right class 1 and 50 class 2. Glyphs 30 to 32 are covered,
/// as one range.
const classed = [_]i32{
    2, 34, 0x0004, 0, 44, 56, 3, 3, // format, coverage, formats, classes, counts
    0, 0, 0, // left class 0, at 16
    0, -70, -80, // left class 1
    0, -90, 15, // left class 2
    2, 1, 30, 32, 0, // coverage at 34: one range
    1, 30, 3, 1, 1, 2, // left classes at 44: from glyph 30
    2, 2, 40, 41, 1, 50, 50, 2, // right classes at 56: two ranges
};

test "a pair is found in its list, past the fields its format says to skip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const lookup = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{&listed});
    const kerning = Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{lookup}) }).?;
    try testing.expectEqual(@as(u8, 1), kerning.len);

    try testing.expectEqual(@as(i16, -40), kerning.kern(10, 11));
    try testing.expectEqual(@as(i16, -50), kerning.kern(10, 12));
    // The last record of the set: three records in, so only reached at the
    // right place if the record length was counted right.
    try testing.expectEqual(@as(i16, -60), kerning.kern(10, 15));
    try testing.expectEqual(@as(i16, 30), kerning.kern(20, 11));

    // A second glyph the set does not list, and a first glyph the coverage
    // does not, are not kerned.
    try testing.expectEqual(@as(i16, 0), kerning.kern(10, 13));
    try testing.expectEqual(@as(i16, 0), kerning.kern(11, 10));
}

test "a class pair is the value where the two classes cross" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const lookup = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{&classed});
    const kerning = Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{lookup}) }).?;

    try testing.expectEqual(@as(i16, -70), kerning.kern(30, 40));
    try testing.expectEqual(@as(i16, -80), kerning.kern(31, 50));
    try testing.expectEqual(@as(i16, -90), kerning.kern(32, 41));
    try testing.expectEqual(@as(i16, 15), kerning.kern(32, 50));
    // A right glyph in no class is in class zero, whose column is zeros.
    try testing.expectEqual(@as(i16, 0), kerning.kern(30, 45));
    // A left glyph the coverage does not have is not asked about at all.
    try testing.expectEqual(@as(i16, 0), kerning.kern(33, 40));
}

test "in a lookup the first subtable with the pair answers, and lookups add up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Exceptions for glyph 30, before the class grid that also covers it.
    const exceptions = [_]i32{
        1, 12, 0x0004, 0, 1, 18, // format, coverage, formats, one set
        1, 1, 30, // coverage at 12
        2, 40, -5, 41, 0, // set at 18: 30 then 40 is -5, 30 then 41 is nothing
    };
    // A second lookup that moves 30 then 50 by another -3.
    const more = [_]i32{
        1, 12, 0x0004, 0, 1, 18, // format, coverage, formats, one set
        1, 1, 30, // coverage at 12
        1, 50, -3, // set at 18
    };
    const first = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{ &exceptions, &classed });
    const second = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{&more});
    const kerning = Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{ first, second }) }).?;
    try testing.expectEqual(@as(u8, 3), kerning.len);

    // The exception wins over the class value, -70.
    try testing.expectEqual(@as(i16, -5), kerning.kern(30, 40));
    // And an exception of zero is still an answer: the grid is not asked.
    try testing.expectEqual(@as(i16, 0), kerning.kern(30, 41));
    // A pair the exceptions do not list falls through to its classes.
    try testing.expectEqual(@as(i16, -90), kerning.kern(32, 41));
    // The second lookup adds to whatever the first said.
    try testing.expectEqual(@as(i16, -83), kerning.kern(30, 50));
}

test "an extension is followed to the pair adjustment inside it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const lookup = try testLookup(gpa, Kerning.extension, Kerning.pair_adjustment, &.{ &listed, &classed });
    const kerning = Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{lookup}) }).?;
    try testing.expectEqual(@as(u8, 2), kerning.len);

    // The same answers as unwrapped: the offsets in a subtable count from
    // the subtable, not from the extension that points at it.
    try testing.expectEqual(@as(i16, -60), kerning.kern(10, 15));
    try testing.expectEqual(@as(i16, -80), kerning.kern(31, 50));

    // An extension around anything but a pair adjustment is not one.
    const other = try testLookup(gpa, Kerning.extension, 4, &.{&listed});
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{other}) }));
}

test "only the lookups the kern feature names are kerning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A pair adjustment under some other feature is positioning, but not
    // this kind.
    const lookup = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{&listed});
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = try testTable(gpa, "cpsp", &.{lookup}) }));

    // And a kern feature with nothing this reads under it is no kerning,
    // which is what lets `Font` fall back to a `kern` table.
    const marks = try testLookup(gpa, 4, 0, &.{&listed});
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = try testTable(gpa, "kern", &.{marks}) }));
}

test "a broken GPOS is no kerning, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const lookup = try testLookup(gpa, Kerning.pair_adjustment, 0, &.{&listed});
    const whole = try testTable(gpa, "kern", &.{lookup});

    // Cut off inside the lookup's header, or before the lists, the table
    // cannot be walked when it opens, and there is nothing to kern with.
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = whole[0..50] }));
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = whole[0..3] }));

    // Cut off inside the pair set, the table opens and the pairs past the
    // cut cannot be read. Those pairs are not kerned; `find` says why.
    const kerning = Kerning.parse(.{ .bytes = whole[0 .. whole.len - 30] }).?;
    try testing.expectEqual(@as(i16, -40), kerning.kern(10, 11));
    try testing.expectEqual(@as(i16, 0), kerning.kern(20, 11));
    try testing.expectError(error.OutOfBounds, kerning.find(20, 11));

    // An extension pointing four gigabytes away is caught, not added.
    const far = try testLookup(gpa, Kerning.extension, Kerning.pair_adjustment, &.{&listed});
    const bytes = try testTable(gpa, "kern", &.{far});
    // The lookup list is at 44, its one lookup 4 bytes into it, and that
    // lookup's one subtable - the extension's eight bytes - 8 into that.
    const wrapper = 44 + 4 + 8;
    std.mem.writeInt(u32, bytes[wrapper + 4 ..][0..4], 0xFFFF_FFF0, .big);
    try testing.expectEqual(@as(?Kerning, null), Kerning.parse(.{ .bytes = bytes }));
}

test "a value record's length is two bytes a bit, and the advance follows the placements" {
    try testing.expectEqual(@as(usize, 0), (Values{ .format = 0 }).size());
    try testing.expectEqual(@as(usize, 2), (Values{ .format = 0x0004 }).size());
    try testing.expectEqual(@as(usize, 16), (Values{ .format = 0x00FF }).size());

    const record: View = .{ .bytes = &.{ 0, 1, 0, 2, 0xFF, 0x9C } };
    try testing.expectEqual(@as(i16, -100), try (Values{ .format = 0x0007 }).advance(record, 0));
    try testing.expectEqual(@as(i16, 2), try (Values{ .format = 0x0005 }).advance(record, 0));
    // No advance in the record is no kerning from it, not a read.
    try testing.expectEqual(@as(i16, 0), try (Values{ .format = 0x0003 }).advance(.empty, 0));
}
