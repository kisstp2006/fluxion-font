// SPDX-License-Identifier: BSD-2-Clause

//! `GSUB`: the rules that turn a run of glyphs into other glyphs.
//!
//! Read here for one job, and it is the job an emoji font gives it: a family
//! is a man, a joiner, a woman, a joiner and a girl, five characters drawn as
//! one picture; a flag is two regional letters drawn as one; a thumb with a
//! skin tone after it is a different thumb. The font says all of that in its
//! `ccmp` feature, as substitutions - and without them every emoji sequence
//! falls apart into its pieces.
//!
//! What is read: single, multiple and ligature substitution, the three forms
//! of contextual and of chained contextual substitution, and the extension
//! wrapper any of them can sit in. Alternates and the reverse chain are not
//! applied, and a lookup's flags - which glyphs it steps over - are not read,
//! because no emoji font sets them. This is not a shaping engine for Arabic or
//! Devanagari; it is enough to put an emoji sequence back together.

const std = @import("std");
const testing = std.testing;

const layout = @import("layout.zig");
const sfnt = @import("sfnt.zig");

const Coverage = layout.Coverage;
const ClassDef = layout.ClassDef;
const Error = sfnt.Error;
const File = sfnt.File;
const View = sfnt.View;

/// A short run of glyphs, being substituted in place. Short because what is
/// substituted is one cluster - an emoji sequence - and never a paragraph.
pub const Glyphs = struct {
    items: [capacity]u16 = undefined,
    len: usize = 0,

    pub const capacity = 64;

    pub fn slice(self: *const Glyphs) []const u16 {
        return self.items[0..self.len];
    }

    /// Add one at the end. False when there is no room, and nothing changes.
    pub fn append(self: *Glyphs, glyph: u16) bool {
        if (self.len == capacity) return false;
        self.items[self.len] = glyph;
        self.len += 1;
        return true;
    }

    /// `count` glyphs from `at` become `with`. False when the result would
    /// not fit, and nothing changes.
    fn replace(self: *Glyphs, at: usize, count: usize, with: []const u16) bool {
        const after = self.len - count + with.len;
        if (after > capacity) return false;
        const tail = self.items[at + count .. self.len];
        if (with.len > count) {
            std.mem.copyBackwards(u16, self.items[at + with.len .. after], tail);
        } else {
            std.mem.copyForwards(u16, self.items[at + with.len .. after], tail);
        }
        @memcpy(self.items[at..][0..with.len], with);
        self.len = after;
        return true;
    }
};

/// How deep a contextual rule may call into other lookups. A font whose rules
/// call each other in a circle stops here rather than running forever.
const max_depth = 8;

