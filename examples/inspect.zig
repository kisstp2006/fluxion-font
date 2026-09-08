// SPDX-License-Identifier: BSD-2-Clause

//! Open a font, say what is in it, and draw a line of text as characters.
//!
//! ```bash
//! zig build example
//! zig build example -- C:/Windows/Fonts/consola.ttf "Fluxion" 28
//! ```
//!
//! The drawing is the interesting part. A rasterised glyph is one byte of
//! coverage per pixel, and a terminal is a grid of characters, so printing
//! the two against each other is a complete renderer in nine lines - and it
//! proves the whole path works without a GPU, a window, or a way to look at a
//! PNG. When the shapes below look like the letters they are supposed to be,
//! every piece of the library did its job.

const std = @import("std");
const font = @import("fluxion_font");

/// Coverage, as characters, from nothing to solid. A ramp rather than a
/// threshold, because a threshold would hide exactly the thing worth seeing:
/// whether the edges are being antialiased or stepped.
const ramp = " .:-=+*#%@";

fn shade(coverage: u8) u8 {
    const index = (@as(usize, coverage) * (ramp.len - 1)) / 255;
    return ramp[index];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var out_buffer: [1 << 16]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const w = &stdout.interface;

    // Everything after the program name: a font, some text and a size, each
    // optional so that `zig build example` on its own still draws something.
    const arguments = try init.minimal.args.toSlice(gpa);
    const path = if (arguments.len > 1) arguments[1] else defaultFont();
    const text = if (arguments.len > 2) arguments[2] else "Fluxion Font";
    const size: f32 = if (arguments.len > 3)
        std.fmt.parseFloat(f32, arguments[3]) catch 24
    else
        24;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(32 << 20));

    const file = try font.sfnt.File.init(bytes);
    const head = try font.tables.Head.read(file);
    const hhea = try font.tables.Hhea.read(file);
    const maxp = try font.tables.Maxp.read(file);
    const hmtx = try font.tables.Hmtx.read(file);
    const characters = try font.cmap.Cmap.read(file);

    try w.print("{s}\n", .{path});
    try w.print("  {d} glyphs, em square {d} units\n", .{ maxp.glyph_count, head.units_per_em });
    try w.print("  ascender {d}, descender {d}, line {d} units\n", .{
        hhea.ascender,
        hhea.descender,
        hhea.lineHeight(),
    });
    try w.print("  character map format {d}{s}\n", .{
        characters.format,
        if (characters.symbol) ", symbol" else "",
    });

    var entries: [64]font.sfnt.Entry = undefined;
    const tables = try file.entries(&entries);
    try w.print("  tables:", .{});
    for (tables) |entry| try w.print(" {f}", .{entry.tag});
    try w.print("\n\n", .{});

    try drawLine(gpa, w, file, head, hmtx, characters, text, size);
    try w.flush();
}

