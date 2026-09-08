// SPDX-License-Identifier: BSD-2-Clause

//! The container a font file is: a directory of tables, and a way to read
//! bytes out of one without believing anything the file says.
//!
//! **Every number in this file came from somewhere else.** A font is data
//! downloaded, embedded in a document, or picked up off the system - and a
//! parser that trusts an offset in it is one crafted file away from reading
//! somebody else's memory. So there is no raw pointer arithmetic anywhere
//! here: `View` holds a slice, every read is bounds-checked against it, and
//! an offset that points past the end is `error.OutOfBounds` rather than a
//! surprise.
//!
//! That checking is not free, and it is worth it anyway. A glyph is read once
//! and rasterised into an atlas that is then used for the life of the
//! program, so the parse happens hundreds of times and the drawing happens
//! millions. The place to be fast is `raster`, not here.
//!
//! ```zig
//! const file = try sfnt.File.init(bytes);
//! const head = try file.table(.head) orelse return error.MissingTable;
//! const units_per_em = try head.int(u16, 18);
//! ```

const std = @import("std");
const testing = std.testing;

/// What can go wrong reading a font file.
pub const Error = error{
    /// A read ran past the end of the data it was given. Either the file is
    /// truncated or an offset in it is wrong; from here the two look the same.
    OutOfBounds,
    /// The file does not begin with a version this can read.
    NotAFont,
    /// A TrueType collection - several fonts in one file. `File.collection`
    /// opens one of them by index.
    IsACollection,
    /// A table the format requires is not in the directory.
    MissingTable,
    /// A table is present but its contents make no sense - a version this
    /// does not know, a count that cannot be right, a format not supported.
    Malformed,
};

// -------------------------------------------------------------------------
// Reading bytes
// -------------------------------------------------------------------------

/// A window onto part of a font file, and the only way to read one.
///
/// Copying a `View` copies two words and no bytes. Every accessor takes an
/// offset from the start of the view rather than from the start of the file,
/// so a table cannot read its neighbour's contents by accident - which is
/// half of what makes the bounds checks worth having.
pub const View = struct {
    bytes: []const u8,

    pub const empty: View = .{ .bytes = &.{} };

    pub inline fn len(self: View) usize {
        return self.bytes.len;
    }

    /// A big-endian integer at `offset`. Everything in a font file is big
    /// endian, including on the little-endian machines every font file has
    /// ever been read on.
    pub fn int(self: View, comptime T: type, offset: usize) Error!T {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        if (offset > self.bytes.len or self.bytes.len - offset < size) return error.OutOfBounds;
        return std.mem.readInt(T, self.bytes[offset..][0..size], .big);
    }

    /// An F2Dot14: a signed fixed-point number with two integer bits and
    /// fourteen fractional ones. What a composite glyph's scale is written
    /// in, and nothing else here.
    pub fn f2dot14(self: View, offset: usize) Error!f32 {
        const raw = try self.int(i16, offset);
        return @as(f32, @floatFromInt(raw)) / 16384.0;
    }

    /// A smaller window, `length` bytes from `offset`.
    pub fn slice(self: View, offset: usize, length: usize) Error!View {
        if (offset > self.bytes.len or self.bytes.len - offset < length) return error.OutOfBounds;
        return .{ .bytes = self.bytes[offset..][0..length] };
    }

    /// Everything from `offset` to the end. For a table whose length the
    /// directory got wrong, or a structure that runs to the end of its table.
    pub fn from(self: View, offset: usize) Error!View {
        if (offset > self.bytes.len) return error.OutOfBounds;
        return .{ .bytes = self.bytes[offset..] };
    }

    /// A cursor that reads forwards from `offset`.
    pub fn cursor(self: View, offset: usize) Cursor {
        return .{ .view = self, .at = offset };
    }
};

