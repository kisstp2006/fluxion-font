// SPDX-License-Identifier: BSD-2-Clause

//! The shape of a glyph: closed contours of straight lines and quadratic
//! curves.
//!
//! What comes out of `glyf` and goes into `raster`. Kept as curves rather
//! than as the line segments the rasteriser eventually wants, because how
//! finely a curve should be chopped up depends on how big it is being drawn -
//! a letter at 11 pixels needs two segments where the same letter on a poster
//! needs forty. Flattening here would have to guess; flattening in `raster`
//! knows.
//!
//! **Quadratic, not cubic.** TrueType curves have one control point, which is
//! why `Command.quadratic` has one and there is no `cubic`. PostScript
//! outlines in a `CFF ` table are cubic, and are not read by this library -
//! see the note in `Font`.
//!
//! The coordinates are **font units** with y upwards, exactly as the file
//! stores them. Turning them into pixels with y downwards is one transform,
//! and it belongs at the point of rasterising because that is where the size
//! is known. See `raster.Transform`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A position, in whatever units the outline is currently in.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Point = .{};

    pub inline fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    /// Halfway between two points. Used more than it looks like it would be:
    /// TrueType stores two curves sharing an implied on-curve point as two
    /// control points in a row, and the point between them is this.
    pub inline fn midpoint(a: Point, b: Point) Point {
        return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    }

    pub fn format(self: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d:.1}, {d:.1})", .{ self.x, self.y });
    }
};

/// A rectangle around something, in the same units.
pub const Bounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    /// The bounds of nothing: inverted, so that the first point taken into
    /// them replaces both edges rather than being compared against a zero
    /// that would wrongly include the origin.
    pub const empty: Bounds = .{
        .min_x = std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .max_x = -std.math.floatMax(f32),
        .max_y = -std.math.floatMax(f32),
    };

    pub inline fn width(self: Bounds) f32 {
        return @max(0, self.max_x - self.min_x);
    }

    pub inline fn height(self: Bounds) f32 {
        return @max(0, self.max_y - self.min_y);
    }

    pub inline fn isEmpty(self: Bounds) bool {
        return self.max_x < self.min_x or self.max_y < self.min_y;
    }

    pub fn include(self: *Bounds, point: Point) void {
        self.min_x = @min(self.min_x, point.x);
        self.min_y = @min(self.min_y, point.y);
        self.max_x = @max(self.max_x, point.x);
        self.max_y = @max(self.max_y, point.y);
    }
};

/// One step of a contour.
pub const Command = union(enum) {
    /// Start a new contour here. Every contour begins with one.
    move: Point,
    /// A straight line from wherever the pen is to here.
    line: Point,
    /// A quadratic curve, through `control`, ending at `to`.
    quadratic: struct { control: Point, to: Point },
    /// Back to where this contour started. TrueType contours are always
    /// closed, so every `move` eventually gets one of these.
    close,

    /// Where the pen ends up. Null for `close`, which returns it to the start
    /// of the contour rather than anywhere new.
    pub fn endpoint(self: Command) ?Point {
        return switch (self) {
            .move => |p| p,
            .line => |p| p,
            .quadratic => |q| q.to,
            .close => null,
        };
    }
};

