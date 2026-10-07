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
//! Devanagari or any script with ligatures needs the whole of `GSUB` and
//! `GPOS` run over whole runs of text, which is its own library. What is
//! here is one glyph per codepoint plus pair kerning - from `GPOS` where the
//! font keeps it, which is where a modern font does, and from `kern` where
//! it does not. That is correct for Latin, Greek, Cyrillic and CJK, and what
//! a UI needs before it needs anything else; what it leaves out is a mark
//! placed on the letter it belongs to. The one exception is an emoji
//! sequence: `substitute` runs a font's `GSUB` over a cluster, which is what
//! an emoji font needs to put a family or a flag together. See `fallback`.
//!
//! **Colour glyphs.** An emoji font draws in colour, from layered outlines
//! (`COLR` and `CPAL`, see `colr`) or from pictures (`CBDT`, see `cbdt`).
//! `renderColor` draws one into RGBA; `render` still gives the coverage of
//! its outline, which is its silhouette.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const cbdt = @import("cbdt.zig");
const cff = @import("cff.zig");
const cmap = @import("cmap.zig");
const colr = @import("colr.zig");
const glyf = @import("glyf.zig");
const gpos = @import("gpos.zig");
const gsub_table = @import("gsub.zig");
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
/// Null only for a font of pictures and nothing else - a `CBDT` emoji font
/// with no outlines at all.
outlines: ?Outlines,
/// The pair kerning in `GPOS`, found when the font was opened, if it has
/// any. When it is there, `kern` reads it and not `kerning`.
pairs: ?gpos.Kerning,
/// The `kern` table, if the font has one. What `kern` reads when `pairs` is
/// null.
kerning: ?View,
/// Colour glyphs: layers or paints, their palette, and pictures.
colors: ?colr.Colr,
palette: ?colr.Palette,
bitmaps: ?cbdt.Bitmaps,
/// The substitutions `substitute` runs.
gsub: ?gsub_table.Gsub,

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
    const bitmaps = try cbdt.Bitmaps.read(file);
    return .{
        .file = file,
        .head = try tables.Head.read(file),
        .hhea = try tables.Hhea.read(file),
        .maxp = try tables.Maxp.read(file),
        .os2 = try tables.Os2.read(file),
        .hmtx = try tables.Hmtx.read(file),
        .characters = try cmap.Cmap.read(file),
        // Pictures instead of shapes are a font too.
        .outlines = Outlines.read(file) catch |err| switch (err) {
            error.MissingTable => if (bitmaps != null) null else return err,
            else => return err,
        },
        // Never an error: a `GPOS` too broken to walk is no kerning, and
        // the font opens without it. See `gpos`.
        .pairs = gpos.Kerning.read(file),
        .kerning = try file.table(.kern),
        .colors = try colr.Colr.read(file),
        .palette = try colr.Palette.read(file),
        .bitmaps = bitmaps,
        .gsub = try gsub_table.Gsub.read(file),
    };
}

