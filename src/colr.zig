// SPDX-License-Identifier: BSD-2-Clause

//! `COLR` and `CPAL`: glyphs drawn in colour, out of the font's own outlines.
//!
//! Two versions of the same idea. **Version 0** says a colour glyph is a
//! stack of ordinary glyphs, each filled with one colour from the palette -
//! a flat, layered picture, which is how most emoji fonts drew until 2021.
//! **Version 1** says it is a small tree of paints: a glyph outline used as a
//! clip, filled with a solid colour or a linear, radial or sweep gradient,
//! moved and turned by transforms, combined by blend modes. Android's Noto
//! Color Emoji is version 1 only; Windows' Segoe UI Emoji carries both, the
//! version 0 layers being the flat fallback for an older renderer.
//!
//! Both are drawn here into RGBA, at a size, with the same rasteriser every
//! other glyph goes through: each outline becomes coverage, the coverage
//! clips a paint, and the paints are composited in premultiplied floating
//! point before the picture comes out as straight-alpha bytes.
//!
//! What is not read: the variation deltas of a variable colour font (a
//! `Var` paint is drawn at its default values), and the four HSL blend modes,
//! which are drawn as plain source-over.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Font = @import("Font.zig");
const outline = @import("outline.zig");
const raster = @import("raster.zig");
const sfnt = @import("sfnt.zig");

const Bounds = outline.Bounds;
const Outline = outline.Outline;
const Point = outline.Point;
const Error = sfnt.Error || Allocator.Error;
const File = sfnt.File;
const View = sfnt.View;

/// The palette index that means "the colour the text is drawn in".
pub const foreground_index: u16 = 0xFFFF;

/// `CPAL`: the colours `COLR` names by number. Only the first palette is
/// used; a font's others are alternatives - a dark theme's - that a caller
/// would have to choose between.
pub const Palette = struct {
    table: View,
    entries: u16,
    first: u16,

    pub fn read(file: File) Error!?Palette {
        const table = try file.table(@enumFromInt(sfnt.tag("CPAL"))) orelse return null;
        if (try table.int(u16, 4) == 0) return null;
        return .{ .table = table, .entries = try table.int(u16, 2), .first = try table.int(u16, 12) };
    }

    /// Colour `index`, straight RGBA, or null past the end of the palette.
    pub fn color(self: Palette, index: u16) Error!?[4]u8 {
        if (index >= self.entries) return null;
        const records = try self.table.int(u32, 8);
        const at = records + (@as(usize, self.first) + index) * 4;
        // Stored blue, green, red, alpha.
        return .{
            try self.table.int(u8, at + 2),
            try self.table.int(u8, at + 1),
            try self.table.int(u8, at),
            try self.table.int(u8, at + 3),
        };
    }
};

pub const Colr = struct {
    table: View,
    version: u16,

    pub fn read(file: File) Error!?Colr {
        const table = try file.table(@enumFromInt(sfnt.tag("COLR"))) orelse return null;
        const version = try table.int(u16, 0);
        if (version > 1) return null;
        return .{ .table = table, .version = version };
    }

    /// Whether the glyph is drawn in colour: it has a paint, or layers.
    pub fn has(self: Colr, glyph: u16) Error!bool {
        return try self.paintOf(glyph) != null or try self.layersOf(glyph) != null;
    }

    /// A version 0 glyph's layers: where in the layer records they start,
    /// and how many.
    fn layersOf(self: Colr, glyph: u16) Error!?struct { first: u16, count: u16 } {
        const t = self.table;
        const count = try t.int(u16, 2);
        const records = try t.int(u32, 4);
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = records + middle * 6;
            const value = try t.int(u16, at);
            if (value < glyph) {
                low = middle + 1;
            } else if (value > glyph) {
                high = middle;
            } else {
                const layers = try t.int(u16, at + 4);
                if (layers == 0) return null;
                return .{ .first = try t.int(u16, at + 2), .count = layers };
            }
        }
        return null;
    }

    /// A version 1 glyph's root paint.
    fn paintOf(self: Colr, glyph: u16) Error!?View {
        if (self.version < 1) return null;
        const t = self.table;
        const list_at = try t.int(u32, 14);
        if (list_at == 0) return null;
        const list = try t.from(list_at);
        const count = try list.int(u32, 0);
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = 4 + middle * 6;
            const value = try list.int(u16, at);
            if (value < glyph) {
                low = middle + 1;
            } else if (value > glyph) {
                high = middle;
            } else return try list.from(try list.int(u32, at + 2));
        }
        return null;
    }

    /// The box a version 1 glyph says it is drawn inside, in font units.
    fn clipOf(self: Colr, glyph: u16) Error!?Bounds {
        if (self.version < 1) return null;
        const t = self.table;
        const list_at = try t.int(u32, 22);
        if (list_at == 0) return null;
        const list = try t.from(list_at);
        const count = try list.int(u32, 1);
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = 5 + middle * 7;
            const first = try list.int(u16, at);
            const last = try list.int(u16, at + 2);
            if (last < glyph) {
                low = middle + 1;
            } else if (first > glyph) {
                high = middle;
            } else {
                const box = try list.from(try list.int(u24, at + 4));
                return .{
                    .min_x = @floatFromInt(try box.int(i16, 1)),
                    .min_y = @floatFromInt(try box.int(i16, 3)),
                    .max_x = @floatFromInt(try box.int(i16, 5)),
                    .max_y = @floatFromInt(try box.int(i16, 7)),
                };
            }
        }
        return null;
    }

    fn layerPaint(self: Colr, index: u32) Error!?View {
        const list_at = try self.table.int(u32, 18);
        if (list_at == 0) return null;
        const list = try self.table.from(list_at);
        if (index >= try list.int(u32, 0)) return null;
        return try list.from(try list.int(u32, 4 + @as(usize, index) * 4));
    }
};

