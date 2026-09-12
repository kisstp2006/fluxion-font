// SPDX-License-Identifier: BSD-2-Clause

//! `CFF `: PostScript outlines, and the small machine that draws them.
//!
//! An OpenType font is one of two things wearing the same container. With
//! `glyf` it is TrueType: rings of points. With `CFF ` it is PostScript: each
//! glyph is a **charstring**, a little program in a stack language that the
//! reader runs, and the shape is what the program drew. Most fonts made by a
//! type foundry in the last twenty years are this kind - the `.otf` files
//! bought, bundled with a design tool, or served as a webfont - so a text
//! stack that reads only `glyf` refuses about half of what a designer hands
//! it.
//!
//! The table is a small file system of its own, and the order things are
//! read in is the order the format lays them out:
//!
//!   1. A header, and then four **INDEX**es - a counted list of byte
//!      strings with an offset table in front, the one structure everything
//!      in CFF is built from. The four are the font names, the **Top DICT**s,
//!      the strings, and the global subroutines.
//!   2. The Top DICT is a run of operand-operator pairs, and it says where
//!      the **CharStrings** INDEX is (one charstring per glyph, in glyph
//!      order) and where the **Private DICT** is, which in turn says where
//!      the local subroutines are.
//!   3. Each charstring is run by `Machine`, which is the Type 2 charstring
//!      interpreter: about thirty operators for lines, curves, hints and
//!      subroutine calls, all in relative coordinates. The hints are counted
//!      and skipped - see the note on hinting in `Font` - and the drawing
//!      operators go into an `outline.Builder` as cubics.
//!
//! Four places a reader of this format goes wrong, each with the test that
//! catches it:
//!
//!   1. **The width is an optional first argument.** A charstring may begin
//!      with its advance width, and nothing marks it: the reader knows it was
//!      there because the first operator has one argument more than it
//!      takes. Miss this and every glyph is drawn shifted by its own width.
//!   2. **Subroutine numbers are biased.** A `callsubr` operand is not the
//!      index; it is the index minus 107, 1131 or 32768 depending on how many
//!      subroutines there are, so that small numbers - which encode in one
//!      byte - reach the middle of a large table. Forget the bias and every
//!      call lands on the wrong routine.
//!   3. **`hintmask` has data after it**, one bit per stem declared so far,
//!      rounded up to bytes - and the stems it counts include the vertical
//!      ones it implicitly declares from whatever is on the stack. Read the
//!      mask bytes as operators and the glyph is garbage from there on.
//!   4. **A CID-keyed font has many Private DICTs**, one per font dict, and
//!      a table saying which glyph uses which. The local subroutines a
//!      charstring calls are the ones of *its* font dict, and a reader that
//!      keeps one set draws every CJK font with the wrong shapes.
//!
//! What is not here: `CFF2`, the variable-font form, which has a different
//! header, no Top DICT and blended operands - and which no static font
//! carries. Fonts with an `Encoding` are read but the encoding is not, since
//! `cmap` is what maps characters in an OpenType font.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const outline = @import("outline.zig");
const sfnt = @import("sfnt.zig");

const Error = sfnt.Error || Allocator.Error;
const File = sfnt.File;
const Outline = outline.Outline;
const Point = outline.Point;
const View = sfnt.View;

/// Read a glyph's shape out of a font, in font units.
///
/// The whole path in one call, for a caller that wants one glyph. Parsing the
/// table again each time is a header, four INDEX offsets and two DICTs - a
/// few dozen bounds-checked reads against the cost of running the
/// charstring - so it costs less than it looks. A caller filling an atlas
/// wants `Cff.read` once and `Cff.outlineOf` per glyph.
pub fn read(gpa: Allocator, file: File, glyph: u16, out: *Outline) Error!void {
    const table: Cff = try .read(file);
    return table.outlineOf(gpa, glyph, out);
}

/// How deep subroutine calls may nest before this gives up.
///
/// The specification's limit is ten, and it is a limit on the font, not a
/// suggestion to the reader: a font that nests deeper is malformed. Here it
/// is also what stops a subroutine that calls itself from running until the
/// stack is gone.
pub const max_subroutine_depth = 10;

/// How many glyphs a `seac` accent composition may stack before this gives
/// up. The operator builds one glyph from two others, and a crafted font
/// can make one of those two the glyph being built.
const max_seac_depth = 4;

// -------------------------------------------------------------------------
// The structures the table is built from
// -------------------------------------------------------------------------

/// A counted list of byte strings: the one structure CFF is made of.
///
/// A two-byte count, one byte saying how wide the offsets are, `count + 1`
/// offsets of that width, and then the data the offsets point into. The
/// offsets are **one-based** - the first item starts at offset 1 - which is
/// a detail from a time when zero meant "not present", and which is worth
/// one comment here rather than one off-by-one bug per reader.
pub const Index = struct {
    count: u16,
    offset_size: u8,
    /// The `count + 1` offsets, each `offset_size` bytes.
    offsets: View,
    /// The data, positioned so that offset 1 is its first byte.
    data: View,

    pub const empty: Index = .{ .count = 0, .offset_size = 1, .offsets = .empty, .data = .empty };

    /// Read the INDEX at `at`, and say where it ends - because the next
    /// structure begins there, and nothing else in the file says where.
    pub fn parse(table: View, at: usize) Error!struct { index: Index, end: usize } {
        const count = try table.int(u16, at);
        // An empty INDEX is the count and nothing else: no offset size and
        // no offsets, which is why this cannot be one path.
        if (count == 0) return .{ .index = .empty, .end = at + 2 };

        const offset_size = try table.int(u8, at + 2);
        if (offset_size < 1 or offset_size > 4) return error.Malformed;

        const offsets = try table.slice(at + 3, (@as(usize, count) + 1) * offset_size);
        // The first data byte is offset 1, so offset `k` is `k - 1` bytes
        // into the data - and the last offset, one past the final item, is
        // the data's length plus one.
        const data_at = at + 3 + offsets.len();

        var index: Index = .{
            .count = count,
            .offset_size = offset_size,
            .offsets = offsets,
            .data = .empty,
        };
        const last = try index.offset(count);
        if (last < 1) return error.Malformed;
        index.data = try table.slice(data_at, last - 1);
        return .{ .index = index, .end = data_at + last - 1 };
    }

    /// The `i`th offset, whatever width they are stored in.
    fn offset(self: Index, i: usize) Error!usize {
        var value: usize = 0;
        for (0..self.offset_size) |byte| {
            value = (value << 8) | try self.offsets.int(u8, i * self.offset_size + byte);
        }
        return value;
    }

    /// The `i`th item.
    pub fn get(self: Index, i: usize) Error!View {
        if (i >= self.count) return error.OutOfBounds;
        const start = try self.offset(i);
        const end = try self.offset(i + 1);
        if (start < 1 or end < start) return error.Malformed;
        return self.data.slice(start - 1, end - start);
    }
};

