// SPDX-License-Identifier: BSD-2-Clause

//! `cmap`: which glyph draws which character.
//!
//! The one table where the format shows its age. A font carries several
//! character maps - one for Windows, one for the Macintosh, sometimes one for
//! a symbol encoding nobody has used since 1998 - and each is in one of
//! fourteen subtable formats, of which four are still met in the wild.
//!
//! `Cmap.parse` picks the best one and reads it. The preference order is the
//! one every text stack uses:
//!
//!   1. **(3, 10)** Windows, full Unicode. Format 12, and the only one that
//!      can name a codepoint above `U+FFFF` - so a font with emoji or rare
//!      CJK has one and text without them does not care.
//!   2. **(0, 4)** and **(0, 6)** Unicode, full range. The same thing under
//!      the platform-independent identifiers.
//!   3. **(3, 1)** Windows, the basic multilingual plane. Format 4, and what
//!      the overwhelming majority of text actually uses.
//!   4. **(0, 3)** Unicode BMP.
//!   5. **(3, 0)** Windows Symbol. Format 4 again, but the codepoints are
//!      hidden in the private use area at `U+F000`, and a font that has only
//!      this one is a dingbat font. See `symbol`.
//!
//! A codepoint the font has no glyph for answers **zero**, which is the
//! `.notdef` glyph - the empty box. That is not an error and must not be
//! treated as one: it is how a renderer knows to draw the box, or to go
//! looking in another font.

const std = @import("std");
const testing = std.testing;

const sfnt = @import("sfnt.zig");

const Error = sfnt.Error;
const File = sfnt.File;
const View = sfnt.View;

/// The glyph for a character that the font has not got. Always index zero,
/// in every font, by definition.
pub const notdef: u16 = 0;

