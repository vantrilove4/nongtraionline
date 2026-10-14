"""Build pre-colored animal atlases from the production-ready base PNGs.

Run from the project root with the bundled Python/Pillow runtime:
  python outputs/tools/generate_animal_variants.py

This is an offline asset step. The game loads these PNG atlases directly and
never applies a color filter or reads pixels from a canvas at runtime.
"""
import json
from pathlib import Path
from PIL import Image, ImageEnhance, ImageOps

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "chicken": {
        "charcoal": [("grayscale", .72), ("brightness", .76), ("contrast", 1.08)],
        "golden": [("sepia", .38), ("saturation", 1.35), ("brightness", .98)],
        "rose": [("hue", -18), ("saturation", 1.25), ("brightness", 1.04)],
        "mint": [("hue", 80), ("saturation", 1.10), ("brightness", 1.06)],
    },
    "pig": {
        "cream": [("hue", 22), ("saturation", .82), ("brightness", 1.10)],
        "spotted": [("saturation", .86), ("contrast", 1.12)],
        "honey": [("sepia", .30), ("saturation", 1.15), ("brightness", 1.02)],
        "lavender": [("hue", 260), ("saturation", 1.20), ("brightness", .99)],
    },
    "cow": {
        "brown": [("hue", 8), ("saturation", 1.18), ("brightness", .88)],
        "golden": [("sepia", .42), ("saturation", 1.45), ("hue", 5), ("brightness", 1.04)],
        "rust": [("hue", -12), ("saturation", 1.25), ("brightness", .93)],
        "rose": [("hue", 330), ("saturation", 1.10), ("brightness", 1.06)],
    },
    "fish": {
        "blue": [("hue", 145), ("saturation", 1.35)],
        "koi": [("hue", -18), ("saturation", 1.25), ("contrast", 1.08)],
        "coral": [("hue", 320), ("saturation", 1.20), ("brightness", 1.05)],
        "pearl": [("hue", 75), ("saturation", 1.25), ("brightness", 1.06)],
    },
}


def rotate_hue(image, degrees):
    hsv = image.convert("HSV")
    hue, saturation, value = hsv.split()
    shift = round(degrees * 255 / 360)
    lut = [((index + shift) % 256) for index in range(256)]
    return Image.merge("HSV", (hue.point(lut), saturation, value)).convert("RGB")


def sepia(image, amount):
    raw = image.tobytes()
    tinted = []
    for index in range(0, len(raw), 3):
        red, green, blue = raw[index:index + 3]
        tinted.append((
            min(255, round(.393 * red + .769 * green + .189 * blue)),
            min(255, round(.349 * red + .686 * green + .168 * blue)),
            min(255, round(.272 * red + .534 * green + .131 * blue)),
        ))
    layer = Image.new("RGB", image.size)
    layer.putdata(tinted)
    return Image.blend(image, layer, amount)


def transform(image, operations):
    for operation, value in operations:
        if operation == "hue":
            image = rotate_hue(image, value)
        elif operation == "saturation":
            image = ImageEnhance.Color(image).enhance(value)
        elif operation == "brightness":
            image = ImageEnhance.Brightness(image).enhance(value)
        elif operation == "contrast":
            image = ImageEnhance.Contrast(image).enhance(value)
        elif operation == "grayscale":
            gray = ImageOps.grayscale(image).convert("RGB")
            image = Image.blend(image, gray, value)
        elif operation == "sepia":
            image = sepia(image, value)
        else:
            raise ValueError(f"Unknown operation: {operation}")
    return image


def main():
    for kind, skins in PROFILES.items():
        directory = ROOT / "assets" / "animals" / kind
        source_path = directory / "atlas.png"
        with Image.open(source_path) as opened:
            source = opened.convert("RGBA")
        alpha = source.getchannel("A")
        base_rgb = source.convert("RGB")
        manifest = {"source": "../atlas.png", "size": list(source.size), "variants": {}}
        for skin, operations in skins.items():
            variant = transform(base_rgb.copy(), operations).convert("RGBA")
            variant.putalpha(alpha.copy())
            output_dir = directory / "variants"
            output_dir.mkdir(parents=True, exist_ok=True)
            output_path = output_dir / f"{skin}.png"
            variant.save(output_path, optimize=True)
            manifest["variants"][skin] = {
                "file": f"variants/{skin}.png",
                "size": list(variant.size),
                "operations": [[name, value] for name, value in operations],
            }
            print(f"{kind}/{skin}: {variant.width}×{variant.height} · {output_path.stat().st_size:,} bytes")
        (directory / "variants.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )


if __name__ == "__main__":
    main()