/// A DICT: operands, then the operator they belong to, over and over.
///
/// The same encoding a charstring uses for its numbers, with two more forms
/// for larger integers and one for reals - and the reason it is read with an
/// iterator rather than into a struct is that a Top DICT has some forty
/// possible operators and this library wants seven of them.
const Dict = struct {
    /// One operator, with what came before it. Escaped operators - the byte
    /// 12 followed by another - are numbered from 1200 so that both kinds
    /// fit in one integer and a `switch` can name either.
    const Entry = struct {
        op: u16,
        operands: []const f64,
    };

    const escape: u16 = 1200;

    at: sfnt.Cursor,
    operands: [48]f64 = undefined,

    fn init(dict: View) Dict {
        return .{ .at = dict.cursor(0) };
    }

    fn next(self: *Dict) Error!?Entry {
        var count: usize = 0;
        while (self.at.remaining() > 0) {
            const b0 = try self.at.int(u8);
            switch (b0) {
                0...21 => {
                    const op: u16 = if (b0 == 12) escape + try self.at.int(u8) else b0;
                    return .{ .op = op, .operands = self.operands[0..count] };
                },
                28 => try self.push(&count, @floatFromInt(try self.at.int(i16))),
                29 => try self.push(&count, @floatFromInt(try self.at.int(i32))),
                30 => try self.push(&count, try self.real()),
                32...246 => try self.push(&count, @floatFromInt(@as(i32, b0) - 139)),
                247...250 => {
                    const b1: i32 = try self.at.int(u8);
                    try self.push(&count, @floatFromInt((@as(i32, b0) - 247) * 256 + b1 + 108));
                },
                251...254 => {
                    const b1: i32 = try self.at.int(u8);
                    try self.push(&count, @floatFromInt(-(@as(i32, b0) - 251) * 256 - b1 - 108));
                },
                else => return error.Malformed,
            }
        }
        // Operands with no operator after them. Nothing to return, and
        // nothing for a caller to do with them.
        return null;
    }

    fn push(self: *Dict, count: *usize, value: f64) Error!void {
        if (count.* >= self.operands.len) return error.Malformed;
        self.operands[count.*] = value;
        count.* += 1;
    }

    /// A real number, stored as nibbles: digits, a point, an exponent
    /// marker, a minus sign, and `f` to end. Written out as text and parsed
    /// back, because the standard library already knows how to read
    /// `-1.5e3` and the nibble stream is that with the characters halved.
    fn real(self: *Dict) Error!f64 {
        var text: [48]u8 = undefined;
        var length: usize = 0;
        done: while (true) {
            const byte = try self.at.int(u8);
            for ([2]u4{ @intCast(byte >> 4), @intCast(byte & 0xF) }) |nibble| {
                const digit = [1]u8{'0' + @as(u8, nibble)};
                const piece: []const u8 = switch (nibble) {
                    0...9 => &digit,
                    0xa => ".",
                    0xb => "E",
                    0xc => "E-",
                    0xe => "-",
                    0xf => break :done,
                    else => return error.Malformed,
                };
                if (length + piece.len > text.len) return error.Malformed;
                @memcpy(text[length..][0..piece.len], piece);
                length += piece.len;
            }
        }
        return std.fmt.parseFloat(f64, text[0..length]) catch error.Malformed;
    }
};

/// What this library wants out of a Top DICT, with the defaults the
/// specification gives a field that is absent.
const TopDict = struct {
    char_strings: ?u32 = null,
    private: ?struct { size: u32, offset: u32 } = null,
    /// Zero means the predefined ISOAdobe charset, where glyph `i` has
    /// string `i`. One and two are the Expert charsets, which no OpenType
    /// font has used since the format that needed them was retired.
    charset: u32 = 0,
    charstring_type: u32 = 2,
    /// Set by the `ROS` operator, which only a CID-keyed font has.
    cid: bool = false,
    fd_array: ?u32 = null,
    fd_select: ?u32 = null,

    fn parse(dict: View) Error!TopDict {
        var top: TopDict = .{};
        var entries: Dict = .init(dict);
        while (try entries.next()) |entry| {
            const args = entry.operands;
            switch (entry.op) {
                15 => top.charset = try operand(u32, args, 0),
                17 => top.char_strings = try operand(u32, args, 0),
                18 => top.private = .{
                    .size = try operand(u32, args, 0),
                    .offset = try operand(u32, args, 1),
                },
                Dict.escape + 6 => top.charstring_type = try operand(u32, args, 0),
                Dict.escape + 30 => top.cid = true,
                Dict.escape + 36 => top.fd_array = try operand(u32, args, 0),
                Dict.escape + 37 => top.fd_select = try operand(u32, args, 0),
                else => {},
            }
        }
        return top;
    }
};

/// The one thing this library wants out of a Private DICT.
const PrivateDict = struct {
    /// Where the local subroutines are, **relative to the start of the
    /// Private DICT** rather than to the table - the one offset in CFF that
    /// is not from the beginning of the table, and a classic mistake.
    subrs: ?u32 = null,

    fn parse(dict: View) Error!PrivateDict {
        var private: PrivateDict = .{};
        var entries: Dict = .init(dict);
        while (try entries.next()) |entry| {
            if (entry.op == 19) private.subrs = try operand(u32, entry.operands, 0);
        }
        return private;
    }
};

/// The `i`th operand of a DICT entry as an integer, or `Malformed` if the
/// font left it out or wrote something that is not one.
fn operand(comptime T: type, operands: []const f64, i: usize) Error!T {
    if (i >= operands.len) return error.Malformed;
    const value = operands[i];
    if (value < 0 or value > std.math.maxInt(T) or value != @trunc(value)) return error.Malformed;
    return @intFromFloat(value);
}

// -------------------------------------------------------------------------
// The table
// -------------------------------------------------------------------------

