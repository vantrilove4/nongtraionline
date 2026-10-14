"""Cut and normalize the farm robot's generated sprite sheets for the game."""
from collections import deque
import json
from pathlib import Path
from statistics import median

from PIL import Image, ImageDraw


PROJECT = Path(__file__).resolve().parents[2]
OUT_DIR = PROJECT / "outputs" / "assets" / "player"
WALK_SOURCE = PROJECT / "work" / "farm-robot-walk-source.png"
ACTION_SOURCE = PROJECT / "work" / "farm-robot-actions-source.png"
OUT = OUT_DIR / "farm-robot-atlas.png"
META = OUT_DIR / "farm-robot-atlas.json"
PREVIEW = PROJECT / "work" / "farm-robot-walk-preview.png"
ACTION_PREVIEW = PROJECT / "work" / "farm-robot-actions-preview.png"
CELL = 64
COLS = 6
ROWS = 14
ANCHOR_X = 32
ANCHOR_Y = 56
TARGET_HEIGHT = 53


def remove_green_background(cell: Image.Image) -> Image.Image:
    """Remove only chroma green connected to the cell's outside edge."""
    rgb = cell.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    key = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            # Flood only pixels strongly matching the lime backdrop. The
            # stricter edge rule keeps real foliage from being eaten by the key.
            if g > 165 and g - r > 75 and g - b > 65:
                key[y * width + x] = 1

    seen = bytearray(width * height)
    queue = deque()

    def add(x: int, y: int) -> None:
        index = y * width + x
        if key[index] and not seen[index]:
            seen[index] = 1
            queue.append(index)

    for x in range(width):
        add(x, 0)
        add(x, height - 1)
    for y in range(height):
        add(0, y)
        add(width - 1, y)
    while queue:
        index = queue.popleft()
        x = index % width
        if x and key[index - 1] and not seen[index - 1]:
            seen[index - 1] = 1
            queue.append(index - 1)
        if x + 1 < width and key[index + 1] and not seen[index + 1]:
            seen[index + 1] = 1
            queue.append(index + 1)
        if index >= width and key[index - width] and not seen[index - width]:
            seen[index - width] = 1
            queue.append(index - width)
        if index + width < width * height and key[index + width] and not seen[index + width]:
            seen[index + width] = 1
            queue.append(index + width)

    rgba = rgb.convert("RGBA")
    mask = Image.new("L", (width, height), 255)
    mask_pixels = mask.load()
    for y in range(height):
        offset = y * width
        for x in range(width):
            r, g, b = pixels[x, y]
            if seen[offset + x] or (g > 220 and r < 40 and b < 35):
                mask_pixels[x, y] = 0
    rgba.putalpha(mask)
    # Clear hidden chroma RGB as well as alpha. Otherwise LANCZOS resizing can
    # bleed the green key back into transparent gaps between robot limbs.
    rgba_pixels = rgba.load()
    for y in range(height):
        for x in range(width):
            if mask_pixels[x, y] == 0:
                rgba_pixels[x, y] = (0, 0, 0, 0)
    return rgba


def cell_bbox(cell: Image.Image):
    return remove_green_background(cell).getchannel("A").getbbox()


def normalized_frame(cell: Image.Image, scale: float, center_x: float,
                     ground_y: float) -> Image.Image:
    cut = remove_green_background(cell)
    bbox = cut.getchannel("A").getbbox()
    result = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    if not bbox:
        return result
    sprite = cut.crop(bbox)
    out_w = max(1, round(sprite.width * scale))
    out_h = max(1, round(sprite.height * scale))
    sprite = sprite.resize((out_w, out_h), Image.Resampling.LANCZOS)
    left = round(ANCHOR_X + (bbox[0] - center_x) * scale)
    top = round(ANCHOR_Y + (bbox[1] - ground_y) * scale)
    result.alpha_composite(sprite, (left, top))
    return result


def paste_row(atlas: Image.Image, row: int, frames: list[Image.Image]) -> None:
    for column, frame in enumerate(frames[:COLS]):
        atlas.alpha_composite(frame, (column * CELL, row * CELL))


def make_preview(atlas: Image.Image, target: Path, rows: list[int], labels: list[str]) -> None:
    scale = 4
    pad = 14
    label_h = 22
    width = pad * 2 + COLS * CELL * scale
    height = pad * 2 + len(rows) * (CELL * scale + label_h)
    sheet = Image.new("RGB", (width, height), "#e8eddf")
    draw = ImageDraw.Draw(sheet)
    for index, row in enumerate(rows):
        y = pad + index * (CELL * scale + label_h)
        draw.text((pad, y), labels[index], fill="#315744")
        for column in range(COLS):
            x = pad + column * CELL * scale
            tile = Image.new("RGBA", (CELL, CELL), "#d5e2ca")
            tile.alpha_composite(atlas.crop((column * CELL, row * CELL,
                                             (column + 1) * CELL, (row + 1) * CELL)))
            sheet.paste(tile.resize((CELL * scale, CELL * scale), Image.Resampling.NEAREST),
                        (x, y + label_h))
    sheet.save(target)


