// SPDX-License-Identifier: BSD-2-Clause

//! Turning an outline into pixels, with the edges smoothed.
//!
//! The method is signed-area accumulation, and it is worth explaining because
//! it looks nothing like the scanline fill people expect.
//!
//! The obvious way to fill a shape is to walk each row, find where the edges
//! cross it, sort the crossings, and fill between them. That is correct and
//! it is a lot of sorting, and getting antialiasing out of it means sampling
//! each row several times.
//!
//! This does something else. For every line segment of the outline it works
//! out, for each pixel the segment passes through, **how much the coverage
//! changes at that pixel** - a signed number, positive where the edge is
//! going one way and negative where it goes back. Nothing is sorted and
//! nothing is filled. Then one pass over the whole buffer takes a running
//! sum, and the sum at each pixel *is* the coverage: inside a shape the
//! upward edges and downward edges have cancelled out to one, outside they
//! have cancelled to zero, and along an edge they land somewhere between,
//! which is the antialiasing. It falls out of the arithmetic rather than
//! being added on top.
//!
//! Two consequences worth knowing:
//!
//!   * **Winding is handled for free.** A hole in an `o` is a contour going
//!     the other way, and its contributions are negative, so the running sum
//!     comes back to zero inside it. Nothing has to know which contour is
//!     which.
//!   * **The coverage is `|sum|`, clamped.** Taking the absolute value is
//!     what makes this a non-zero winding fill and stops a contour drawn
//!     backwards from disappearing.
//!
//! The idea is Raph Levien's, from font-rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const outline = @import("outline.zig");

const Outline = outline.Outline;
const Point = outline.Point;

/// A glyph, rasterised: one byte of coverage per pixel.
///
/// Not a colour. Zero is nothing, 255 is fully inside the shape, and what to
/// do with that is the renderer's business - text is usually this multiplied
/// by a colour, which is why an atlas of these is a single-channel texture
/// and not an RGBA one.
pub const Bitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub const empty: Bitmap = .{ .pixels = &.{}, .width = 0, .height = 0 };

    pub fn deinit(self: *Bitmap, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    pub inline fn isEmpty(self: Bitmap) bool {
        return self.width == 0 or self.height == 0;
    }

    /// The coverage at a pixel. Zero outside the bitmap, so a caller
    /// sampling around an edge does not have to check first.
    pub inline fn at(self: Bitmap, x: u32, y: u32) u8 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[y * self.width + x];
    }

    /// One row. What an atlas copies.
    pub inline fn row(self: Bitmap, y: u32) []const u8 {
        if (y >= self.height) return &.{};
        return self.pixels[y * self.width ..][0..self.width];
    }
};

/// How finely a curve is chopped into straight lines.
///
/// Smaller is smoother and slower. The number is a tolerance in pixels
/// squared, and three is the value font-rs settled on - at a normal text size
/// the difference between this and a much finer flattening is below what a
/// byte of coverage can express.
const flatness: f32 = 3.0;

/// Draw `shape` into a bitmap `width` by `height`.
///
/// **The outline must already be in pixel space**, with y pointing down and
/// the shape's top left corner at the origin. `Placement` works that out from
/// a font's units and a pixel size; doing it here would mean this function
/// needing to know what a font is.
///
/// Anything outside the bitmap is clipped rather than being an error, because
/// rounding a glyph's bounds to whole pixels routinely puts a fraction of an
/// edge just outside them.
pub fn rasterize(gpa: Allocator, shape: Outline, width: u32, height: u32) Allocator.Error!Bitmap {
    if (width == 0 or height == 0) return .empty;

    // One column wider than the bitmap. Every segment writes to the pixel it
    // ends in *and the one after it*, and a segment ending in the last column
    // would otherwise write past the row. The extra column is accumulated and
    // then thrown away.
    const stride = width + 1;
    const area = try gpa.alloc(f32, stride * height);
    defer gpa.free(area);
    @memset(area, 0);

    var pen: Pen = .{ .area = area, .stride = stride, .height = height };

    var at: Point = .zero;
    var start: Point = .zero;
    for (shape.commands.items) |command| {
        switch (command) {
            .move => |p| {
                // An unclosed contour still has to be closed, or its edges do
                // not cancel and everything after it is filled.
                pen.line(at, start);
                at = p;
                start = p;
            },
            .line => |p| {
                pen.line(at, p);
                at = p;
            },
            .quadratic => |q| {
                pen.quadratic(at, q.control, q.to);
                at = q.to;
            },
            .cubic => |c| {
                pen.cubic(at, c.control1, c.control2, c.to);
                at = c.to;
            },
            .close => {
                pen.line(at, start);
                at = start;
            },
        }
    }
    pen.line(at, start);

    // The running sum, and the only place the coverage actually appears.
    const pixels = try gpa.alloc(u8, width * height);
    errdefer gpa.free(pixels);

    var sum: f32 = 0;
    for (0..height) |y| {
        const source = area[y * stride ..][0..stride];
        const target = pixels[y * width ..][0..width];
        for (0..width) |x| {
            sum += source[x];
            // Non-zero winding: a contour drawn the other way round is still
            // inside, which is why this is the absolute value.
            const filled = @min(@abs(sum), 1.0);
            target[x] = @intFromFloat(@round(filled * 255.0));
        }
        // The spare column, accumulated so the row's edges balance, and not
        // written anywhere.
        sum += source[width];
    }

    return .{ .pixels = pixels, .width = width, .height = height };
}