/// The outlines of a PostScript font, and what a charstring needs to run.
pub const Cff = struct {
    table: View,
    char_strings: Index,
    global_subrs: Index,
    /// The local subroutines of a plain font's one Private DICT. Empty for a
    /// CID-keyed font, whose subroutines are per font dict - see `cid`.
    local_subrs: Index,
    /// The extra structure of a CID-keyed font: which font dict each glyph
    /// belongs to, and the dicts themselves. Null for a plain font.
    cid: ?struct { fd_select: View, fd_array: Index },
    /// Where the charset is; see `TopDict.charset`. Needed only by `seac`.
    charset: u32,

    /// Find the table and everything a charstring needs from it.
    pub fn read(file: File) Error!Cff {
        return parse(try file.required(.cff));
    }

    pub fn parse(table: View) Error!Cff {
        if (try table.int(u8, 0) != 1) return error.Malformed;
        const header_size = try table.int(u8, 2);

        // The four INDEXes, back to back, each found by where the last one
        // ended. Only two of them are kept: the names are for a font menu,
        // and the strings are for glyph names - which `seac` looks up by
        // number rather than by name, so even it does not need them.
        const names = try Index.parse(table, header_size);
        const top_dicts = try Index.parse(table, names.end);
        const strings = try Index.parse(table, top_dicts.end);
        const global_subrs = try Index.parse(table, strings.end);

        if (top_dicts.index.count < 1) return error.Malformed;
        const top: TopDict = try .parse(try top_dicts.index.get(0));

        if (top.charstring_type != 2) return error.Malformed;
        const char_strings_at = top.char_strings orelse return error.Malformed;
        const char_strings = try Index.parse(table, char_strings_at);

        var cff: Cff = .{
            .table = table,
            .char_strings = char_strings.index,
            .global_subrs = global_subrs.index,
            .local_subrs = .empty,
            .cid = null,
            .charset = top.charset,
        };

        if (top.cid) {
            const fd_array_at = top.fd_array orelse return error.Malformed;
            const fd_select_at = top.fd_select orelse return error.Malformed;
            cff.cid = .{
                .fd_select = try table.from(fd_select_at),
                .fd_array = (try Index.parse(table, fd_array_at)).index,
            };
        } else if (top.private) |private| {
            cff.local_subrs = try localSubrs(table, private.offset, private.size);
        }

        return cff;
    }

    /// The local subroutines a Private DICT points at, or none.
    fn localSubrs(table: View, offset: u32, size: u32) Error!Index {
        const dict = try table.slice(offset, size);
        const private: PrivateDict = try .parse(dict);
        const subrs = private.subrs orelse return .empty;
        return (try Index.parse(table, offset + subrs)).index;
    }

    /// How many glyphs there are, by the charstrings. The same number as
    /// `maxp` in a well-formed font; the smaller of the two is what a caller
    /// should loop to.
    pub inline fn glyphCount(self: Cff) u16 {
        return self.char_strings.count;
    }

    /// The local subroutines a glyph's charstring may call.
    ///
    /// For a plain font, the one set. For a CID-keyed font, the set of
    /// whichever font dict `FDSelect` assigns the glyph to, which means
    /// reading that dict and its Private DICT here - two small DICT walks per
    /// glyph, and the same trade `glyf` makes in re-reading `loca`.
    fn localSubrsFor(self: Cff, glyph: u16) Error!Index {
        const cid = self.cid orelse return self.local_subrs;
        const fd = try fdSelect(cid.fd_select, glyph);
        const dict: TopDict = try .parse(try cid.fd_array.get(fd));
        const private = dict.private orelse return .empty;
        return localSubrs(self.table, private.offset, private.size);
    }

    /// Which font dict a glyph belongs to.
    ///
    /// Two formats: a byte per glyph, or ranges of glyphs that share one.
    /// The ranges are sorted, and a CJK font has a few hundred of them over
    /// tens of thousands of glyphs - enough that filling an atlas is worth a
    /// binary search rather than a scan.
    fn fdSelect(table: View, glyph: u16) Error!u8 {
        switch (try table.int(u8, 0)) {
            0 => return table.int(u8, 1 + @as(usize, glyph)),
            3 => {
                const count = try table.int(u16, 1);
                const sentinel = try table.int(u16, 3 + @as(usize, count) * 3);
                if (glyph >= sentinel) return error.OutOfBounds;

                // The last range whose first glyph is at or before this one.
                var low: usize = 0;
                var high: usize = count;
                while (high - low > 1) {
                    const middle = low + (high - low) / 2;
                    if (try table.int(u16, 3 + middle * 3) <= glyph) low = middle else high = middle;
                }
                return table.int(u8, 3 + low * 3 + 2);
            },
            else => return error.Malformed,
        }
    }

    /// Read a glyph's shape into `out`, in font units.
    ///
    /// `out` is cleared first, for the reason `glyf.Glyf.outlineOf` gives: a
    /// caller filling an atlas reuses one allocation for every glyph.
    pub fn outlineOf(self: Cff, gpa: Allocator, glyph: u16, out: *Outline) Error!void {
        out.clear();
        try self.readInto(gpa, glyph, out, 0);
    }

    fn readInto(self: Cff, gpa: Allocator, glyph: u16, out: *Outline, depth: u8) Error!void {
        if (depth > max_seac_depth) return error.Malformed;
        // Past the end is nothing to draw rather than an error, as in `glyf`:
        // a glyph index is something the caller got from `cmap`, and a
        // `cmap` that points past the charstrings is the font's fault.
        if (glyph >= self.char_strings.count) return;

        var machine: Machine = .{
            .cff = &self,
            .builder = .init(gpa, out),
            .local_subrs = try self.localSubrsFor(glyph),
        };
        _ = try machine.run(try self.char_strings.get(glyph));
        try machine.builder.close();

        // An accented letter built from two others. The base is drawn where
        // it is; the accent is drawn separately and moved - which is what
        // `glyf` does for a composite, and the same `Outline.append` serves.
        const seac = machine.seac orelse return;
        try self.readInto(gpa, try self.glyphForStandardCode(seac.base), out, depth + 1);

        var accent: Outline = .empty;
        defer accent.deinit(gpa);
        try self.readInto(gpa, try self.glyphForStandardCode(seac.accent), &accent, depth + 1);
        accent.transform(1, 1, seac.dx, seac.dy);
        try out.append(gpa, accent);
    }

    /// The glyph that `seac` means by a Standard Encoding code.
    ///
    /// The operator names its two parts by their codes in the Standard
    /// Encoding - a table from 1985 that gives `A` the code 65 and `grave`
    /// the code 193 - which map to string numbers, which the charset maps to
    /// glyphs. Three lookups for one accent, and the reason the charset is
    /// read at all.
    fn glyphForStandardCode(self: Cff, code: u8) Error!u16 {
        const sid = standard_encoding[code];
        if (sid == 0) return error.Malformed;

        switch (self.charset) {
            // ISOAdobe: glyph `i` is string `i`, no table needed.
            0 => return if (sid < self.char_strings.count) sid else error.Malformed,
            // The Expert charsets. Predefined, enormous, and not carried
            // here: a font that composes accents through them is one this
            // library will not have met.
            1, 2 => return error.Malformed,
            else => {},
        }

        const charset = try self.table.from(self.charset);
        const count = self.char_strings.count;
        // Glyph zero is `.notdef` and is not stored; the table starts at one.
        switch (try charset.int(u8, 0)) {
            0 => {
                for (1..count) |glyph| {
                    if (try charset.int(u16, 1 + (glyph - 1) * 2) == sid) return @intCast(glyph);
                }
            },
            1, 2 => |format| {
                // Runs of consecutive strings: a first, and how many follow.
                var at = charset.cursor(1);
                var glyph: u32 = 1;
                while (glyph < count) {
                    const first = try at.int(u16);
                    const left: u32 = if (format == 1) try at.int(u8) else try at.int(u16);
                    if (sid >= first and sid <= first + left) {
                        const found = glyph + (sid - first);
                        return if (found < count) @intCast(found) else error.Malformed;
                    }
                    glyph += left + 1;
                }
            },
            else => return error.Malformed,
        }
        return error.Malformed;
    }
};

/// The Standard Encoding, as the string number each code stands for.
///
/// Codes 32 to 126 are the printable ASCII range and map to strings 1 to 95
/// in order; the upper half is the Adobe set of accents, ligatures and
/// currency signs at the positions the 1985 table put them. Zero is a code
/// with nothing at it. Only `seac` looks here.
const standard_encoding: [256]u16 = blk: {
    var table: [256]u16 = @splat(0);
    for (32..127) |code| table[code] = @intCast(code - 31);
    const upper = [_]struct { u8, u16 }{
        .{ 161, 96 },  .{ 162, 97 },  .{ 163, 98 },  .{ 164, 99 },  .{ 165, 100 }, .{ 166, 101 },
        .{ 167, 102 }, .{ 168, 103 }, .{ 169, 104 }, .{ 170, 105 }, .{ 171, 106 }, .{ 172, 107 },
        .{ 173, 108 }, .{ 174, 109 }, .{ 175, 110 }, .{ 177, 111 }, .{ 178, 112 }, .{ 179, 113 },
        .{ 180, 114 }, .{ 182, 115 }, .{ 183, 116 }, .{ 184, 117 }, .{ 185, 118 }, .{ 186, 119 },
        .{ 187, 120 }, .{ 188, 121 }, .{ 189, 122 }, .{ 191, 123 }, .{ 193, 124 }, .{ 194, 125 },
        .{ 195, 126 }, .{ 196, 127 }, .{ 197, 128 }, .{ 198, 129 }, .{ 199, 130 }, .{ 200, 131 },
        .{ 202, 132 }, .{ 203, 133 }, .{ 205, 134 }, .{ 206, 135 }, .{ 207, 136 }, .{ 208, 137 },
        .{ 225, 138 }, .{ 227, 139 }, .{ 232, 140 }, .{ 233, 141 }, .{ 234, 142 }, .{ 235, 143 },
        .{ 241, 144 }, .{ 245, 145 }, .{ 248, 146 }, .{ 249, 147 }, .{ 250, 148 }, .{ 251, 149 },
    };
    for (upper) |pair| table[pair[0]] = pair[1];
    break :blk table;
};

// -------------------------------------------------------------------------
// The charstring interpreter
// -------------------------------------------------------------------------