pub const Gsub = struct {
    table: View,

    pub fn read(file: File) Error!?Gsub {
        const table = try file.table(@enumFromInt(sfnt.tag("GSUB"))) orelse return null;
        if (try table.int(u16, 0) != 1) return null;
        return .{ .table = table };
    }

    /// Apply every lookup that `features` name, for the font's default
    /// script, in the order the font lists its lookups - which is the order
    /// the specification says they run in, whatever order the features came.
    pub fn apply(self: Gsub, glyphs: *Glyphs, features: []const u32) Error!void {
        var wanted: [256]u16 = undefined;
        const lookups = try self.lookupsFor(features, &wanted);
        for (lookups) |index| try self.applyLookup(index, glyphs, 0);
    }

    /// The lookups the features name, sorted, each once.
    fn lookupsFor(self: Gsub, features: []const u32, out: *[256]u16) Error![]const u16 {
        const t = self.table;
        const scripts = try t.from(try t.int(u16, 4));
        const feature_list = try t.from(try t.int(u16, 6));

        const lang_sys = try defaultLanguage(scripts) orelse return out[0..0];
        var count: usize = 0;

        const add = struct {
            fn feature(list: View, index: u16, wanted: []const u32, lookups: *[256]u16, n: *usize) Error!void {
                const records = try list.int(u16, 0);
                if (index >= records) return;
                const record = 2 + @as(usize, index) * 6;
                const tag = try list.int(u32, record);
                if (std.mem.indexOfScalar(u32, wanted, tag) == null) return;
                const table = try list.from(try list.int(u16, record + 4));
                const indices = try table.int(u16, 2);
                for (0..indices) |k| {
                    if (n.* == lookups.len) return;
                    lookups[n.*] = try table.int(u16, 4 + k * 2);
                    n.* += 1;
                }
            }
        };

        const required = try lang_sys.int(u16, 2);
        if (required != 0xFFFF) try add.feature(feature_list, required, features, out, &count);
        const feature_count = try lang_sys.int(u16, 4);
        for (0..feature_count) |k| {
            try add.feature(feature_list, try lang_sys.int(u16, 6 + k * 2), features, out, &count);
        }

        const found = out[0..count];
        std.mem.sort(u16, found, {}, std.sort.asc(u16));
        // Two features naming one lookup run it once.
        var unique: usize = 0;
        for (found, 0..) |index, k| {
            if (k > 0 and index == found[k - 1]) continue;
            found[unique] = index;
            unique += 1;
        }
        return found[0..unique];
    }

    /// The language system to use: the default one of `DFLT`, else of the
    /// first script there is. An emoji is not in any script, and an emoji
    /// font puts its rules under `DFLT`.
    fn defaultLanguage(scripts: View) Error!?View {
        const count = try scripts.int(u16, 0);
        if (count == 0) return null;
        var chosen: usize = 0;
        for (0..count) |k| {
            if (try scripts.int(u32, 2 + k * 6) == sfnt.tag("DFLT")) {
                chosen = k;
                break;
            }
        }
        const script = try scripts.from(try scripts.int(u16, 2 + chosen * 6 + 4));
        const default = try script.int(u16, 0);
        if (default != 0) return try script.from(default);
        // No default: the first language the script has.
        if (try script.int(u16, 2) == 0) return null;
        return try script.from(try script.int(u16, 4 + 4));
    }

    fn lookup(self: Gsub, index: u16) Error!?View {
        const list = try self.table.from(try self.table.int(u16, 8));
        if (index >= try list.int(u16, 0)) return null;
        return try list.from(try list.int(u16, 2 + @as(usize, index) * 2));
    }

    /// One lookup, over the whole run.
    fn applyLookup(self: Gsub, index: u16, glyphs: *Glyphs, depth: u8) Error!void {
        var at: usize = 0;
        while (at < glyphs.len) {
            at = try self.applyAt(index, glyphs, at, depth) orelse at + 1;
        }
    }

    /// One lookup at one place. Where to carry on from when one of its
    /// subtables applied, and null when none did.
    fn applyAt(self: Gsub, index: u16, glyphs: *Glyphs, at: usize, depth: u8) Error!?usize {
        const table = try self.lookup(index) orelse return null;
        const kind = try table.int(u16, 0);
        const subtables = try table.int(u16, 4);
        for (0..subtables) |k| {
            var subtable = try table.from(try table.int(u16, 6 + k * 2));
            var subtable_kind = kind;
            if (kind == 7) {
                subtable_kind = try subtable.int(u16, 2);
                subtable = try subtable.from(try subtable.int(u32, 4));
            }
            if (try self.applySubtable(subtable_kind, subtable, glyphs, at, depth)) |next| return next;
        }
        return null;
    }

    fn applySubtable(self: Gsub, kind: u16, t: View, glyphs: *Glyphs, at: usize, depth: u8) Error!?usize {
        const glyph = glyphs.items[at];
        const format = try t.int(u16, 0);
        switch (kind) {
            1 => {
                const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(glyph) orelse return null;
                glyphs.items[at] = switch (format) {
                    1 => @bitCast(@as(i16, @bitCast(glyph)) +% try t.int(i16, 4)),
                    2 => if (covered < try t.int(u16, 4)) try t.int(u16, 6 + @as(usize, covered) * 2) else return null,
                    else => return null,
                };
                return at + 1;
            },
            2 => {
                if (format != 1) return null;
                const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(glyph) orelse return null;
                if (covered >= try t.int(u16, 4)) return null;
                const sequence = try t.from(try t.int(u16, 6 + @as(usize, covered) * 2));
                const count = try sequence.int(u16, 0);
                var with: [Glyphs.capacity]u16 = undefined;
                if (count > with.len) return null;
                for (0..count) |k| with[k] = try sequence.int(u16, 2 + k * 2);
                if (!glyphs.replace(at, 1, with[0..count])) return null;
                return at + count;
            },
            4 => {
                if (format != 1) return null;
                const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(glyph) orelse return null;
                if (covered >= try t.int(u16, 4)) return null;
                const set = try t.from(try t.int(u16, 6 + @as(usize, covered) * 2));
                const ligatures = try set.int(u16, 0);
                for (0..ligatures) |k| {
                    const ligature = try set.from(try set.int(u16, 2 + k * 2));
                    const components = try ligature.int(u16, 2);
                    if (components == 0 or at + components > glyphs.len) continue;
                    const matched = for (1..components) |c| {
                        if (glyphs.items[at + c] != try ligature.int(u16, 4 + (c - 1) * 2)) break false;
                    } else true;
                    if (!matched) continue;
                    _ = glyphs.replace(at, components, &.{try ligature.int(u16, 0)});
                    return at + 1;
                }
                return null;
            },
            5 => return self.context(t, format, glyphs, at, depth),
            6 => return self.chained(t, format, glyphs, at, depth),
            else => return null,
        }
    }

    /// Contextual substitution: a sequence of glyphs, matched by glyph, by
    /// class or by coverage, and lookups to run at places inside it.
    fn context(self: Gsub, t: View, format: u16, glyphs: *Glyphs, at: usize, depth: u8) Error!?usize {
        const glyph = glyphs.items[at];
        switch (format) {
            1, 2 => {
                const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(glyph) orelse return null;
                const classes: ?ClassDef = if (format == 2) try ClassDef.at(t, try t.int(u16, 4)) else null;
                const sets_at: usize = if (format == 2) 6 else 4;
                const set_index: u16 = if (classes) |c| try c.class(glyph) else covered;
                if (set_index >= try t.int(u16, sets_at)) return null;
                const set_offset = try t.int(u16, sets_at + 2 + @as(usize, set_index) * 2);
                if (set_offset == 0) return null;
                const set = try t.from(set_offset);
                for (0..try set.int(u16, 0)) |k| {
                    const rule = try set.from(try set.int(u16, 2 + k * 2));
                    const count = try rule.int(u16, 0);
                    const records = try rule.int(u16, 2);
                    const input: Sequence = .{ .values = try rule.from(4), .classes = classes };
                    if (!try input.matchesFrom(glyphs, at + 1, count -| 1)) continue;
                    const lookups = try rule.from(4 + (@as(usize, count) -| 1) * 2);
                    return try self.runRecords(lookups, records, glyphs, at, count, depth);
                }
                return null;
            },
            3 => {
                const count = try t.int(u16, 2);
                const records = try t.int(u16, 4);
                const input: Sequence = .{ .values = try t.from(6), .coverages = t };
                if (!try input.matchesFrom(glyphs, at, count)) return null;
                return try self.runRecords(try t.from(6 + @as(usize, count) * 2), records, glyphs, at, count, depth);
            },
            else => return null,
        }
    }

    /// Chained contextual substitution: the same, with glyphs that must come
    /// before and after the sequence without being part of it.
    fn chained(self: Gsub, t: View, format: u16, glyphs: *Glyphs, at: usize, depth: u8) Error!?usize {
        const glyph = glyphs.items[at];
        switch (format) {
            1, 2 => {
                const covered = try (try Coverage.at(t, try t.int(u16, 2))).index(glyph) orelse return null;
                var backtrack_classes: ?ClassDef = null;
                var input_classes: ?ClassDef = null;
                var lookahead_classes: ?ClassDef = null;
                var sets_at: usize = 4;
                var set_index: u16 = covered;
                if (format == 2) {
                    backtrack_classes = try ClassDef.at(t, try t.int(u16, 4));
                    input_classes = try ClassDef.at(t, try t.int(u16, 6));
                    lookahead_classes = try ClassDef.at(t, try t.int(u16, 8));
                    sets_at = 10;
                    set_index = try input_classes.?.class(glyph);
                }
                if (set_index >= try t.int(u16, sets_at)) return null;
                const set_offset = try t.int(u16, sets_at + 2 + @as(usize, set_index) * 2);
                if (set_offset == 0) return null;
                const set = try t.from(set_offset);
                for (0..try set.int(u16, 0)) |k| {
                    const rule = try set.from(try set.int(u16, 2 + k * 2));
                    var cursor: usize = 0;
                    const back_count = try rule.int(u16, cursor);
                    const backtrack: Sequence = .{ .values = try rule.from(cursor + 2), .classes = backtrack_classes };
                    cursor += 2 + @as(usize, back_count) * 2;
                    const input_count = try rule.int(u16, cursor);
                    const input: Sequence = .{ .values = try rule.from(cursor + 2), .classes = input_classes };
                    cursor += 2 + (@as(usize, input_count) -| 1) * 2;
                    const ahead_count = try rule.int(u16, cursor);
                    const lookahead: Sequence = .{ .values = try rule.from(cursor + 2), .classes = lookahead_classes };
                    cursor += 2 + @as(usize, ahead_count) * 2;
                    const records = try rule.int(u16, cursor);

                    if (!try backtrack.matchesBefore(glyphs, at, back_count)) continue;
                    if (!try input.matchesFrom(glyphs, at + 1, input_count -| 1)) continue;
                    if (!try lookahead.matchesFrom(glyphs, at + @max(input_count, 1), ahead_count)) continue;
                    return try self.runRecords(try rule.from(cursor + 2), records, glyphs, at, input_count, depth);
                }
                return null;
            },
            3 => {
                var cursor: usize = 2;
                const back_count = try t.int(u16, cursor);
                const backtrack: Sequence = .{ .values = try t.from(cursor + 2), .coverages = t };
                cursor += 2 + @as(usize, back_count) * 2;
                const input_count = try t.int(u16, cursor);
                const input: Sequence = .{ .values = try t.from(cursor + 2), .coverages = t };
                cursor += 2 + @as(usize, input_count) * 2;
                const ahead_count = try t.int(u16, cursor);
                const lookahead: Sequence = .{ .values = try t.from(cursor + 2), .coverages = t };
                cursor += 2 + @as(usize, ahead_count) * 2;
                const records = try t.int(u16, cursor);

                if (input_count == 0) return null;
                if (!try backtrack.matchesBefore(glyphs, at, back_count)) return null;
                if (!try input.matchesFrom(glyphs, at, input_count)) return null;
                if (!try lookahead.matchesFrom(glyphs, at + input_count, ahead_count)) return null;
                return try self.runRecords(try t.from(cursor + 2), records, glyphs, at, input_count, depth);
            },
            else => return null,
        }
    }

    /// Run a matched rule's lookups at the places in the sequence they name,
    /// and say where the sequence ends now. A lookup that changes the length
    /// - a ligature, a multiple substitution - moves every place after it.
    fn runRecords(self: Gsub, records: View, count: u16, glyphs: *Glyphs, at: usize, length: u16, depth: u8) Error!usize {
        var places: [Glyphs.capacity]usize = undefined;
        const span = @min(@as(usize, @max(length, 1)), places.len);
        for (0..span) |k| places[k] = at + k;
        var end = at + span;
        if (depth >= max_depth) return end;

        for (0..count) |k| {
            const sequence_index = try records.int(u16, k * 4);
            const lookup_index = try records.int(u16, k * 4 + 2);
            if (sequence_index >= span) continue;
            const place = places[sequence_index];
            if (place >= glyphs.len) continue;
            const before = glyphs.len;
            _ = try self.applyAt(lookup_index, glyphs, place, depth + 1);
            if (glyphs.len == before) continue;
            const grew = @as(isize, @intCast(glyphs.len)) - @as(isize, @intCast(before));
            for (places[0..span]) |*p| {
                if (p.* > place) p.* = @intCast(@max(@as(isize, @intCast(place)), @as(isize, @intCast(p.*)) + grew));
            }
            end = @intCast(@max(@as(isize, @intCast(place + 1)), @as(isize, @intCast(end)) + grew));
        }
        return @min(end, glyphs.len);
    }
};

