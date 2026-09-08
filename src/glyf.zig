// SPDX-License-Identifier: BSD-2-Clause

//! `glyf` and `loca`: the shapes themselves.
//!
//! `loca` says where in `glyf` each glyph starts, and `glyf` holds the
//! outlines. Two kinds of glyph live there:
//!
//!   * A **simple** glyph is a ring of points per contour, each marked
//!     on-curve or off-curve, stored as deltas in as few bits as they fit
//!     into. Compact, and the compactness is where the work is.
//!   * A **composite** glyph is other glyphs, each placed under a transform.
//!     An `ä` is an `a` and a dieresis; a font that has a hundred accented
//!     letters stores four outlines and ninety-six recipes.
//!
//! Both come out as an `outline.Outline` and the caller cannot tell which it
//! got, which is the point.
//!
//! Three things in this file are where a reader goes wrong, and each has the
//! test that catches it:
//!
//!   1. **A contour need not start on the curve.** An `o` is a ring of four
//!      control points with no on-curve point anywhere, and the first point
//!      of the contour has to be invented halfway between two of them.
//!   2. **`X_SAME_OR_POSITIVE` means two different things** depending on
//!      whether `X_SHORT_VECTOR` is set beside it: the sign of a byte, or
//!      that the coordinate did not change at all.
//!   3. **A glyph with no outline is normal.** A space has an advance width
//!      and an empty entry in `loca`, and treating that as an error rejects
//!      every font ever made.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const outline = @import("outline.zig");
const sfnt = @import("sfnt.zig");
const tables = @import("tables.zig");

const Error = sfnt.Error || Allocator.Error;
const File = sfnt.File;
const Outline = outline.Outline;
const Point = outline.Point;
const View = sfnt.View;

/// Read a glyph's shape out of a font, in font units.
///
/// The whole path from a file to a shape, in one call: `head` says how to
/// read `loca`, `loca` says where the glyph is in `glyf`, and `glyf` says
/// what it looks like. Re-reading those two small tables per glyph costs a
/// handful of bounds-checked integers against the cost of rasterising, and
/// buys a caller that does not have to hold three things to ask for one.
///
/// A caller filling an atlas with a whole font wants `Glyf.read` instead,
/// which does the same after being told the tables once.
pub fn read(gpa: Allocator, file: File, glyph: u16, out: *Outline) Error!void {
    const table: Glyf = try .read(file);
    return table.outlineOf(gpa, glyph, out);
}

/// How deep a composite glyph may reach before this gives up.
///
/// The specification suggests implementations support at least five levels,
/// and real fonts rarely go past two. The cap is here because a glyph that
/// refers to itself - by accident or on purpose - would otherwise recurse
/// until the stack ran out.
pub const max_composite_depth = 8;

/// The point flags, as the file spells them.
const Flag = struct {
    const on_curve: u8 = 0x01;
    const x_short: u8 = 0x02;
    const y_short: u8 = 0x04;
    const repeat: u8 = 0x08;
    /// With `x_short`: the byte is positive. Without it: x did not change.
    const x_same_or_positive: u8 = 0x10;
    const y_same_or_positive: u8 = 0x20;
};

/// The composite component flags.
const Component = struct {
    const args_are_words: u16 = 0x0001;
    const args_are_xy: u16 = 0x0002;
    const have_scale: u16 = 0x0008;
    const more: u16 = 0x0020;
    const have_xy_scale: u16 = 0x0040;
    const have_two_by_two: u16 = 0x0080;
    /// Hinting bytecode follows the components. Not run here; named so that
    /// a reader of this file is not left wondering what bit 8 is.
    const have_instructions: u16 = 0x0100;
};

comptime {
    // Referenced so the declaration is not dead; see `readComposite`.
    _ = Component.have_instructions;
}