/// The Type 2 charstring machine: a stack of numbers, a pen, and the
/// operators that move one by taking from the other.
///
/// Everything is relative. The pen starts at the origin and every operator
/// moves it by the deltas on the stack, which is what makes the encoding
/// compact - a stem 20 units wide is `20` however far across the glyph it
/// is - and what makes a single misread number wrong for the rest of the
/// glyph rather than for one point.
const Machine = struct {
    cff: *const Cff,
    builder: outline.Builder,
    local_subrs: Index,

    /// The operand stack. Forty-eight is the specification's limit, and a
    /// charstring that needs more is one this refuses rather than one it
    /// grows for.
    stack: [48]f32 = undefined,
    top: usize = 0,
    /// The transient array, for the `put` and `get` operators - scratch
    /// storage some old fonts use in place of a second stack.
    transient: [32]f32 = @splat(0),

    x: f32 = 0,
    y: f32 = 0,
    /// How many stems have been declared, which is how wide a `hintmask` is.
    stems: u32 = 0,
    /// Whether the first stack-clearing operator has been and gone, taking
    /// the optional width with it. See `takeWidth`.
    width_seen: bool = false,
    depth: u8 = 0,
    /// A composition requested by `endchar`, to be carried out by the caller
    /// once this machine is done - it needs two more charstrings run, and a
    /// machine is one charstring.
    seac: ?struct { base: u8, accent: u8, dx: f32, dy: f32 } = null,

    /// The number a `callsubr` operand has added to it. Small operands take
    /// one byte, so the bias puts the one-byte range over the middle of the
    /// table where the most-used routines are placed.
    fn bias(count: u16) i32 {
        return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
    }

    /// Run one charstring. True when it reached `endchar`, which ends the
    /// glyph even from inside a subroutine; false when it returned or ran
    /// out of bytes.
    fn run(self: *Machine, code: View) Error!bool {
        var at = code.cursor(0);
        while (at.remaining() > 0) {
            const b0 = try at.int(u8);
            switch (b0) {
                // Numbers. The same scheme as a DICT for the one-, two- and
                // three-byte forms; the five-byte form here is a 16.16 fixed
                // point rather than an integer, which is the one place the
                // two encodings disagree.
                32...246 => try self.push(@floatFromInt(@as(i32, b0) - 139)),
                247...250 => {
                    const b1: i32 = try at.int(u8);
                    try self.push(@floatFromInt((@as(i32, b0) - 247) * 256 + b1 + 108));
                },
                251...254 => {
                    const b1: i32 = try at.int(u8);
                    try self.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - b1 - 108));
                },
                28 => try self.push(@floatFromInt(try at.int(i16))),
                255 => try self.push(@as(f32, @floatFromInt(try at.int(i32))) / 65536.0),

                // Hints: counted, and otherwise ignored.
                1, 3, 18, 23 => {
                    self.takeWidth(self.top % 2 == 1);
                    self.stems += @intCast(self.top / 2);
                    self.top = 0;
                },
                19, 20 => {
                    // Arguments still on the stack here are vertical stems
                    // the font did not bother to name with `vstem`. They
                    // count, and the mask that follows is one bit per stem.
                    self.takeWidth(self.top % 2 == 1);
                    self.stems += @intCast(self.top / 2);
                    self.top = 0;
                    try at.skip((self.stems + 7) / 8);
                },

                // Moves, which begin a contour.
                21 => {
                    self.takeWidth(self.top > 2);
                    try self.moveBy(self.arg(0), self.arg(1));
                    self.top = 0;
                },
                22 => {
                    self.takeWidth(self.top > 1);
                    try self.moveBy(self.arg(0), 0);
                    self.top = 0;
                },
                4 => {
                    self.takeWidth(self.top > 1);
                    try self.moveBy(0, self.arg(0));
                    self.top = 0;
                },

                // Lines.
                5 => {
                    var i: usize = 0;
                    while (i + 2 <= self.top) : (i += 2) try self.lineBy(self.arg(i), self.arg(i + 1));
                    self.top = 0;
                },
                6, 7 => {
                    // Alternating: `hlineto` is horizontal, vertical,
                    // horizontal...; `vlineto` starts the other way.
                    for (0..self.top) |i| {
                        const horizontal = (i % 2 == 0) == (b0 == 6);
                        if (horizontal) try self.lineBy(self.arg(i), 0) else try self.lineBy(0, self.arg(i));
                    }
                    self.top = 0;
                },

                // Curves.
                8 => {
                    var i: usize = 0;
                    while (i + 6 <= self.top) : (i += 6) try self.curveBy(self.args6(i));
                    self.top = 0;
                },
                24 => {
                    // Curves, then one line.
                    var i: usize = 0;
                    while (self.top - i >= 8) : (i += 6) try self.curveBy(self.args6(i));
                    if (self.top - i == 2) try self.lineBy(self.arg(i), self.arg(i + 1));
                    self.top = 0;
                },
                25 => {
                    // Lines, then one curve.
                    var i: usize = 0;
                    while (self.top - i >= 8) : (i += 2) try self.lineBy(self.arg(i), self.arg(i + 1));
                    if (self.top - i == 6) try self.curveBy(self.args6(i));
                    self.top = 0;
                },
                26, 27 => {
                    // `vvcurveto` and `hhcurveto`: every curve starts and
                    // ends going the same way, and the odd first argument if
                    // there is one is a sideways nudge on the first curve.
                    var i: usize = 0;
                    var nudge: f32 = 0;
                    if (self.top % 4 == 1) {
                        nudge = self.arg(0);
                        i = 1;
                    }
                    while (i + 4 <= self.top) : (i += 4) {
                        const a = self.arg(i);
                        const b = self.arg(i + 1);
                        const c = self.arg(i + 2);
                        const d = self.arg(i + 3);
                        if (b0 == 26) {
                            try self.curveBy(.{ nudge, a, b, c, 0, d });
                        } else {
                            try self.curveBy(.{ a, nudge, b, c, d, 0 });
                        }
                        nudge = 0;
                    }
                    self.top = 0;
                },
                30, 31 => {
                    // `vhcurveto` and `hvcurveto`: each curve starts one way
                    // and ends the other, alternating, and a fifth argument
                    // on the last one lets it end slightly off-axis.
                    var horizontal = b0 == 31;
                    var i: usize = 0;
                    while (i + 4 <= self.top) : (i += 4) {
                        const a = self.arg(i);
                        const b = self.arg(i + 1);
                        const c = self.arg(i + 2);
                        const d = self.arg(i + 3);
                        const last: f32 = if (self.top - i == 5) self.arg(i + 4) else 0;
                        if (horizontal) {
                            try self.curveBy(.{ a, 0, b, c, last, d });
                        } else {
                            try self.curveBy(.{ 0, a, b, c, d, last });
                        }
                        horizontal = !horizontal;
                    }
                    self.top = 0;
                },

                // Subroutines.
                10 => if (try self.call(self.local_subrs)) return true,
                29 => if (try self.call(self.cff.global_subrs)) return true,
                11 => return false,

                14 => {
                    // A width may be here too, on a glyph with no other
                    // operator - a space - or in front of a composition.
                    self.takeWidth(self.top == 1 or self.top == 5);
                    if (self.top == 4) {
                        self.seac = .{
                            .dx = self.arg(0),
                            .dy = self.arg(1),
                            .base = std.math.lossyCast(u8, self.arg(2)),
                            .accent = std.math.lossyCast(u8, self.arg(3)),
                        };
                    }
                    self.top = 0;
                    return true;
                },

                12 => try self.escaped(try at.int(u8)),

                else => return error.Malformed,
            }
        }
        return false;
    }

    /// The two-byte operators: the flex family, and the arithmetic that
    /// Type 1 fonts converted to Type 2 sometimes still carry.
    fn escaped(self: *Machine, op: u8) Error!void {
        switch (op) {
            // Flex: two curves that together are nearly flat, which a
            // renderer at small sizes may draw as a line. This one never
            // does; the two curves are drawn as given.
            35 => {
                if (self.top < 13) return error.Malformed;
                try self.curveBy(self.args6(0));
                try self.curveBy(self.args6(6));
                self.top = 0;
            },
            34 => {
                // `hflex`: both curves horizontal at the ends, and the
                // second comes back to the height the first left.
                if (self.top < 7) return error.Malformed;
                const y0 = self.y;
                try self.curveBy(.{ self.arg(0), 0, self.arg(1), self.arg(2), self.arg(3), 0 });
                try self.curveBy(.{ self.arg(4), 0, self.arg(5), y0 - self.y, self.arg(6), 0 });
                self.top = 0;
            },
            36 => {
                // `hflex1`: like `hflex`, with the first and last control
                // points free to move vertically.
                if (self.top < 9) return error.Malformed;
                const y0 = self.y;
                try self.curveBy(.{ self.arg(0), self.arg(1), self.arg(2), self.arg(3), self.arg(4), 0 });
                const c1: Point = .init(self.x + self.arg(5), self.y);
                const c2: Point = .init(c1.x + self.arg(6), c1.y + self.arg(7));
                try self.curveTo(c1, c2, .init(c2.x + self.arg(8), y0));
                self.top = 0;
            },
            37 => {
                // `flex1`: the endpoint's last delta is given for one axis
                // only - whichever the whole flex moved further along - and
                // the other axis returns to where it started.
                if (self.top < 11) return error.Malformed;
                const x0 = self.x;
                const y0 = self.y;
                var dx: f32 = 0;
                var dy: f32 = 0;
                for (0..5) |i| {
                    dx += self.arg(i * 2);
                    dy += self.arg(i * 2 + 1);
                }
                try self.curveBy(self.args6(0));
                const c1: Point = .init(self.x + self.arg(6), self.y + self.arg(7));
                const c2: Point = .init(c1.x + self.arg(8), c1.y + self.arg(9));
                const end: Point = if (@abs(dx) > @abs(dy))
                    .init(c2.x + self.arg(10), y0)
                else
                    .init(x0, c2.y + self.arg(10));
                try self.curveTo(c1, c2, end);
                self.top = 0;
            },

            // Arithmetic. Deprecated since 2000 and rare, and cheap enough
            // to have rather than refuse a font over.
            3 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return if (a != 0 and b != 0) 1 else 0;
                }
            }.f),
            4 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return if (a != 0 or b != 0) 1 else 0;
                }
            }.f),
            5 => try self.unary(struct {
                fn f(a: f32) f32 {
                    return if (a == 0) 1 else 0;
                }
            }.f),
            9 => try self.unary(struct {
                fn f(a: f32) f32 {
                    return @abs(a);
                }
            }.f),
            10 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return a + b;
                }
            }.f),
            11 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return a - b;
                }
            }.f),
            12 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return if (b == 0) 0 else a / b;
                }
            }.f),
            14 => try self.unary(struct {
                fn f(a: f32) f32 {
                    return -a;
                }
            }.f),
            15 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return if (a == b) 1 else 0;
                }
            }.f),
            18 => _ = try self.pop(),
            20 => {
                const i = try self.pop();
                const value = try self.pop();
                const slot = std.math.lossyCast(usize, i);
                if (slot >= self.transient.len) return error.Malformed;
                self.transient[slot] = value;
            },
            21 => {
                const slot = std.math.lossyCast(usize, try self.pop());
                if (slot >= self.transient.len) return error.Malformed;
                try self.push(self.transient[slot]);
            },
            22 => {
                const v2 = try self.pop();
                const v1 = try self.pop();
                const s2 = try self.pop();
                const s1 = try self.pop();
                try self.push(if (v1 <= v2) s1 else s2);
            },
            // `random` is meant to give a number in (0, 1]. A glyph that
            // depends on one is not reproducible, and half is a fair answer.
            23 => try self.push(0.5),
            24 => try self.binary(struct {
                fn f(a: f32, b: f32) f32 {
                    return a * b;
                }
            }.f),
            26 => try self.unary(struct {
                fn f(a: f32) f32 {
                    return @sqrt(@abs(a));
                }
            }.f),
            27 => {
                const a = try self.pop();
                try self.push(a);
                try self.push(a);
            },
            28 => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(b);
                try self.push(a);
            },
            29 => {
                const i = std.math.lossyCast(usize, @max(0, try self.pop()));
                if (i >= self.top) return error.Malformed;
                try self.push(self.stack[self.top - 1 - i]);
            },
            30 => {
                const j = std.math.lossyCast(i32, try self.pop());
                const n = std.math.lossyCast(usize, try self.pop());
                if (n == 0 or n > self.top) return error.Malformed;
                const window = self.stack[self.top - n .. self.top];
                const shift: usize = @intCast(@mod(j, @as(i32, @intCast(n))));
                std.mem.rotate(f32, window, n - shift);
            },
            else => return error.Malformed,
        }
    }

    // ---- the stack ----

    fn push(self: *Machine, value: f32) Error!void {
        if (self.top >= self.stack.len) return error.Malformed;
        self.stack[self.top] = value;
        self.top += 1;
    }

    fn pop(self: *Machine) Error!f32 {
        if (self.top == 0) return error.Malformed;
        self.top -= 1;
        return self.stack[self.top];
    }

    fn unary(self: *Machine, comptime f: fn (f32) f32) Error!void {
        try self.push(f(try self.pop()));
    }

    fn binary(self: *Machine, comptime f: fn (f32, f32) f32) Error!void {
        const b = try self.pop();
        const a = try self.pop();
        try self.push(f(a, b));
    }

    /// The `i`th argument, or zero past the end. The drawing operators loop
    /// over what is there, and a short stack means fewer segments rather
    /// than a read of whatever was left in the array.
    inline fn arg(self: *const Machine, i: usize) f32 {
        return if (i < self.top) self.stack[i] else 0;
    }

    fn args6(self: *const Machine, i: usize) [6]f32 {
        return .{ self.arg(i), self.arg(i + 1), self.arg(i + 2), self.arg(i + 3), self.arg(i + 4), self.arg(i + 5) };
    }

    /// Drop the width, if the first operator of the glyph carried one.
    ///
    /// The width is the advance - the same number `hmtx` has, which is
    /// where this library reads it from - and it may or may not be in front
    /// of the first operator's arguments. The only way to know is that the
    /// operator has one argument more than it uses, which is what `extra`
    /// says. Whichever way, it is decided once: after the first
    /// stack-clearing operator there is never a width.
    fn takeWidth(self: *Machine, extra: bool) void {
        if (self.width_seen) return;
        self.width_seen = true;
        if (extra and self.top > 0) {
            std.mem.copyForwards(f32, self.stack[0 .. self.top - 1], self.stack[1..self.top]);
            self.top -= 1;
        }
    }

    // ---- the pen ----

    fn moveBy(self: *Machine, dx: f32, dy: f32) Error!void {
        self.x += dx;
        self.y += dy;
        try self.builder.moveTo(.init(self.x, self.y));
    }

    fn lineBy(self: *Machine, dx: f32, dy: f32) Error!void {
        self.x += dx;
        self.y += dy;
        try self.builder.lineTo(.init(self.x, self.y));
    }

    /// A curve by six deltas: to the first control point, from there to the
    /// second, and from there to the end. This is how every curve operator
    /// is written in the file, and the alternating and axis-aligned forms
    /// above are this with some of the six fixed at zero.
    fn curveBy(self: *Machine, d: [6]f32) Error!void {
        const c1: Point = .init(self.x + d[0], self.y + d[1]);
        const c2: Point = .init(c1.x + d[2], c1.y + d[3]);
        try self.curveTo(c1, c2, .init(c2.x + d[4], c2.y + d[5]));
    }

    fn curveTo(self: *Machine, c1: Point, c2: Point, to: Point) Error!void {
        // A curve before any move: the specification forbids it, and some
        // fonts do it anyway. Beginning a contour at the pen is what every
        // other reader does with them.
        if (!self.builder.open) try self.builder.moveTo(.init(self.x, self.y));
        self.x = to.x;
        self.y = to.y;
        try self.builder.cubicTo(c1, c2, to);
    }

    /// Call a subroutine out of `subrs`, by the biased number on the stack.
    fn call(self: *Machine, subrs: Index) Error!bool {
        const number = std.math.lossyCast(i32, try self.pop()) + bias(subrs.count);
        if (number < 0 or number >= subrs.count) return error.Malformed;
        if (self.depth >= max_subroutine_depth) return error.Malformed;

        self.depth += 1;
        defer self.depth -= 1;
        return self.run(try subrs.get(@intCast(number)));
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// The fixtures build a `CFF ` table byte by byte, INDEX by INDEX, and the
// charstrings are written as the list of numbers and operators they are.
// Nothing here comes from a real font; the tests that open one are in
// `Font` and `examples/inspect.zig`.

/// One token of a charstring, for writing fixtures.
const Token = union(enum) {
    /// A number, in the three-byte form so the fixture does not depend on
    /// the one-byte encoding being right - that has its own test.
    n: i16,
    /// A one-byte operator.
    op: u8,
    /// A two-byte operator, after the escape.
    esc: u8,
};

fn charstring(gpa: Allocator, tokens: []const Token) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    for (tokens) |token| {
        switch (token) {
            .n => |value| {
                var pair: [2]u8 = undefined;
                std.mem.writeInt(i16, &pair, value, .big);
                try bytes.append(gpa, 28);
                try bytes.appendSlice(gpa, &pair);
            },
            .op => |op| try bytes.append(gpa, op),
            .esc => |op| try bytes.appendSlice(gpa, &.{ 12, op }),
        }
    }
    return bytes.toOwnedSlice(gpa);
}

