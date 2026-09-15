// SPDX-License-Identifier: BSD-2-Clause

//! A font, opened: the tables parsed, and everything a renderer asks of it.
//!
//! The front door. The seven modules under it read one thing each and are
//! there for a caller that wants a part - a tool that lists tables, a
//! validator that walks every glyph. This is the whole, and it is what a
//! renderer holds. A TrueType font and a PostScript one open the same way and
//! answer the same questions; which kind it was is `Outlines`' business.
//!
//! ```zig
//! var font: Font = try .init(bytes);
//!
//! const text = font.at(16);            // sixteen pixels per em
//! const width = try text.measure("Hello");
//! const line = text.lineHeight();
//!
//! var glyph = try font.render(gpa, font.glyphFor('H'), text.scale);
//! defer glyph.deinit(gpa);
//! ```
//!
//! **The bytes are borrowed.** A `Font` holds views into the file it was
//! given and copies none of it, so the file has to outlive the font. That is
//! what makes opening one nearly free - a few dozen bounds-checked reads -
//! and it is why a `@embedFile` is the usual way to carry one.
//!
//! Two things this does not do, and both are deliberate:
//!
//! **No hinting.** A TrueType font carries a bytecode program per glyph that
//! nudges its outline onto the pixel grid at small sizes. Running it means a
//! stack machine with about eighty instructions, and the result is only
//! visible below about fourteen pixels on a display that is not
//! high-density. What is here instead is a good antialiased rasteriser, which
//! is the trade every modern text stack has made.
//!
//! **No shaping.** Turning a string into positioned glyphs in Arabic,
//! Devanagari or any script with ligatures needs `GSUB` and `GPOS`, which are
//! their own library. What is here is one glyph per codepoint plus `kern`
//! pairs - correct for Latin, Greek, Cyrillic and CJK, and what a UI needs
//! before it needs anything else.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const cff = @import("cff.zig");
const cmap = @import("cmap.zig");
const glyf = @import("glyf.zig");
const outline = @import("outline.zig");
const raster = @import("raster.zig");
const sfnt = @import("sfnt.zig");
const tables = @import("tables.zig");

const Outline = outline.Outline;
const View = sfnt.View;

const Font = @This();

pub const Error = sfnt.Error || Allocator.Error;

file: sfnt.File,
head: tables.Head,
hhea: tables.Hhea,
maxp: tables.Maxp,
/// In nearly every font made since 1997, and absent from some old ones. See
/// `Scaled.lineHeight` for what it changes.
os2: ?tables.Os2,
hmtx: tables.Hmtx,
characters: cmap.Cmap,
outlines: Outlines,
/// The `kern` table, if the font has one.
kerning: ?View,

/// Where the shapes are: `glyf` for a TrueType font, `CFF ` for a
/// PostScript one.
///
/// A tagged union, because the two are different formats with different
/// readers and a font has exactly one of them. Everything above this point
/// asks for an outline and gets one, and the only place that knows which
/// kind of font it is holding is the `switch` in `outlineOf` - which is
/// what a tagged union is for, and why it is not two optional fields that
/// every caller would have to check.
pub const Outlines = union(enum) {
    truetype: glyf.Glyf,
    postscript: cff.Cff,

    /// Find whichever table the font has. `glyf` wins if both are there,
    /// which no real font does and the specification does not allow.
    pub fn read(file: sfnt.File) Error!Outlines {
        if (try file.table(.glyf) != null) return .{ .truetype = try .read(file) };
        if (try file.table(.cff) != null) return .{ .postscript = try .read(file) };
        return error.MissingTable;
    }

    /// Read a glyph's shape into `out`, in font units, whichever kind it is.
    ///
    /// `inline else` is the union being switched on once for every tag at
    /// compile time: the body is instantiated per variant with `table` as
    /// the concrete type, so the call resolves statically and nothing is
    /// dispatched through a pointer. It reads as one line because the two
    /// readers were given the same method on purpose.
    pub fn outlineOf(self: Outlines, gpa: Allocator, glyph: u16, out: *Outline) Error!void {
        switch (self) {
            inline else => |table| try table.outlineOf(gpa, glyph, out),
        }
    }
};

/// Open a font. A collection is `error.IsACollection`: which of its fonts is
/// meant is `initMember`'s to be told.
pub fn init(bytes: []const u8) Error!Font {
    return open(try sfnt.File.init(bytes));
}