/// A colour glyph, drawn: straight RGBA, four bytes a pixel, top row first.
///
/// A fully transparent pixel carries the colour of the drawn pixels beside
/// it rather than black, so that a texture filter sampling across the edge
/// of the picture blends towards the edge's colour and not towards a dark
/// fringe.
pub const Picture = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// How far right of the pen the picture starts, and how far above the
    /// baseline its top row is.
    left: i32,
    top: i32,

    pub fn deinit(self: *Picture, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// The largest picture drawn, a side. A colour glyph bigger than this is
/// refused rather than allocated: no text is set that large, and a font
/// whose clip box is a mile wide should not take the memory to find out.
pub const max_side: u32 = 1024;

/// Draw a colour glyph at `scale` pixels per font unit. Null when the glyph
/// has no colour form, or it would come out empty or too large.
pub fn render(gpa: Allocator, font: *const Font, colr: Colr, palette: ?Palette, glyph: u16, scale: f32, foreground: [4]u8) (Error || error{TooLarge})!?Picture {
    const root = try colr.paintOf(glyph);
    const layers = if (root == null) try colr.layersOf(glyph) else null;
    if (root == null and layers == null) return null;

    var painter: Painter = .{ .gpa = gpa, .font = font, .colr = colr, .palette = palette, .foreground = premultiplied(foreground) };

    // How big: the glyph's clip box when the font gives one, else what its
    // outlines cover.
    var box: Bounds = .empty;
    if (root) |paint| {
        box = try colr.clipOf(glyph) orelse blk: {
            var found: Bounds = .empty;
            try painter.bounds(paint, Affine.identity, &found, 0);
            break :blk found;
        };
    } else if (layers) |l| {
        for (0..l.count) |k| {
            const layer_glyph = try layerRecord(colr, l.first + k);
            try painter.outlineBounds(layer_glyph.glyph, Affine.identity, &box);
        }
    }
    if (box.isEmpty()) return null;

    const placement: raster.Placement = .init(box, scale);
    if (placement.width == 0 or placement.height == 0) return null;
    if (placement.width > max_side or placement.height > max_side) return error.TooLarge;

    painter.width = placement.width;
    painter.height = placement.height;
    var canvas = try Canvas.init(gpa, placement.width, placement.height);
    defer canvas.deinit(gpa);

    // Font units, y up, to the picture's pixels, y down.
    const base: Affine = .{ .xx = scale, .yx = 0, .xy = 0, .yy = -scale, .dx = placement.offset_x, .dy = placement.offset_y };
    if (root) |paint| {
        try painter.draw(paint, base, &canvas, 0);
    } else if (layers) |l| {
        for (0..l.count) |k| {
            const layer = try layerRecord(colr, l.first + k);
            try painter.drawSolidGlyph(layer.glyph, base, try painter.colorOf(layer.palette, 1), &canvas);
        }
    }

    return .{
        .pixels = try canvas.toStraight(gpa),
        .width = placement.width,
        .height = placement.height,
        .left = placement.left,
        .top = placement.top,
    };
}

fn layerRecord(colr: Colr, index: usize) Error!struct { glyph: u16, palette: u16 } {
    const at = try colr.table.int(u32, 8) + index * 4;
    return .{ .glyph = try colr.table.int(u16, at), .palette = try colr.table.int(u16, at + 2) };
}

/// `x' = xx x + xy y + dx`, `y' = yx x + yy y + dy`.
const Affine = struct {
    xx: f32,
    yx: f32,
    xy: f32,
    yy: f32,
    dx: f32,
    dy: f32,

    const identity: Affine = .{ .xx = 1, .yx = 0, .xy = 0, .yy = 1, .dx = 0, .dy = 0 };

    /// This after `inner`: a point goes through `inner` first.
    fn after(self: Affine, inner: Affine) Affine {
        return .{
            .xx = self.xx * inner.xx + self.xy * inner.yx,
            .yx = self.yx * inner.xx + self.yy * inner.yx,
            .xy = self.xx * inner.xy + self.xy * inner.yy,
            .yy = self.yx * inner.xy + self.yy * inner.yy,
            .dx = self.xx * inner.dx + self.xy * inner.dy + self.dx,
            .dy = self.yx * inner.dx + self.yy * inner.dy + self.dy,
        };
    }

    fn apply(self: Affine, p: Point) Point {
        return .{ .x = self.xx * p.x + self.xy * p.y + self.dx, .y = self.yx * p.x + self.yy * p.y + self.dy };
    }

    fn inverse(self: Affine) ?Affine {
        const det = self.xx * self.yy - self.xy * self.yx;
        if (@abs(det) < 1e-12) return null;
        const xx = self.yy / det;
        const xy = -self.xy / det;
        const yx = -self.yx / det;
        const yy = self.xx / det;
        return .{ .xx = xx, .yx = yx, .xy = xy, .yy = yy, .dx = -(xx * self.dx + xy * self.dy), .dy = -(yx * self.dx + yy * self.dy) };
    }

    fn translate(x: f32, y: f32) Affine {
        return .{ .xx = 1, .yx = 0, .xy = 0, .yy = 1, .dx = x, .dy = y };
    }

    /// `inner` done about a centre rather than the origin.
    fn around(inner: Affine, cx: f32, cy: f32) Affine {
        return translate(cx, cy).after(inner.after(translate(-cx, -cy)));
    }
};

/// Premultiplied colour, in floating point: what the paints are composited
/// in, so that a half-covered edge of a half-transparent layer comes out
/// right.
const Color = [4]f32;

fn premultiplied(c: [4]u8) Color {
    const a = @as(f32, @floatFromInt(c[3])) / 255;
    return .{
        @as(f32, @floatFromInt(c[0])) / 255 * a,
        @as(f32, @floatFromInt(c[1])) / 255 * a,
        @as(f32, @floatFromInt(c[2])) / 255 * a,
        a,
    };
}

const Canvas = struct {
    pixels: []Color,
    width: u32,
    height: u32,

    fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Canvas {
        const pixels = try gpa.alloc(Color, @as(usize, width) * height);
        @memset(pixels, .{ 0, 0, 0, 0 });
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    fn deinit(self: *Canvas, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    /// Straight-alpha bytes, with the colour of the drawn pixels bled into
    /// the transparent ones beside them - twice, so a filter two pixels wide
    /// finds a colour too.
    fn toStraight(self: Canvas, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, self.pixels.len * 4);
        for (self.pixels, 0..) |c, i| {
            const a = std.math.clamp(c[3], 0, 1);
            const px = out[i * 4 ..][0..4];
            if (a <= 0) {
                px.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |k| px[k] = byte(c[k] / a);
            px[3] = byte(a);
        }
        bleed(out, self.width, self.height);
        bleed(out, self.width, self.height);
        return out;
    }
};

fn byte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

/// Give each transparent pixel that touches a coloured one the average
/// colour of its coloured neighbours, still transparent. A pixel coloured
/// this way colours the ones after it in turn.
pub fn bleed(pixels: []u8, width: u32, height: u32) void {
    const w: usize = width;
    const h: usize = height;
    // A transparent pixel is coloured when its colour is not black: a pixel
    // given black stays uncoloured, which costs nothing, black being what it
    // had.
    var coloured: [4]u32 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const px = pixels[(y * w + x) * 4 ..][0..4];
            if (px[3] != 0 or px[0] != 0 or px[1] != 0 or px[2] != 0) continue;
            coloured = .{ 0, 0, 0, 0 };
            var oy: isize = -1;
            while (oy <= 1) : (oy += 1) {
                var ox: isize = -1;
                while (ox <= 1) : (ox += 1) {
                    const nx = @as(isize, @intCast(x)) + ox;
                    const ny = @as(isize, @intCast(y)) + oy;
                    if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                    const n = pixels[(@as(usize, @intCast(ny)) * w + @as(usize, @intCast(nx))) * 4 ..][0..4];
                    if (n[3] == 0 and n[0] == 0 and n[1] == 0 and n[2] == 0) continue;
                    for (0..3) |k| coloured[k] += n[k];
                    coloured[3] += 1;
                }
            }
            if (coloured[3] == 0) continue;
            for (0..3) |k| px[k] = @intCast(coloured[k] / coloured[3]);
        }
    }
}

/// How deep a paint tree may go. A font whose glyphs paint each other in a
/// circle stops here.
const max_depth = 32;

/// Most colour stops a gradient is read with.
const max_stops = 64;

const Painter = struct {
    gpa: Allocator,
    font: *const Font,
    colr: Colr,
    palette: ?Palette,
    foreground: Color,
    width: u32 = 0,
    height: u32 = 0,

    fn colorOf(self: *Painter, index: u16, alpha: f32) Error!Color {
        var c: Color = if (index == foreground_index)
            self.foreground
        else if (self.palette) |palette|
            if (try palette.color(index)) |rgba| premultiplied(rgba) else .{ 0, 0, 0, 0 }
        else
            .{ 0, 0, 0, 1 };
        for (&c) |*channel| channel.* *= std.math.clamp(alpha, 0, 1);
        return c;
    }

    /// Where a glyph's outline lands under `m`, added to `box`.
    fn outlineBounds(self: *Painter, glyph: u16, m: Affine, box: *Bounds) Error!void {
        var shape: Outline = .empty;
        defer shape.deinit(self.gpa);
        try self.font.outlineOf(self.gpa, glyph, &shape);
        if (shape.isEmpty()) return;
        const own = shape.bounds();
        for ([_]Point{
            .{ .x = own.min_x, .y = own.min_y },
            .{ .x = own.max_x, .y = own.min_y },
            .{ .x = own.min_x, .y = own.max_y },
            .{ .x = own.max_x, .y = own.max_y },
        }) |corner| box.include(m.apply(corner));
    }

    /// What a paint tree draws inside, in font units, for a glyph whose font
    /// gives no clip box: every outline in it, where its transforms put it.
    fn bounds(self: *Painter, paint: View, m: Affine, box: *Bounds, depth: u8) Error!void {
        if (depth >= max_depth) return;
        const format = try paint.int(u8, 0);
        switch (format) {
            1 => {
                const count = try paint.int(u8, 1);
                const first = try paint.int(u32, 2);
                for (0..count) |k| {
                    const layer = try self.colr.layerPaint(first + @as(u32, @intCast(k))) orelse continue;
                    try self.bounds(layer, m, box, depth + 1);
                }
            },
            10 => try self.outlineBounds(try paint.int(u16, 4), m, box),
            11 => {
                const glyph = try paint.int(u16, 1);
                const child = try self.colr.paintOf(glyph) orelse return;
                try self.bounds(child, m, box, depth + 1);
            },
            32 => {
                try self.bounds(try paint.from(try paint.int(u24, 1)), m, box, depth + 1);
                try self.bounds(try paint.from(try paint.int(u24, 5)), m, box, depth + 1);
            },
            12...31 => {
                const t = try transformOf(paint, format) orelse return;
                try self.bounds(try paint.from(try paint.int(u24, 1)), m.after(t), box, depth + 1);
            },
            else => {},
        }
    }

    /// Draw a paint over `dst`, source-over.
    fn draw(self: *Painter, paint: View, m: Affine, dst: *Canvas, depth: u8) (Error || error{TooLarge})!void {
        if (depth >= max_depth) return;
        const format = try paint.int(u8, 0);
        switch (format) {
            1 => {
                const count = try paint.int(u8, 1);
                const first = try paint.int(u32, 2);
                for (0..count) |k| {
                    const layer = try self.colr.layerPaint(first + @as(u32, @intCast(k))) orelse continue;
                    try self.draw(layer, m, dst, depth + 1);
                }
            },
            10 => {
                const child = try paint.from(try paint.int(u24, 1));
                const glyph = try paint.int(u16, 4);
                // A solid fill of a shape is the common case, and needs no
                // second canvas.
                const child_format = try child.int(u8, 0);
                if (child_format == 2 or child_format == 3) {
                    const color = try self.colorOf(try child.int(u16, 1), try child.f2dot14(3));
                    return self.drawSolidGlyph(glyph, m, color, dst);
                }
                const mask = try self.coverage(glyph, m) orelse return;
                defer self.gpa.free(mask);
                var layer = try Canvas.init(self.gpa, self.width, self.height);
                defer layer.deinit(self.gpa);
                try self.draw(child, m, &layer, depth + 1);
                for (dst.pixels, layer.pixels, mask) |*d, s, cover| {
                    if (cover == 0) continue;
                    const k = @as(f32, @floatFromInt(cover)) / 255;
                    d.* = over(.{ s[0] * k, s[1] * k, s[2] * k, s[3] * k }, d.*);
                }
            },
            11 => {
                const glyph = try paint.int(u16, 1);
                if (try self.colr.paintOf(glyph)) |child| return self.draw(child, m, dst, depth + 1);
                if (try self.colr.layersOf(glyph)) |l| {
                    for (0..l.count) |k| {
                        const layer = try layerRecord(self.colr, l.first + k);
                        try self.drawSolidGlyph(layer.glyph, m, try self.colorOf(layer.palette, 1), dst);
                    }
                }
            },
            12...31 => {
                const t = try transformOf(paint, format) orelse return;
                try self.draw(try paint.from(try paint.int(u24, 1)), m.after(t), dst, depth + 1);
            },
            32 => {
                var backdrop = try Canvas.init(self.gpa, self.width, self.height);
                defer backdrop.deinit(self.gpa);
                var source = try Canvas.init(self.gpa, self.width, self.height);
                defer source.deinit(self.gpa);
                try self.draw(try paint.from(try paint.int(u24, 5)), m, &backdrop, depth + 1);
                try self.draw(try paint.from(try paint.int(u24, 1)), m, &source, depth + 1);
                const mode = try paint.int(u8, 4);
                for (backdrop.pixels, source.pixels, dst.pixels) |b, s, *d| d.* = over(composite(mode, s, b), d.*);
            },
            2...9 => {
                // A fill with no shape to clip it covers the whole picture.
                const fill = try Fill.read(self, paint, format, m) orelse return;
                for (0..self.height) |y| {
                    for (0..self.width) |x| {
                        const i = y * self.width + x;
                        dst.pixels[i] = over(fill.at(x, y), dst.pixels[i]);
                    }
                }
            },
            else => {},
        }
    }

    fn drawSolidGlyph(self: *Painter, glyph: u16, m: Affine, color: Color, dst: *Canvas) Error!void {
        const mask = try self.coverage(glyph, m) orelse return;
        defer self.gpa.free(mask);
        for (dst.pixels, mask) |*d, cover| {
            if (cover == 0) continue;
            const k = @as(f32, @floatFromInt(cover)) / 255;
            d.* = over(.{ color[0] * k, color[1] * k, color[2] * k, color[3] * k }, d.*);
        }
    }

    /// A glyph's outline under `m`, as coverage the size of the picture.
    fn coverage(self: *Painter, glyph: u16, m: Affine) Error!?[]u8 {
        var shape: Outline = .empty;
        defer shape.deinit(self.gpa);
        try self.font.outlineOf(self.gpa, glyph, &shape);
        if (shape.isEmpty()) return null;
        shape.affine(m.xx, m.yx, m.xy, m.yy, m.dx, m.dy);
        const bitmap = try raster.rasterize(self.gpa, shape, self.width, self.height);
        return bitmap.pixels;
    }
};

/// The transform a transform paint applies to its child, in font units.
fn transformOf(paint: View, format: u8) Error!?Affine {
    const base = format - format % 2;
    const pi = std.math.pi;
    switch (base) {
        12 => {
            const t = try paint.from(try paint.int(u24, 4));
            return .{
                .xx = try fixed(t, 0),
                .yx = try fixed(t, 4),
                .xy = try fixed(t, 8),
                .yy = try fixed(t, 12),
                .dx = try fixed(t, 16),
                .dy = try fixed(t, 20),
            };
        },
        14 => return Affine.translate(try fword(paint, 4), try fword(paint, 6)),
        16, 18 => {
            const s: Affine = .{ .xx = try paint.f2dot14(4), .yx = 0, .xy = 0, .yy = try paint.f2dot14(6), .dx = 0, .dy = 0 };
            return if (base == 18) s.around(try fword(paint, 8), try fword(paint, 10)) else s;
        },
        20, 22 => {
            const k = try paint.f2dot14(4);
            const s: Affine = .{ .xx = k, .yx = 0, .xy = 0, .yy = k, .dx = 0, .dy = 0 };
            return if (base == 22) s.around(try fword(paint, 6), try fword(paint, 8)) else s;
        },
        24, 26 => {
            // Counter-clockwise, half a turn per 1.0.
            const angle = try paint.f2dot14(4) * pi;
            const r: Affine = .{ .xx = @cos(angle), .yx = @sin(angle), .xy = -@sin(angle), .yy = @cos(angle), .dx = 0, .dy = 0 };
            return if (base == 26) r.around(try fword(paint, 6), try fword(paint, 8)) else r;
        },
        28, 30 => {
            const x_skew = try paint.f2dot14(4) * pi;
            const y_skew = try paint.f2dot14(6) * pi;
            const s: Affine = .{ .xx = 1, .yx = @tan(y_skew), .xy = -@tan(x_skew), .yy = 1, .dx = 0, .dy = 0 };
            return if (base == 30) s.around(try fword(paint, 8), try fword(paint, 10)) else s;
        },
        else => return null,
    }
}

fn fixed(view: View, at: usize) Error!f32 {
    return @as(f32, @floatFromInt(try view.int(i32, at))) / 65536;
}

fn fword(view: View, at: usize) Error!f32 {
    return @floatFromInt(try view.int(i16, at));
}

/// A solid colour or a gradient, ready to be asked for its colour at a
/// pixel.
const Fill = struct {
    kind: enum { solid, linear, radial, sweep },
    solid: Color = .{ 0, 0, 0, 0 },
    /// From the picture's pixels back to font units.
    back: Affine = Affine.identity,
    stops: [max_stops]Stop = undefined,
    stop_count: usize = 0,
    extend: u8 = 0,
    // Linear: the start and the direction, already projected.
    p0: Point = .zero,
    along: Point = .zero,
    // Radial: two circles.
    c0: Point = .zero,
    r0: f32 = 0,
    c1: Point = .zero,
    r1: f32 = 0,
    // Sweep: the centre and the angles, in degrees.
    start: f32 = 0,
    end: f32 = 0,

    const Stop = struct { offset: f32, color: [4]f32 };

    fn read(painter: *Painter, paint: View, format: u8, m: Affine) Error!?Fill {
        const variable = format % 2 == 1;
        const base = format - format % 2;
        if (base == 2) return .{ .kind = .solid, .solid = try painter.colorOf(try paint.int(u16, 1), try paint.f2dot14(3)) };

        var fill: Fill = .{ .kind = .linear, .back = m.inverse() orelse return null };
        const line = try paint.from(try paint.int(u24, 1));
        fill.extend = try line.int(u8, 0);
        const count = @min(try line.int(u16, 1), max_stops);
        const stride: usize = if (variable) 10 else 6;
        for (0..count) |k| {
            const stop = 3 + k * stride;
            const index = try line.int(u16, stop + 2);
            const alpha = try line.f2dot14(stop + 4);
            // Interpolated straight, premultiplied afterwards.
            var straight: [4]f32 = .{ 0, 0, 0, 0 };
            if (index == foreground_index) {
                const f = painter.foreground;
                if (f[3] > 0) straight = .{ f[0] / f[3], f[1] / f[3], f[2] / f[3], f[3] };
            } else if (painter.palette) |palette| {
                if (try palette.color(index)) |c| {
                    straight = .{ @as(f32, @floatFromInt(c[0])) / 255, @as(f32, @floatFromInt(c[1])) / 255, @as(f32, @floatFromInt(c[2])) / 255, @as(f32, @floatFromInt(c[3])) / 255 };
                }
            }
            straight[3] *= std.math.clamp(alpha, 0, 1);
            fill.stops[k] = .{ .offset = try line.f2dot14(stop), .color = straight };
        }
        if (count == 0) return null;
        fill.stop_count = count;
        std.mem.sort(Stop, fill.stops[0..count], {}, struct {
            fn less(_: void, a: Stop, b: Stop) bool {
                return a.offset < b.offset;
            }
        }.less);

        switch (base) {
            4 => {
                const p0: Point = .{ .x = try fword(paint, 4), .y = try fword(paint, 6) };
                const p1: Point = .{ .x = try fword(paint, 8), .y = try fword(paint, 10) };
                const p2: Point = .{ .x = try fword(paint, 12), .y = try fword(paint, 14) };
                // The colour runs from p0 towards p1, measured along the
                // normal of p0 to p2: p1 projected onto it.
                const d = Point{ .x = p1.x - p0.x, .y = p1.y - p0.y };
                const n = Point{ .x = -(p2.y - p0.y), .y = p2.x - p0.x };
                const nn = n.x * n.x + n.y * n.y;
                fill.along = if (nn == 0) d else blk: {
                    const k = (d.x * n.x + d.y * n.y) / nn;
                    break :blk .{ .x = n.x * k, .y = n.y * k };
                };
                fill.p0 = p0;
            },
            6 => {
                fill.kind = .radial;
                fill.c0 = .{ .x = try fword(paint, 4), .y = try fword(paint, 6) };
                fill.r0 = @floatFromInt(try paint.int(u16, 8));
                fill.c1 = .{ .x = try fword(paint, 10), .y = try fword(paint, 12) };
                fill.r1 = @floatFromInt(try paint.int(u16, 14));
            },
            8 => {
                fill.kind = .sweep;
                fill.c0 = .{ .x = try fword(paint, 4), .y = try fword(paint, 6) };
                fill.start = try paint.f2dot14(8) * 180;
                fill.end = try paint.f2dot14(10) * 180;
            },
            else => return null,
        }
        return fill;
    }

    fn at(self: Fill, x: usize, y: usize) Color {
        if (self.kind == .solid) return self.solid;
        const p = self.back.apply(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 });
        const t: f32 = switch (self.kind) {
            .solid => unreachable,
            .linear => blk: {
                const ll = self.along.x * self.along.x + self.along.y * self.along.y;
                if (ll == 0) break :blk 0;
                break :blk ((p.x - self.p0.x) * self.along.x + (p.y - self.p0.y) * self.along.y) / ll;
            },
            .radial => self.radialAt(p) orelse return .{ 0, 0, 0, 0 },
            .sweep => blk: {
                var angle = std.math.radiansToDegrees(std.math.atan2(p.y - self.c0.y, p.x - self.c0.x));
                if (angle < 0) angle += 360;
                const span = self.end - self.start;
                if (span == 0) break :blk 0;
                break :blk (angle - self.start) / span;
            },
        };
        return self.colorAt(t);
    }

    /// The largest t whose circle passes through `p` with a radius that is
    /// not negative: the two-point conical gradient.
    fn radialAt(self: Fill, p: Point) ?f32 {
        const cd = Point{ .x = self.c1.x - self.c0.x, .y = self.c1.y - self.c0.y };
        const pd = Point{ .x = p.x - self.c0.x, .y = p.y - self.c0.y };
        const dr = self.r1 - self.r0;
        const a = cd.x * cd.x + cd.y * cd.y - dr * dr;
        const b = pd.x * cd.x + pd.y * cd.y + self.r0 * dr;
        const c = pd.x * pd.x + pd.y * pd.y - self.r0 * self.r0;
        if (@abs(a) < 1e-6) {
            if (b == 0) return null;
            const t = c / (2 * b);
            return if (self.r0 + t * dr >= 0) t else null;
        }
        const disc = b * b - a * c;
        if (disc < 0) return null;
        const root = @sqrt(disc);
        const high = @max((b + root) / a, (b - root) / a);
        const low = @min((b + root) / a, (b - root) / a);
        if (self.r0 + high * dr >= 0) return high;
        if (self.r0 + low * dr >= 0) return low;
        return null;
    }

    fn colorAt(self: Fill, raw: f32) Color {
        const stops = self.stops[0..self.stop_count];
        const first = stops[0].offset;
        const last = stops[stops.len - 1].offset;
        const range = last - first;
        var t = raw;
        if (range > 0) switch (self.extend) {
            1 => t = first + @mod(t - first, range),
            2 => {
                const u = @mod(t - first, 2 * range);
                t = first + if (u > range) 2 * range - u else u;
            },
            else => {},
        };
        t = std.math.clamp(t, first, last);

        var straight = stops[stops.len - 1].color;
        for (stops[0 .. stops.len - 1], stops[1..]) |a, b| {
            if (t > b.offset) continue;
            const span = b.offset - a.offset;
            const k = if (span <= 0) 1 else (t - a.offset) / span;
            for (0..4) |c| straight[c] = a.color[c] + (b.color[c] - a.color[c]) * k;
            break;
        }
        return .{ straight[0] * straight[3], straight[1] * straight[3], straight[2] * straight[3], straight[3] };
    }
};