/// The accumulation buffer, and the two operations that write to it.
const Pen = struct {
    area: []f32,
    stride: u32,
    height: u32,

    /// Add one straight edge's contribution.
    ///
    /// This is the whole algorithm. For each row the segment crosses it works
    /// out how much of the row's height the segment spans (`dy`), which is
    /// the total coverage change that row owes, and then splits that change
    /// between the pixels the segment passes through in proportion to how
    /// much of each it covers.
    fn line(self: *Pen, from: Point, to: Point) void {
        // A horizontal segment changes no row's coverage, and dividing by its
        // height would be dividing by zero.
        if (from.y == to.y) return;

        // Remember which way round it was: that sign is what makes a hole a
        // hole.
        const direction: f32, const p0: Point, const p1: Point =
            if (from.y < to.y) .{ 1.0, from, to } else .{ -1.0, to, from };

        const dxdy = (p1.x - p0.x) / (p1.y - p0.y);

        var x = p0.x;
        var y: u32 = if (p0.y < 0) 0 else @intFromFloat(p0.y);
        if (p0.y < 0) x -= p0.y * dxdy; // walk up to the top edge

        const last: u32 = if (p1.y < 0)
            0
        else if (p1.y >= @as(f32, @floatFromInt(self.height)))
            self.height
        else
            @intFromFloat(@ceil(p1.y));

        while (y < @min(last, self.height)) : (y += 1) {
            const row: f32 = @floatFromInt(y);
            // How much of this row the segment actually spans - the whole row
            // in the middle of a long edge, a fraction at either end.
            const dy = @min(row + 1, p1.y) - @max(row, p0.y);
            const x_next = x + dxdy * dy;
            const d = dy * direction;

            const x0 = @min(x, x_next);
            const x1 = @max(x, x_next);
            self.span(y, x0, x1, d, (x + x_next) * 0.5);
            x = x_next;
        }
    }

    /// Share one row's coverage change `d` between the pixels from `x0` to
    /// `x1`.
    ///
    /// Two cases, and the second is the only fiddly arithmetic in the file.
    ///
    /// When the segment stays within one pixel of this row - a steep edge,
    /// which most of a letter is - the change splits between that pixel and
    /// the next in proportion to where the segment's midpoint fell. That is
    /// the whole of it.
    ///
    /// When it crosses several - a shallow edge, the top of an `e` - the
    /// change is spread across them by area. The first pixel gets the
    /// triangle the segment cuts off in it, the last gets its triangle, and
    /// the ones between get an equal strip each. The three formulas below are
    /// those areas, and they are written to sum to exactly one so that a
    /// nearly horizontal edge does not lose coverage.
    fn span(self: *Pen, y: u32, x0_in: f32, x1_in: f32, d: f32, middle: f32) void {
        const start = self.stride * y;
        const limit: f32 = @floatFromInt(self.stride - 1);

        // Everything left of the bitmap still counts: an edge off to the left
        // covers every pixel of the row, so its change belongs in column
        // zero. Dropping it would leave the row unfilled.
        const x0 = std.math.clamp(x0_in, 0, limit);
        const x1 = std.math.clamp(x1_in, 0, limit);

        const x0_floor = @floor(x0);
        const x0_index: u32 = @intFromFloat(x0_floor);
        const x1_ceil = @ceil(x1);
        const x1_index: u32 = @intFromFloat(x1_ceil);

        if (x1_index <= x0_index + 1) {
            const fraction = std.math.clamp(middle, 0, limit) - x0_floor;
            self.add(start + x0_index, d * (1.0 - fraction));
            self.add(start + x0_index + 1, d * fraction);
            return;
        }

        const inverse = 1.0 / (x1 - x0);
        const x0_fraction = x0 - x0_floor;
        // The triangle in the first pixel.
        const first = 0.5 * inverse * (1.0 - x0_fraction) * (1.0 - x0_fraction);
        const x1_fraction = x1 - x1_ceil + 1.0;
        // And the one in the last.
        const last = 0.5 * inverse * x1_fraction * x1_fraction;

        self.add(start + x0_index, d * first);

        if (x1_index == x0_index + 2) {
            // Exactly two pixels: the middle one gets everything the two ends
            // did not, which is what keeps the row summing to one.
            self.add(start + x0_index + 1, d * (1.0 - first - last));
        } else {
            const second = inverse * (1.5 - x0_fraction);
            self.add(start + x0_index + 1, d * (second - first));

            var i = x0_index + 2;
            while (i < x1_index - 1) : (i += 1) {
                self.add(start + i, d * inverse);
            }

            const before_last = second + @as(f32, @floatFromInt(x1_index - x0_index - 3)) * inverse;
            self.add(start + x1_index - 1, d * (1.0 - before_last - last));
        }

        self.add(start + x1_index, d * last);
    }

    inline fn add(self: *Pen, index: usize, value: f32) void {
        if (index < self.area.len) self.area[index] += value;
    }

    /// Chop a quadratic into straight lines and draw those.
    ///
    /// How many depends on how bent the curve is, which is what the second
    /// difference of its three points measures: a curve whose control point
    /// is nearly on the line between its ends is nearly a line, and one
    /// segment does it.
    fn quadratic(self: *Pen, from: Point, control: Point, to: Point) void {
        const dev_x = from.x - 2 * control.x + to.x;
        const dev_y = from.y - 2 * control.y + to.y;
        const deviation = dev_x * dev_x + dev_y * dev_y;

        if (deviation < 0.333) {
            self.line(from, to);
            return;
        }

        const steps: u32 = @intFromFloat(1 + @floor(@sqrt(@sqrt(flatness * deviation))));
        const count = @min(steps, 64);

        var previous = from;
        for (1..count + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const next = evaluate(from, control, to, t);
            self.line(previous, next);
            previous = next;
        }
    }

    /// Chop a cubic into straight lines and draw those.
    ///
    /// The same idea as `quadratic` with one more control point: a cubic has
    /// two second differences rather than one, and how bent it is anywhere
    /// is bounded by the larger. That bound is three times what a quadratic
    /// with the same difference would give, because a cubic's second
    /// derivative carries a factor of six where a quadratic's carries two -
    /// which is where the nine comes from, being three squared.
    fn cubic(self: *Pen, from: Point, control1: Point, control2: Point, to: Point) void {
        const d1x = from.x - 2 * control1.x + control2.x;
        const d1y = from.y - 2 * control1.y + control2.y;
        const d2x = control1.x - 2 * control2.x + to.x;
        const d2y = control1.y - 2 * control2.y + to.y;
        const deviation = 9 * @max(d1x * d1x + d1y * d1y, d2x * d2x + d2y * d2y);

        if (deviation < 0.333) {
            self.line(from, to);
            return;
        }

        const steps: u32 = @intFromFloat(1 + @floor(@sqrt(@sqrt(flatness * deviation))));
        const count = @min(steps, 64);

        var previous = from;
        for (1..count + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const next = evaluateCubic(from, control1, control2, to, t);
            self.line(previous, next);
            previous = next;
        }
    }
};