def read_grid(path: Path, columns: int, rows: int, expected_min: int = 1):
    image = Image.open(path).convert("RGB")
    if image.width < columns * expected_min or image.height < rows * expected_min:
        raise ValueError(f"Sprite sheet is too small for {columns}x{rows}: {image.size}")
    return image, image.width / columns, image.height / rows


def get_cell(sheet: Image.Image, col: int, row: int, cell_w: float, cell_h: float):
    x0, x1 = round(col * cell_w), round((col + 1) * cell_w)
    y0, y1 = round(row * cell_h), round((row + 1) * cell_h)
    return sheet.crop((x0, y0, x1, y1)), (x0, y0, x1, y1)


def main() -> None:
    walk, walk_w, walk_h = read_grid(WALK_SOURCE, 6, 4, 100)
    actions, action_w, action_h = read_grid(ACTION_SOURCE, 6, 6, 100)
    if abs(walk_w - walk_h) > 1 or abs(action_w - action_h) > 1:
        raise ValueError(f"Sprite sheet cells are not square: walk={walk_w:.2f}x{walk_h:.2f}, "
                         f"actions={action_w:.2f}x{action_h:.2f}")

    directions = ["down", "up", "left", "right"]
    walk_cells = [[get_cell(walk, col, row, walk_w, walk_h)[0]
                   for col in range(6)] for row in range(4)]
    walk_bboxes = [[cell_bbox(cell) for cell in row] for row in walk_cells]
    heights = [box[3] - box[1] for row in walk_bboxes for box in row if box]
    scale = TARGET_HEIGHT / (sum(heights) / len(heights))
    walk_baselines = [round(median(box[3] for box in row if box))
                      for row in walk_bboxes]

    atlas = Image.new("RGBA", (COLS * CELL, ROWS * CELL), (0, 0, 0, 0))
    # Use each direction's last, settled step as a stable idle pose. All four
    # idle frames stay on a single anchor and the same robot scale.
    for row, direction in enumerate(directions):
        idle_cell = walk_cells[row][5]
        idle_box = walk_bboxes[row][5]
        if not idle_box:
            raise ValueError(f"Empty idle source for {direction}")
        idle = normalized_frame(idle_cell, scale, walk_w * 0.5, walk_baselines[row])
        paste_row(atlas, row, [idle] * 4)

    for row, direction in enumerate(directions):
        frames = []
        for col, cell in enumerate(walk_cells[row]):
            bbox = walk_bboxes[row][col]
            if not bbox:
                raise ValueError(f"Empty walk frame: {direction} frame {col + 1}")
            frames.append(normalized_frame(cell, scale, walk_w * 0.5, walk_baselines[row]))
        paste_row(atlas, 4 + row, frames)

    action_names = ["plant", "hoe", "water", "harvest_crop", "feed_animal", "harvest_animal"]
    action_grid = [[get_cell(actions, col, row, action_w, action_h)[0]
                    for col in range(6)] for row in range(6)]
    action_baselines = []
    for row in range(6):
        floor_samples = []
        for cell in action_grid[row]:
            alpha = remove_green_background(cell).getchannel("A")
            pixels = alpha.load()
            bottom = [y + 1 for y in range(round(action_h * 0.55), round(action_h))
                      for x in range(round(action_w * 0.25), round(action_w * 0.75))
                      if pixels[x, y] > 0]
            if bottom:
                floor_samples.append(max(bottom))
        action_baselines.append(round(median(floor_samples)))
    for row, name in enumerate(action_names):
        frames = []
        for col, cell in enumerate(action_grid[row]):
            bbox = cell_bbox(cell)
            if not bbox:
                raise ValueError(f"Empty action frame: {name} frame {col + 1}")
            frames.append(normalized_frame(cell, scale, action_w * 0.5,
                                           action_baselines[row]))
        paste_row(atlas, 8 + row, frames)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT, optimize=True)
    clips = {}
    for row, direction in enumerate(directions):
        clips[f"idle_{direction}"] = {"row": row, "frames": 4, "fps": 2, "loop": True}
        clips[f"walk_{direction}"] = {"row": 4 + row, "frames": 6, "fps": 8.5, "loop": True}
    for row, name in enumerate(action_names):
        clips[name] = {"row": 8 + row, "frames": 6, "fps": 8, "loop": False}
    META.write_text(json.dumps({
        "frameSize": [CELL, CELL],
        "anchor": [ANCHOR_X, ANCHOR_Y],
        "columns": COLS,
        "clips": clips,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    make_preview(atlas, PREVIEW, list(range(8)), [
        "IDLE DOWN", "IDLE UP", "IDLE LEFT", "IDLE RIGHT",
        "WALK DOWN", "WALK UP", "WALK LEFT", "WALK RIGHT",
    ])
    make_preview(atlas, ACTION_PREVIEW, list(range(8, 14)), action_names)
    print(f"walk frame bbox heights: {heights}; walk baselines: {walk_baselines}; "
          f"action baselines: {action_baselines}; shared scale: {scale:.4f}")
    print(f"atlas: {OUT} ({atlas.width}x{atlas.height}, RGBA)")


if __name__ == "__main__":
    main()