/// A character map, already chosen out of the several a font carries.
pub const Cmap = struct {
    /// The chosen subtable, not the whole `cmap`.
    table: View,
    format: u16,
    /// Whether the codepoints in this table are shifted into the private use
    /// area. True only for a Windows Symbol map, where the font stores `A` at
    /// `U+F041`. `glyph` does the shifting, so a caller passes ordinary
    /// codepoints either way.
    symbol: bool,

    /// Read the character map out of a font, picking the best subtable.
    pub fn read(file: File) Error!Cmap {
        return parse(try file.required(.cmap));
    }

    /// The same, given the `cmap` table itself.
    pub fn parse(table: View) Error!Cmap {
        const count = try table.int(u16, 2);

        var best: ?struct { offset: u32, rank: u8, symbol: bool } = null;

        for (0..count) |i| {
            const at = 4 + i * 8;
            const platform = try table.int(u16, at);
            const encoding = try table.int(u16, at + 2);
            const offset = try table.int(u32, at + 4);

            // Lower is better. Anything not listed is not usable.
            const rank: u8, const is_symbol: bool = switch (platform) {
                0 => switch (encoding) {
                    4, 6 => .{ 1, false },
                    0, 1, 2, 3 => .{ 3, false },
                    else => continue,
                },
                3 => switch (encoding) {
                    10 => .{ 0, false },
                    1 => .{ 2, false },
                    0 => .{ 4, true },
                    else => continue,
                },
                else => continue,
            };

            if (best == null or rank < best.?.rank) {
                best = .{ .offset = offset, .rank = rank, .symbol = is_symbol };
            }
        }

        const chosen = best orelse return error.Malformed;
        const subtable = try table.from(chosen.offset);
        const format = try subtable.int(u16, 0);

        switch (format) {
            0, 4, 6, 12 => {},
            else => return error.Malformed,
        }

        return .{ .table = subtable, .format = format, .symbol = chosen.symbol };
    }

    /// The glyph index for a codepoint, or `notdef`.
    ///
    /// No error union, and that is deliberate. A character the font has no
    /// glyph for answers `notdef`, and so does a character map too malformed
    /// to answer at all - because the caller does the same thing either way:
    /// draws the empty box, or goes looking in another font. Making every
    /// lookup a `try` would put an error path in the middle of a text layout
    /// for a case that has a perfectly good answer.
    pub fn lookup(self: Cmap, codepoint: u21) u16 {
        return self.glyph(codepoint) catch notdef;
    }

    /// The same, reporting a malformed table rather than hiding it. For a
    /// tool that validates fonts; `lookup` is the one to draw with.
    pub fn glyph(self: Cmap, codepoint: u21) Error!u16 {
        const wanted: u32 = if (self.symbol and codepoint < 0x100)
            // A symbol font stores its glyphs at U+F000 upwards. Trying the
            // shifted codepoint first, and then the plain one, is what every
            // implementation does and what makes such a font usable at all.
            0xF000 + @as(u32, codepoint)
        else
            codepoint;

        const found = switch (self.format) {
            0 => try self.lookupByte(wanted),
            4 => try self.lookupSegmented(wanted),
            6 => try self.lookupTrimmed(wanted),
            12 => try self.lookupGroups(wanted),
            else => notdef,
        };

        if (found != notdef or !self.symbol or wanted == codepoint) return found;
        // The shifted lookup found nothing; the font may store it plainly.
        return switch (self.format) {
            0 => self.lookupByte(codepoint),
            4 => self.lookupSegmented(codepoint),
            6 => self.lookupTrimmed(codepoint),
            12 => self.lookupGroups(codepoint),
            else => notdef,
        };
    }

    /// Format 0: one byte in, one byte out. The original Macintosh map, and
    /// still met on old symbol fonts.
    fn lookupByte(self: Cmap, codepoint: u32) Error!u16 {
        if (codepoint > 0xFF) return notdef;
        return try self.table.int(u8, 6 + codepoint);
    }

    /// Format 6: a run of consecutive codepoints, and a glyph for each.
    fn lookupTrimmed(self: Cmap, codepoint: u32) Error!u16 {
        const first = try self.table.int(u16, 6);
        const count = try self.table.int(u16, 8);
        if (codepoint < first or codepoint >= @as(u32, first) + count) return notdef;
        return self.table.int(u16, 10 + (codepoint - first) * 2);
    }

    /// Format 4: the basic multilingual plane, in segments.
    ///
    /// The format everything actually uses, and the one with the trap in it.
    /// Each segment either adds a constant to the codepoint or points into a
    /// shared array of glyph indices - and it points by *byte offset from the
    /// field itself*, which is a way of writing a pointer that made sense
    /// when the table was mapped into memory and read as a C struct. Getting
    /// that offset wrong gives plausible glyphs for the wrong characters,
    /// which is worse than a crash.
    fn lookupSegmented(self: Cmap, codepoint: u32) Error!u16 {
        if (codepoint > 0xFFFF) return notdef;
        const character: u16 = @intCast(codepoint);

        const segments = try self.table.int(u16, 6) / 2;
        if (segments == 0) return notdef;

        const ends_at: usize = 14;
        const starts_at: usize = ends_at + @as(usize, segments) * 2 + 2;
        const deltas_at: usize = starts_at + @as(usize, segments) * 2;
        const ranges_at: usize = deltas_at + @as(usize, segments) * 2;

        // The segments are sorted by end code, so the first one that reaches
        // this character is the one that owns it - if it owns it at all.
        var low: usize = 0;
        var high: usize = segments;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (try self.table.int(u16, ends_at + middle * 2) < character) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low >= segments) return notdef;

        const start = try self.table.int(u16, starts_at + low * 2);
        if (character < start) return notdef;

        const delta = try self.table.int(u16, deltas_at + low * 2);
        const range_offset_at = ranges_at + low * 2;
        const range_offset = try self.table.int(u16, range_offset_at);

        if (range_offset == 0) {
            // The simple case: the glyph is the character plus a constant,
            // wrapping at sixteen bits, which is why this is `+%`.
            return character +% delta;
        }

        // The awkward case. The offset is from the position of the field
        // itself, in bytes, and then two bytes per character into the
        // segment.
        const index_at = range_offset_at + range_offset + (character - start) * 2;
        const found = try self.table.int(u16, index_at);
        // Zero means "no glyph" here and must not have the delta added, or
        // every hole in the segment would name a real glyph.
        if (found == notdef) return notdef;
        return found +% delta;
    }

    /// Format 12: groups of consecutive codepoints, over the whole of
    /// Unicode. What a font with anything above `U+FFFF` in it uses.
    fn lookupGroups(self: Cmap, codepoint: u32) Error!u16 {
        const groups = try self.table.int(u32, 12);
        if (groups == 0) return notdef;

        var low: u32 = 0;
        var high: u32 = groups;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = 16 + @as(usize, middle) * 12;
            const first = try self.table.int(u32, at);
            const last = try self.table.int(u32, at + 4);

            if (codepoint < first) {
                high = middle;
            } else if (codepoint > last) {
                low = middle + 1;
            } else {
                const start_glyph = try self.table.int(u32, at + 8);
                const found = start_glyph + (codepoint - first);
                // A group whose arithmetic runs past the glyph count is a
                // broken font, and answering `notdef` is better than handing
                // back an index nothing can draw.
                return if (found > std.math.maxInt(u16)) notdef else @intCast(found);
            }
        }
        return notdef;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A `cmap` with one subtable in it, under one platform and encoding.
