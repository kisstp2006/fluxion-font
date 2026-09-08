// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Font - a TrueType file, and the pixels it describes.
//!
//! `Font` is the front door, and the six modules under it are there for a
//! caller that wants a part rather than the whole:
//!
//!   `Font`     a font opened: the tables parsed, and what a renderer asks
//!   `sfnt`     the container a font file is: a directory of tables
//!   `tables`   the ones every font has - `head`, `hhea`, `maxp`, `OS/2`,
//!              `hmtx` - read into structs
//!   `cmap`     a character to the glyph that draws it
//!   `glyf`     a glyph to its outline, composites included
//!   `outline`  the shape itself: contours of lines and quadratic curves
//!   `raster`   the outline to coverage, with the edges smoothed
//!
//! ```zig
//! const fonts = @import("fluxion_font");
//!
//! var font: fonts.Font = try .init(bytes);
//!
//! const text = font.at(16);              // sixteen pixels per em
//! const width = try text.measure("Hello");
//!
//! var glyph = try font.render(gpa, try font.glyphFor('H'), text.scale);
//! defer glyph.deinit(gpa);
//! ```
//!
//! **The bytes are borrowed.** A `Font` holds views into the file it was given
//! and copies none of it, so the file must outlive the font - which is what
//! makes opening one nearly free, and why `@embedFile` is the usual way to
//! carry one.
//!
//! **It reads a font; it does not choose one.** There is no fallback chain, no
//! system font directory and no shaping. Which file to open is the program's
//! business, and turning a run of text into a sequence of glyphs with
//! ligatures and marks in the right places is a much larger library than this
//! one. What this does is the part underneath both: bytes in, coverage out.
//!
//! **TrueType outlines only.** A `CFF ` table holds PostScript outlines, which
//! are cubic and a different format entirely; a font that has one and no
//! `glyf` is refused rather than half-read. Every font shipped with Windows,
//! macOS and the usual open families has `glyf`.
//!
//! **Nothing here trusts the file.** Every offset is checked against the
//! length it points into before it is followed, because a font is a file that
//! arrives from somewhere, and a table directory is a list of offsets a
//! malformed one can point anywhere. A table that runs past the end of the
//! file is clipped to it; an offset that starts past the end is an error.
//!
//! Nothing here allocates except through the allocator it is handed, and only
//! `outline` and `raster` need one at all.

const std = @import("std");

/// A font opened, and everything a renderer asks of it.
pub const Font = @import("Font.zig");

pub const sfnt = @import("sfnt.zig");
pub const tables = @import("tables.zig");
pub const cmap = @import("cmap.zig");
pub const glyf = @import("glyf.zig");
pub const outline = @import("outline.zig");
pub const raster = @import("raster.zig");

/// A font at one size: measuring, line height, and the scale to render at.
/// See `Font.at`.
pub const Scaled = Font.Scaled;

/// A glyph rasterised, with where it sits relative to the pen. See
/// `Font.render`.
pub const Rendered = Font.Rendered;

/// An open font file, under the `Font` that usually holds it. See `sfnt`.
pub const File = sfnt.File;

/// The shape of one glyph. See `outline`.
pub const Outline = outline.Outline;

/// Coverage, eight bits a pixel. See `raster`.
pub const Bitmap = raster.Bitmap;

/// Where a glyph sits in its bitmap, and how big that bitmap is. See `raster`.
pub const Placement = raster.Placement;

/// The glyph a font draws for a character it has nothing for. See `cmap`.
pub const notdef = cmap.notdef;

test {
    _ = Font;
    _ = sfnt;
    _ = tables;
    _ = cmap;
    _ = glyf;
    _ = outline;
    _ = raster;
}