/// The outlines of a font, and the index that finds one.
pub const Glyf = struct {
    glyf: View,
    loca: View,
    /// From `head`. Whether `loca` holds four-byte offsets or two-byte ones
    /// that have been halved.
    long_loca: bool,
    glyph_count: u16,

    /// Find the two tables a glyph outline needs.
    pub fn read(file: File) Error!Glyf {
        const head = try tables.Head.read(file);
        const maxp = try tables.Maxp.read(file);
        return .{
            .glyf = try file.required(.glyf),
            .loca = try file.required(.loca),
            .long_loca = head.long_loca,
            .glyph_count = maxp.glyph_count,
        };
    }

    /// Where a glyph's data is in `glyf`, or null if it has no outline.
    ///
    /// An entry whose start equals its end is a glyph with nothing to draw -
    /// a space, a control character, or a glyph the font defines only so that
    /// the indices line up. That is not an error, and this answers null for
    /// it rather than an empty range, so the caller has one thing to check
    /// instead of two.
    pub fn locate(self: Glyf, glyph: u16) Error!?struct { start: u32, end: u32 } {
        if (glyph >= self.glyph_count) return null;

        const start: u32, const end: u32 = if (self.long_loca) .{
            try self.loca.int(u32, @as(usize, glyph) * 4),
            try self.loca.int(u32, @as(usize, glyph) * 4 + 4),
        } else .{
            // The short form stores half the offset, because every glyph
            // begins on an even byte and storing the low bit would waste it.
            @as(u32, try self.loca.int(u16, @as(usize, glyph) * 2)) * 2,
            @as(u32, try self.loca.int(u16, @as(usize, glyph) * 2 + 2)) * 2,
        };

        if (end <= start) return null;
        return .{ .start = start, .end = end };
    }

    /// Read a glyph's shape into `out`, in font units.
    ///
    /// `out` is cleared first. It is a parameter rather than a return value
    /// so that a caller filling an atlas can reuse one allocation for every
    /// glyph in the font instead of making and freeing a few thousand.
    pub fn outlineOf(self: Glyf, gpa: Allocator, glyph: u16, out: *Outline) Error!void {
        out.clear();
        try self.readInto(gpa, glyph, out, 0);
    }

    fn readInto(self: Glyf, gpa: Allocator, glyph: u16, out: *Outline, depth: u8) Error!void {
        if (depth > max_composite_depth) return error.Malformed;

        const where = try self.locate(glyph) orelse return;
        const data = try self.glyf.slice(where.start, where.end - where.start);
        if (data.len() < 10) return error.Malformed;

        const contours = try data.int(i16, 0);
        if (contours >= 0) {
            try readSimple(gpa, data, @intCast(contours), out);
        } else {
            try self.readComposite(gpa, data, out, depth);
        }
    }

    fn readComposite(self: Glyf, gpa: Allocator, data: View, out: *Outline, depth: u8) Error!void {
        var part: Outline = .{};
        defer part.deinit(gpa);

        var at = data.cursor(10);
        while (true) {
            const flags = try at.int(u16);
            const index = try at.int(u16);

            // The two arguments are either a displacement or a pair of point
            // numbers to line up. Point matching is vanishingly rare and not
            // done here; the offset is taken as zero so the part at least
            // lands somewhere sensible rather than not at all.
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & Component.args_are_words != 0) {
                const a = try at.int(i16);
                const b = try at.int(i16);
                if (flags & Component.args_are_xy != 0) {
                    dx = @floatFromInt(a);
                    dy = @floatFromInt(b);
                }
            } else {
                const a = try at.int(i8);
                const b = try at.int(i8);
                if (flags & Component.args_are_xy != 0) {
                    dx = @floatFromInt(a);
                    dy = @floatFromInt(b);
                }
            }

            // The transform, in the order the file writes it.
            var xx: f32 = 1;
            var xy: f32 = 0;
            var yx: f32 = 0;
            var yy: f32 = 1;
            if (flags & Component.have_scale != 0) {
                xx = try readF2Dot14(&at);
                yy = xx;
            } else if (flags & Component.have_xy_scale != 0) {
                xx = try readF2Dot14(&at);
                yy = try readF2Dot14(&at);
            } else if (flags & Component.have_two_by_two != 0) {
                xx = try readF2Dot14(&at);
                xy = try readF2Dot14(&at);
                yx = try readF2Dot14(&at);
                yy = try readF2Dot14(&at);
            }

            part.clear();
            try self.readInto(gpa, index, &part, depth + 1);
            part.affine(xx, xy, yx, yy, dx, dy);
            try out.append(gpa, part);

            if (flags & Component.more == 0) break;
        }

        // Instructions may follow the last component. They are hinting
        // bytecode, which this library does not run - see the note in `Font`
        // about hinting - so there is nothing left to read.
    }
};