/// Open the `index`th font of a TrueType collection - a `.ttc`, which is what
/// Windows ships its Chinese, Japanese and Korean interface fonts in - or,
/// at nought, a file that is one font and not a collection at all.
///
/// What a system's font lookup hands back is a file and a place in it, and
/// this takes both, so a caller need not ask which kind of file it was.
pub fn initMember(bytes: []const u8, index: u32) Error!Font {
    const file = sfnt.File.init(bytes) catch |err| switch (err) {
        error.IsACollection => return open(try sfnt.File.collectionMember(bytes, index)),
        else => return err,
    };
    // A file that is one font has one member, and it is the first.
    if (index != 0) return error.OutOfBounds;
    return open(file);
}

fn open(file: sfnt.File) Error!Font {
    return .{
        .file = file,
        .head = try tables.Head.read(file),
        .hhea = try tables.Hhea.read(file),
        .maxp = try tables.Maxp.read(file),
        .os2 = try tables.Os2.read(file),
        .hmtx = try tables.Hmtx.read(file),
        .characters = try cmap.Cmap.read(file),
        .outlines = try Outlines.read(file),
        .kerning = try file.table(.kern),
    };
}

/// Whether the shapes are PostScript charstrings rather than TrueType
/// contours. Nothing above this layer needs to know; a tool that reports on
/// a font might.
pub inline fn isPostScript(self: Font) bool {
    return self.outlines == .postscript;
}

/// How many glyphs the font has.
pub inline fn glyphCount(self: Font) u16 {
    return self.maxp.glyph_count;
}

/// The glyph that draws a character, or `notdef` - glyph zero, the empty box.
///
/// No error union, for the reason `cmap.Cmap.lookup` has none: a character
/// the font cannot draw is the normal case for most characters in most fonts,
/// and the empty box is what should be drawn while another font is looked
/// for.
pub inline fn glyphFor(self: Font, codepoint: u21) u16 {
    return self.characters.lookup(codepoint);
}

/// Whether the font can draw this character at all.
pub inline fn has(self: Font, codepoint: u21) bool {
    return self.glyphFor(codepoint) != cmap.notdef;
}

/// How many pixels one font unit is, when the em square is `pixels_per_em`
/// pixels across.
///
/// The one conversion between the font's world and the screen's. A "16 pixel
/// font" means `pixels_per_em = 16`, which is *not* the height of a capital
/// and not the height of a line - both are smaller and larger than it
/// respectively, which surprises people every time.
pub inline fn scaleFor(self: Font, pixels_per_em: f32) f32 {
    return pixels_per_em / @as(f32, @floatFromInt(self.head.units_per_em));
}

/// How far the pen moves after drawing this glyph, in font units.
pub inline fn advance(self: Font, glyph: u16) Error!u16 {
    return self.hmtx.advance(glyph);
}

/// How much closer these two glyphs sit than their advances alone would put
/// them, in font units. Negative for the pairs that need it - `AV`, `To`,
/// `Yo` - and zero for everything else, which is almost every pair.
///
/// Only the `kern` table, in format 0. Modern fonts put their kerning in
/// `GPOS` instead, which needs a shaping engine to read; a font with only
/// `GPOS` answers zero here and sets text that looks slightly loose rather
/// than wrong.
pub fn kern(self: Font, left: u16, right: u16) Error!i16 {
    const table = self.kerning orelse return 0;
    if (table.len() < 4) return 0;

    // Microsoft's header is two 16-bit fields; Apple's is 32 bits wide. A
    // zero in the first two bytes means the Microsoft form, which is what a
    // Windows font has and what this reads.
    if (try table.int(u16, 0) != 0) return 0;
    const subtables = try table.int(u16, 2);

    var cursor: usize = 4;
    for (0..subtables) |_| {
        if (cursor + 6 > table.len()) break;
        const length = try table.int(u16, cursor + 2);
        const coverage = try table.int(u16, cursor + 4);

        const format = coverage >> 8;
        const horizontal = coverage & 0x0001 != 0;
        const minimum = coverage & 0x0002 != 0;

        if (format == 0 and horizontal and !minimum) {
            if (try kernPairs(table, cursor + 6, left, right)) |value| return value;
        }

        if (length == 0) break;
        cursor += length;
    }
    return 0;
}

