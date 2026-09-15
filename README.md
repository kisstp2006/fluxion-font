# Fluxion Font

A TrueType or OpenType file, and the pixels it describes. For Zig 0.16. No
dependencies.

| Module | What it is |
| --- | --- |
| `Font` | A font opened: the tables parsed, and what a renderer asks. The front door. |
| `sfnt` | The container a font file is: a directory of tables, read without believing any of it. |
| `tables` | The ones every font has - `head`, `hhea`, `maxp`, `OS/2`, `hmtx` - as structs. |
| `cmap` | A character to the glyph that draws it. Formats 0, 4, 6 and 12. |
| `glyf` | A TrueType glyph to its outline, composites included. |
| `cff` | A PostScript glyph to its outline, by running its charstring. |
| `outline` | The shape itself: closed contours of lines and curves, quadratic or cubic. |
| `raster` | The outline to coverage, with the edges smoothed. |

```zig
const font = @import("fluxion_font");

var face: font.Font = try .init(@embedFile("Inter.ttf"));

const text = face.at(16);                       // sixteen pixels per em
const width = try text.measure("Hello");
const line = text.lineHeight();

var glyph = try face.render(gpa, face.glyphFor('H'), text.scale);
defer glyph.deinit(gpa);
// glyph.bitmap is one byte of coverage per pixel; glyph.left and glyph.top
// say where it goes relative to the pen.
```

## What it is for