/// The glyphs a rule wants, one entry each, as a list of glyph numbers, of
/// classes or of coverage offsets.
const Sequence = struct {
    values: View,
    classes: ?ClassDef = null,
    /// What coverage offsets count from, when the entries are coverages.
    coverages: ?View = null,

    fn matches(self: Sequence, k: usize, glyph: u16) Error!bool {
        const value = try self.values.int(u16, k * 2);
        if (self.coverages) |base| return try (try Coverage.at(base, value)).index(glyph) != null;
        if (self.classes) |classes| return try classes.class(glyph) == value;
        return glyph == value;
    }

    /// The `count` entries against the glyphs from `from` on.
    fn matchesFrom(self: Sequence, glyphs: *const Glyphs, from: usize, count: usize) Error!bool {
        if (from + count > glyphs.len) return false;
        for (0..count) |k| {
            if (!try self.matches(k, glyphs.items[from + k])) return false;
        }
        return true;
    }

    /// The `count` entries against the glyphs before `at`, nearest first -
    /// which is the order a backtrack is written in.
    fn matchesBefore(self: Sequence, glyphs: *const Glyphs, at: usize, count: usize) Error!bool {
        if (count > at) return false;
        for (0..count) |k| {
            if (!try self.matches(k, glyphs.items[at - 1 - k])) return false;
        }
        return true;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn put(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .big);
}

/// A `GSUB` with one feature, `ccmp`, and one lookup: whatever `lookup` is,
/// at offset 48. Laid out by hand so every offset is known.
fn testTable(lookup: []const u8, buffer: []u8) []u8 {
    @memset(buffer, 0);
    put(buffer, 0, 1);
    put(buffer, 4, 10); // script list
    put(buffer, 6, 30); // feature list
    put(buffer, 8, 44); // lookup list
    // Script list: DFLT, its default language naming feature 0.
    put(buffer, 10, 1);
    @memcpy(buffer[12..16], "DFLT");
    put(buffer, 16, 8);
    put(buffer, 18, 4);
    put(buffer, 22, 0);
    put(buffer, 24, 0xFFFF);
    put(buffer, 26, 1);
    put(buffer, 28, 0);
    // Feature list: ccmp, lookup 0.
    put(buffer, 30, 1);
    @memcpy(buffer[32..36], "ccmp");
    put(buffer, 36, 8);
    put(buffer, 40, 1);
    put(buffer, 42, 0);
    // Lookup list: one, at 48.
    put(buffer, 44, 1);
    put(buffer, 46, 4);
    @memcpy(buffer[48..][0..lookup.len], lookup);
    return buffer[0 .. 48 + lookup.len];
}

const ccmp = [_]u32{sfnt.tag("ccmp")};

test "a ligature turns a sequence into one glyph and leaves the rest" {
    // Lookup type 4: glyph 10 then 11, 12 is glyph 99.
    var lookup: [34]u8 = @splat(0);
    put(&lookup, 0, 4);
    put(&lookup, 4, 1);
    put(&lookup, 6, 8);
    // Subtable at 8: format 1, coverage at +8, one set at +14.
    put(&lookup, 8, 1);
    put(&lookup, 10, 8);
    put(&lookup, 12, 1);
    put(&lookup, 14, 14);
    // Coverage at 16: glyph 10.
    put(&lookup, 16, 1);
    put(&lookup, 18, 1);
    put(&lookup, 20, 10);
    // Set at 22: one ligature at +4.
    put(&lookup, 22, 1);
    put(&lookup, 24, 4);
    // Ligature at 26: 99 from three components.
    put(&lookup, 26, 99);
    put(&lookup, 28, 3);
    put(&lookup, 30, 11);
    put(&lookup, 32, 12);

    var buffer: [128]u8 = undefined;
    const gsub: Gsub = .{ .table = .{ .bytes = testTable(&lookup, &buffer) } };

    var glyphs: Glyphs = .{};
    for ([_]u16{ 10, 11, 12, 13 }) |g| _ = glyphs.append(g);
    try gsub.apply(&glyphs, &ccmp);
    try testing.expectEqualSlices(u16, &.{ 99, 13 }, glyphs.slice());

    // Half the sequence is not the ligature.
    var half: Glyphs = .{};
    for ([_]u16{ 10, 11, 13 }) |g| _ = half.append(g);
    try gsub.apply(&half, &ccmp);
    try testing.expectEqualSlices(u16, &.{ 10, 11, 13 }, half.slice());

    // And a feature that was not asked for is not applied.
    try gsub.apply(&glyphs, &.{sfnt.tag("liga")});
}

test "a multiple substitution makes room, and a single one swaps in place" {
    // Lookup type 2: glyph 5 becomes 6, 7, 8.
    var lookup: [30]u8 = @splat(0);
    put(&lookup, 0, 2);
    put(&lookup, 4, 1);
    put(&lookup, 6, 8);
    put(&lookup, 8, 1);
    put(&lookup, 10, 8); // coverage at 16
    put(&lookup, 12, 1);
    put(&lookup, 14, 14); // sequence at 22
    put(&lookup, 16, 1);
    put(&lookup, 18, 1);
    put(&lookup, 20, 5);
    put(&lookup, 22, 3);
    put(&lookup, 24, 6);
    put(&lookup, 26, 7);
    put(&lookup, 28, 8);

    var buffer: [128]u8 = undefined;
    const gsub: Gsub = .{ .table = .{ .bytes = testTable(&lookup, &buffer) } };
    var glyphs: Glyphs = .{};
    for ([_]u16{ 1, 5, 2 }) |g| _ = glyphs.append(g);
    try gsub.apply(&glyphs, &ccmp);
    try testing.expectEqualSlices(u16, &.{ 1, 6, 7, 8, 2 }, glyphs.slice());
}

test "a run too long to grow is left as it was" {
    var glyphs: Glyphs = .{};
    while (glyphs.append(1)) {}
    try testing.expect(!glyphs.replace(0, 1, &.{ 2, 3 }));
    try testing.expectEqual(Glyphs.capacity, glyphs.len);
    try testing.expect(glyphs.replace(0, 2, &.{4}));
    try testing.expectEqual(@as(u16, 4), glyphs.items[0]);
    try testing.expectEqual(Glyphs.capacity - 1, glyphs.len);
}
