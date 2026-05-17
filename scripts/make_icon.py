"""Generate the DimFort Vim/Neovim-companion branding assets.

Run from the companion repo root:
    python scripts/make_icon.py

Produces, all into this repo:
    icon.png           — 256x256 square icon, rounded corners ([m·s⁻²])
    icon_alt.png       — alt icon, kg / m·s fraction motif
    social_preview.png — 1280x640 GitHub social-preview banner with
                         the DimFort wordmark + "Vim/Neovim Companion"

The other companions (VSCode, Emacs) and the upstream DimFort repo
each have their own copy of this generator. The palette and glyph
stay in sync by convention.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Palette — kept in sync across all assets.
BG_TOP = (32, 50, 78)        # deep navy
BG_BOTTOM = (18, 28, 46)
ACCENT = (118, 194, 255)     # bright cyan-blue
TEXT = (240, 244, 252)
RULE = (255, 184, 76)        # amber for the bracket / rule accents
WATERMARK_ALPHA = 46         # ~18% — frame, F watermark


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------


def _vertical_gradient(
    w: int, h: int,
    top: tuple[int, int, int],
    bot: tuple[int, int, int],
) -> Image.Image:
    img = Image.new("RGB", (w, h), top)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (w, y)], fill=c)
    return img


def _load_font(px: int) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/Library/Fonts/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ]
    for path in candidates:
        if Path(path).is_file():
            try:
                return ImageFont.truetype(path, px)
            except OSError:
                continue
    return ImageFont.load_default()


def _load_clarendon(px: int, *, index: int = 5) -> ImageFont.ImageFont:
    """Bold SuperClarendon for the F watermark + DimFort wordmark."""
    path = "/System/Library/Fonts/Supplemental/SuperClarendon.ttc"
    try:
        return ImageFont.truetype(path, px, index=index)
    except OSError:
        return _load_font(px)


def _round_corners(img: Image.Image, radius: int) -> Image.Image:
    """Return an RGBA copy of ``img`` with rounded corners (alpha mask)."""
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, img.size[0] - 1, img.size[1] - 1],
        radius=radius,
        fill=255,
    )
    out = img.copy()
    out.putalpha(mask)
    return out


# ---------------------------------------------------------------------------
# Icon tile (square)
# ---------------------------------------------------------------------------


def _icon_background(size: int) -> Image.Image:
    """Gradient + translucent rounded frame + Clarendon F watermark."""
    img = _vertical_gradient(size, size, BG_TOP, BG_BOTTOM).convert("RGBA")
    scale = size / 256

    pad = round(14 * scale)
    frame_radius = round(36 * scale)
    frame_width = max(1, round(5 * scale))
    frame_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(frame_layer).rounded_rectangle(
        [pad, pad, size - pad, size - pad],
        radius=frame_radius,
        outline=(ACCENT[0], ACCENT[1], ACCENT[2], WATERMARK_ALPHA),
        width=frame_width,
    )
    img = Image.alpha_composite(img, frame_layer)

    f_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    f_draw = ImageDraw.Draw(f_layer)
    f_font = _load_clarendon(round(260 * scale))
    f_text = "F"
    fb = f_draw.textbbox((0, round(-7 * scale)), f_text, font=f_font)
    fw = fb[2] - fb[0]
    fh = fb[3] - fb[1]
    f_draw.text(
        ((size - fw) / 2 - fb[0], (size - fh) / 2 - fb[1] - round(6 * scale)),
        f_text,
        font=f_font,
        fill=(ACCENT[0], ACCENT[1], ACCENT[2], WATERMARK_ALPHA),
    )
    img = Image.alpha_composite(img, f_layer)
    return img


def build_equation_tile(size: int = 256) -> Image.Image:
    """``[m·s⁻²]`` motif scaled to ``size``×``size``. RGBA output."""
    img = _icon_background(size)
    draw = ImageDraw.Draw(img)
    scale = size / 256

    big_font = _load_font(round(58 * scale))
    sup_font = _load_font(round(36 * scale))
    bracket_font = _load_font(round(77 * scale))

    open_text = "["
    body_text = "m·s"
    sup_text = "-2"
    close_text = "]"

    open_box = draw.textbbox((0, 0), open_text, font=bracket_font)
    body_box = draw.textbbox((0, 0), body_text, font=big_font)
    sup_box = draw.textbbox((0, 0), sup_text, font=sup_font)
    close_box = draw.textbbox((0, 0), close_text, font=bracket_font)

    open_w = open_box[2] - open_box[0]
    body_w = body_box[2] - body_box[0]
    sup_w = sup_box[2] - sup_box[0]
    close_w = close_box[2] - close_box[0]
    gap_to_sup = round(2 * scale)
    gap_to_close = round(2 * scale)
    bracket_inset = round(14 * scale)
    total_w = (
        open_w + body_w + gap_to_sup + sup_w + gap_to_close + close_w
        - 2 * bracket_inset
    )

    bracket_h = open_box[3] - open_box[1]
    body_glyph_h = body_box[3] - body_box[1]
    x = (size - total_w) / 2
    bracket_y = (size - bracket_h) / 2 - round(4 * scale)
    body_y = bracket_y + (bracket_h - body_glyph_h) / 2

    draw.text(
        (x - open_box[0], bracket_y - open_box[1]),
        open_text,
        font=bracket_font,
        fill=RULE,
    )
    body_x = x + open_w - bracket_inset
    draw.text(
        (body_x - body_box[0], body_y - body_box[1]),
        body_text,
        font=big_font,
        fill=TEXT,
    )
    sup_x = body_x + body_w + gap_to_sup
    draw.text(
        (sup_x - sup_box[0], body_y - sup_box[1] - round(12 * scale)),
        sup_text,
        font=sup_font,
        fill=TEXT,
    )
    close_x = sup_x + sup_w + gap_to_close - bracket_inset
    draw.text(
        (close_x - close_box[0], bracket_y - close_box[1]),
        close_text,
        font=bracket_font,
        fill=RULE,
    )

    return img


def build_fraction_tile(size: int = 256) -> Image.Image:
    """Alternate ``kg / m·s`` motif scaled to ``size``×``size``. RGBA output."""
    img = _icon_background(size)
    draw = ImageDraw.Draw(img)
    scale = size / 256

    title_font = _load_font(round(72 * scale))
    sub_font = _load_font(round(46 * scale))

    top_text = "kg"
    tb = draw.textbbox((0, 0), top_text, font=title_font)
    tw = tb[2] - tb[0]
    th = tb[3] - tb[1]
    draw.text(
        ((size - tw) / 2 - tb[0], round(56 * scale) - tb[1]),
        top_text,
        font=title_font,
        fill=TEXT,
    )

    bar_y = round(56 * scale) + th + round(14 * scale)
    draw.line(
        [(round(54 * scale), bar_y), (size - round(54 * scale), bar_y)],
        fill=RULE,
        width=max(1, round(6 * scale)),
    )

    bot_text = "m·s"
    bb = draw.textbbox((0, round(-10 * scale)), bot_text, font=sub_font)
    bw = bb[2] - bb[0]
    draw.text(
        ((size - bw) / 2 - bb[0], bar_y + round(10 * scale) - bb[1]),
        bot_text,
        font=sub_font,
        fill=TEXT,
    )

    return img


# ---------------------------------------------------------------------------
# Social-preview banner (1280x640)
# ---------------------------------------------------------------------------

SOCIAL_W = 1280
SOCIAL_H = 640


def build_social(subtitle: str | None = None) -> Image.Image:
    """1280x640 GitHub social-preview banner.

    Layout: icon tile on the left, "DimFort" wordmark on the right
    (optionally with a subtitle beneath, e.g. "VSCode Companion").
    Rounded corners applied by the caller.
    """
    img = _vertical_gradient(
        SOCIAL_W, SOCIAL_H, BG_TOP, BG_BOTTOM
    ).convert("RGBA")

    # Outer translucent frame.
    frame_layer = Image.new("RGBA", (SOCIAL_W, SOCIAL_H), (0, 0, 0, 0))
    ImageDraw.Draw(frame_layer).rounded_rectangle(
        [36, 36, SOCIAL_W - 36, SOCIAL_H - 36],
        radius=64,
        outline=(ACCENT[0], ACCENT[1], ACCENT[2], WATERMARK_ALPHA),
        width=8,
    )
    img = Image.alpha_composite(img, frame_layer)

    # Icon tile on the left.
    tile_size = 380
    tile = build_equation_tile(tile_size)
    tile_x = 100
    tile_y = (SOCIAL_H - tile_size) // 2
    img.paste(tile, (tile_x, tile_y), tile)

    draw = ImageDraw.Draw(img)

    # Wordmark + optional subtitle to the right of the tile. Size and
    # placement are tuned so "DimFort" fits with margin even with a
    # long subtitle, and the block is vertically centred (or lifted a
    # touch when a subtitle pushes it down).
    wordmark = "DimFort"
    word_font = _load_clarendon(126)
    word_box = draw.textbbox((0, 0), wordmark, font=word_font)
    word_h = word_box[3] - word_box[1]

    sub_font = _load_font(48) if subtitle else None
    sub_box = (
        draw.textbbox((0, 0), subtitle, font=sub_font)
        if subtitle and sub_font is not None
        else None
    )
    sub_h = (sub_box[3] - sub_box[1]) if sub_box is not None else 0

    rule_gap = 18 if subtitle else 0
    rule_thickness = 6 if subtitle else 0
    block_h = word_h + (rule_gap + rule_thickness + 22 + sub_h if subtitle else 0)
    block_top = (SOCIAL_H - block_h) / 2 - 8
    word_x = tile_x + tile_size + 70
    word_y = block_top

    draw.text(
        (word_x - word_box[0], word_y - word_box[1]),
        wordmark,
        font=word_font,
        fill=TEXT,
    )

    if subtitle and sub_box is not None and sub_font is not None:
        rule_y = word_y + word_h + rule_gap
        draw.line(
            [(word_x, rule_y), (word_x + 220, rule_y)],
            fill=RULE,
            width=rule_thickness,
        )
        sub_y = rule_y + rule_thickness + 14
        draw.text(
            (word_x - sub_box[0], sub_y - sub_box[1]),
            subtitle,
            font=sub_font,
            fill=TEXT,
        )

    return img


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


ICON_CORNER_RADIUS = 36   # matches the inner frame radius for visual rhyme
SOCIAL_CORNER_RADIUS = 64


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent

    icon_path = repo_root / "icon.png"
    icon_alt_path = repo_root / "icon_alt.png"
    social_path = repo_root / "social_preview.png"

    _round_corners(build_equation_tile(256), ICON_CORNER_RADIUS).save(
        icon_path, "PNG", optimize=True,
    )
    print(f"wrote {icon_path} ({icon_path.stat().st_size} bytes)")

    _round_corners(build_fraction_tile(256), ICON_CORNER_RADIUS).save(
        icon_alt_path, "PNG", optimize=True,
    )
    print(f"wrote {icon_alt_path} ({icon_alt_path.stat().st_size} bytes)")

    _round_corners(
        build_social("Vim/Neovim Companion"), SOCIAL_CORNER_RADIUS,
    ).save(social_path, "PNG", optimize=True)
    print(f"wrote {social_path} ({social_path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