/// Whether the shapes are PostScript charstrings rather than TrueType
/// contours. Nothing above this layer needs to know; a tool that reports on
/// a font might.
pub inline fn isPostScript(self: Font) bool {
    const shapes = self.outlines orelse return false;
    return shapes == .postscript;
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
/// From `GPOS` when the font kerns there, which nearly every font made in
/// the last fifteen years does and Inter does exclusively: the pair
/// adjustments its `kern` feature names, found once when the font was
/// opened, so a call here is a few coverage searches and nothing else. See
/// `gpos`. Otherwise from the `kern` table, in format 0, which is where an
/// older font keeps it.
///
/// **Never from both.** A font with both carries `kern` for software that
/// cannot read `GPOS`, and the two say much the same thing - adding them
/// would kern every pair twice. `GPOS` wins, which is the rule HarfBuzz follows
/// too. A font whose `GPOS` has no pair kerning this can read - none at all,
/// or only the contextual kind - falls back to its `kern` table, which is
/// the designer's own approximation and better than nothing.
///
/// The error is the `kern` table's. The `GPOS` side has none to give: a pair
/// whose subtable cannot be read is a pair that is not kerned.
pub fn kern(self: Font, left: u16, right: u16) Error!i16 {
    if (self.pairs) |*pairs| return pairs.kern(left, right);
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

/// The shape of a glyph, in font units. See `outline`. Empty in a font of
/// pictures.
pub inline fn outlineOf(self: Font, gpa: Allocator, glyph: u16, out: *Outline) Error!void {
    const shapes = self.outlines orelse return out.clear();
    return shapes.outlineOf(gpa, glyph, out);
}

/// Run the font's substitutions for `features` - `ccmp` is the one an emoji
/// font puts its sequences in - over a cluster of glyphs. A font with no
/// `GSUB` leaves them as they are.
pub fn substitute(self: Font, glyphs: *gsub_table.Glyphs, features: []const u32) Error!void {
    const table = self.gsub orelse return;
    try table.apply(glyphs, features);
}

/// Whether a glyph has a colour form for `renderColor` to draw.
pub fn hasColor(self: Font, glyph: u16) bool {
    if (self.colors) |table| {
        if (table.has(glyph) catch false) return true;
    }
    if (self.bitmaps) |table| {
        if (table.has(glyph) catch false) return true;
    }
    return false;
}

/// A picture decoded for `renderColor`: straight RGBA, top row first, in
/// memory from the allocator it was given.
pub const Decoded = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

pub const ColorOptions = struct {
    /// What palette entry `0xFFFF` - "the text's colour" - is drawn in.
    /// Emoji fonts do not use it.
    foreground: [4]u8 = .{ 0, 0, 0, 255 },
    /// Turns a PNG into pixels, for a font that keeps its colour glyphs as
    /// pictures. Without one, such a glyph has no colour form here.
    decode_png: ?*const fn (gpa: Allocator, png: []const u8) anyerror!Decoded = null,
};

/// A colour glyph drawn. See `colr.Picture`; the advance is the glyph's.
pub const Colored = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    advance: f32,

    pub fn deinit(self: *Colored, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// Draw a glyph in colour at `pixels_per_em`: its layers or paints if the
/// font has `COLR`, else its picture if it has `CBDT` and a decoder was
/// given. Null when the glyph has no colour form.
pub fn renderColor(self: *const Font, gpa: Allocator, glyph: u16, pixels_per_em: f32, options: ColorOptions) (Error || error{ TooLarge, BadPicture })!?Colored {
    const scale = self.scaleFor(pixels_per_em);
    const pen = @as(f32, @floatFromInt(try self.advance(glyph))) * scale;
    if (self.colors) |table| {
        if (try colr.render(gpa, self, table, self.palette, glyph, scale, options.foreground)) |picture| {
            return .{ .pixels = picture.pixels, .width = picture.width, .height = picture.height, .left = picture.left, .top = picture.top, .advance = pen };
        }
    }
    const decode = options.decode_png orelse return null;
    const table = self.bitmaps orelse return null;
    const found = try table.find(glyph, pixels_per_em) orelse return null;
    const source = decode(gpa, found.png) catch return error.BadPicture;
    defer gpa.free(source.pixels);
    if (source.width == 0 or source.height == 0 or source.pixels.len < @as(usize, source.width) * source.height * 4) return error.BadPicture;

    const k = pixels_per_em / @as(f32, @floatFromInt(@max(found.ppem, 1)));
    const width: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(source.width)) * k))));
    const height: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(source.height)) * k))));
    if (width > colr.max_side or height > colr.max_side) return error.TooLarge;
    const pixels = try resample(gpa, source, width, height);
    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .left = @intFromFloat(@round(@as(f32, @floatFromInt(found.bearing_x)) * k)),
        .top = @intFromFloat(@round(@as(f32, @floatFromInt(found.bearing_y)) * k)),
        .advance = pen,
    };
}