/// Write an INDEX with four-byte offsets, whatever the items.
fn writeIndex(gpa: Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    var pair: [2]u8 = undefined;
    std.mem.writeInt(u16, &pair, @intCast(items.len), .big);
    try out.appendSlice(gpa, &pair);
    if (items.len == 0) return;

    try out.append(gpa, 4);
    var offset: u32 = 1;
    var quad: [4]u8 = undefined;
    std.mem.writeInt(u32, &quad, offset, .big);
    try out.appendSlice(gpa, &quad);
    for (items) |item| {
        offset += @intCast(item.len);
        std.mem.writeInt(u32, &quad, offset, .big);
        try out.appendSlice(gpa, &quad);
    }
    for (items) |item| try out.appendSlice(gpa, item);
}

fn indexSize(items: []const []const u8) u32 {
    if (items.len == 0) return 2;
    var total: u32 = 3 + 4 * (@as(u32, @intCast(items.len)) + 1);
    for (items) |item| total += @intCast(item.len);
    return total;
}

/// A five-byte DICT integer, so an offset takes the same room whatever it is
/// and the layout can be computed before anything is written.
fn dictInt(gpa: Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var quad: [4]u8 = undefined;
    std.mem.writeInt(u32, &quad, value, .big);
    try out.append(gpa, 29);
    try out.appendSlice(gpa, &quad);
}