fn readF2Dot14(at: *sfnt.Cursor) Error!f32 {
    const raw = try at.int(i16);
    return @as(f32, @floatFromInt(raw)) / 16384.0;
}

/// One point of a simple glyph, as read out of the parallel arrays.
const Vertex = struct {
    x: f32,
    y: f32,
    on_curve: bool,
};

fn readSimple(gpa: Allocator, data: View, contour_count: u16, out: *Outline) Error!void {
    if (contour_count == 0) return;

    // The last index of each contour, so the last of the last is how many
    // points there are altogether.
    const ends_at: usize = 10;
    const point_count: usize = @as(usize, try data.int(u16, ends_at + (contour_count - 1) * 2)) + 1;

    const instruction_length = try data.int(u16, ends_at + @as(usize, contour_count) * 2);
    var at = data.cursor(ends_at + @as(usize, contour_count) * 2 + 2 + instruction_length);

    // Flags, expanded past their repeat counts. A stack buffer for the
    // common case and the heap for a glyph with more points than any Latin
    // letter has - which is most CJK ideographs.
    var inline_flags: [256]u8 = undefined;
    const flags = if (point_count <= inline_flags.len)
        inline_flags[0..point_count]
    else
        try gpa.alloc(u8, point_count);
    defer if (point_count > inline_flags.len) gpa.free(flags);

    {
        var i: usize = 0;
        while (i < point_count) {
            const flag = try at.int(u8);
            flags[i] = flag;
            i += 1;

            if (flag & Flag.repeat != 0) {
                var times = try at.int(u8);
                while (times > 0 and i < point_count) : (times -= 1) {
                    flags[i] = flag;
                    i += 1;
                }
            }
        }
    }

    var inline_points: [256]Vertex = undefined;
    const points = if (point_count <= inline_points.len)
        inline_points[0..point_count]
    else
        try gpa.alloc(Vertex, point_count);
    defer if (point_count > inline_points.len) gpa.free(points);

    // The x deltas, then the y deltas, each accumulated from the last.
    var x: i32 = 0;
    for (flags, 0..) |flag, i| {
        if (flag & Flag.x_short != 0) {
            const magnitude: i32 = try at.int(u8);
            // With the short flag, this bit is the sign.
            x += if (flag & Flag.x_same_or_positive != 0) magnitude else -magnitude;
        } else if (flag & Flag.x_same_or_positive == 0) {
            // Without it, the bit set means "unchanged" and clear means
            // "there is a signed word here". This is the reading that is easy
            // to get backwards.
            x += try at.int(i16);
        }
        points[i] = .{ .x = @floatFromInt(x), .y = 0, .on_curve = flag & Flag.on_curve != 0 };
    }

    var y: i32 = 0;
    for (flags, 0..) |flag, i| {
        if (flag & Flag.y_short != 0) {
            const magnitude: i32 = try at.int(u8);
            y += if (flag & Flag.y_same_or_positive != 0) magnitude else -magnitude;
        } else if (flag & Flag.y_same_or_positive == 0) {
            y += try at.int(i16);
        }
        points[i].y = @floatFromInt(y);
    }

    // Now the rings.
    var builder: outline.Builder = .init(gpa, out);
    var first: usize = 0;
    for (0..contour_count) |contour| {
        const last: usize = try data.int(u16, ends_at + contour * 2);
        if (last < first or last >= point_count) return error.Malformed;

        try emitContour(&builder, points[first .. last + 1]);
        first = last + 1;
    }
    try builder.close();
}

