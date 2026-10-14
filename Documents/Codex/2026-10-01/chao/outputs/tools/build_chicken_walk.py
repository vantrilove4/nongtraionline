"""Replace only the chicken's side-walk rows with normalized six-pose frames.

Source: assets/animals/chicken/walk-side-source.png (generated transparent sheet)
Run with the bundled Python/Pillow environment from the repository root.
"""
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
CHICKEN = ROOT / "assets" / "animals" / "chicken"
SOURCE = CHICKEN / "walk-side-source.png"
ATLAS = CHICKEN / "atlas.png"
FRAME = 64
ANCHOR_X = 32
ANCHOR_Y = 56

sys.path.insert(0, str(ROOT / "tools"))
from generate_animal_variants import PROFILES, transform  # noqa: E402


def source_frames():
    image = Image.open(SOURCE).convert("RGBA")
    if image.size != (1536, 1024):
        raise ValueError(f"Expected 1536x1024 source sheet, got {image.size}")

    alpha = np.asarray(image.getchannel("A"))
    frames = []
    for source_row in range(4):
        y0, y1 = source_row * 256, (source_row + 1) * 256
        occupied = alpha[y0:y1].max(axis=0) > 16
        edges = np.diff(np.r_[False, occupied, False].astype(np.int8))
        starts = np.flatnonzero(edges == 1)
        ends = np.flatnonzero(edges == -1)
        if len(starts) != 3:
            raise ValueError(f"Source row {source_row + 1} has {len(starts)} sprites; expected 3")
        for start, end in zip(starts, ends):
            crop = image.crop((max(0, int(start) - 4), y0, min(image.width, int(end) + 4), y1))
            bounds = crop.getchannel("A").getbbox()
            if not bounds:
                raise ValueError(f"Empty sprite in source row {source_row + 1}")
            frames.append(crop.crop(bounds))
    return frames


def normalize(frames):
    # Apply one scale to every pose so the chicken does not pulse between frames.
    max_width = max(frame.width for frame in frames)
    max_height = max(frame.height for frame in frames)
    scale = min(46 / max_width, 44 / max_height)
    normalized = []
    for sprite in frames:
        width = max(1, round(sprite.width * scale))
        height = max(1, round(sprite.height * scale))
        sprite = sprite.resize((width, height), Image.Resampling.LANCZOS)
        frame = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
        bounds = sprite.getchannel("A").getbbox()
        offset = (round(ANCHOR_X - (bounds[0] + bounds[2]) / 2), ANCHOR_Y - bounds[3])
        frame.alpha_composite(sprite, offset)
        normalized.append(frame)
    return normalized


def main():
    frames = normalize(source_frames())
    atlas = Image.open(ATLAS).convert("RGBA")
    if atlas.size != (384, 1024):
        raise ValueError(f"Expected 384x1024 chicken atlas, got {atlas.size}")

    # Six left-facing frames, followed by six right-facing frames.
    for direction_row, direction_frames in ((6, frames[:6]), (7, frames[6:])):
        for column, frame in enumerate(direction_frames):
            atlas.alpha_composite(frame, (column * FRAME, direction_row * FRAME))
    atlas.save(ATLAS, optimize=True)

    # Rebuild the existing purchasable chicken skins from the corrected base atlas.
    base_rgb = atlas.convert("RGB")
    base_alpha = atlas.getchannel("A")
    for skin, operations in PROFILES["chicken"].items():
        variant = transform(base_rgb.copy(), operations).convert("RGBA")
        variant.putalpha(base_alpha.copy())
        variant.save(CHICKEN / "variants" / f"{skin}.png", optimize=True)

    # A temporary contact sheet is used for visual QA; it is removed after review.
    preview = Image.new("RGBA", (FRAME * 6 * 3, FRAME * 2 * 3), "#eee9d8")
    draw = ImageDraw.Draw(preview)
    for direction_row, direction_frames in enumerate((frames[:6], frames[6:])):
        draw.text((8, direction_row * FRAME * 3 + 4), "WALK LEFT" if direction_row == 0 else "WALK RIGHT", fill="#354a36")
        for column, frame in enumerate(direction_frames):
            preview.alpha_composite(frame.resize((FRAME * 3, FRAME * 3), Image.Resampling.NEAREST), (column * FRAME * 3, direction_row * FRAME * 3 + 22))
    preview.convert("RGB").save(ROOT / ".review-chicken-walk-v2.png")

    # Guard against accidental frame-size changes or a missing/shifted baseline.
    for index, frame in enumerate(frames):
        if frame.size != (FRAME, FRAME):
            raise ValueError(f"Frame {index + 1} has inconsistent dimensions")
        bbox = frame.getchannel("A").getbbox()
        if not bbox or abs(bbox[3] - ANCHOR_Y) > 1:
            raise ValueError(f"Frame {index + 1} has an inconsistent foot baseline: {bbox}")

    print(f"Updated chicken side-walk rows: 12 frames, {FRAME}x{FRAME}, shared baseline y={ANCHOR_Y}")


if __name__ == "__main__":
    main()