/// Search one format 0 subtable for a pair.
fn kernPairs(table: View, subtable_at: usize, left: u16, right: u16) Error!?i16 {
    const count = try table.int(u16, subtable_at);
    // The four fields after the count are a binary search hint the file
    // computed in advance, and are not needed: the pairs are sorted, so a
    // search of our own finds the same entry without trusting three more
    // numbers out of the file.
    const pairs_at = subtable_at + 8;
    const wanted = (@as(u32, left) << 16) | right;

    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry_at = pairs_at + middle * 6;
        const key = try table.int(u32, entry_at);

        if (key < wanted) {
            low = middle + 1;
        } else if (key > wanted) {
            high = middle;
        } else {
            return try table.int(i16, entry_at + 4);
        }
    }
    return null;
}

/// The shape of a glyph, in font units. See `outline`.
pub inline fn outlineOf(self: Font, gpa: Allocator, glyph: u16, out: *Outline) Error!void {
    return self.outlines.outlineOf(gpa, glyph, out);
}

/// A glyph turned into pixels, and where it goes.
pub const Rendered = struct {
    bitmap: raster.Bitmap,
    /// How far right of the pen the bitmap's left edge is.
    left: i32,
    /// How far above the baseline its top row is.
    top: i32,
    /// How far the pen moves afterwards, in pixels.
    advance: f32,

    pub fn deinit(self: *Rendered, gpa: Allocator) void {
        self.bitmap.deinit(gpa);
        self.* = undefined;
    }
};

/// Rasterise one glyph at a scale from `scaleFor`.
///
/// A glyph with nothing to draw - a space - comes back with an empty bitmap
/// and a real advance, which is exactly what a renderer needs: move the pen,
/// draw nothing.
pub fn render(self: Font, gpa: Allocator, glyph: u16, scale: f32) Error!Rendered {
    const pen = @as(f32, @floatFromInt(try self.advance(glyph))) * scale;

    var shape: Outline = .empty;
    defer shape.deinit(gpa);
    try self.outlineOf(gpa, glyph, &shape);

    if (shape.isEmpty()) {
        return .{ .bitmap = .empty, .left = 0, .top = 0, .advance = pen };
    }

    const placement: raster.Placement = .init(shape.bounds(), scale);
    placement.apply(&shape);

    return .{
        .bitmap = try raster.rasterize(gpa, shape, placement.width, placement.height),
        .left = placement.left,
        .top = placement.top,
        .advance = pen,
    };
}

// -------------------------------------------------------------------------
// A font at a size
// -------------------------------------------------------------------------

