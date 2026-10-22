from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


FRAME = 64
COLS = 6
SOURCE_COL_CENTERS = (264, 454, 644, 834)
SOURCE_ROW_HEIGHT = 118
WALK_SEQUENCE = (0, 1, 2, 3, 2, 1)


def remove_connected_background(crop: Image.Image) -> Image.Image:
    rgb = np.asarray(crop.convert("RGB"), dtype=np.int16)
    edge = np.concatenate((rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]), axis=0)
    background = np.median(edge, axis=0)
    distance = np.sqrt(np.sum((rgb - background) ** 2, axis=2))
    candidates = distance <= 54
    height, width = candidates.shape
    visited = np.zeros((height, width), dtype=np.uint8)
    queue: deque[tuple[int, int]] = deque()

    for x in range(width):
        if candidates[0, x]:
            visited[0, x] = 1
            queue.append((0, x))
        if candidates[height - 1, x] and not visited[height - 1, x]:
            visited[height - 1, x] = 1
            queue.append((height - 1, x))
    for y in range(height):
        if candidates[y, 0] and not visited[y, 0]:
            visited[y, 0] = 1
            queue.append((y, 0))
        if candidates[y, width - 1] and not visited[y, width - 1]:
            visited[y, width - 1] = 1
            queue.append((y, width - 1))

    while queue:
        y, x = queue.popleft()
        for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= ny < height and 0 <= nx < width and candidates[ny, nx] and not visited[ny, nx]:
                visited[ny, nx] = 1
                queue.append((ny, nx))

    rgba = np.dstack((rgb.astype(np.uint8), np.where(visited, 0, 255).astype(np.uint8)))
    return Image.fromarray(rgba, "RGBA")


def extract_frame(sheet: Image.Image, row: int, col: int) -> Image.Image:
    cx = SOURCE_COL_CENTERS[col]
    y0 = row * SOURCE_ROW_HEIGHT
    crop = sheet.crop((cx - 82, y0, cx + 82, min(y0 + SOURCE_ROW_HEIGHT, sheet.height)))
    sprite = remove_connected_background(crop)
    alpha = sprite.getchannel("A")
    bounds = alpha.getbbox()
    frame = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    if not bounds:
        return frame
    sprite = sprite.crop(bounds)
    scale = min(58 / sprite.height, 60 / sprite.width)
    size = (max(1, round(sprite.width * scale)), max(1, round(sprite.height * scale)))
    sprite = sprite.resize(size, Image.Resampling.LANCZOS)
    frame.alpha_composite(sprite, ((FRAME - size[0]) // 2, 61 - size[1]))
    return frame


def main() -> None:
    parser = argparse.ArgumentParser(description="Crop the supplied farmer sheet into the game's fixed-frame atlas.")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    sheet = Image.open(args.source).convert("RGB")
    if sheet.size != (1024, 1536):
        raise SystemExit(f"Expected the supplied 1024x1536 sheet, got {sheet.size}")

    atlas = Image.new("RGBA", (COLS * FRAME, 14 * FRAME), (0, 0, 0, 0))
    # Idle and walk directions are rows 0-7 in the supplied sheet.
    for row in range(8):
        sequence = range(4) if row < 4 else WALK_SEQUENCE
        for frame, source_col in enumerate(sequence):
            atlas.alpha_composite(extract_frame(sheet, row, source_col), (frame * FRAME, row * FRAME))

    # The reference has carry, plant, water, harvest and cheer actions. Map these
    # into the game's existing action slots; hoe uses the planting pose.
    action_rows = {8: 9, 9: 9, 10: 10, 11: 11, 12: 8, 13: 12}
    for atlas_row, source_row in action_rows.items():
        for frame, source_col in enumerate(WALK_SEQUENCE):
            atlas.alpha_composite(extract_frame(sheet, source_row, source_col), (frame * FRAME, atlas_row * FRAME))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(args.output, optimize=True)


if __name__ == "__main__":
    main()