/// Reading forwards through a view.
///
/// Where `View` is for a structure whose fields are at known offsets, this is
/// for one that is a run of things - the points of a glyph, the segments of a
/// character map - where each read decides where the next one starts.
pub const Cursor = struct {
    view: View,
    at: usize,

    pub fn int(self: *Cursor, comptime T: type) Error!T {
        const value = try self.view.int(T, self.at);
        self.at += @divExact(@typeInfo(T).int.bits, 8);
        return value;
    }

    pub fn slice(self: *Cursor, length: usize) Error!View {
        const window = try self.view.slice(self.at, length);
        self.at += length;
        return window;
    }

    pub fn skip(self: *Cursor, count: usize) Error!void {
        if (self.at > self.view.len() or self.view.len() - self.at < count) {
            return error.OutOfBounds;
        }
        self.at += count;
    }

    /// How much is left. A structure that says how many items it has can be
    /// checked against this before a loop rather than during one.
    pub inline fn remaining(self: Cursor) usize {
        return if (self.at >= self.view.len()) 0 else self.view.len() - self.at;
    }
};

// -------------------------------------------------------------------------
// The table directory
// -------------------------------------------------------------------------

/// A four-character table name, as the file spells it.
///
/// An enum over the tags this library knows, with `_` for the rest - a font
/// carries a dozen tables nothing here reads, and they are not errors.
pub const Tag = enum(u32) {
    cmap = tag("cmap"),
    glyf = tag("glyf"),
    head = tag("head"),
    hhea = tag("hhea"),
    hmtx = tag("hmtx"),
    kern = tag("kern"),
    loca = tag("loca"),
    maxp = tag("maxp"),
    name = tag("name"),
    post = tag("post"),
    /// `OS/2`, which has a slash in it, because 1990.
    os2 = tag("OS/2"),
    /// PostScript outlines. Present instead of `glyf` in an OpenType font,
    /// and not read here - see the note in `Font`.
    cff = tag("CFF "),
    _,

    pub fn format(self: Tag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var text: [4]u8 = undefined;
        std.mem.writeInt(u32, &text, @intFromEnum(self), .big);
        for (&text) |*c| {
            if (c.* < 0x20 or c.* > 0x7E) c.* = '.';
        }
        try w.writeAll(&text);
    }
};

/// One entry of the table directory.
pub const Entry = struct {
    tag: Tag,
    offset: u32,
    length: u32,
};