/// Turn one ring of points into a contour.
///
/// The ring may begin anywhere, including on a control point - an `o` is four
/// control points and no on-curve point at all. When that happens the
/// starting point has to be invented: halfway between the last point and the
/// first, which is exactly the implied point that two consecutive control
/// points always have between them.
fn emitContour(builder: *outline.Builder, ring: []const Vertex) Allocator.Error!void {
    if (ring.len == 0) return;

    const at = struct {
        fn point(v: Vertex) Point {
            return .{ .x = v.x, .y = v.y };
        }
    }.point;

    // Where to start, and how far into the ring the real work begins.
    var start: Point = undefined;
    var offset: usize = undefined;

    if (ring[0].on_curve) {
        start = at(ring[0]);
        offset = 1;
    } else if (ring[ring.len - 1].on_curve) {
        // Start at the end of the ring instead, and walk the whole of it.
        start = at(ring[ring.len - 1]);
        offset = 0;
    } else {
        // No on-curve point anywhere: the start is implied between the two
        // ends, and the ring is walked from its first point.
        start = Point.midpoint(at(ring[ring.len - 1]), at(ring[0]));
        offset = 0;
    }

    try builder.moveTo(start);

    for (0..ring.len) |i| {
        // Walking the whole ring from `offset` ends back where it started,
        // which is what closes the shape: the final point is the one `moveTo`
        // used, and emitting it again is what consumes a control point that
        // was still waiting.
        const vertex = ring[(offset + i) % ring.len];
        if (vertex.on_curve) {
            try builder.curveTo(at(vertex));
        } else {
            try builder.controlAt(at(vertex));
        }
    }

    try builder.close();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Build a simple glyph: contour ends, then flags and coordinates, all in the
/// long forms so the fixture stays readable.
fn buildSimpleGlyph(
    gpa: Allocator,
    ends: []const u16,
    points: []const Vertex,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);

    var header: [10]u8 = undefined;
    std.mem.writeInt(i16, header[0..2], @intCast(ends.len), .big);
    std.mem.writeInt(i16, header[2..4], 0, .big);
    std.mem.writeInt(i16, header[4..6], 0, .big);
    std.mem.writeInt(i16, header[6..8], 1000, .big);
    std.mem.writeInt(i16, header[8..10], 1000, .big);
    try bytes.appendSlice(gpa, &header);

    for (ends) |end| {
        var pair: [2]u8 = undefined;
        std.mem.writeInt(u16, &pair, end, .big);
        try bytes.appendSlice(gpa, &pair);
    }
    try bytes.appendSlice(gpa, &.{ 0, 0 }); // no instructions

    // One flag per point, no repeats, both coordinates as signed words.
    for (points) |p| {
        try bytes.append(gpa, if (p.on_curve) Flag.on_curve else 0);
    }

    var previous: i32 = 0;
    for (points) |p| {
        const value: i32 = @intFromFloat(p.x);
        var pair: [2]u8 = undefined;
        std.mem.writeInt(i16, &pair, @intCast(value - previous), .big);
        try bytes.appendSlice(gpa, &pair);
        previous = value;
    }
    previous = 0;
    for (points) |p| {
        const value: i32 = @intFromFloat(p.y);
        var pair: [2]u8 = undefined;
        std.mem.writeInt(i16, &pair, @intCast(value - previous), .big);
        try bytes.appendSlice(gpa, &pair);
        previous = value;
    }

    return bytes.toOwnedSlice(gpa);
}

/// A `Glyf` over one glyph, with a two-entry `loca` around it.
fn oneGlyph(glyph: []const u8, loca: *[8]u8) Glyf {
    std.mem.writeInt(u32, loca[0..4], 0, .big);
    std.mem.writeInt(u32, loca[4..8], @intCast(glyph.len), .big);
    return .{
        .glyf = .{ .bytes = glyph },
        .loca = .{ .bytes = loca },
        .long_loca = true,
        .glyph_count = 1,
    };
}