The piece the fluxion ecosystem did not have.
[Fluxion Text](https://github.com/kisstp2006/fluxion-text) can wrap a
paragraph if you tell it how wide each character is; nothing could tell it.
[Fluxion UI](https://github.com/kisstp2006/fluxion-ui) can lay out a
paragraph if you tell it how big the text is; nothing could tell it that
either. This is what answers both, and it draws the glyphs afterwards.

**Bytes in, coverage out.** It reads a font; it does not choose one. There is
no fallback chain and no system font directory - which file to open is the
program's business.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-font
```

```zig
const fluxion = b.dependency("fluxion_font", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_font", fluxion.module("fluxion_font"));
```

**Nothing comes with it.** A font file is bytes, and turning bytes into
coverage needs arithmetic and an allocator. Nothing here opens a window,
decodes an image or talks to a GPU, so nothing here depends on the packages
that do - which also means it builds for `wasm32-freestanding` unchanged.

## The path a glyph takes

```
bytes ──▶ sfnt ──▶ cmap ──▶ glyf | cff ──▶ outline ──▶ raster ──▶ coverage
        directory  'H' is   glyph 43     contours   pixels
        of tables  glyph 43 is these     of curves
```

Each step is a module, and each can be used on its own: a tool that lists
tables needs `sfnt`; a validator that walks every glyph needs `glyf` or
`cff`; a renderer needs all of them, and holds a `Font` instead.

The fork in the middle is the one thing about OpenType worth knowing before
opening a file. A TrueType font stores each glyph as rings of points in
`glyf`, with quadratic curves between them. A PostScript-flavoured one - the
`.otf` a foundry sells, and most of what is served as a webfont - stores each
glyph as a **charstring** in `CFF `: a small program in a stack language,
with cubic curves, subroutines and hints, that a reader runs to find out what
the glyph looks like. `Font.Outlines` holds whichever the file has, and
everything above it gets an `outline.Outline` either way.

## Nothing here trusts the file

A font is a file that arrives from somewhere - downloaded, embedded in a
document, picked up off the system - and a table directory is a list of
offsets that a malformed one can point anywhere. So there is no pointer
arithmetic in this library at all: `sfnt.View` holds a slice, every read is
bounds-checked against it, and an offset past the end is `error.OutOfBounds`
rather than a surprise.

That costs a comparison per field and it is worth it. A glyph is read once
into an atlas that is then used for the life of the program: the parse happens
hundreds of times and the drawing happens millions. The place to be fast is
`raster`.

Two things the checking catches that are worth naming, because both are in
real files rather than hypothetical ones:

- **A table whose length runs past the end of the file** is clipped to it
  rather than refused. Fonts in the wild do this to their last table.
- **A composite glyph that refers to itself** stops at
  `glyf.max_composite_depth` with an error, rather than recursing until the
  stack runs out. A charstring subroutine that calls itself stops the same
  way at `cff.max_subroutine_depth`.

## The rasteriser

Signed-area accumulation, and it is worth knowing that it is not a scanline
fill. For every line segment it records **how much the coverage changes** at
each pixel the segment crosses - a signed number - and nothing is sorted and
nothing is filled. One running sum over the buffer afterwards turns those
changes into coverage: inside a shape the upward and downward edges have
cancelled to one, outside to zero, and along an edge to something between,
which *is* the antialiasing. It falls out of the arithmetic rather than being
added on top.

Two things come free with it:

- **Winding.** The hole in an `o` is a contour going the other way, so its
  contributions are negative and the sum returns to zero inside it. Nothing
  has to know which contour is which.
- **A contour drawn backwards still fills**, because the coverage is the
  absolute value of the sum.

The idea is Raph Levien's, from font-rs.

## What is here, and what is not

Read and tested:

- TrueType outlines (`glyf`), simple and composite, under any two-by-two transform
- PostScript outlines (`CFF `): the whole Type 2 charstring set - lines,
  curves, flex, hints counted and skipped, local and global subroutines with
  their bias, `seac` accent composition - and CID-keyed fonts with a Private
  DICT per font dict, which is what every CJK OpenType font is
- Character maps in formats 0, 4, 6 and 12, including the Windows Symbol shift
- `head`, `hhea`, `hmtx`, `maxp`, `OS/2`, and `kern` in format 0
- TrueType collections (`.ttc`), one font at a time: `Font.initMember(bytes,
  index)`, which takes the file and the place in it that a system's font
  lookup hands back, and index nought of a file that is one font
- Antialiased rasterising, metrics, and string measurement with kerning

Not here, and each for a reason:

| | Why |
| --- | --- |
| **`CFF2` and variable fonts** | The variable form of both outline formats blends several sets of coordinates by an axis position, and `CFF2` has a different header and DICT-less layout to go with it. A static instance of any variable font reads fine; the variation itself is a second library. |
| **Hinting** | A bytecode stack machine with about eighty instructions, whose result is only visible below fourteen pixels on a display that is not high-density. A good antialiased rasteriser instead is the trade every modern text stack has made. |
| **Shaping** | Ligatures, marks and reordering need `GSUB` and `GPOS`, which are their own library. One glyph per codepoint plus `kern` pairs is correct for Latin, Greek, Cyrillic and CJK. |
| **A glyph atlas** | Packing rasterised glyphs into one texture belongs with whatever owns the texture. This hands you the coverage. |

## Examples

```bash
zig build example
zig build example -- C:/Windows/Fonts/segoeui.ttf "Áévgj W." 26
```

Opens a font, says what is in it, and draws the text as characters:

```
C:/Windows/Fonts/consola.ttf
  3031 glyphs, em square 2048 units
  ascender 1521, descender -527, line 2398 units
  character map format 4
  TrueType outlines
  tables: GDEF GPOS GSUB MERG OS/2 cmap cvt  fpgm gasp glyf head hhea hmtx loca maxp meta name post prep

  #@      @%
  #@      @%    :+#%*-     :+#%%#=      :*%%####.
  #@      @%   =%%**%@*    *%#+*%@+    =@#==%@#*.
  #@.     @%  .%#.   #@-   .     %@.   %%   .%#
  #@@@@@@@@%  +@-    .@#         +@:  :@+    #@
  #@+=====@%  #%      %%     .:--*@:  :@*    %%
  #@      @%  %%      #@   :#@@@@@@:   #%-  +@+
  #@      @%  %%      %%  .%%-.  +@:   *%@%%@*
  #@      @%  *@.    .%#  -@=    +@:  :@-:--.
  #@      @%  -@*    *@-  =@=   :%@:  =@=
  #@      @%   #@#==#@*   :%%==*@#@:  :%@%###+-
  #@      @%    +%@@%=     -%@@#:-@:   #%**##%@+
                  .          .        +@-    .%%
                                      %@      %%
                                      #@+.  .+@*
                                      .#@@%@@%+
```

A terminal is a grid of characters and a rasterised glyph is a grid of
coverage, so printing one against the other is a complete renderer in nine
lines - and it proves the whole path without a GPU, a window, or a way to look
at a PNG.

## Build

```bash
zig build test        # the suite
zig build example     # a font, described and drawn
zig build docs        # API docs into zig-out/docs
```

The tests come in two halves. The **unit tests build their font files byte by
byte** - a directory with a table that lies about its length, a `cmap` segment
that points into a shared array, a composite glyph that refers to itself -
because a real font cannot tell you what happens when an offset is wrong, no
real font having a wrong one. The **integration tests open a font off this
machine** and check the pixels: that a capital `H` is two runs of ink near the
top and one at the crossbar, that an `o` has a hole in the middle, that a
space has an advance and no pixels, and that every glyph in the font - three
thousand of them, composites included - reads without a bounds error. On a
machine with no fonts they skip rather than fail.

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: BSD-2-Clause`

[BSD 2-Clause](LICENSE). Fluxion libraries are licensed by layer: the
foundation is CC0, the engine infrastructure is BSL-1.0, and what builds on
top of it - this, and [Fluxion UI](https://github.com/kisstp2006/fluxion-ui) -
is BSD.