/// Source over destination, premultiplied.
fn over(s: Color, d: Color) Color {
    const keep = 1 - s[3];
    return .{ s[0] + d[0] * keep, s[1] + d[1] * keep, s[2] + d[2] * keep, s[3] + d[3] * keep };
}

/// `PaintComposite`'s modes, premultiplied. The HSL ones are drawn as
/// source-over.
fn composite(mode: u8, s: Color, d: Color) Color {
    const sa = s[3];
    const da = d[3];
    return switch (mode) {
        0 => .{ 0, 0, 0, 0 },
        1 => s,
        2 => d,
        4 => over(d, s),
        5 => scaled(s, da),
        6 => scaled(d, sa),
        7 => scaled(s, 1 - da),
        8 => scaled(d, 1 - sa),
        9 => add(scaled(s, da), scaled(d, 1 - sa)),
        10 => add(scaled(d, sa), scaled(s, 1 - da)),
        11 => add(scaled(s, 1 - da), scaled(d, 1 - sa)),
        12 => .{ @min(1, s[0] + d[0]), @min(1, s[1] + d[1]), @min(1, s[2] + d[2]), @min(1, sa + da) },
        13...23 => blended(mode, s, d),
        else => over(s, d),
    };
}

fn scaled(c: Color, k: f32) Color {
    return .{ c[0] * k, c[1] * k, c[2] * k, c[3] * k };
}