/// An open font file.
pub const File = struct {
    /// The whole file. Table offsets are from here, which is why a table
    /// cannot be read without it.
    bytes: View,
    /// Where the table directory starts. Zero for a plain font, and something
    /// else for one taken out of a collection.
    directory_at: usize,
    table_count: u16,

    /// The version number a TrueType outline font starts with. `OTTO` is the
    /// other one, and means PostScript outlines in a `CFF ` table.
    const truetype: u32 = 0x00010000;
    const otto: u32 = tag("OTTO");
    const collection: u32 = tag("ttcf");
    /// What Apple shipped before OpenType existed. The same layout.
    const apple: u32 = tag("true");

    /// Open a font.
    ///
    /// The bytes are borrowed, not copied, and must outlive the `File` - a
    /// font is most often a `@embedFile` or a buffer read once at startup,
    /// and copying a megabyte to parse a dozen tables would be waste.
    pub fn init(bytes: []const u8) Error!File {
        const view: View = .{ .bytes = bytes };
        const version = try view.int(u32, 0);

        switch (version) {
            truetype, otto, apple => {},
            collection => return error.IsACollection,
            else => return error.NotAFont,
        }

        return .{
            .bytes = view,
            .directory_at = 0,
            .table_count = try view.int(u16, 4),
        };
    }

    /// Open one font out of a TrueType collection - a file with several in
    /// it, sharing their glyph outlines. `.ttc`, and what Windows ships its
    /// CJK fonts as.
    pub fn collectionMember(bytes: []const u8, index: u32) Error!File {
        const view: View = .{ .bytes = bytes };
        if (try view.int(u32, 0) != collection) return error.NotAFont;

        const count = try view.int(u32, 8);
        if (index >= count) return error.OutOfBounds;

        // The header is followed by one offset per font, each pointing at a
        // table directory somewhere later in the file.
        const at = try view.int(u32, 12 + 4 * index);
        const directory = try view.from(at);

        switch (try directory.int(u32, 0)) {
            truetype, otto, apple => {},
            else => return error.NotAFont,
        }

        return .{
            .bytes = view,
            .directory_at = at,
            .table_count = try directory.int(u16, 4),
        };
    }

    /// How many fonts are in a collection. One, for a file that is not one.
    pub fn collectionCount(bytes: []const u8) Error!u32 {
        const view: View = .{ .bytes = bytes };
        if (try view.int(u32, 0) != collection) return 1;
        return view.int(u32, 8);
    }

    /// Whether the outlines are PostScript rather than TrueType.
    ///
    /// Worth asking early and reporting clearly: a `CFF ` font parses its
    /// directory, its character map and its metrics perfectly well here, and
    /// then has no `glyf` table to get a shape out of. Failing at
    /// `Font.init` with a name for the problem beats failing at the first
    /// glyph with `MissingTable`.
    pub fn isPostScript(self: File) bool {
        return (self.find(.cff) catch null) != null;
    }

    /// The directory entry for `wanted`, or null.
    ///
    /// A linear scan. The directory is sorted by tag and could be searched in
    /// four steps rather than a few dozen, and it is not worth it: this is
    /// called about ten times in the life of a font.
    pub fn find(self: File, wanted: Tag) Error!?Entry {
        var at = self.directory_at + 12;
        for (0..self.table_count) |_| {
            const found: Tag = @enumFromInt(try self.bytes.int(u32, at));
            if (found == wanted) {
                return .{
                    .tag = found,
                    .offset = try self.bytes.int(u32, at + 8),
                    .length = try self.bytes.int(u32, at + 12),
                };
            }
            at += 16;
        }
        return null;
    }

    /// The contents of a table, or null if the font has not got it.
    ///
    /// The length in the directory is treated as a maximum rather than as
    /// truth: a font whose last table is a few bytes shorter than it claims
    /// is common enough that rejecting it would be wrong, and every read
    /// inside the table is bounds-checked anyway.
    pub fn table(self: File, wanted: Tag) Error!?View {
        const entry = try self.find(wanted) orelse return null;
        const rest = try self.bytes.from(entry.offset);
        return .{ .bytes = rest.bytes[0..@min(entry.length, rest.len())] };
    }

    /// The contents of a table the format requires.
    pub fn required(self: File, wanted: Tag) Error!View {
        return try self.table(wanted) orelse error.MissingTable;
    }

    /// Every table in the file, in directory order. For an inspector, and for
    /// the test that checks a real font has what it should.
    pub fn entries(self: File, buffer: []Entry) Error![]Entry {
        const count = @min(self.table_count, buffer.len);
        var at = self.directory_at + 12;
        for (0..count) |i| {
            buffer[i] = .{
                .tag = @enumFromInt(try self.bytes.int(u32, at)),
                .offset = try self.bytes.int(u32, at + 8),
                .length = try self.bytes.int(u32, at + 12),
            };
            at += 16;
        }
        return buffer[0..count];
    }
};

/// The number four ASCII characters make, read big-endian - which is how the
/// file stores a table name, and how two of them can be compared with one
/// instruction instead of a loop.
pub inline fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A font file with a directory and nothing else in it, built byte by byte.
///
/// The whole point of testing a parser this way is that the input is known
/// exactly, including the parts that are wrong on purpose. A real font is an
/// integration test - see `Font` - and cannot tell you what happens when an
/// offset points past the end, because no real font does that.
pub const TestTable = struct {
    tag: *const [4]u8,
    body: []const u8,
};

pub fn buildTestFont(allocator: std.mem.Allocator, tables: []const TestTable) ![]u8 {
    return buildTestFontAt(allocator, 0, tables);
}

/// The same, for a font that will be embedded `base` bytes into a larger
/// file.
///
/// A table directory holds offsets from the start of the *file*, not from the
/// start of the directory - which is easy to forget, and is exactly what a
/// collection is: several directories in one file, all pointing into it
/// absolutely. Getting this wrong in a fixture produces a font that parses
/// and then reads the wrong bytes, which is a worse kind of broken than one
/// that fails.
pub fn buildTestFontAt(allocator: std.mem.Allocator, base: u32, tables: []const TestTable) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const count: u16 = @intCast(tables.len);
    var header: [12]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], File.truetype, .big);
    std.mem.writeInt(u16, header[4..6], count, .big);
    std.mem.writeInt(u16, header[6..8], 0, .big);
    std.mem.writeInt(u16, header[8..10], 0, .big);
    std.mem.writeInt(u16, header[10..12], 0, .big);
    try out.appendSlice(allocator, &header);

    // The directory comes first, so where the bodies go is known before any
    // of them is written.
    var body_at: u32 = base + @as(u32, @intCast(12 + 16 * tables.len));
    for (tables) |t| {
        var entry: [16]u8 = undefined;
        @memcpy(entry[0..4], t.tag);
        std.mem.writeInt(u32, entry[4..8], 0, .big); // checksum, unread here
        std.mem.writeInt(u32, entry[8..12], body_at, .big);
        std.mem.writeInt(u32, entry[12..16], @intCast(t.body.len), .big);
        try out.appendSlice(allocator, &entry);
        body_at += @intCast(t.body.len);
    }
    for (tables) |t| try out.appendSlice(allocator, t.body);

    return out.toOwnedSlice(allocator);
}