/// Rasterise a run of text and print it, one row of pixels per line.
///
/// The glyphs are drawn into one buffer at the right places rather than one
/// after another, because that is what a real renderer does and it is what
/// makes the kerning and the bearings visible: a letter that sat a pixel too
/// far right would be obvious here.
fn drawLine(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    file: font.sfnt.File,
    head: font.tables.Head,
    hmtx: font.tables.Hmtx,
    characters: font.cmap.Cmap,
    text: []const u8,
    size: f32,
) !void {
    const scale = size / @as(f32, @floatFromInt(head.units_per_em));

    // How wide the whole line is, so the canvas can be allocated once.
    var width: f32 = 0;
    var counting = (try std.unicode.Utf8View.init(text)).iterator();
    while (counting.nextCodepoint()) |codepoint| {
        width += @as(f32, @floatFromInt(try hmtx.advance(characters.lookup(codepoint)))) * scale;
    }

    const hhea = try font.tables.Hhea.read(file);
    const ascent = @as(f32, @floatFromInt(hhea.ascender)) * scale;
    const canvas_w: u32 = @intFromFloat(@ceil(width) + 2);
    const canvas_h: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(hhea.lineHeight())) * scale) + 2);

    const canvas = try gpa.alloc(u8, canvas_w * canvas_h);
    @memset(canvas, 0);

    var shape: font.outline.Outline = .empty;
    defer shape.deinit(gpa);

    var pen_x: f32 = 1;
    var letters = (try std.unicode.Utf8View.init(text)).iterator();
    while (letters.nextCodepoint()) |codepoint| {
        const glyph = characters.lookup(codepoint);

        try font.glyf.read(gpa, file, glyph, &shape);
        if (!shape.isEmpty()) {
            const place: font.raster.Placement = .init(shape.bounds(), scale);
            place.apply(&shape);

            var bitmap = try font.raster.rasterize(gpa, shape, place.width, place.height);
            defer bitmap.deinit(gpa);

            // Where the glyph goes: right of the pen by its left bearing,
            // and down from the top by the baseline less its own height.
            const x0: i32 = @as(i32, @intFromFloat(pen_x)) + place.left;
            const y0: i32 = @as(i32, @intFromFloat(ascent)) - place.top + 1;

            for (0..bitmap.height) |row| {
                const y = y0 + @as(i32, @intCast(row));
                if (y < 0 or y >= canvas_h) continue;
                for (0..bitmap.width) |column| {
                    const x = x0 + @as(i32, @intCast(column));
                    if (x < 0 or x >= canvas_w) continue;
                    const target = &canvas[@as(usize, @intCast(y)) * canvas_w + @as(usize, @intCast(x))];
                    target.* = @max(target.*, bitmap.at(@intCast(column), @intCast(row)));
                }
            }
        }

        pen_x += @as(f32, @floatFromInt(try hmtx.advance(glyph))) * scale;
    }

    for (0..canvas_h) |y| {
        for (0..canvas_w) |x| try w.print("{c}", .{shade(canvas[y * canvas_w + x])});
        try w.print("\n", .{});
    }
}

/// A font this machine is likely to have, so `zig build example` with no
/// arguments draws something.
///
/// Not checked for existence here - the read that follows reports a missing
/// file better than a guess would, and with the path in the message.
fn defaultFont() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/consola.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// A font from the system, or null. The unit tests inside the library build
/// their own fixtures and check the parsing exactly; these check the other
/// half - that a font somebody else made, full of the things real fonts do,
/// comes out as the letters it should.
fn systemFont(gpa: std.mem.Allocator) !?[]u8 {
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

/// How many separate runs of ink there are across one row.
///
/// The shape-independent way to ask what a letter looks like: an `H` near its
/// top is two runs and at its crossbar is one, an `o` is two everywhere but
/// the very top and bottom, and an `l` is one. Counting runs survives a font
/// whose stems are thin, a size that rounds differently, and a glyph that is
/// wider or narrower than expected - none of which a fixed sample column
/// survives.
fn inkRuns(bitmap: font.raster.Bitmap, row: u32) usize {
    var runs: usize = 0;
    var inside = false;
    for (0..bitmap.width) |x| {
        const inked = bitmap.at(@intCast(x), row) > 128;
        if (inked and !inside) runs += 1;
        inside = inked;
    }
    return runs;
}

test "a real font opens, and its numbers are the ones a font has" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const head = try font.tables.Head.read(file);
    const hhea = try font.tables.Hhea.read(file);
    const maxp = try font.tables.Maxp.read(file);

    try testing.expect(head.units_per_em >= 16);
    try testing.expect(maxp.glyph_count > 100);
    // Up is positive and down is negative. A font that got this backwards
    // would draw every line on top of the one before it.
    try testing.expect(hhea.ascender > 0);
    try testing.expect(hhea.descender < 0);
    try testing.expect(hhea.lineHeight() > head.units_per_em / 2);
}

test "a real font finds the letters it obviously has" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const characters = try font.cmap.Cmap.read(file);

    for ("ABCabc0123 .,") |character| {
        try testing.expect(characters.lookup(character) != font.notdef);
    }

    // The same letter twice is the same glyph and two letters are not, which
    // is the cheapest check that the map is being read rather than invented.
    const a = characters.lookup('a');
    try testing.expectEqual(a, characters.lookup('a'));
    try testing.expect(a != characters.lookup('b'));

    // A codepoint nothing has is notdef, and that is an answer rather than
    // an error.
    try testing.expectEqual(font.notdef, characters.lookup(0x10FFFD));
}