/// Build a plain `CFF ` table around these charstrings.
///
/// A header, a name, one Top DICT, no strings, the global subroutines, the
/// charstrings, then a Private DICT pointing at the local subroutines - in
/// that order, because the Top DICT's offsets have to be known before it is
/// written and everything after it is laid out to make them computable.
fn buildTestCff(gpa: Allocator, fixture: struct {
    char_strings: []const []const u8,
    local_subrs: []const []const u8 = &.{},
    global_subrs: []const []const u8 = &.{},
    /// A format 0 charset - a string number per glyph from glyph one - or
    /// none, meaning ISOAdobe.
    charset: []const u16 = &.{},
}) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // The Top DICT is always the same size: CharStrings, Private, and a
    // charset if there is one, each operand five bytes.
    const top_size: u32 = 6 + 11 + @as(u32, if (fixture.charset.len > 0) 6 else 0);
    const top_index_size: u32 = 3 + 8 + top_size;
    const name_index = indexSize(&.{"T"});
    const char_strings_at = 4 + name_index + top_index_size + 2 + indexSize(fixture.global_subrs);
    const charset_at = char_strings_at + indexSize(fixture.char_strings);
    const charset_size: u32 = if (fixture.charset.len > 0) 1 + 2 * @as(u32, @intCast(fixture.charset.len)) else 0;
    const private_at = charset_at + charset_size;
    const private_size: u32 = if (fixture.local_subrs.len > 0) 6 else 0;

    try out.appendSlice(gpa, &.{ 1, 0, 4, 4 });
    try writeIndex(gpa, &out, &.{"T"});

    var top: std.ArrayList(u8) = .empty;
    defer top.deinit(gpa);
    try dictInt(gpa, &top, char_strings_at);
    try top.append(gpa, 17);
    try dictInt(gpa, &top, private_size);
    try dictInt(gpa, &top, private_at);
    try top.append(gpa, 18);
    if (fixture.charset.len > 0) {
        try dictInt(gpa, &top, charset_at);
        try top.append(gpa, 15);
    }
    try writeIndex(gpa, &out, &.{top.items});

    try writeIndex(gpa, &out, &.{}); // strings
    try writeIndex(gpa, &out, fixture.global_subrs);
    try writeIndex(gpa, &out, fixture.char_strings);

    if (fixture.charset.len > 0) {
        try out.append(gpa, 0);
        for (fixture.charset) |sid| {
            var pair: [2]u8 = undefined;
            std.mem.writeInt(u16, &pair, sid, .big);
            try out.appendSlice(gpa, &pair);
        }
    }

    if (fixture.local_subrs.len > 0) {
        // Subrs, relative to the Private DICT: immediately after it.
        try dictInt(gpa, &out, private_size);
        try out.append(gpa, 19);
        try writeIndex(gpa, &out, fixture.local_subrs);
    }

    return out.toOwnedSlice(gpa);
}

fn readGlyph(gpa: Allocator, table: []const u8, glyph: u16, shape: *Outline) !void {
    const cff: Cff = try .parse(.{ .bytes = table });
    try cff.outlineOf(gpa, glyph, shape);
}

fn countCubics(shape: Outline) usize {
    var cubics: usize = 0;
    for (shape.commands.items) |command| {
        if (command == .cubic) cubics += 1;
    }
    return cubics;
}

/// `0 0 rmoveto 600 0 rlineto -300 700 rlineto`: the triangle every test
/// below draws, so the fixtures differ only in what is being tested.
const triangle = [_]Token{
    .{ .n = 0 },    .{ .n = 0 },   .{ .op = 21 },
    .{ .n = 600 },  .{ .n = 0 },   .{ .op = 5 },
    .{ .n = -300 }, .{ .n = 700 }, .{ .op = 5 },
};

fn expectTriangle(shape: Outline) !void {
    try testing.expectEqual(1, shape.contourCount());
    const box = shape.bounds();
    try testing.expectEqual(@as(f32, 0), box.min_x);
    try testing.expectEqual(@as(f32, 600), box.max_x);
    try testing.expectEqual(@as(f32, 0), box.min_y);
    try testing.expectEqual(@as(f32, 700), box.max_y);
}

test "an INDEX is a count, an offset width, one-based offsets and data" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try writeIndex(testing.allocator, &bytes, &.{ "ab", "", "cde" });
    try bytes.appendSlice(testing.allocator, "tail");

    const parsed = try Index.parse(.{ .bytes = bytes.items }, 0);
    try testing.expectEqual(3, parsed.index.count);
    // It ends exactly where the next thing begins.
    try testing.expectEqual(bytes.items.len - 4, parsed.end);

    try testing.expectEqualStrings("ab", (try parsed.index.get(0)).bytes);
    try testing.expectEqualStrings("", (try parsed.index.get(1)).bytes);
    try testing.expectEqualStrings("cde", (try parsed.index.get(2)).bytes);
    try testing.expectError(error.OutOfBounds, parsed.index.get(3));

    // An empty INDEX is two bytes and nothing else.
    const empty = try Index.parse(.{ .bytes = &.{ 0, 0, 9, 9 } }, 0);
    try testing.expectEqual(0, empty.index.count);
    try testing.expectEqual(2, empty.end);
}