/// A picture to a new size: each new pixel the average of the old ones it
/// covers, weighted by how much of each it covers, in premultiplied colour so
/// a transparent neighbour does not darken an edge.
fn resample(gpa: Allocator, source: Decoded, width: u32, height: u32) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    const sx = @as(f32, @floatFromInt(source.width)) / @as(f32, @floatFromInt(width));
    const sy = @as(f32, @floatFromInt(source.height)) / @as(f32, @floatFromInt(height));
    for (0..height) |y| {
        const y0 = @as(f32, @floatFromInt(y)) * sy;
        const y1 = y0 + sy;
        for (0..width) |x| {
            const x0 = @as(f32, @floatFromInt(x)) * sx;
            const x1 = x0 + sx;
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            var weight: f32 = 0;
            var row: usize = @intFromFloat(@floor(y0));
            while (@as(f32, @floatFromInt(row)) < y1 and row < source.height) : (row += 1) {
                const fy = @min(y1, @as(f32, @floatFromInt(row + 1))) - @max(y0, @as(f32, @floatFromInt(row)));
                var column: usize = @intFromFloat(@floor(x0));
                while (@as(f32, @floatFromInt(column)) < x1 and column < source.width) : (column += 1) {
                    const fx = @min(x1, @as(f32, @floatFromInt(column + 1))) - @max(x0, @as(f32, @floatFromInt(column)));
                    const w = fx * fy;
                    const px = source.pixels[(row * source.width + column) * 4 ..][0..4];
                    const a = @as(f32, @floatFromInt(px[3])) / 255;
                    for (0..3) |c| sum[c] += @as(f32, @floatFromInt(px[c])) / 255 * a * w;
                    sum[3] += a * w;
                    weight += w;
                }
            }
            const px = out[(y * width + x) * 4 ..][0..4];
            const a = if (weight > 0) sum[3] / weight else 0;
            if (a <= 0) {
                px.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |c| px[c] = @intFromFloat(@round(std.math.clamp(sum[c] / weight / a, 0, 1) * 255));
            px[3] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
        }
    }
    colr.bleed(out, width, height);
    return out;
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

    // And a font with no kerning at all answers zero rather than failing.
    if (font.kerning == null and font.pairs == null) try testing.expectEqual(0, value);
}

/// Inter from the system, by weight, or null. It keeps all of its kerning in
/// `GPOS` and has no `kern` table, which is what makes it the font to check
/// that `GPOS` is read.
fn systemInter(gpa: Allocator, comptime weight: []const u8) !?[]u8 {
    const candidates = [_][]const u8{
        "/usr/share/fonts/rsms-inter-fonts/Inter-" ++ weight ++ ".ttf",
        "/usr/share/fonts/inter/Inter-" ++ weight ++ ".ttf",
        "/usr/share/fonts/truetype/inter/Inter-" ++ weight ++ ".ttf",
        "/usr/share/fonts/opentype/inter/Inter-" ++ weight ++ ".otf",
        "C:/Windows/Fonts/Inter-" ++ weight ++ ".ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch continue;
    }
    return null;
}

test "Inter's kerning, which is only in GPOS, is read" {
    var found = false;
    inline for (.{ "Regular", "SemiBold" }) |weight| {
        if (try systemInter(testing.allocator, weight)) |bytes| {
            defer testing.allocator.free(bytes);
            found = true;

            const font: Font = try .init(bytes);
            try testing.expect(font.pairs != null);

            // The pairs everybody notices when they are not kerned.
            for ([_]*const [2]u8{ "To", "AV", "Yo", "Ty", "VA" }) |pair| {
                try testing.expect(try font.kern(font.glyphFor(pair[0]), font.glyphFor(pair[1])) < 0);
            }
            // And two straight stems are spaced by their sidebearings alone.
            try testing.expectEqual(0, try font.kern(font.glyphFor('H'), font.glyphFor('H')));

            // A measurement takes the kerning in: "AVATAR" is narrower than
            // its letters' advances added up.
            const text = font.at(16);
            var letters: f32 = 0;
            for ("AVATAR") |c| letters += try text.advanceOf(c);
            try testing.expect(try text.measure("AVATAR") < letters - 1);
        }
    }
    if (!found) return error.SkipZigTest;
}

