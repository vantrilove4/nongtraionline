"""Extract fixed-size transparent animal animation atlases from the reference sheet.

Run from the project root with the bundled Python/Pillow runtime:
  python outputs/tools/build_animal_atlases.py

The sprite sheet uses a visual checkerboard. This script removes the connected
low-chroma background around each outlined animal while filling enclosed light
areas, which keeps the white/cream details on the cow and chicken intact.
"""
import json
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "animals" / "source-reference.png"
CELL = 64
ATLAS_COLUMNS = 6

# Sprite centers measured from the supplied 1536 x 1024 sheet.
X = {
    "idle": [248, 312, 376, 440],
    "walk": [532, 595, 658, 721, 784, 847],
    # Column 2 in this panel contains only the thought bubble, so it is skipped.
    "hungry": [920, 1034, 1100],
    "collect": [1190, 1253, 1316, 1379, 1442, 1502],
    "swim": [532, 595, 658, 721, 784, 847],
}
ANIMALS = {
    "pig": {
        "tops": [46, 102, 155, 205],
        "directions": ["down", "up", "left", "right"],
        "states": ["idle", "walk", "hungry", "collect"],
    },
    "cow": {
        "tops": [326, 384, 443, 499],
        "directions": ["down", "up", "left", "right"],
        "states": ["idle", "walk", "hungry", "collect"],
    },
    "chicken": {
        "tops": [604, 668, 720, 780],
        "directions": ["down", "up", "left", "right"],
        "states": ["idle", "walk", "hungry", "collect"],
    },
    "fish": {
        "tops": [889, 945],
        "directions": ["left", "right"],
        "states": ["idle", "swim", "hungry", "collect"],
    },
}
FRAME_COUNTS = {"idle": 4, "walk": 6, "swim": 6, "hungry": 3, "collect": 6}