test "a real capital H has two uprights and a gap between them" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const head = try font.tables.Head.read(file);
    const characters = try font.cmap.Cmap.read(file);

    var shape: font.outline.Outline = .empty;
    defer shape.deinit(testing.allocator);
    try font.glyf.read(testing.allocator, file, characters.lookup('H'), &shape);
    try testing.expect(!shape.isEmpty());

    const scale = 64.0 / @as(f32, @floatFromInt(head.units_per_em));
    const place: font.raster.Placement = .init(shape.bounds(), scale);
    place.apply(&shape);

    var bitmap = try font.raster.rasterize(testing.allocator, shape, place.width, place.height);
    defer bitmap.deinit(testing.allocator);

    try testing.expect(bitmap.width > 10 and bitmap.width < 80);
    try testing.expect(bitmap.height > 30 and bitmap.height < 80);

    // An H is two uprights near the top and one solid band at the crossbar,
    // which is true of an H in every font and of almost nothing else. Counted
    // as runs of ink rather than sampled at fixed columns: a stem is two or
    // three pixels wide at this size, and a quarter of the way across lands
    // in the gap in a narrow font and on the stem in a wide one.
    try testing.expectEqual(2, inkRuns(bitmap, 2));
    try testing.expectEqual(1, inkRuns(bitmap, bitmap.height / 2));
}

test "a real lowercase o is a ring with a hole in it" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const head = try font.tables.Head.read(file);
    const characters = try font.cmap.Cmap.read(file);

    var shape: font.outline.Outline = .empty;
    defer shape.deinit(testing.allocator);
    try font.glyf.read(testing.allocator, file, characters.lookup('o'), &shape);

    // Two contours: the outside and the inside.
    try testing.expectEqual(2, shape.contourCount());

    const scale = 48.0 / @as(f32, @floatFromInt(head.units_per_em));
    const place: font.raster.Placement = .init(shape.bounds(), scale);
    place.apply(&shape);

    var bitmap = try font.raster.rasterize(testing.allocator, shape, place.width, place.height);
    defer bitmap.deinit(testing.allocator);

    // The middle is empty and the sides are not - which is the winding rule
    // working, and the single most visible thing the rasteriser can get
    // wrong.
    try testing.expect(bitmap.at(bitmap.width / 2, bitmap.height / 2) < 100);
    try testing.expect(bitmap.at(1, bitmap.height / 2) > 100 or bitmap.at(2, bitmap.height / 2) > 100);
}

test "a real space has an advance and no pixels" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const hmtx = try font.tables.Hmtx.read(file);
    const characters = try font.cmap.Cmap.read(file);

    const space = characters.lookup(' ');
    try testing.expect(try hmtx.advance(space) > 0);

    var shape: font.outline.Outline = .empty;
    defer shape.deinit(testing.allocator);
    try font.glyf.read(testing.allocator, file, space, &shape);
    try testing.expect(shape.isEmpty());
}

test "every glyph in a real font reads without a bounds error" {
    // The broadest test in the library: walk the whole font and read every
    // outline. A font has thousands of glyphs, several of them composite,
    // some of them empty, and any offset arithmetic that is wrong anywhere
    // shows up here as an error rather than as a letter nobody looks at.
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const file = try font.sfnt.File.init(bytes);
    const maxp = try font.tables.Maxp.read(file);
    const table: font.glyf.Glyf = try .read(file);

    var shape: font.outline.Outline = .empty;
    defer shape.deinit(testing.allocator);

    var drawn: usize = 0;
    for (0..maxp.glyph_count) |i| {
        try table.outlineOf(testing.allocator, @intCast(i), &shape);
        if (!shape.isEmpty()) drawn += 1;
    }

    // And most of them had something in them, which says the loop was
    // reading outlines rather than quietly finding nothing.
    try testing.expect(drawn > maxp.glyph_count / 2);
}