/// A point on a quadratic curve at parameter `t`.
fn evaluate(from: Point, control: Point, to: Point, t: f32) Point {
    const one_minus = 1 - t;
    const a = one_minus * one_minus;
    const b = 2 * one_minus * t;
    const c = t * t;
    return .{
        .x = a * from.x + b * control.x + c * to.x,
        .y = a * from.y + b * control.y + c * to.y,
    };
}

/// A point on a cubic curve at parameter `t`: the Bernstein form, which is
/// the four weights `(1-t)³, 3(1-t)²t, 3(1-t)t², t³` applied to the four
/// points. They sum to one, so the result is always somewhere inside the
/// hull the points make.
fn evaluateCubic(from: Point, control1: Point, control2: Point, to: Point, t: f32) Point {
    const one_minus = 1 - t;
    const a = one_minus * one_minus * one_minus;
    const b = 3 * one_minus * one_minus * t;
    const c = 3 * one_minus * t * t;
    const d = t * t * t;
    return .{
        .x = a * from.x + b * control1.x + c * control2.x + d * to.x,
        .y = a * from.y + b * control1.y + c * control2.y + d * to.y,
    };
}

/// Where a glyph goes on a pixel grid, and how big it comes out.
///
/// The arithmetic between font units and pixels, in one place. A font is
/// drawn on a grid `units_per_em` across with y pointing up; a bitmap counts
/// pixels from the top left with y pointing down. Both facts have to be
/// applied at once, and applying only one of them draws the glyph upside
/// down, which is the single most common way to get this wrong.
pub const Placement = struct {
    /// How many pixels one font unit is.
    scale: f32,
    /// The size of the bitmap needed, in whole pixels.
    width: u32,
    height: u32,
    /// What to add after scaling, to bring the shape into the bitmap.
    offset_x: f32,
    offset_y: f32,
    /// Where the glyph sits relative to the pen: how far right of it the
    /// bitmap starts, and how far *above* the baseline its top row is.
    /// A renderer needs both to put the bitmap on the screen.
    left: i32,
    top: i32,

    /// Work out where a glyph of these bounds goes, at this scale.
    ///
    /// The bounds are in font units. The bitmap is grown to whole pixels in
    /// both directions, so a shape that starts a third of a pixel in gets a
    /// column of nearly empty coverage rather than being cut off.
    pub fn init(bounds: outline.Bounds, scale: f32) Placement {
        if (bounds.isEmpty()) {
            return .{ .scale = scale, .width = 0, .height = 0, .offset_x = 0, .offset_y = 0, .left = 0, .top = 0 };
        }

        const left = @floor(bounds.min_x * scale);
        const right = @ceil(bounds.max_x * scale);
        // y flips here: the top of the bitmap is the *largest* y in font units.
        const top = @floor(-bounds.max_y * scale);
        const bottom = @ceil(-bounds.min_y * scale);

        return .{
            .scale = scale,
            .width = @intFromFloat(@max(0, right - left)),
            .height = @intFromFloat(@max(0, bottom - top)),
            .offset_x = -left,
            .offset_y = -top,
            .left = @intFromFloat(left),
            .top = @intFromFloat(-top),
        };
    }

    /// Put an outline where this placement says, ready to be rasterised.
    ///
    /// Scales, flips y, and moves the result so its top left is the bitmap's
    /// origin.
    pub fn apply(self: Placement, shape: *Outline) void {
        shape.transform(self.scale, -self.scale, self.offset_x, self.offset_y);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// How much of the bitmap is covered, as a fraction. The area a shape
/// actually filled, which is what most of these tests are really asking.
fn coverage(bitmap: Bitmap) f32 {
    var total: f64 = 0;
    for (bitmap.pixels) |p| total += @as(f64, @floatFromInt(p)) / 255.0;
    return @floatCast(total);
}

fn rectangle(gpa: Allocator, shape: *Outline, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    var builder: outline.Builder = .init(gpa, shape);
    try builder.moveTo(.init(x0, y0));
    try builder.lineTo(.init(x1, y0));
    try builder.lineTo(.init(x1, y1));
    try builder.lineTo(.init(x0, y1));
    try builder.close();
}

test "a whole-pixel rectangle is filled solid, with nothing outside it" {
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try rectangle(testing.allocator, &shape, 2, 2, 8, 6);

    var bitmap = try rasterize(testing.allocator, shape, 10, 10);
    defer bitmap.deinit(testing.allocator);

    // Inside is solid.
    try testing.expectEqual(255, bitmap.at(3, 3));
    try testing.expectEqual(255, bitmap.at(7, 5));
    // Outside is nothing.
    try testing.expectEqual(0, bitmap.at(0, 0));
    try testing.expectEqual(0, bitmap.at(9, 9));
    try testing.expectEqual(0, bitmap.at(1, 3));
    try testing.expectEqual(0, bitmap.at(8, 3));

    // And the area is exactly what the rectangle covers: 6 by 4.
    try testing.expectApproxEqAbs(24, coverage(bitmap), 0.05);
}

test "a half-pixel edge comes out half covered" {
    // The whole point of antialiasing: a shape that ends in the middle of a
    // pixel column leaves that column at half coverage rather than choosing.
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try rectangle(testing.allocator, &shape, 0, 0, 2.5, 4);

    var bitmap = try rasterize(testing.allocator, shape, 4, 4);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(255, bitmap.at(0, 0));
    try testing.expectEqual(255, bitmap.at(1, 0));
    try testing.expectApproxEqAbs(128, @as(f32, @floatFromInt(bitmap.at(2, 0))), 3);
    try testing.expectEqual(0, bitmap.at(3, 0));

    try testing.expectApproxEqAbs(10, coverage(bitmap), 0.1);
}

test "a contour inside another one is a hole" {
    // The winding rule, and the reason an `o` has a middle. The inner
    // rectangle is wound the other way, so its contributions cancel.
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);

    var builder: outline.Builder = .init(testing.allocator, &shape);
    try builder.moveTo(.init(0, 0));
    try builder.lineTo(.init(10, 0));
    try builder.lineTo(.init(10, 10));
    try builder.lineTo(.init(0, 10));
    try builder.close();
    // The other way round.
    try builder.moveTo(.init(3, 3));
    try builder.lineTo(.init(3, 7));
    try builder.lineTo(.init(7, 7));
    try builder.lineTo(.init(7, 3));
    try builder.close();

    var bitmap = try rasterize(testing.allocator, shape, 10, 10);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(255, bitmap.at(1, 1));
    // The hole.
    try testing.expectEqual(0, bitmap.at(5, 5));
    try testing.expectEqual(0, bitmap.at(4, 4));

    // A hundred less the sixteen taken out.
    try testing.expectApproxEqAbs(84, coverage(bitmap), 0.2);
}

test "a contour wound backwards still fills" {
    // Non-zero winding with the absolute value taken: a shape drawn the other
    // way round is still a shape, and vanishing would be worse than filling.
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);

    var builder: outline.Builder = .init(testing.allocator, &shape);
    try builder.moveTo(.init(2, 2));
    try builder.lineTo(.init(2, 8));
    try builder.lineTo(.init(8, 8));
    try builder.lineTo(.init(8, 2));
    try builder.close();

    var bitmap = try rasterize(testing.allocator, shape, 10, 10);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(255, bitmap.at(5, 5));
    try testing.expectApproxEqAbs(36, coverage(bitmap), 0.2);
}