fn wrap(allocator: std.mem.Allocator, platform: u16, encoding: u16, subtable: []const u8) ![]u8 {
    const header = 12;
    const bytes = try allocator.alloc(u8, header + subtable.len);
    std.mem.writeInt(u16, bytes[0..2], 0, .big);
    std.mem.writeInt(u16, bytes[2..4], 1, .big);
    std.mem.writeInt(u16, bytes[4..6], platform, .big);
    std.mem.writeInt(u16, bytes[6..8], encoding, .big);
    std.mem.writeInt(u32, bytes[8..12], header, .big);
    @memcpy(bytes[header..], subtable);
    return bytes;
}

/// Format 4 with two segments and no glyph array: `A`..`C` and the terminator.
fn format4(allocator: std.mem.Allocator) ![]u8 {
    const segments: u16 = 2;
    const size = 16 + @as(usize, segments) * 8;
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 0);

    std.mem.writeInt(u16, bytes[0..2], 4, .big);
    std.mem.writeInt(u16, bytes[2..4], @intCast(size), .big);
    std.mem.writeInt(u16, bytes[6..8], segments * 2, .big);

    const ends = 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;

    // 'A'..'C' map to glyphs 10..12 by adding a constant.
    std.mem.writeInt(u16, bytes[ends..][0..2], 'C', .big);
    std.mem.writeInt(u16, bytes[starts..][0..2], 'A', .big);
    std.mem.writeInt(u16, bytes[deltas..][0..2], 10 -% @as(u16, 'A'), .big);

    // Every format 4 table ends with a segment for 0xFFFF.
    std.mem.writeInt(u16, bytes[ends + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, bytes[starts + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, bytes[deltas + 2 ..][0..2], 1, .big);

    return bytes;
}

test "format 4 maps a segment by adding a constant" {
    const subtable = try format4(testing.allocator);
    defer testing.allocator.free(subtable);
    const bytes = try wrap(testing.allocator, 3, 1, subtable);
    defer testing.allocator.free(bytes);

    const map = try Cmap.parse(.{ .bytes = bytes });
    try testing.expectEqual(4, map.format);
    try testing.expect(!map.symbol);

    try testing.expectEqual(10, try map.glyph('A'));
    try testing.expectEqual(11, try map.glyph('B'));
    try testing.expectEqual(12, try map.glyph('C'));

    // Outside the segment there is no glyph, and that is an answer rather
    // than an error - it is how a renderer knows to draw the empty box.
    try testing.expectEqual(notdef, try map.glyph('D'));
    try testing.expectEqual(notdef, try map.glyph(' '));
    try testing.expectEqual(notdef, try map.glyph(0x1F600));
}

test "format 4 with a range offset reads the shared glyph array" {
    // The awkward half of format 4: a segment that points into an array
    // instead of adding a constant, by a byte offset from the field itself.
    const segments: u16 = 2;
    const header = 16 + @as(usize, segments) * 8;
    const size = header + 3 * 2; // three glyphs in the shared array
    const subtable = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(subtable);
    @memset(subtable, 0);

    std.mem.writeInt(u16, subtable[0..2], 4, .big);
    std.mem.writeInt(u16, subtable[2..4], @intCast(size), .big);
    std.mem.writeInt(u16, subtable[6..8], segments * 2, .big);

    const ends = 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;
    const ranges = deltas + segments * 2;

    std.mem.writeInt(u16, subtable[ends..][0..2], 'C', .big);
    std.mem.writeInt(u16, subtable[starts..][0..2], 'A', .big);
    std.mem.writeInt(u16, subtable[deltas..][0..2], 0, .big);
    // From the field at `ranges`, the array starts at `header`.
    std.mem.writeInt(u16, subtable[ranges..][0..2], @intCast(header - ranges), .big);

    std.mem.writeInt(u16, subtable[ends + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, subtable[starts + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, subtable[deltas + 2 ..][0..2], 1, .big);

    std.mem.writeInt(u16, subtable[header..][0..2], 77, .big);
    std.mem.writeInt(u16, subtable[header + 2 ..][0..2], 0, .big); // a hole
    std.mem.writeInt(u16, subtable[header + 4 ..][0..2], 79, .big);

    const bytes = try wrap(testing.allocator, 3, 1, subtable);
    defer testing.allocator.free(bytes);
    const map = try Cmap.parse(.{ .bytes = bytes });

    try testing.expectEqual(77, try map.glyph('A'));
    // A zero in the array means no glyph, and must not have the delta added
    // to it - or every hole would name a real glyph.
    try testing.expectEqual(notdef, try map.glyph('B'));
    try testing.expectEqual(79, try map.glyph('C'));
}

test "format 12 reaches past the basic multilingual plane" {
    const groups: u32 = 2;
    const size = 16 + groups * 12;
    const subtable = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(subtable);
    @memset(subtable, 0);

    std.mem.writeInt(u16, subtable[0..2], 12, .big);
    std.mem.writeInt(u32, subtable[4..8], size, .big);
    std.mem.writeInt(u32, subtable[12..16], groups, .big);

    // 'a'..'z' at glyph 40, and an emoji block up at U+1F600.
    std.mem.writeInt(u32, subtable[16..20], 'a', .big);
    std.mem.writeInt(u32, subtable[20..24], 'z', .big);
    std.mem.writeInt(u32, subtable[24..28], 40, .big);

    std.mem.writeInt(u32, subtable[28..32], 0x1F600, .big);
    std.mem.writeInt(u32, subtable[32..36], 0x1F64F, .big);
    std.mem.writeInt(u32, subtable[36..40], 900, .big);

    const bytes = try wrap(testing.allocator, 3, 10, subtable);
    defer testing.allocator.free(bytes);
    const map = try Cmap.parse(.{ .bytes = bytes });

    try testing.expectEqual(12, map.format);
    try testing.expectEqual(40, try map.glyph('a'));
    try testing.expectEqual(41, try map.glyph('b'));
    try testing.expectEqual(65, try map.glyph('z'));
    try testing.expectEqual(notdef, try map.glyph('A'));

    // The whole reason format 12 exists.
    try testing.expectEqual(900, try map.glyph(0x1F600));
    try testing.expectEqual(901, try map.glyph(0x1F601));
    try testing.expectEqual(notdef, try map.glyph(0x1F700));
}

test "format 6 is a run of consecutive codepoints" {
    const count: u16 = 3;
    const size = 10 + @as(usize, count) * 2;
    const subtable = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(subtable);
    @memset(subtable, 0);

    std.mem.writeInt(u16, subtable[0..2], 6, .big);
    std.mem.writeInt(u16, subtable[2..4], @intCast(size), .big);
    std.mem.writeInt(u16, subtable[6..8], '0', .big);
    std.mem.writeInt(u16, subtable[8..10], count, .big);
    std.mem.writeInt(u16, subtable[10..12], 5, .big);
    std.mem.writeInt(u16, subtable[12..14], 6, .big);
    std.mem.writeInt(u16, subtable[14..16], 7, .big);

    const bytes = try wrap(testing.allocator, 0, 3, subtable);
    defer testing.allocator.free(bytes);
    const map = try Cmap.parse(.{ .bytes = bytes });

    try testing.expectEqual(5, try map.glyph('0'));
    try testing.expectEqual(7, try map.glyph('2'));
    try testing.expectEqual(notdef, try map.glyph('3'));
    try testing.expectEqual(notdef, try map.glyph('/'));
}

test "a symbol map is asked at U+F000 first, then plainly" {
    // A Windows Symbol font stores 'A' at U+F041, and a caller should not
    // have to know that.
    const segments: u16 = 2;
    const size = 16 + @as(usize, segments) * 8;
    const subtable = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(subtable);
    @memset(subtable, 0);

    std.mem.writeInt(u16, subtable[0..2], 4, .big);
    std.mem.writeInt(u16, subtable[2..4], @intCast(size), .big);
    std.mem.writeInt(u16, subtable[6..8], segments * 2, .big);

    const ends = 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;

    std.mem.writeInt(u16, subtable[ends..][0..2], 0xF0FF, .big);
    std.mem.writeInt(u16, subtable[starts..][0..2], 0xF000, .big);
    std.mem.writeInt(u16, subtable[deltas..][0..2], 3 -% @as(u16, 0xF000), .big);

    std.mem.writeInt(u16, subtable[ends + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, subtable[starts + 2 ..][0..2], 0xFFFF, .big);
    std.mem.writeInt(u16, subtable[deltas + 2 ..][0..2], 1, .big);

    const bytes = try wrap(testing.allocator, 3, 0, subtable);
    defer testing.allocator.free(bytes);
    const map = try Cmap.parse(.{ .bytes = bytes });

    try testing.expect(map.symbol);
    // Asked for 'A', found at U+F041, without the caller knowing.
    try testing.expectEqual(3 + 0x41, try map.glyph('A'));
}

test "the best subtable wins when a font carries several" {
    // A font with both a BMP map and a full Unicode one: the full one is the
    // right choice, because it is the only one that can name an emoji.
    const four = try format4(testing.allocator);
    defer testing.allocator.free(four);

    const twelve_size = 16 + 12;
    var twelve: [twelve_size]u8 = @splat(0);
    std.mem.writeInt(u16, twelve[0..2], 12, .big);
    std.mem.writeInt(u32, twelve[4..8], twelve_size, .big);
    std.mem.writeInt(u32, twelve[12..16], 1, .big);
    std.mem.writeInt(u32, twelve[16..20], 'A', .big);
    std.mem.writeInt(u32, twelve[20..24], 'A', .big);
    std.mem.writeInt(u32, twelve[24..28], 999, .big);

    const header = 4 + 2 * 8;
    const bytes = try testing.allocator.alloc(u8, header + four.len + twelve.len);
    defer testing.allocator.free(bytes);

    std.mem.writeInt(u16, bytes[0..2], 0, .big);
    std.mem.writeInt(u16, bytes[2..4], 2, .big);
    // (3, 1) first in the directory, so a parser that takes the first one
    // rather than the best one would pick it.
    std.mem.writeInt(u16, bytes[4..6], 3, .big);
    std.mem.writeInt(u16, bytes[6..8], 1, .big);
    std.mem.writeInt(u32, bytes[8..12], header, .big);
    std.mem.writeInt(u16, bytes[12..14], 3, .big);
    std.mem.writeInt(u16, bytes[14..16], 10, .big);
    std.mem.writeInt(u32, bytes[16..20], @intCast(header + four.len), .big);

    @memcpy(bytes[header..][0..four.len], four);
    @memcpy(bytes[header + four.len ..], &twelve);

    const map = try Cmap.parse(.{ .bytes = bytes });
    try testing.expectEqual(12, map.format);
    try testing.expectEqual(999, try map.glyph('A'));
}

test "a cmap with nothing usable in it says so" {
    var bytes: [12]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[2..4], 1, .big);
    // Platform 7 is not one anybody has ever defined.
    std.mem.writeInt(u16, bytes[4..6], 7, .big);
    std.mem.writeInt(u32, bytes[8..12], 12, .big);

    try testing.expectError(error.Malformed, Cmap.parse(.{ .bytes = &bytes }));
}