/// A font with only what opening one needs, plus `extra`: twenty-seven
/// glyphs of five hundred units on a thousand-unit em, `A` to `Z` drawn by
/// glyphs 1 to 26, and no outlines. Built byte by byte so a test can give it
/// exactly the kerning it is about.
fn testFont(gpa: Allocator, extra: []const sfnt.TestTable) ![]u8 {
    const glyphs = 27;

    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
    std.mem.writeInt(u16, head[18..20], 1000, .big);

    var hhea: [36]u8 = @splat(0);
    std.mem.writeInt(i16, hhea[4..6], 800, .big);
    std.mem.writeInt(i16, hhea[6..8], -200, .big);
    std.mem.writeInt(u16, hhea[34..36], glyphs, .big);

    var maxp: [6]u8 = @splat(0);
    std.mem.writeInt(u16, maxp[4..6], glyphs, .big);

    var hmtx: [glyphs * 4]u8 = @splat(0);
    for (0..glyphs) |g| std.mem.writeInt(u16, hmtx[g * 4 ..][0..2], 500, .big);

    // One Windows Unicode subtable, in format 6: 26 characters from `A`.
    var characters: [12 + 10 + 26 * 2]u8 = @splat(0);
    std.mem.writeInt(u16, characters[2..4], 1, .big);
    std.mem.writeInt(u16, characters[4..6], 3, .big);
    std.mem.writeInt(u16, characters[6..8], 1, .big);
    std.mem.writeInt(u32, characters[8..12], 12, .big);
    std.mem.writeInt(u16, characters[12..14], 6, .big);
    std.mem.writeInt(u16, characters[14..16], 10 + 26 * 2, .big);
    std.mem.writeInt(u16, characters[18..20], 'A', .big);
    std.mem.writeInt(u16, characters[20..22], 26, .big);
    for (0..26) |k| std.mem.writeInt(u16, characters[22 + k * 2 ..][0..2], @intCast(k + 1), .big);

    // Every glyph empty: a `loca` of zeros, over a `glyf` of nothing.
    const loca: [(glyphs + 1) * 2]u8 = @splat(0);

    var list: [16]sfnt.TestTable = undefined;
    const required = [_]sfnt.TestTable{
        .{ .tag = "head", .body = &head },
        .{ .tag = "hhea", .body = &hhea },
        .{ .tag = "maxp", .body = &maxp },
        .{ .tag = "hmtx", .body = &hmtx },
        .{ .tag = "cmap", .body = &characters },
        .{ .tag = "loca", .body = &loca },
        .{ .tag = "glyf", .body = &.{} },
    };
    @memcpy(list[0..required.len], &required);
    @memcpy(list[required.len..][0..extra.len], extra);
    return sfnt.buildTestFont(gpa, list[0 .. required.len + extra.len]);
}

/// A `kern` table in format 0 with one pair in it.
fn testKern(left: u16, right: u16, value: i16) [24]u8 {
    var bytes: [24]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[2..4], 1, .big); // one subtable
    std.mem.writeInt(u16, bytes[6..8], 20, .big); // its length
    std.mem.writeInt(u16, bytes[8..10], 0x0001, .big); // format 0, horizontal
    std.mem.writeInt(u16, bytes[10..12], 1, .big); // one pair, after the search hints
    std.mem.writeInt(u16, bytes[18..20], left, .big);
    std.mem.writeInt(u16, bytes[20..22], right, .big);
    std.mem.writeInt(i16, bytes[22..24], value, .big);
    return bytes;
}