/// The font at one pixel size, with the multiplications already done.
///
/// Everything a layout asks - how tall is a line, how wide is this string -
/// in pixels rather than font units, so the caller never multiplies by a
/// scale and never forgets to.
pub const Scaled = struct {
    font: *const Font,
    /// Pixels per font unit. See `Font.scaleFor`.
    scale: f32,

    /// How far above the baseline the tallest glyph reaches, in pixels.
    /// Positive.
    pub fn ascent(self: Scaled) f32 {
        return @as(f32, @floatFromInt(self.metrics().ascender)) * self.scale;
    }

    /// How far below it the deepest reaches, in pixels. **Negative**, as the
    /// font stores it - see `tables.Hhea.descender`.
    pub fn descent(self: Scaled) f32 {
        return @as(f32, @floatFromInt(self.metrics().descender)) * self.scale;
    }

    /// Baseline to baseline, in pixels.
    pub fn lineHeight(self: Scaled) f32 {
        const m = self.metrics();
        const units = @as(i32, m.ascender) - @as(i32, m.descender) + @as(i32, m.line_gap);
        return @as(f32, @floatFromInt(units)) * self.scale;
    }

    /// Which of the two sets of vertical metrics to believe.
    ///
    /// `hhea` has the ones the original Macintosh needed; `OS/2` has the ones
    /// a typographer set. They disagree often enough to matter, and a font
    /// that sets bit 7 of `fsSelection` is asking for its typographic ones -
    /// so that is what it gets, and everything else falls back to `hhea`.
    fn metrics(self: Scaled) struct { ascender: i16, descender: i16, line_gap: i16 } {
        if (self.font.os2) |os2| {
            if (os2.use_typo_metrics) return .{
                .ascender = os2.typo_ascender,
                .descender = os2.typo_descender,
                .line_gap = os2.typo_line_gap,
            };
        }
        return .{
            .ascender = self.font.hhea.ascender,
            .descender = self.font.hhea.descender,
            .line_gap = self.font.hhea.line_gap,
        };
    }

    /// How far the pen moves after one glyph, in pixels.
    pub fn advance(self: Scaled, glyph: u16) Error!f32 {
        return @as(f32, @floatFromInt(try self.font.advance(glyph))) * self.scale;
    }

    /// How wide one character is, in pixels. What
    /// [Fluxion Text](https://github.com/kisstp2006/fluxion-text)'s `wrap`
    /// wants, and the reason it takes a function rather than a font.
    pub fn advanceOf(self: Scaled, codepoint: u21) Error!f32 {
        return self.advance(self.font.glyphFor(codepoint));
    }

    /// How wide a run of UTF-8 is, in pixels, kerning included.
    ///
    /// Not the same as the sum of the glyph bounding boxes: the pen advance
    /// of a letter includes the space beside it, and `kern` takes some of it
    /// back between particular pairs. Measuring by adding up boxes gives a
    /// number that is wrong in both directions at once.
    ///
    /// Invalid UTF-8 is skipped rather than refused. Text arriving from a
    /// file or a network is not this function's to police, and a measurement
    /// that could fail would put an error path in every caller.
    pub fn measure(self: Scaled, text: []const u8) Error!f32 {
        var total: f32 = 0;
        var previous: ?u16 = null;

        var i: usize = 0;
        while (i < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + length > text.len) break;
            const codepoint = std.unicode.utf8Decode(text[i..][0..length]) catch {
                i += length;
                continue;
            };
            i += length;

            const glyph = self.font.glyphFor(codepoint);
            if (previous) |left| {
                total += @as(f32, @floatFromInt(try self.font.kern(left, glyph))) * self.scale;
            }
            total += try self.advance(glyph);
            previous = glyph;
        }
        return total;
    }
};

/// The font at `pixels_per_em` pixels. See `Scaled`.
pub fn at(self: *const Font, pixels_per_em: f32) Scaled {
    return .{ .font = self, .scale = self.scaleFor(pixels_per_em) };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// The parsing is checked exactly by the modules underneath, against fixtures
// built byte by byte. What is checked here is the whole: that a real font
// opens and its numbers hang together. `examples/inspect.zig` carries the
// ones that look at pixels.

fn systemFont(gpa: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/consola.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch continue;
    }
    return null;
}

/// A TrueType collection from the system, or null: Yu Gothic beside Yu Gothic
/// UI on Windows, Cambria beside Cambria Math, and the Noto CJK fonts on a
/// Linux box that has them.
fn systemCollection(gpa: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/YuGothM.ttc",
        "C:/Windows/Fonts/cambria.ttc",
        "C:/Windows/Fonts/msgothic.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(64 << 20)) catch continue;
    }
    return null;
}

test "a font out of a collection opens by its place in the file" {
    const bytes = try systemCollection(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    try testing.expectError(error.IsACollection, init(bytes));
    const count = try sfnt.File.collectionCount(bytes);
    try testing.expect(count >= 2);

    // Two fonts sharing one file: each is a whole font, at a directory of
    // its own, and each draws the letters.
    const first = try initMember(bytes, 0);
    const second = try initMember(bytes, 1);
    try testing.expect(first.file.directory_at != second.file.directory_at);
    try testing.expect(first.has('A') and second.has('A'));
    try testing.expect(try first.at(16).measure("Hello") > 0);

    try testing.expectError(error.OutOfBounds, initMember(bytes, count));
}

test "a font that is not a collection is its own only member" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const whole = try init(bytes);
    const member = try initMember(bytes, 0);
    try testing.expectEqual(whole.glyphCount(), member.glyphCount());
    try testing.expectEqual(whole.glyphFor('A'), member.glyphFor('A'));
    try testing.expectError(error.OutOfBounds, initMember(bytes, 1));
}