def foreground_mask(image, dark_outline_only=False, max_y=51, keep_nearby_parts=False):
    """Keep the central outlined animal and discard the baked checkerboard."""
    w, h = image.size
    px = image.convert("RGBA")
    data = list(px.getdata())
    core = bytearray(w * h)
    for i, (r, g, b, a) in enumerate(data):
        chroma = max(r, g, b) - min(r, g, b)
        luma = (r * 299 + g * 587 + b * 114) // 1000
        blue_halo = b > r * 1.03 and b > g * 1.02 and b - r > 8
        # The source prints frame numbers immediately under some poses. They
        # share the animal's dark outline colors, so exclude the label strip
        # before connected-component analysis (after the top-margin offset).
        is_outline = luma <= 145 if dark_outline_only else (chroma >= 32 or luma <= 135)
        if i // w <= max_y and a > 36 and not blue_halo and is_outline:
            core[i] = 1

    # Close small gaps in outlines, then find the animal's main colored/dark
    # mass. The wider source window lets shifted walk frames remain whole.
    mask_image = Image.frombytes("L", (w, h), bytes(255 if v else 0 for v in core))
    closed = mask_image.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    core = bytearray(1 if value else 0 for value in closed.tobytes())
    seen = bytearray(w * h)
    components = []
    for start, value in enumerate(core):
        if not value or seen[start]:
            continue
        seen[start] = 1
        queue = [start]
        for index in queue:
            x, y = index % w, index // w
            for yy in range(max(0, y - 1), min(h, y + 2)):
                for xx in range(max(0, x - 1), min(w, x + 2)):
                    ni = yy * w + xx
                    if core[ni] and not seen[ni]:
                        seen[ni] = 1
                        queue.append(ni)
        xs = [i % w for i in queue]
        ys = [i // w for i in queue]
        x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
        bw, bh = x1 - x0 + 1, y1 - y0 + 1
        touches_edge = x0 == 0 or y0 == 0 or x1 == w - 1 or y1 == h - 1
        edge_background = touches_edge and (bw > w * .85 or bh > h * .85)
        rule = (bw > w * .65 and bh < 12) or (bh > h * .65 and bw < 12) or edge_background
        if len(queue) >= 30 and not rule:
            components.append((len(queue), x0, y0, x1, y1, queue))
    if not components:
        if not dark_outline_only:
            return foreground_mask(image, dark_outline_only=True, max_y=max_y,
                                   keep_nearby_parts=keep_nearby_parts)
        return bytearray(w * h)
    components.sort(reverse=True, key=lambda c: c[0])
    main = components[0]
    if not dark_outline_only and (main[3] - main[1] + 1 > w * .85 and main[4] - main[2] + 1 > h * .75):
        # A saturated action-panel background may merge with the sprite in the
        # broad color mask. Retry with only the dark silhouette outline.
        return foreground_mask(image, dark_outline_only=True, max_y=max_y,
                               keep_nearby_parts=keep_nearby_parts)
    keep = bytearray(w * h)
    # The outlined animal is one connected component. Other nearby components
    # are often frame numbers, panel borders, or pieces of the adjacent pose.
    related = [main]
    if keep_nearby_parts:
        # The front-facing chicken's small feet are separated from its body
        # by transparent pixels in this reference. Keep nearby components,
        # while the tightly sized crop excludes adjacent animation cells.
        mx0, my0, mx1, my1 = main[1:5]
        for component in components[1:]:
            _, x0, y0, x1, y1, _ = component
            near_body = (component[0] >= 4 and x0 >= mx0 - 7 and x1 <= mx1 + 7
                         and y0 >= my0 - 3 and y1 <= my1 + 10)
            if near_body:
                related.append(component)
    for component in related:
        for index in component[5]:
            keep[index] = 1

    outside = bytearray(w * h)
    flood = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not keep[i] and not outside[i]:
                outside[i] = 1; flood.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not keep[i] and not outside[i]:
                outside[i] = 1; flood.append(i)
    while flood:
        i = flood.popleft(); x, y = i % w, i // w
        for yy in range(max(0, y - 1), min(h, y + 2)):
            for xx in range(max(0, x - 1), min(w, x + 2)):
                ni = yy * w + xx
                if not keep[ni] and not outside[ni]:
                    outside[ni] = 1; flood.append(ni)
    return bytearray(1 if keep[i] or not outside[i] else 0 for i in range(w * h))


def crop_frame(source, cx, cy, anchor_y=56, window=84, max_y=51, keep_nearby_parts=False):
    # Source poses shift within a roughly 63 px grid. Search a wider region,
    # then isolate the central animal by its connected outlined silhouette.
    # A small top margin prevents ears/horns touching the crop edge, which
    # lets the edge-background filter distinguish the animal from panel art.
    half = window // 2
    frame = source.crop((cx - half, cy - 4, cx + half, cy + 60)).convert("RGBA")
    mask = foreground_mask(frame, max_y=max_y, keep_nearby_parts=keep_nearby_parts)
    rgba = list(frame.getdata())
    for i, (r, g, b, a) in enumerate(rgba):
        # The sheet prints frame numbers and a panel rule directly beneath
        # the animals. The feet finish above this strip; clear it explicitly.
        x, y = i % frame.width, i // frame.width
        blue_halo = b > r * 1.03 and b > g * 1.02 and b - r > 8
        if not mask[i] or blue_halo or y < 3 or y > max_y:
            rgba[i] = (r, g, b, 0)
    frame.putdata(rgba)
    bbox = frame.getchannel("A").getbbox()
    if bbox:
        # Shift only; never resize a frame. The animal's foot baseline and
        # horizontal center share the same anchor in every frame of this clip.
        left, top, right, bottom = bbox
        if anchor_y == 32:
            dy = round(anchor_y - (top + bottom - 1) / 2)
        else:
            dy = round(anchor_y - (bottom - 1))
        aligned = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
        dx = round(CELL / 2 - (left + right) / 2)
        aligned.alpha_composite(frame, (dx, dy))
        frame = aligned
    return frame


def main():
    source = Image.open(SOURCE).convert("RGBA")
    for kind, spec in ANIMALS.items():
        direction_rows = []
        anchor = [32, 32] if kind == "fish" else [32, 56]
        metadata = {"frameSize": [CELL, CELL], "anchor": anchor,
                    "columns": ATLAS_COLUMNS, "clips": {}}
        row_index = 0
        for state in spec["states"]:
            for direction_index, direction in enumerate(spec["directions"]):
                source_y = spec["tops"][direction_index]
                xs = X["walk" if state == "swim" else state]
                down_chicken_walk = kind == "chicken" and state == "walk" and direction == "down"
                if down_chicken_walk:
                    # This row's six reference poses are spaced about 59 px
                    # apart (unlike the other rows). The generic 63 px grid
                    # drifted progressively left and clipped the last poses.
                    xs = [532, 592, 651, 710, 768, 827]
                source_frames = [crop_frame(source, x, source_y, anchor[1],
                                            window=64 if down_chicken_walk else 84,
                                            max_y=59 if down_chicken_walk else 51,
                                            keep_nearby_parts=down_chicken_walk) for x in xs]
                count = FRAME_COUNTS[state]
                frames = [source_frames[i % len(source_frames)] for i in range(ATLAS_COLUMNS)]
                metadata["clips"][f"{state}_{direction}"] = {
                    "row": row_index, "frames": count,
                    "fps": 4 if state in ("idle", "hungry") else 8,
                    "loop": state != "collect",
                }
                direction_rows.append(frames)
                row_index += 1
        atlas = Image.new("RGBA", (CELL * ATLAS_COLUMNS, CELL * row_index), (0, 0, 0, 0))
        for row, frames in enumerate(direction_rows):
            for col, frame in enumerate(frames):
                atlas.alpha_composite(frame, (col * CELL, row * CELL))
        out_dir = ROOT / "assets" / "animals" / kind
        out_dir.mkdir(parents=True, exist_ok=True)
        atlas.save(out_dir / "atlas.png", optimize=True)
        (out_dir / "atlas.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{kind}: {atlas.size} atlas, {row_index} clips")


if __name__ == "__main__":
    main()