test "a triangle comes back as three lines and a close" {
    const glyph = try buildSimpleGlyph(testing.allocator, &.{2}, &.{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 600, .y = 0, .on_curve = true },
        .{ .x = 300, .y = 700, .on_curve = true },
    });
    defer testing.allocator.free(glyph);

    var loca: [8]u8 = undefined;
    const table = oneGlyph(glyph, &loca);

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try table.outlineOf(testing.allocator, 0, &shape);

    try testing.expectEqual(1, shape.contourCount());
    const box = shape.bounds();
    try testing.expectEqual(@as(f32, 0), box.min_x);
    try testing.expectEqual(@as(f32, 600), box.max_x);
    try testing.expectEqual(@as(f32, 700), box.max_y);
}

test "a ring with no on-curve point anywhere starts at an implied one" {
    // This is what an `o` is, and a reader that assumes the first point is on
    // the curve draws it with a corner.
    const glyph = try buildSimpleGlyph(testing.allocator, &.{3}, &.{
        .{ .x = 0, .y = 500, .on_curve = false },
        .{ .x = 500, .y = 1000, .on_curve = false },
        .{ .x = 1000, .y = 500, .on_curve = false },
        .{ .x = 500, .y = 0, .on_curve = false },
    });
    defer testing.allocator.free(glyph);

    var loca: [8]u8 = undefined;
    const table = oneGlyph(glyph, &loca);

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try table.outlineOf(testing.allocator, 0, &shape);

    try testing.expectEqual(1, shape.contourCount());

    // Every segment is a curve; there is not a straight line in it.
    var curves: usize = 0;
    var lines: usize = 0;
    for (shape.commands.items) |command| {
        switch (command) {
            .quadratic => curves += 1,
            .line => lines += 1,
            else => {},
        }
    }
    try testing.expectEqual(0, lines);
    try testing.expectEqual(4, curves);

    // The contour begins halfway between the last control point and the
    // first, which for this ring is (250, 250).
    try testing.expectEqual(outline.Point.init(250, 250), shape.commands.items[0].move);
}

test "two contours make a glyph with a hole in it" {
    const glyph = try buildSimpleGlyph(testing.allocator, &.{ 2, 5 }, &.{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 900, .y = 0, .on_curve = true },
        .{ .x = 0, .y = 900, .on_curve = true },
        .{ .x = 200, .y = 200, .on_curve = true },
        .{ .x = 400, .y = 200, .on_curve = true },
        .{ .x = 200, .y = 400, .on_curve = true },
    });
    defer testing.allocator.free(glyph);

    var loca: [8]u8 = undefined;
    const table = oneGlyph(glyph, &loca);

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try table.outlineOf(testing.allocator, 0, &shape);

    try testing.expectEqual(2, shape.contourCount());
}

test "a glyph with no outline is a space, not an error" {
    // `loca` entries that are equal mean nothing to draw, and every font has
    // dozens of them.
    var loca: [12]u8 = undefined;
    std.mem.writeInt(u32, loca[0..4], 0, .big);
    std.mem.writeInt(u32, loca[4..8], 0, .big);
    std.mem.writeInt(u32, loca[8..12], 0, .big);

    const table: Glyf = .{
        .glyf = .empty,
        .loca = .{ .bytes = &loca },
        .long_loca = true,
        .glyph_count = 2,
    };

    try testing.expectEqual(null, try table.locate(0));

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try table.outlineOf(testing.allocator, 0, &shape);
    try testing.expect(shape.isEmpty());
}

test "the short loca form stores half the offset" {
    var loca: [4]u8 = undefined;
    std.mem.writeInt(u16, loca[0..2], 0, .big);
    std.mem.writeInt(u16, loca[2..4], 5, .big);

    const table: Glyf = .{
        .glyf = .empty,
        .loca = .{ .bytes = &loca },
        .long_loca = false,
        .glyph_count = 1,
    };

    const where = (try table.locate(0)).?;
    try testing.expectEqual(0, where.start);
    // Five in the file means ten bytes in, which is the whole reason the
    // short form can address a table larger than 65535 bytes.
    try testing.expectEqual(10, where.end);
}