test "a view reads big-endian and refuses to run off the end" {
    const view: View = .{ .bytes = &.{ 0x12, 0x34, 0x56, 0x78 } };

    try testing.expectEqual(0x12, try view.int(u8, 0));
    try testing.expectEqual(0x1234, try view.int(u16, 0));
    try testing.expectEqual(0x3456, try view.int(u16, 1));
    try testing.expectEqual(0x12345678, try view.int(u32, 0));

    // One byte short is an error, not a read of whatever is next in memory.
    try testing.expectError(error.OutOfBounds, view.int(u32, 1));
    try testing.expectError(error.OutOfBounds, view.int(u16, 3));
    try testing.expectError(error.OutOfBounds, view.int(u8, 4));

    // And an offset far past the end does not wrap around into a small one.
    try testing.expectError(error.OutOfBounds, view.int(u8, std.math.maxInt(usize)));
}

test "signed reads keep their sign" {
    const view: View = .{ .bytes = &.{ 0xFF, 0xFF, 0x80, 0x00 } };
    try testing.expectEqual(-1, try view.int(i16, 0));
    try testing.expectEqual(-32768, try view.int(i16, 2));
}

test "an F2Dot14 is two integer bits and fourteen fractional" {
    // The four values the specification names.
    const view: View = .{ .bytes = &.{ 0x70, 0x00, 0x80, 0x00, 0x00, 0x00, 0xC0, 0x00 } };
    try testing.expectApproxEqAbs(1.75, try view.f2dot14(0), 1e-6);
    try testing.expectApproxEqAbs(-2.0, try view.f2dot14(2), 1e-6);
    try testing.expectApproxEqAbs(0.0, try view.f2dot14(4), 1e-6);
    try testing.expectApproxEqAbs(-1.0, try view.f2dot14(6), 1e-6);
}

test "a slice cannot reach outside its parent" {
    const view: View = .{ .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } };

    const inner = try view.slice(2, 4);
    try testing.expectEqual(4, inner.len());
    try testing.expectEqual(3, try inner.int(u8, 0));

    // The parent has eight bytes; the child has four, and reading past them
    // fails even though the bytes exist in the file.
    try testing.expectError(error.OutOfBounds, inner.int(u8, 4));
    try testing.expectError(error.OutOfBounds, view.slice(6, 4));
}

test "a cursor reads forwards and stops at the end" {
    const view: View = .{ .bytes = &.{ 0, 1, 0, 2, 0, 3 } };
    var at = view.cursor(0);

    try testing.expectEqual(1, try at.int(u16));
    try testing.expectEqual(2, try at.int(u16));
    try testing.expectEqual(2, at.remaining());
    try testing.expectEqual(3, try at.int(u16));
    try testing.expectEqual(0, at.remaining());
    try testing.expectError(error.OutOfBounds, at.int(u16));
}

test "a tag is four characters as one number" {
    try testing.expectEqual(@intFromEnum(Tag.head), tag("head"));
    try testing.expectEqual(Tag.glyf, @as(Tag, @enumFromInt(tag("glyf"))));

    // A tag nothing here knows is a number, not an error.
    const unknown: Tag = @enumFromInt(tag("ZZZZ"));
    try testing.expectEqual(tag("ZZZZ"), @intFromEnum(unknown));

    var text: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    try w.print("{f}", .{Tag.os2});
    try testing.expectEqualStrings("OS/2", w.buffered());
}