test "an unclosed contour is closed rather than bleeding" {
    // A contour whose last point does not return to its first would leave the
    // edges unbalanced, and everything to the right of it filled.
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);

    try shape.commands.append(testing.allocator, .{ .move = .init(2, 2) });
    try shape.commands.append(testing.allocator, .{ .line = .init(8, 2) });
    try shape.commands.append(testing.allocator, .{ .line = .init(8, 8) });
    // No line back, and no close.

    var bitmap = try rasterize(testing.allocator, shape, 10, 10);
    defer bitmap.deinit(testing.allocator);

    // The triangle is filled and the rest of the row is not.
    try testing.expectEqual(0, bitmap.at(0, 9));
    try testing.expectEqual(0, bitmap.at(9, 9));
    try testing.expect(coverage(bitmap) < 25);
}

test "a curve is smooth, not a staircase" {
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);

    var builder: outline.Builder = .init(testing.allocator, &shape);
    try builder.moveTo(.init(0, 16));
    try builder.controlAt(.init(0, 0));
    try builder.curveTo(.init(16, 0));
    try builder.lineTo(.init(16, 16));
    try builder.close();

    var bitmap = try rasterize(testing.allocator, shape, 16, 16);
    defer bitmap.deinit(testing.allocator);

    // A quarter-disc bulge: the corner it curves away from is empty, the
    // opposite one is solid.
    try testing.expectEqual(0, bitmap.at(0, 0));
    try testing.expectEqual(255, bitmap.at(15, 15));

    // Somewhere along the edge there is a partial pixel, which is what says
    // the curve was antialiased rather than stepped.
    var partial: usize = 0;
    for (bitmap.pixels) |p| {
        if (p > 10 and p < 245) partial += 1;
    }
    try testing.expect(partial > 8);
}

