// SPDX-License-Identifier: BSD-2-Clause

//! `CBLC` and `CBDT`: colour glyphs kept as pictures.
//!
//! The other way a font draws an emoji: not outlines at all, but a PNG for
//! each glyph at one or two sizes - "strikes" - which a renderer scales to
//! the size it wants. `CBLC` is the index (which strikes there are, and
//! where each glyph's picture is); `CBDT` holds the pictures. Android's flags
//! are drawn this way, and so was all of its Noto Color Emoji before 2023.
//!
//! This finds a glyph's PNG and its metrics. Decoding the PNG is not done
//! here - this library reads fonts and decodes no images - so `Font` asks
//! its caller for a decoder when it draws one.

const std = @import("std");
const testing = std.testing;

const sfnt = @import("sfnt.zig");

const Error = sfnt.Error;
const File = sfnt.File;
const View = sfnt.View;

pub const Bitmaps = struct {
    index: View,
    data: View,

    pub fn read(file: File) Error!?Bitmaps {
        const index = try file.table(@enumFromInt(sfnt.tag("CBLC"))) orelse return null;
        const data = try file.table(@enumFromInt(sfnt.tag("CBDT"))) orelse return null;
        if (try index.int(u32, 4) == 0) return null;
        return .{ .index = index, .data = data };
    }

    /// A glyph's picture in one strike.
    pub const Found = struct {
        /// The PNG, as the file has it.
        png: []const u8,
        /// The strike's size, pixels per em: what the picture's pixels are
        /// measured against.
        ppem: u8,
        /// How far right of the pen it starts and how far above the baseline
        /// its top is, in the strike's pixels.
        bearing_x: i8,
        bearing_y: i8,
    };

    pub fn has(self: Bitmaps, glyph: u16) Error!bool {
        return try self.find(glyph, 0) != null;
    }

    /// The glyph's picture from the strike nearest `pixels_per_em` that is
    /// at least that big - scaling down looks better than scaling up - or
    /// the biggest there is.
    pub fn find(self: Bitmaps, glyph: u16, pixels_per_em: f32) Error!?Found {
        const strikes = try self.index.int(u32, 4);
        var best: ?usize = null;
        var best_ppem: u8 = 0;
        for (0..strikes) |k| {
            const record = 8 + k * 48;
            const first = try self.index.int(u16, record + 40);
            const last = try self.index.int(u16, record + 42);
            if (glyph < first or glyph > last) continue;
            const ppem = try self.index.int(u8, record + 45);
            const fits = @as(f32, @floatFromInt(ppem)) >= pixels_per_em;
            const best_fits = @as(f32, @floatFromInt(best_ppem)) >= pixels_per_em;
            const better = if (best == null)
                true
            else if (fits and best_fits)
                ppem < best_ppem
            else if (fits != best_fits)
                fits
            else
                ppem > best_ppem;
            if (better) {
                best = k;
                best_ppem = ppem;
            }
        }
        const strike = best orelse return null;
        return self.inStrike(strike, glyph);
    }

    fn inStrike(self: Bitmaps, strike: usize, glyph: u16) Error!?Found {
        const record = 8 + strike * 48;
        const array_at = try self.index.int(u32, record);
        const subtables = try self.index.int(u32, record + 8);
        const ppem = try self.index.int(u8, record + 45);
        const array = try self.index.from(array_at);

        for (0..subtables) |k| {
            const first = try array.int(u16, k * 8);
            const last = try array.int(u16, k * 8 + 2);
            if (glyph < first or glyph > last) continue;
            const subtable = try array.from(try array.int(u32, k * 8 + 4));
            const index_format = try subtable.int(u16, 0);
            const image_format = try subtable.int(u16, 2);
            const image_at: usize = try subtable.int(u32, 4);
            const place: usize = glyph - first;

            var start: usize = 0;
            var end: usize = 0;
            // Formats 2 and 5 keep one set of metrics for every glyph.
            var shared: ?View = null;
            switch (index_format) {
                1 => {
                    start = image_at + try subtable.int(u32, 8 + place * 4);
                    end = image_at + try subtable.int(u32, 8 + (place + 1) * 4);
                },
                3 => {
                    start = image_at + try subtable.int(u16, 8 + place * 2);
                    end = image_at + try subtable.int(u16, 8 + (place + 1) * 2);
                },
                2 => {
                    const size = try subtable.int(u32, 8);
                    shared = try subtable.slice(12, 8);
                    start = image_at + place * size;
                    end = start + size;
                },
                4 => {
                    const count = try subtable.int(u32, 8);
                    var low: usize = 0;
                    var high: usize = count;
                    const found = while (low < high) {
                        const middle = low + (high - low) / 2;
                        const value = try subtable.int(u16, 12 + middle * 4);
                        if (value < glyph) {
                            low = middle + 1;
                        } else if (value > glyph) {
                            high = middle;
                        } else break middle;
                    } else return null;
                    start = image_at + try subtable.int(u16, 12 + found * 4 + 2);
                    end = image_at + try subtable.int(u16, 12 + (found + 1) * 4 + 2);
                },
                5 => {
                    const size = try subtable.int(u32, 8);
                    shared = try subtable.slice(12, 8);
                    const count = try subtable.int(u32, 20);
                    const found = for (0..count) |n| {
                        if (try subtable.int(u16, 24 + n * 2) == glyph) break n;
                    } else return null;
                    start = image_at + found * size;
                    end = start + size;
                },
                else => return null,
            }
            if (end <= start) return null;
            const image = try self.data.slice(start, end - start);
            return switch (image_format) {
                17 => .{
                    .png = (try image.slice(9, try image.int(u32, 5))).bytes,
                    .ppem = ppem,
                    .bearing_x = try image.int(i8, 2),
                    .bearing_y = try image.int(i8, 3),
                },
                18 => .{
                    .png = (try image.slice(12, try image.int(u32, 8))).bytes,
                    .ppem = ppem,
                    .bearing_x = try image.int(i8, 2),
                    .bearing_y = try image.int(i8, 3),
                },
                19 => .{
                    .png = (try image.slice(4, try image.int(u32, 0))).bytes,
                    .ppem = ppem,
                    .bearing_x = if (shared) |m| try m.int(i8, 2) else 0,
                    .bearing_y = if (shared) |m| try m.int(i8, 3) else 0,
                },
                else => null,
            };
        }
        return null;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .big);
}

fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .big);
}

test "a glyph's picture is found in the strike nearest the size, from above" {
    // Two strikes, 32 and 109 pixels, each holding glyph 4 in format 1 with
    // image format 17.
    var index: [8 + 2 * 48 + 2 * (8 + 8 + 8)]u8 = @splat(0);
    put32(&index, 0, 0x00030000);
    put32(&index, 4, 2);
    const arrays = 8 + 2 * 48;
    for (0..2) |k| {
        const record = 8 + k * 48;
        const array_at = arrays + k * 24;
        put32(&index, record, @intCast(array_at));
        put32(&index, record + 8, 1);
        put16(&index, record + 40, 4);
        put16(&index, record + 42, 4);
        index[record + 44] = if (k == 0) 32 else 109;
        index[record + 45] = if (k == 0) 32 else 109;
        // The one subtable: glyphs 4 to 4, header at +8.
        put16(&index, array_at, 4);
        put16(&index, array_at + 2, 4);
        put32(&index, array_at + 4, 8);
        // Header: index format 1, image format 17, images at 4 + 13k.
        put16(&index, array_at + 8, 1);
        put16(&index, array_at + 10, 17);
        put32(&index, array_at + 12, @intCast(4 + k * 13));
        put32(&index, array_at + 16, 0);
        put32(&index, array_at + 20, 13);
    }

    // Two pictures: metrics, a length of four, and four bytes standing in
    // for the PNG.
    var data: [4 + 2 * 13]u8 = @splat(0);
    put32(&data, 0, 0x00030000);
    for (0..2) |k| {
        const at = 4 + k * 13;
        data[at + 2] = 1; // bearing x
        data[at + 3] = if (k == 0) 30 else 100; // bearing y
        put32(&data, at + 5, 4);
        @memcpy(data[at + 9 ..][0..4], if (k == 0) "smal" else "larg");
    }

    const bitmaps: Bitmaps = .{ .index = .{ .bytes = &index }, .data = .{ .bytes = &data } };
    const small = (try bitmaps.find(4, 20)).?;
    try testing.expectEqual(@as(u8, 32), small.ppem);
    try testing.expectEqualStrings("smal", small.png);
    try testing.expectEqual(@as(i8, 30), small.bearing_y);

    const large = (try bitmaps.find(4, 64)).?;
    try testing.expectEqual(@as(u8, 109), large.ppem);
    try testing.expectEqualStrings("larg", large.png);

    // Bigger than any strike: the biggest.
    try testing.expectEqual(@as(u8, 109), (try bitmaps.find(4, 400)).?.ppem);
    try testing.expect(try bitmaps.find(5, 20) == null);
}