fn add(a: Color, b: Color) Color {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

/// A separable blend mode: the two colours mixed channel by channel where
/// both are there, each kept as it is where only it is.
fn blended(mode: u8, s: Color, d: Color) Color {
    const sa = s[3];
    const da = d[3];
    var out: Color = undefined;
    for (0..3) |k| {
        const cs = if (sa > 0) s[k] / sa else 0;
        const cd = if (da > 0) d[k] / da else 0;
        const b: f32 = switch (mode) {
            13 => cs + cd - cs * cd,
            14 => hardLight(cd, cs),
            15 => @min(cs, cd),
            16 => @max(cs, cd),
            17 => if (cd <= 0) 0 else if (cs >= 1) 1 else @min(1, cd / (1 - cs)),
            18 => if (cd >= 1) 1 else if (cs <= 0) 0 else 1 - @min(1, (1 - cd) / cs),
            19 => hardLight(cs, cd),
            20 => softLight(cs, cd),
            21 => @abs(cs - cd),
            22 => cs + cd - 2 * cs * cd,
            23 => cs * cd,
            else => cs,
        };
        out[k] = s[k] * (1 - da) + d[k] * (1 - sa) + sa * da * b;
    }
    out[3] = sa + da - sa * da;
    return out;
}

fn hardLight(cs: f32, cd: f32) f32 {
    if (cs <= 0.5) return cd * 2 * cs;
    const k = 2 * cs - 1;
    return cd + k - cd * k;
}

fn softLight(cs: f32, cd: f32) f32 {
    if (cs <= 0.5) return cd - (1 - 2 * cs) * cd * (1 - cd);
    const dd = if (cd <= 0.25) ((16 * cd - 12) * cd + 4) * cd else @sqrt(cd);
    return cd + (2 * cs - 1) * (dd - cd);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "source over keeps what is under a transparent pixel" {
    const red: Color = .{ 1, 0, 0, 1 };
    const half_blue: Color = .{ 0, 0, 0.5, 0.5 };
    try testing.expectEqual(red, over(.{ 0, 0, 0, 0 }, red));
    const mixed = over(half_blue, red);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mixed[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mixed[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), mixed[3], 1e-6);
}

test "a transform after another applies the inner one first" {
    const move = Affine.translate(10, 0);
    const twice: Affine = .{ .xx = 2, .yx = 0, .xy = 0, .yy = 2, .dx = 0, .dy = 0 };
    const p = twice.after(move).apply(.{ .x = 1, .y = 1 });
    try testing.expectEqual(@as(f32, 22), p.x);
    try testing.expectEqual(@as(f32, 2), p.y);
    const back = twice.after(move).inverse().?.apply(p);
    try testing.expectApproxEqAbs(@as(f32, 1), back.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), back.y, 1e-5);
}

test "a gradient pads, repeats and reflects past its last stop" {
    var fill: Fill = .{ .kind = .linear };
    fill.stops[0] = .{ .offset = 0, .color = .{ 0, 0, 0, 1 } };
    fill.stops[1] = .{ .offset = 1, .color = .{ 1, 1, 1, 1 } };
    fill.stop_count = 2;

    try testing.expectApproxEqAbs(@as(f32, 0.25), fill.colorAt(0.25)[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), fill.colorAt(1.25)[0], 1e-5);
    fill.extend = 1;
    try testing.expectApproxEqAbs(@as(f32, 0.25), fill.colorAt(1.25)[0], 1e-5);
    fill.extend = 2;
    try testing.expectApproxEqAbs(@as(f32, 0.75), fill.colorAt(1.25)[0], 1e-5);
}

test "a two-circle gradient finds the circle a point is on" {
    // Concentric: radius 0 at t = 0, radius 100 at t = 1.
    const fill: Fill = .{ .kind = .radial, .c0 = .zero, .r0 = 0, .c1 = .zero, .r1 = 100 };
    try testing.expectApproxEqAbs(@as(f32, 0.5), fill.radialAt(.{ .x = 50, .y = 0 }).?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.3), fill.radialAt(.{ .x = 0, .y = -30 }).?, 1e-4);
}

test "transparent pixels take the colour beside them, and stay transparent" {
    var pixels = [_]u8{
        200, 10, 10, 255, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    bleed(&pixels, 3, 1);
    try testing.expectEqualSlices(u8, &.{ 200, 10, 10, 255 }, pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 200, 10, 10, 0 }, pixels[4..8]);
    try testing.expectEqualSlices(u8, &.{ 200, 10, 10, 0 }, pixels[8..12]);
}