test "a cubic is smooth too, and covers what a circle would" {
    // A quarter-disc drawn the PostScript way: one cubic with the control
    // points at the magic 0.5523 of the radius that makes a cubic hug a
    // circle to within a fraction of a percent. The area of a quarter of a
    // 16-pixel disc is 64π, which is the number the coverage has to land on
    // for the flattening to be fine enough.
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);

    const k: f32 = 0.5523 * 16;
    var builder: outline.Builder = .init(testing.allocator, &shape);
    try builder.moveTo(.init(16, 16));
    try builder.lineTo(.init(0, 16));
    try builder.cubicTo(.init(0, 16 - k), .init(16 - k, 0), .init(16, 0));
    try builder.close();

    var bitmap = try rasterize(testing.allocator, shape, 16, 16);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(0, bitmap.at(0, 0));
    try testing.expectEqual(255, bitmap.at(15, 15));
    // A little under, always: the chords a curve is chopped into lie inside
    // the arc, and seven of them around a quarter of this circle give up
    // about a pixel and a half between them. That is the tolerance
    // `flatness` chose, made visible - a tenth of a pixel of sag on each
    // chord, which no byte of coverage can show.
    try testing.expectApproxEqAbs(64 * std.math.pi, coverage(bitmap), 2.5);

    var partial: usize = 0;
    for (bitmap.pixels) |p| {
        if (p > 10 and p < 245) partial += 1;
    }
    try testing.expect(partial > 8);
}