test "a font file hands back the tables it was built with" {
    const bytes = try buildTestFont(testing.allocator, &.{
        .{ .tag = "head", .body = &.{ 0xAA, 0xBB } },
        .{ .tag = "maxp", .body = &.{ 0x00, 0x05 } },
    });
    defer testing.allocator.free(bytes);

    const file = try File.init(bytes);
    try testing.expectEqual(2, file.table_count);

    const head = (try file.table(.head)).?;
    try testing.expectEqual(2, head.len());
    try testing.expectEqual(0xAABB, try head.int(u16, 0));

    const maxp = try file.required(.maxp);
    try testing.expectEqual(5, try maxp.int(u16, 0));

    // A table the font has not got is null, not an error - plenty are
    // optional - and `required` is the one that complains.
    try testing.expectEqual(null, try file.table(.kern));
    try testing.expectError(error.MissingTable, file.required(.kern));
}

test "a file that is not a font says so" {
    try testing.expectError(error.NotAFont, File.init(&.{ 'n', 'o', 'p', 'e' }));
    // Too short to hold even a version.
    try testing.expectError(error.OutOfBounds, File.init(&.{ 0, 1 }));
}

test "a collection is refused by init and opened by name" {
    // A two-font collection whose members are the same tiny font.
    const member = try buildTestFont(testing.allocator, &.{
        .{ .tag = "head", .body = &.{ 0, 1 } },
    });
    defer testing.allocator.free(member);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    var header: [20]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], File.collection, .big);
    std.mem.writeInt(u32, header[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, header[8..12], 2, .big);
    std.mem.writeInt(u32, header[12..16], 20, .big);
    std.mem.writeInt(u32, header[16..20], @intCast(20 + member.len), .big);
    try bytes.appendSlice(testing.allocator, &header);

    // Each member's directory has to be built knowing where in the file it
    // will land, because the offsets in it are absolute.
    const first = try buildTestFontAt(testing.allocator, 20, &.{
        .{ .tag = "head", .body = &.{ 0, 7 } },
    });
    defer testing.allocator.free(first);
    const second = try buildTestFontAt(testing.allocator, @intCast(20 + member.len), &.{
        .{ .tag = "head", .body = &.{ 0, 1 } },
    });
    defer testing.allocator.free(second);

    try bytes.appendSlice(testing.allocator, first);
    try bytes.appendSlice(testing.allocator, second);

    // `init` will not guess which one was meant.
    try testing.expectError(error.IsACollection, File.init(bytes.items));
    try testing.expectEqual(2, try File.collectionCount(bytes.items));

    // Each member is found through its own directory, and they differ - so a
    // reader that opened the wrong one would be caught here rather than
    // quietly showing the first font every time.
    const one = try File.collectionMember(bytes.items, 0);
    try testing.expectEqual(7, try (try one.required(.head)).int(u16, 0));

    const two = try File.collectionMember(bytes.items, 1);
    try testing.expectEqual(1, try (try two.required(.head)).int(u16, 0));

    try testing.expectError(error.OutOfBounds, File.collectionMember(bytes.items, 2));

    // And a plain font is a collection of one.
    try testing.expectEqual(1, try File.collectionCount(member));
}

test "a table whose length runs past the file is clipped, not refused" {
    // Fonts in the wild do this to their last table, and rejecting them
    // outright would be wrong when every read inside is checked anyway.
    var bytes = try buildTestFont(testing.allocator, &.{
        .{ .tag = "head", .body = &.{ 1, 2, 3, 4 } },
    });
    defer testing.allocator.free(bytes);

    // Claim sixteen bytes where there are four.
    std.mem.writeInt(u32, bytes[24..28], 16, .big);

    const file = try File.init(bytes);
    const head = (try file.table(.head)).?;
    try testing.expectEqual(4, head.len());
    try testing.expectError(error.OutOfBounds, head.int(u32, 4));
}

test "a table offset past the end of the file is caught" {
    var bytes = try buildTestFont(testing.allocator, &.{
        .{ .tag = "head", .body = &.{ 1, 2 } },
    });
    defer testing.allocator.free(bytes);

    // The offset field of the one entry, pointed a long way past the end.
    std.mem.writeInt(u32, bytes[20..24], 0xFFFF, .big);

    const file = try File.init(bytes);
    try testing.expectError(error.OutOfBounds, file.table(.head));
}