test "a DICT reads every integer form, a real, and an escaped operator" {
    const bytes = [_]u8{
        0x8b, // 0
        247, 0, // 108
        251, 0, // -108
        28, 0x01, 0x00, // 256
        29, 0x00, 0x01, 0x00, 0x00, // 65536
        30, 0xe1, 0xa5, 0xf0, // -1.5, as nibbles: - 1 . 5 end
        17, // CharStrings
        12, 30, // ROS, escaped
    };
    var dict: Dict = .init(.{ .bytes = &bytes });

    const first = (try dict.next()).?;
    try testing.expectEqual(17, first.op);
    try testing.expectEqualSlices(f64, &.{ 0, 108, -108, 256, 65536, -1.5 }, first.operands);

    const second = (try dict.next()).?;
    try testing.expectEqual(Dict.escape + 30, second.op);
    try testing.expectEqual(0, second.operands.len);

    try testing.expectEqual(null, try dict.next());
}

test "a charstring of lines is one contour, closed" {
    const glyph = try charstring(testing.allocator, &triangle ++ [_]Token{.{ .op = 14 }});
    defer testing.allocator.free(glyph);
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);
    try expectTriangle(shape);
    try testing.expectEqual(outline.Command.close, std.meta.activeTag(shape.commands.items[shape.commands.items.len - 1]));
}

test "a width in front of the first operator is taken off, whichever operator it is" {
    // The same triangle three ways: a width before `rmoveto`, a width before
    // an `hstem` that comes first, and a width before a `hintmask`. Each
    // operator has one argument more than it takes, and each has to notice.
    const before_move = [_]Token{ .{ .n = 500 }, .{ .n = 0 }, .{ .n = 0 }, .{ .op = 21 } } ++ triangle[3..].* ++ [_]Token{.{ .op = 14 }};
    const before_stem = [_]Token{ .{ .n = 500 }, .{ .n = 10 }, .{ .n = 20 }, .{ .op = 1 } } ++ triangle ++ [_]Token{.{ .op = 14 }};
    const before_mask = [_]Token{ .{ .n = 500 }, .{ .n = 10 }, .{ .n = 20 }, .{ .op = 19 }, .{ .op = 0x80 } } ++ triangle ++ [_]Token{.{ .op = 14 }};

    for ([_][]const Token{ &before_move, &before_stem, &before_mask }) |tokens| {
        const glyph = try charstring(testing.allocator, tokens);
        defer testing.allocator.free(glyph);
        const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
        defer testing.allocator.free(table);

        var shape: Outline = .empty;
        defer shape.deinit(testing.allocator);
        try readGlyph(testing.allocator, table, 0, &shape);
        try expectTriangle(shape);
    }
}

test "the one-byte number forms and the 16.16 form decode as the specification says" {
    // `rmoveto` by the four numbers, then a line so there is a shape to
    // measure: 0 (byte 139), 107 (byte 246), 108 (247 0), -108 (251 0), and
    // 1.5 as a 32-bit fixed point after the 255 marker.
    const bytes = [_]u8{
        139, 246, 21, // 0 107 rmoveto
        247, 0, 251, 0, 5, // 108 -108 rlineto
        255, 0x00, 0x01, 0x80, 0x00, 139, 5, // 1.5 0 rlineto
        14,
    };
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{&bytes} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);

    try testing.expectEqual(Point.init(0, 107), shape.commands.items[0].move);
    try testing.expectEqual(Point.init(108, -1), shape.commands.items[1].line);
    try testing.expectEqual(Point.init(109.5, -1), shape.commands.items[2].line);
}

test "the alternating curve operators alternate, and come out cubic" {
    // `100 0 rmoveto`, then `hvcurveto` with two sets: the first starts
    // horizontal and ends vertical, the second the other way round.
    const glyph = try charstring(testing.allocator, &.{
        .{ .n = 100 }, .{ .n = 0 },    .{ .op = 21 },
        .{ .n = 100 }, .{ .n = 50 },   .{ .n = 50 },
        .{ .n = 100 }, .{ .n = 50 },   .{ .n = -50 },
        .{ .n = 50 },  .{ .n = -100 }, .{ .op = 31 },
        .{ .op = 14 },
    });
    defer testing.allocator.free(glyph);
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);

    try testing.expectEqual(2, countCubics(shape));
    const first = shape.commands.items[1].cubic;
    try testing.expectEqual(Point.init(200, 0), first.control1);
    try testing.expectEqual(Point.init(250, 50), first.control2);
    try testing.expectEqual(Point.init(250, 150), first.to);
    const second = shape.commands.items[2].cubic;
    try testing.expectEqual(Point.init(250, 200), second.control1);
    try testing.expectEqual(Point.init(200, 250), second.control2);
    try testing.expectEqual(Point.init(100, 250), second.to);
}

test "a local subroutine is found through its bias" {
    // The triangle lives in subroutine zero, and the glyph calls it by the
    // number -107 - which is zero once the bias for a small table is added.
    const subr = try charstring(testing.allocator, &triangle ++ [_]Token{.{ .op = 11 }});
    defer testing.allocator.free(subr);
    const glyph = try charstring(testing.allocator, &.{ .{ .n = -107 }, .{ .op = 10 }, .{ .op = 14 } });
    defer testing.allocator.free(glyph);

    const table = try buildTestCff(testing.allocator, .{
        .char_strings = &.{glyph},
        .local_subrs = &.{subr},
    });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);
    try expectTriangle(shape);
}

test "endchar inside a subroutine ends the glyph, and a global one is reached the same way" {
    // Here the subroutine ends with `endchar` rather than `return`, and the
    // line after the call in the glyph must never run.
    const subr = try charstring(testing.allocator, &triangle ++ [_]Token{.{ .op = 14 }});
    defer testing.allocator.free(subr);
    const glyph = try charstring(testing.allocator, &.{
        .{ .n = -107 }, .{ .op = 29 },
        .{ .n = 5000 }, .{ .n = 5000 },
        .{ .op = 5 },
    });
    defer testing.allocator.free(glyph);

    const table = try buildTestCff(testing.allocator, .{
        .char_strings = &.{glyph},
        .global_subrs = &.{subr},
    });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);
    try expectTriangle(shape);
}

test "a subroutine that calls itself stops rather than recursing forever" {
    const subr = try charstring(testing.allocator, &.{ .{ .n = -107 }, .{ .op = 10 }, .{ .op = 11 } });
    defer testing.allocator.free(subr);
    const glyph = try charstring(testing.allocator, &.{ .{ .n = -107 }, .{ .op = 10 }, .{ .op = 14 } });
    defer testing.allocator.free(glyph);

    const table = try buildTestCff(testing.allocator, .{
        .char_strings = &.{glyph},
        .local_subrs = &.{subr},
    });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try testing.expectError(error.Malformed, readGlyph(testing.allocator, table, 0, &shape));
}

test "hintmask skips one bit per stem, the implicit vertical ones included" {
    // Two horizontal stems named, two vertical ones left on the stack for
    // `hintmask` to count: four stems, one mask byte. The byte is 0xF0,
    // which read as an operator would be a number pushed onto the stack and
    // would shift every point of the triangle after it.
    const glyph = try charstring(testing.allocator, &[_]Token{
        .{ .n = 0 },     .{ .n = 10 }, .{ .n = 20 }, .{ .n = 10 }, .{ .op = 1 },
        .{ .n = 0 },     .{ .n = 10 }, .{ .n = 20 }, .{ .n = 10 }, .{ .op = 19 },
        .{ .op = 0xF0 },
    } ++ triangle ++ [_]Token{.{ .op = 14 }});
    defer testing.allocator.free(glyph);
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);
    try expectTriangle(shape);
}