test "a shape larger than the bitmap is clipped, not an error" {
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    try rectangle(testing.allocator, &shape, -50, -50, 50, 50);

    var bitmap = try rasterize(testing.allocator, shape, 4, 4);
    defer bitmap.deinit(testing.allocator);

    // Every pixel is inside the shape.
    for (bitmap.pixels) |p| try testing.expectEqual(255, p);
}

test "an empty outline rasterises to nothing" {
    const shape: Outline = .{};
    var bitmap = try rasterize(testing.allocator, shape, 4, 4);
    defer bitmap.deinit(testing.allocator);

    try testing.expectEqual(0, coverage(bitmap));
}

test "a zero-sized bitmap is empty rather than an allocation" {
    const shape: Outline = .{};
    var bitmap = try rasterize(testing.allocator, shape, 0, 10);
    defer bitmap.deinit(testing.allocator);
    try testing.expect(bitmap.isEmpty());
}

test "placement scales, flips y, and reports where the glyph sits" {
    // A glyph 500 units wide and 700 tall, sitting 50 above the baseline,
    // drawn at a scale of a tenth.
    const bounds: outline.Bounds = .{ .min_x = 0, .min_y = 50, .max_x = 500, .max_y = 700 };
    const placement: Placement = .init(bounds, 0.1);

    try testing.expectEqual(50, placement.width);
    try testing.expectEqual(65, placement.height);
    try testing.expectEqual(0, placement.left);
    // The top row is 70 pixels above the baseline, which is what a renderer
    // subtracts from the pen's y.
    try testing.expectEqual(70, placement.top);
}

test "placement puts a shape's top left at the bitmap origin" {
    var shape: Outline = .{};
    defer shape.deinit(testing.allocator);
    // In font units, y up: a box from (100, 200) to (300, 600).
    try rectangle(testing.allocator, &shape, 100, 200, 300, 600);

    const placement: Placement = .init(shape.bounds(), 0.05);
    placement.apply(&shape);

    const box = shape.bounds();
    try testing.expectApproxEqAbs(0, box.min_x, 0.001);
    try testing.expectApproxEqAbs(0, box.min_y, 0.001);
    try testing.expectApproxEqAbs(10, box.max_x, 0.001);
    try testing.expectApproxEqAbs(20, box.max_y, 0.001);
}

test "an empty glyph places as a zero-sized bitmap" {
    const placement: Placement = .init(.empty, 0.1);
    try testing.expectEqual(0, placement.width);
    try testing.expectEqual(0, placement.height);
}