/// A `GPOS` that kerns `A` then `V` - glyphs 1 and 22 of `testFont` - by
/// -80, and nothing else: one script, one `kern` feature, one lookup, one
/// list of pairs. Each number is sixteen bits; the comments count in bytes.
const test_gpos = gposBytes(&.{
    1, 0, 10, 30, 44, // version 1.0, then the script, feature and lookup lists
    1, 0x4446, 0x4C54, 8, // 10: one script, "DFLT", at +8
    4, 0, // 18: its default language system at +4
    0, 0xFFFF, 1, 0, // 22: no required feature, and feature 0
    1, 0x6B65, 0x726E, 8, // 30: one feature, "kern", at +8
    0, 1, 0, // 38: lookup 0
    1, 4, // 44: one lookup, at +4
    2, 0, 1, 8, // 48: a pair adjustment, one subtable at +8
    1, 12, 0x0004, 0, 1, 18, // 56: a list of pairs, its coverage, an advance, one set
    1, 1, 1, // 68: glyph 1 is covered
    1, 22, -80, // 74: glyph 1 then glyph 22 moves by -80
});

fn gposBytes(comptime words: []const i32) [words.len * 2]u8 {
    var out: [words.len * 2]u8 = undefined;
    for (words, 0..) |word, k| {
        std.mem.writeInt(u16, out[k * 2 ..][0..2], @truncate(@as(u32, @bitCast(word))), .big);
    }
    return out;
}

test "a font with no GPOS kerns from its kern table" {
    const kerning = testKern(1, 22, -50);
    const bytes = try testFont(testing.allocator, &.{.{ .tag = "kern", .body = &kerning }});
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    try testing.expect(font.pairs == null);
    try testing.expectEqual(-50, try font.kern(font.glyphFor('A'), font.glyphFor('V')));
    try testing.expectEqual(0, try font.kern(font.glyphFor('V'), font.glyphFor('A')));

    // At a thousand pixels to a thousand-unit em, a unit is a pixel: two
    // advances of 500, less 50.
    try testing.expectApproxEqAbs(@as(f32, 950), try font.at(1000).measure("AV"), 0.001);
}

test "a font that kerns in GPOS uses that, and not its kern table as well" {
    const kerning = testKern(1, 22, -50);
    const bytes = try testFont(testing.allocator, &.{
        .{ .tag = "GPOS", .body = &test_gpos },
        .{ .tag = "kern", .body = &kerning },
    });
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    try testing.expect(font.pairs != null);
    // -80 from `GPOS`: not the `kern` table's -50, and not the two added.
    try testing.expectEqual(-80, try font.kern(font.glyphFor('A'), font.glyphFor('V')));
    try testing.expectEqual(0, try font.kern(font.glyphFor('A'), font.glyphFor('W')));
    try testing.expectApproxEqAbs(@as(f32, 920), try font.at(1000).measure("AV"), 0.001);
}

test "a GPOS too broken to read falls back to the kern table, and opens" {
    // The lookup list pointed past the end of the table.
    var broken = test_gpos;
    std.mem.writeInt(u16, broken[8..10], 0xFFF0, .big);
    const kerning = testKern(1, 22, -50);

    const with_kern = try testFont(testing.allocator, &.{
        .{ .tag = "GPOS", .body = &broken },
        .{ .tag = "kern", .body = &kerning },
    });
    defer testing.allocator.free(with_kern);
    const font: Font = try .init(with_kern);
    try testing.expect(font.pairs == null);
    try testing.expectEqual(-50, try font.kern(font.glyphFor('A'), font.glyphFor('V')));

    // With nothing to fall back on, nothing is kerned - and nothing fails.
    const alone = try testFont(testing.allocator, &.{.{ .tag = "GPOS", .body = &broken }});
    defer testing.allocator.free(alone);
    const bare: Font = try .init(alone);
    try testing.expectEqual(0, try bare.kern(bare.glyphFor('A'), bare.glyphFor('V')));
    try testing.expectApproxEqAbs(@as(f32, 1000), try bare.at(1000).measure("AV"), 0.001);
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

/// An emoji font in colour from the system, or null: Segoe UI Emoji on
/// Windows - paints, with layers beside them - then Noto Color Emoji in its
/// paint-only form wherever a copy is, then the Linux one.
fn systemColorFont(gpa: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/seguiemj.ttf",
        "C:/Program Files/Android/Android Studio/plugins/design-tools/resources/layoutlib/data/fonts/NotoColorEmoji.ttf",
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(64 << 20)) catch continue;
    }
    return null;
}