test "a glyph index past the end of the font is nothing, not a read" {
    var loca: [8]u8 = @splat(0);
    const table: Glyf = .{
        .glyf = .empty,
        .loca = .{ .bytes = &loca },
        .long_loca = true,
        .glyph_count = 1,
    };
    try testing.expectEqual(null, try table.locate(500));
}

test "a composite places its part under a transform" {
    // A glyph made of one other glyph, moved and halved.
    const part = try buildSimpleGlyph(testing.allocator, &.{2}, &.{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 400, .y = 0, .on_curve = true },
        .{ .x = 0, .y = 400, .on_curve = true },
    });
    defer testing.allocator.free(part);

    var composite: std.ArrayList(u8) = .empty;
    defer composite.deinit(testing.allocator);

    var header: [10]u8 = undefined;
    std.mem.writeInt(i16, header[0..2], -1, .big); // composite
    @memset(header[2..], 0);
    try composite.appendSlice(testing.allocator, &header);

    var entry: [10]u8 = undefined;
    std.mem.writeInt(u16, entry[0..2], Component.args_are_words | Component.args_are_xy | Component.have_scale, .big);
    std.mem.writeInt(u16, entry[2..4], 0, .big); // component is glyph 0
    std.mem.writeInt(i16, entry[4..6], 100, .big); // dx
    std.mem.writeInt(i16, entry[6..8], 50, .big); // dy
    std.mem.writeInt(i16, entry[8..10], 8192, .big); // scale 0.5 in F2Dot14
    try composite.appendSlice(testing.allocator, &entry);

    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(testing.allocator);
    try glyf.appendSlice(testing.allocator, part);
    try glyf.appendSlice(testing.allocator, composite.items);

    var loca: [12]u8 = undefined;
    std.mem.writeInt(u32, loca[0..4], 0, .big);
    std.mem.writeInt(u32, loca[4..8], @intCast(part.len), .big);
    std.mem.writeInt(u32, loca[8..12], @intCast(glyf.items.len), .big);

    const table: Glyf = .{
        .glyf = .{ .bytes = glyf.items },
        .loca = .{ .bytes = &loca },
        .long_loca = true,
        .glyph_count = 2,
    };

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try table.outlineOf(testing.allocator, 1, &shape);

    try testing.expectEqual(1, shape.contourCount());
    const box = shape.bounds();
    // The part was 0..400; halved and moved right by 100 it is 100..300.
    try testing.expectApproxEqAbs(100, box.min_x, 0.01);
    try testing.expectApproxEqAbs(300, box.max_x, 0.01);
    try testing.expectApproxEqAbs(50, box.min_y, 0.01);
    try testing.expectApproxEqAbs(250, box.max_y, 0.01);
}

test "a composite that refers to itself stops rather than recursing forever" {
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(testing.allocator);

    var header: [10]u8 = undefined;
    std.mem.writeInt(i16, header[0..2], -1, .big);
    @memset(header[2..], 0);
    try glyf.appendSlice(testing.allocator, &header);

    var entry: [8]u8 = undefined;
    std.mem.writeInt(u16, entry[0..2], Component.args_are_words | Component.args_are_xy, .big);
    std.mem.writeInt(u16, entry[2..4], 0, .big); // itself
    std.mem.writeInt(i16, entry[4..6], 0, .big);
    std.mem.writeInt(i16, entry[6..8], 0, .big);
    try glyf.appendSlice(testing.allocator, &entry);

    var loca: [8]u8 = undefined;
    std.mem.writeInt(u32, loca[0..4], 0, .big);
    std.mem.writeInt(u32, loca[4..8], @intCast(glyf.items.len), .big);

    const table: Glyf = .{
        .glyf = .{ .bytes = glyf.items },
        .loca = .{ .bytes = &loca },
        .long_loca = true,
        .glyph_count = 1,
    };

    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    // A crafted font can do this, and the answer has to be an error rather
    // than a stack overflow.
    try testing.expectError(error.Malformed, table.outlineOf(testing.allocator, 0, &shape));
}