/// A glyph's shape.
///
/// Owns its commands. A glyph is read once and rasterised into an atlas, so
/// the allocation happens a few hundred times in the life of a program and
/// the rasterising happens for every one of those - which is why this is a
/// plain list rather than anything clever.
pub const Outline = struct {
    commands: std.ArrayList(Command) = .empty,

    /// A shape with nothing in it. What a glyph starts as, and what a space
    /// stays as.
    pub const empty: Outline = .{};

    pub fn deinit(self: *Outline, gpa: Allocator) void {
        self.commands.deinit(gpa);
        self.* = undefined;
    }

    /// Throw the shape away but keep the memory, for the next glyph.
    pub fn clear(self: *Outline) void {
        self.commands.clearRetainingCapacity();
    }

    /// Whether there is anything to draw. A space has an advance width and no
    /// outline at all, and so does every control character - so this is the
    /// common case rather than an edge one.
    pub inline fn isEmpty(self: Outline) bool {
        return self.commands.items.len == 0;
    }

    /// The box the shape fits in.
    ///
    /// Computed from the commands rather than read from the glyph header,
    /// and the two can disagree: a font is allowed to declare a box larger
    /// than its outline, and several do. For deciding how many pixels to
    /// allocate, the real one is the one that matters.
    ///
    /// The control point of a curve is included, which makes this box a
    /// little larger than the true one - a quadratic never reaches its
    /// control point. Being generous costs a row of empty pixels in an atlas;
    /// being exact costs solving for the extrema of every curve, and nobody
    /// has ever noticed the difference.
    pub fn bounds(self: Outline) Bounds {
        var box: Bounds = .empty;
        for (self.commands.items) |command| {
            switch (command) {
                .move, .line => |p| box.include(p),
                .quadratic => |q| {
                    box.include(q.control);
                    box.include(q.to);
                },
                .close => {},
            }
        }
        return box;
    }

    /// Move and scale every point: `x * scale_x + offset_x`, and the same for
    /// y. What a composite glyph does to its parts, and what turning font
    /// units into pixels does to the whole thing.
    pub fn transform(self: *Outline, scale_x: f32, scale_y: f32, offset_x: f32, offset_y: f32) void {
        const move = struct {
            fn point(p: Point, sx: f32, sy: f32, ox: f32, oy: f32) Point {
                return .{ .x = p.x * sx + ox, .y = p.y * sy + oy };
            }
        }.point;

        for (self.commands.items) |*command| {
            switch (command.*) {
                .move => |*p| p.* = move(p.*, scale_x, scale_y, offset_x, offset_y),
                .line => |*p| p.* = move(p.*, scale_x, scale_y, offset_x, offset_y),
                .quadratic => |*q| {
                    q.control = move(q.control, scale_x, scale_y, offset_x, offset_y);
                    q.to = move(q.to, scale_x, scale_y, offset_x, offset_y);
                },
                .close => {},
            }
        }
    }

    /// The general form: `x' = a*x + c*y + dx`, `y' = b*x + d*y + dy`.
    ///
    /// Needed because a composite glyph may place its parts under any
    /// two-by-two matrix, not only a scale - which is how an `ä` can be built
    /// from an `a` and a dieresis, and how some fonts build a small-capital
    /// from a capital by squashing it at a slight angle.
    pub fn affine(self: *Outline, a: f32, b: f32, c: f32, d: f32, dx: f32, dy: f32) void {
        const move = struct {
            fn point(p: Point, ma: f32, mb: f32, mc: f32, md: f32, ox: f32, oy: f32) Point {
                return .{
                    .x = ma * p.x + mc * p.y + ox,
                    .y = mb * p.x + md * p.y + oy,
                };
            }
        }.point;

        for (self.commands.items) |*command| {
            switch (command.*) {
                .move => |*p| p.* = move(p.*, a, b, c, d, dx, dy),
                .line => |*p| p.* = move(p.*, a, b, c, d, dx, dy),
                .quadratic => |*q| {
                    q.control = move(q.control, a, b, c, d, dx, dy);
                    q.to = move(q.to, a, b, c, d, dx, dy);
                },
                .close => {},
            }
        }
    }

    /// Add every command of `other` to this outline, unchanged. What a
    /// composite glyph does once its part has been placed.
    pub fn append(self: *Outline, gpa: Allocator, other: Outline) Allocator.Error!void {
        try self.commands.appendSlice(gpa, other.commands.items);
    }

    /// How many closed contours there are. An `o` has two, an `i` has two, an
    /// `l` has one, and `%` has five.
    pub fn contourCount(self: Outline) usize {
        var count: usize = 0;
        for (self.commands.items) |command| {
            if (command == .move) count += 1;
        }
        return count;
    }
};

/// Building an outline one contour at a time.
///
/// The reason this is not just an `ArrayList` with methods is the implied
/// point. TrueType stores a contour as a ring of points, each marked on-curve
/// or off-curve, and two off-curve points in a row mean there is an on-curve
/// point halfway between them that the file does not store. `curveTo` is
/// where that is worked out, so `glyf` can walk the ring and say what it
/// sees without also keeping track of what it saw last.
pub const Builder = struct {
    outline: *Outline,
    gpa: Allocator,
    /// Where the current contour began, so `close` knows where to go back to.
    start: Point = .zero,
    /// Where the pen is.
    at: Point = .zero,
    /// An off-curve point seen but not yet used, because what it means
    /// depends on what comes next.
    pending: ?Point = null,
    open: bool = false,

    pub fn init(gpa: Allocator, outline: *Outline) Builder {
        return .{ .outline = outline, .gpa = gpa };
    }

    /// Begin a contour. Closes the one before it, if any.
    pub fn moveTo(self: *Builder, point: Point) Allocator.Error!void {
        try self.close();
        try self.outline.commands.append(self.gpa, .{ .move = point });
        self.start = point;
        self.at = point;
        self.open = true;
    }

    /// A straight line to `point`.
    pub fn lineTo(self: *Builder, point: Point) Allocator.Error!void {
        try self.flushPending(point);
        try self.outline.commands.append(self.gpa, .{ .line = point });
        self.at = point;
    }

    /// An off-curve point.
    ///
    /// Not a command by itself, because what it means depends on the next
    /// point: followed by an on-curve point it is one curve, and followed by
    /// another off-curve point it is two, meeting at the midpoint. Holding it
    /// here is what lets the caller not care.
    pub fn controlAt(self: *Builder, control: Point) Allocator.Error!void {
        if (self.pending) |held| {
            // Two in a row: the on-curve point between them is implied.
            const between = Point.midpoint(held, control);
            try self.outline.commands.append(self.gpa, .{
                .quadratic = .{ .control = held, .to = between },
            });
            self.at = between;
        }
        self.pending = control;
    }

    /// An on-curve point, using whatever control point is waiting.
    pub fn curveTo(self: *Builder, point: Point) Allocator.Error!void {
        if (self.pending) |held| {
            try self.outline.commands.append(self.gpa, .{
                .quadratic = .{ .control = held, .to = point },
            });
            self.pending = null;
        } else {
            try self.outline.commands.append(self.gpa, .{ .line = point });
        }
        self.at = point;
    }

    /// Finish the current contour, back at its beginning.
    pub fn close(self: *Builder) Allocator.Error!void {
        if (!self.open) return;
        // A control point left over at the end of a ring curves back to the
        // start, which is what makes an `o` round at the top rather than
        // having a notch in it.
        try self.flushPending(self.start);
        try self.outline.commands.append(self.gpa, .close);
        self.at = self.start;
        self.pending = null;
        self.open = false;
    }

    fn flushPending(self: *Builder, next: Point) Allocator.Error!void {
        const held = self.pending orelse return;
        self.pending = null;
        try self.outline.commands.append(self.gpa, .{
            .quadratic = .{ .control = held, .to = next },
        });
        self.at = next;
    }
};