/// Whether a picture has colour in it - a pixel that is drawn and is not
/// grey - rather than one shade.
fn isColourful(pixels: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const p = pixels[i..][0..4];
        if (p[3] > 200 and (@max(p[0], p[1], p[2]) - @min(p[0], p[1], p[2])) > 60) return true;
    }
    return false;
}

test "an emoji is drawn in colour, and a letter has no colour form" {
    const bytes = try systemColorFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const font: Font = try .init(bytes);

    const smile = font.glyphFor(0x1F600);
    try testing.expect(smile != cmap.notdef);
    try testing.expect(font.hasColor(smile));

    var picture = (try font.renderColor(testing.allocator, smile, 48, .{})).?;
    defer picture.deinit(testing.allocator);
    // About an em, and coloured.
    try testing.expect(picture.width > 30 and picture.width < 80);
    try testing.expect(picture.height > 30 and picture.height < 80);
    try testing.expect(picture.top > 20);
    try testing.expect(picture.advance > 30);
    try testing.expect(isColourful(picture.pixels));

    // Twice the size is about twice as wide.
    var big = (try font.renderColor(testing.allocator, smile, 96, .{})).?;
    defer big.deinit(testing.allocator);
    try testing.expect(big.width >= picture.width * 2 - 4 and big.width <= picture.width * 2 + 4);

    // A digit is drawn in the font's outline, not in colour.
    const one = font.glyphFor('1');
    if (one != cmap.notdef and !font.hasColor(one)) {
        try testing.expect(try font.renderColor(testing.allocator, one, 48, .{}) == null);
    }
}

test "a font of pictures opens, and its pictures are scaled to the size asked for" {
    // The flags Android draws, kept as pictures: Android Studio carries a
    // copy, and a Linux box with Noto has its own.
    const candidates = [_][]const u8{
        "C:/Program Files/Android/Android Studio/plugins/design-tools/resources/layoutlib/data/fonts/NotoColorEmojiFlags.ttf",
        "/usr/share/fonts/truetype/noto/NotoColorEmojiFlags.ttf",
    };
    const bytes = for (candidates) |path| {
        break std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20)) catch continue;
    } else return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const font: Font = try .init(bytes);
    try testing.expect(font.outlines == null);
    const flag = for (1..font.glyphCount()) |g| {
        if (font.hasColor(@intCast(g))) break @as(u16, @intCast(g));
    } else return error.TestUnexpectedResult;

    // No decoder: no colour form here.
    try testing.expect(try font.renderColor(testing.allocator, flag, 32, .{}) == null);

    // A stand-in decoder: whatever the PNG, a red square 136 pixels across,
    // which is what the strike's pictures measure.
    const Red = struct {
        fn decode(gpa: Allocator, png: []const u8) anyerror!Decoded {
            try testing.expect(std.mem.startsWith(u8, png, "\x89PNG"));
            const pixels = try gpa.alloc(u8, 136 * 128 * 4);
            var i: usize = 0;
            while (i < pixels.len) : (i += 4) pixels[i..][0..4].* = .{ 255, 0, 0, 255 };
            return .{ .pixels = pixels, .width = 136, .height = 128 };
        }
    };
    var picture = (try font.renderColor(testing.allocator, flag, 32, .{ .decode_png = Red.decode })).?;
    defer picture.deinit(testing.allocator);
    // 109 pixels per em in the strike, 32 asked for.
    try testing.expectEqual(@as(u32, 40), picture.width);
    try testing.expectEqual(@as(u32, 38), picture.height);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, picture.pixels[0..4]);
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