test "measuring a string is more than adding up the letters" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    const text = font.at(16);

    try testing.expectEqual(@as(f32, 0), try text.measure(""));

    const one = try text.measure("i");
    try testing.expect(try text.measure("iiiii") > one * 4);

    // A longer string measures wider, and a space is not free.
    try testing.expect(try text.measure("Hello world") > try text.measure("Hello"));
    try testing.expect(try text.measure("a a") > try text.measure("aa"));
}

test "a scaled font is the font times a number, and the number is per em" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    const small = font.at(16);
    const large = font.at(32);

    // Twice the size is twice everything.
    try testing.expectApproxEqRel(small.lineHeight() * 2, large.lineHeight(), 0.001);
    try testing.expectApproxEqRel(try small.measure("Hello"), try large.measure("Hello") / 2, 0.001);

    // Up is positive, down is negative, and a line is taller than the em
    // square it is named after - which is the thing that surprises people.
    try testing.expect(small.ascent() > 0);
    try testing.expect(small.descent() < 0);
    try testing.expect(small.lineHeight() > small.ascent());
}

test "invalid UTF-8 is measured, not refused" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    // Text off a network is not this function's to police.
    try testing.expect(try font.at(16).measure(&.{ 'a', 0xFF, 0xFE, 'b' }) > 0);
}

test "a rendered glyph knows where it sits relative to the pen" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);

    var glyph = try font.render(testing.allocator, font.glyphFor('H'), font.scaleFor(64));
    defer glyph.deinit(testing.allocator);

    try testing.expect(!glyph.bitmap.isEmpty());
    // A capital sits on the baseline and reaches up, so its top is above it
    // and its bitmap is no taller than that reach.
    try testing.expect(glyph.top > 0);
    try testing.expect(glyph.advance > 0);

    // A space moves the pen and draws nothing.
    var space = try font.render(testing.allocator, font.glyphFor(' '), font.scaleFor(64));
    defer space.deinit(testing.allocator);
    try testing.expect(space.bitmap.isEmpty());
    try testing.expect(space.advance > 0);
}

test "kerning is a small number of font units, or nothing at all" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    const value = try font.kern(font.glyphFor('A'), font.glyphFor('V'));

    // Whatever the font has, a pair moves by a fraction of an em - one that
    // moved by a whole em would be unreadable.
    const limit: i32 = font.head.units_per_em;
    try testing.expect(@as(i32, value) > -limit and @as(i32, value) < limit);

    // And a font with no `kern` table answers zero rather than failing.
    if (font.kerning == null) try testing.expectEqual(0, value);
}

/// A PostScript-flavoured OpenType font from the system, or null. Windows
/// ships a handful of `.otf` files with its Hebrew fonts; a Linux box with
/// the Adobe or Noto CJK fonts installed has them by the dozen.
fn systemPostScriptFont(gpa: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/FrankRuhlHofshi-Regular.otf",
        "C:/Windows/Fonts/DavidCLM-Medium.otf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/OTF/SourceSans3-Regular.otf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch continue;
    }
    return null;
}

test "a PostScript font opens the same way and draws the same letters" {
    const bytes = try systemPostScriptFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    try testing.expect(font.isPostScript());

    // The metrics are the same tables whichever kind of outline the font
    // has, so the scaled questions answer the same way.
    const text = font.at(16);
    try testing.expect(text.ascent() > 0);
    try testing.expect(try text.measure("Hello") > try text.measure("Hell"));

    // And a capital comes out as ink where a capital has it.
    var glyph = try font.render(testing.allocator, font.glyphFor('H'), font.scaleFor(64));
    defer glyph.deinit(testing.allocator);
    try testing.expect(!glyph.bitmap.isEmpty());
    try testing.expect(glyph.top > 0);

    // The shapes are cubics, which is what says the charstrings were run
    // rather than a `glyf` table found by accident.
    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try font.outlineOf(testing.allocator, font.glyphFor('o'), &shape);
    var cubics: usize = 0;
    for (shape.commands.items) |command| {
        if (command == .cubic) cubics += 1;
    }
    try testing.expect(cubics > 0);
}

test "a font missing a table it cannot do without says so" {
    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
    std.mem.writeInt(u16, head[18..20], 1000, .big);

    const bytes = try sfnt.buildTestFont(testing.allocator, &.{
        .{ .tag = "head", .body = &head },
    });
    defer testing.allocator.free(bytes);

    try testing.expectError(error.MissingTable, Font.init(bytes));
}