test "a builder makes a closed triangle" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.lineTo(.init(10, 0));
    try builder.lineTo(.init(5, 10));
    try builder.close();

    try testing.expectEqual(4, outline.commands.items.len);
    try testing.expectEqual(Command.move, std.meta.activeTag(outline.commands.items[0]));
    try testing.expectEqual(Command.close, std.meta.activeTag(outline.commands.items[3]));
    try testing.expectEqual(1, outline.contourCount());
    try testing.expect(!outline.isEmpty());
}

test "two off-curve points in a row imply an on-curve point between them" {
    // This is the rule that makes TrueType outlines compact, and the one a
    // naive reader gets wrong - it produces a shape with corners where the
    // font has curves.
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.controlAt(.init(10, 0));
    try builder.controlAt(.init(20, 0));
    try builder.curveTo(.init(30, 0));
    try builder.close();

    // Two curves, not one, and the first ends halfway between the controls.
    var curves: usize = 0;
    for (outline.commands.items) |command| {
        if (command == .quadratic) curves += 1;
    }
    try testing.expectEqual(2, curves);
    try testing.expectEqual(Point.init(15, 0), outline.commands.items[1].quadratic.to);
}

test "a control point left over at the end curves back to the start" {
    // An `o` has no on-curve point at the top of its ring, and a reader that
    // dropped the leftover control would leave a notch there.
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.lineTo(.init(10, 0));
    try builder.controlAt(.init(10, 10));
    try builder.close();

    const last = outline.commands.items[outline.commands.items.len - 2];
    try testing.expectEqual(Command.quadratic, std.meta.activeTag(last));
    try testing.expectEqual(Point.init(0, 0), last.quadratic.to);
}

test "an on-curve point with no control waiting is a straight line" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.curveTo(.init(10, 0));
    try builder.close();

    try testing.expectEqual(Command.line, std.meta.activeTag(outline.commands.items[1]));
}

test "a new contour closes the one before it" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.lineTo(.init(10, 0));
    try builder.moveTo(.init(20, 20));
    try builder.lineTo(.init(30, 20));
    try builder.close();

    try testing.expectEqual(2, outline.contourCount());
    // move, line, close, move, line, close
    try testing.expectEqual(6, outline.commands.items.len);
    try testing.expectEqual(Command.close, std.meta.activeTag(outline.commands.items[2]));
}

test "bounds cover every point, control points included" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.controlAt(.init(50, 100));
    try builder.curveTo(.init(100, 0));
    try builder.close();

    const box = outline.bounds();
    try testing.expectEqual(@as(f32, 0), box.min_x);
    try testing.expectEqual(@as(f32, 100), box.max_x);
    // Generous by design: the curve peaks at y = 50, and the control point
    // at y = 100 is what the box is measured to.
    try testing.expectEqual(@as(f32, 100), box.max_y);
    try testing.expectEqual(@as(f32, 100), box.width());
}

test "an empty outline has empty bounds and nothing to draw" {
    const outline: Outline = .{};
    try testing.expect(outline.isEmpty());
    try testing.expect(outline.bounds().isEmpty());
    try testing.expectEqual(0, outline.contourCount());
}

test "a transform moves and scales every point" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.controlAt(.init(10, 20));
    try builder.curveTo(.init(20, 0));
    try builder.close();

    // Half size, flipped in y, moved right - which is roughly what turning
    // font units into pixels does.
    outline.transform(0.5, -0.5, 100, 50);

    try testing.expectEqual(Point.init(100, 50), outline.commands.items[0].move);
    try testing.expectEqual(Point.init(105, 40), outline.commands.items[1].quadratic.control);
    try testing.expectEqual(Point.init(110, 50), outline.commands.items[1].quadratic.to);
}

test "clearing keeps the memory for the next glyph" {
    var outline: Outline = .{};
    defer outline.deinit(testing.allocator);

    var builder: Builder = .init(testing.allocator, &outline);
    try builder.moveTo(.init(0, 0));
    try builder.lineTo(.init(1, 1));
    try builder.close();

    const capacity = outline.commands.capacity;
    outline.clear();

    try testing.expect(outline.isEmpty());
    try testing.expectEqual(capacity, outline.commands.capacity);
}