test "hflex is two curves that come back to the height they started at" {
    const glyph = try charstring(testing.allocator, &.{
        .{ .n = 0 },  .{ .n = 100 },  .{ .op = 21 },
        .{ .n = 50 }, .{ .n = 50 },   .{ .n = 30 },
        .{ .n = 50 }, .{ .n = 50 },   .{ .n = 50 },
        .{ .n = 50 }, .{ .esc = 34 }, .{ .op = 14 },
    });
    defer testing.allocator.free(glyph);
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);

    try testing.expectEqual(2, countCubics(shape));
    try testing.expectEqual(Point.init(150, 130), shape.commands.items[1].cubic.to);
    try testing.expectEqual(Point.init(300, 100), shape.commands.items[2].cubic.to);
}

test "a charstring with nothing but endchar draws nothing, and so does a glyph past the end" {
    const glyph = try charstring(testing.allocator, &.{ .{ .n = 250 }, .{ .op = 14 } });
    defer testing.allocator.free(glyph);
    const table = try buildTestCff(testing.allocator, .{ .char_strings = &.{glyph} });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 0, &shape);
    try testing.expect(shape.isEmpty());

    try readGlyph(testing.allocator, table, 7, &shape);
    try testing.expect(shape.isEmpty());
}

test "seac composes two glyphs by their Standard Encoding codes" {
    // Glyph 1 is `A` (string 34, code 65) and glyph 2 is `grave` (string
    // 124, code 193), by the charset. Glyph 3 is `endchar` with four
    // arguments: put the grave 100 right and 200 up of the A.
    const base = try charstring(testing.allocator, &triangle ++ [_]Token{.{ .op = 14 }});
    defer testing.allocator.free(base);
    const accent = try charstring(testing.allocator, &.{
        .{ .n = 0 },   .{ .n = 0 },  .{ .op = 21 },
        .{ .n = 10 },  .{ .n = 0 },  .{ .op = 5 },
        .{ .n = 0 },   .{ .n = 10 }, .{ .op = 5 },
        .{ .op = 14 },
    });
    defer testing.allocator.free(accent);
    const composed = try charstring(testing.allocator, &.{
        .{ .n = 100 }, .{ .n = 200 }, .{ .n = 65 }, .{ .n = 193 }, .{ .op = 14 },
    });
    defer testing.allocator.free(composed);
    const notdef = try charstring(testing.allocator, &.{.{ .op = 14 }});
    defer testing.allocator.free(notdef);

    const table = try buildTestCff(testing.allocator, .{
        .char_strings = &.{ notdef, base, accent, composed },
        .charset = &.{ 34, 124, 500 },
    });
    defer testing.allocator.free(table);

    var shape: Outline = .empty;
    defer shape.deinit(testing.allocator);
    try readGlyph(testing.allocator, table, 3, &shape);

    try testing.expectEqual(2, shape.contourCount());
    const box = shape.bounds();
    try testing.expectEqual(@as(f32, 600), box.max_x);
    // The accent's ten units, moved up by two hundred, still fit under the
    // triangle's peak - so the top of the box is the base, and the accent
    // shows as its own moved contour.
    try testing.expectEqual(@as(f32, 700), box.max_y);
    var found = false;
    for (shape.commands.items) |command| {
        if (command == .move and command.move.x == 100 and command.move.y == 200) found = true;
    }
    try testing.expect(found);
}

test "a CID-keyed font runs each glyph with the subroutines of its own font dict" {
    // Two font dicts, each with a subroutine zero that draws a different
    // width; two glyphs with the same charstring, `callsubr 0`. FDSelect
    // gives glyph zero to the first dict and glyph one to the second, so the
    // same bytes come out two different shapes - which is the whole test.
    const wide = try charstring(testing.allocator, &triangle ++ [_]Token{.{ .op = 11 }});
    defer testing.allocator.free(wide);
    const narrow = try charstring(testing.allocator, &.{
        .{ .n = 0 },    .{ .n = 0 },   .{ .op = 21 },
        .{ .n = 300 },  .{ .n = 0 },   .{ .op = 5 },
        .{ .n = -150 }, .{ .n = 700 }, .{ .op = 5 },
        .{ .op = 11 },
    });
    defer testing.allocator.free(narrow);
    const glyph = try charstring(testing.allocator, &.{ .{ .n = -107 }, .{ .op = 10 }, .{ .op = 14 } });
    defer testing.allocator.free(glyph);

    // Layout: header, name, top dict, strings, gsubrs, charstrings,
    // FDSelect, FDArray, then two Private DICTs each followed by its subrs.
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const top_size: u32 = 17 + 7 + 7 + 6; // ROS, FDArray, FDSelect, CharStrings
    const char_strings_at: u32 = 4 + indexSize(&.{"T"}) + (3 + 8 + top_size) + 2 + 2;
    const fd_select_at = char_strings_at + indexSize(&.{ glyph, glyph });
    const fd_select_size: u32 = 1 + 2 + 3 * 2 + 2;
    const fd_array_at = fd_select_at + fd_select_size;
    const font_dict_size: u32 = 11;
    const fd_array_size: u32 = 3 + 4 * 3 + 2 * font_dict_size;
    const private_size: u32 = 6;
    const first_private_at = fd_array_at + fd_array_size;
    const second_private_at = first_private_at + private_size + indexSize(&.{wide});

    try out.appendSlice(gpa, &.{ 1, 0, 4, 4 });
    try writeIndex(gpa, &out, &.{"T"});

    var top: std.ArrayList(u8) = .empty;
    defer top.deinit(gpa);
    try dictInt(gpa, &top, 391);
    try dictInt(gpa, &top, 392);
    try dictInt(gpa, &top, 0);
    try top.appendSlice(gpa, &.{ 12, 30 });
    try dictInt(gpa, &top, fd_array_at);
    try top.appendSlice(gpa, &.{ 12, 36 });
    try dictInt(gpa, &top, fd_select_at);
    try top.appendSlice(gpa, &.{ 12, 37 });
    try dictInt(gpa, &top, char_strings_at);
    try top.append(gpa, 17);
    try testing.expectEqual(top_size, top.items.len);
    try writeIndex(gpa, &out, &.{top.items});

    try writeIndex(gpa, &out, &.{});
    try writeIndex(gpa, &out, &.{});
    try testing.expectEqual(char_strings_at, out.items.len);
    try writeIndex(gpa, &out, &.{ glyph, glyph });

    // FDSelect format 3: two ranges, then the sentinel.
    try out.appendSlice(gpa, &.{ 3, 0, 2, 0, 0, 0, 0, 1, 1, 0, 2 });

    var dicts: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&dicts) |*d| d.deinit(gpa);
    for (&dicts, [_]u32{ first_private_at, second_private_at }) |*d, at| {
        try dictInt(gpa, d, private_size);
        try dictInt(gpa, d, at);
        try d.append(gpa, 18);
    }
    try testing.expectEqual(fd_array_at, out.items.len);
    try writeIndex(gpa, &out, &.{ dicts[0].items, dicts[1].items });

    for ([_][]const u8{ wide, narrow }) |subr| {
        try dictInt(gpa, &out, private_size);
        try out.append(gpa, 19);
        try writeIndex(gpa, &out, &.{subr});
    }

    var shape: Outline = .empty;
    defer shape.deinit(gpa);

    try readGlyph(gpa, out.items, 0, &shape);
    try testing.expectEqual(@as(f32, 600), shape.bounds().max_x);
    try readGlyph(gpa, out.items, 1, &shape);
    try testing.expectEqual(@as(f32, 300), shape.bounds().max_x);
}

test "a table that is not CFF version 1, or has no charstrings, is refused" {
    try testing.expectError(error.Malformed, Cff.parse(.{ .bytes = &.{ 2, 0, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0 } }));

    // Version 1, four empty INDEXes: a Top DICT is required.
    try testing.expectError(error.Malformed, Cff.parse(.{ .bytes = &.{ 1, 0, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0 } }));
}
