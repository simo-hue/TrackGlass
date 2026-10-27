#!/usr/bin/env python3
"""Generate the app icon sets and the menu-bar template icon from Design/Brand/trackglass-logo-v1.png.

Usage: python3 Scripts/make-icons.py   (requires Pillow; run from the repo root)

Writes:
  iOS/Resources/Assets.xcassets/AppIcon.appiconset   single 1024 px universal icon (iOS masks the corners)
  Mac/Resources/Assets.xcassets/AppIcon.appiconset   the ten macOS sizes, HIG rounded-rect with margin and shadow
  Mac/Resources/Assets.xcassets/MenuBarIcon.imageset 18 pt template image at 1x/2x/3x (SPEC §6.1)
The generated PNGs are committed; this script exists so they can be regenerated after a brand change.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "Design", "Brand", "trackglass-logo-v1.png")
IOS_SET = os.path.join(ROOT, "iOS", "Resources", "Assets.xcassets", "AppIcon.appiconset")
MAC_SET = os.path.join(ROOT, "Mac", "Resources", "Assets.xcassets", "AppIcon.appiconset")
MENU_SET = os.path.join(ROOT, "Mac", "Resources", "Assets.xcassets", "MenuBarIcon.imageset")
BACKGROUND = (10, 10, 13)  # #0a0a0d from the brand prompt


def write_json(directory, payload):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "Contents.json"), "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def square_source():
    image = Image.open(SOURCE).convert("RGB")
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    return image.crop((left, top, left + side, top + side))


def ios_icon(source):
    os.makedirs(IOS_SET, exist_ok=True)
    source.resize((1024, 1024), Image.LANCZOS).save(os.path.join(IOS_SET, "AppIcon-1024.png"), optimize=True)
    write_json(IOS_SET, {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })
    write_json(os.path.dirname(IOS_SET), {"info": {"author": "xcode", "version": 1}})


def mac_master(source):
    """HIG macOS icon: 824/1024 rounded rectangle (radius ≈ 22.4 %) on a transparent canvas with a soft shadow."""
    canvas = 1024
    inset = 100
    body = canvas - 2 * inset
    radius = round(body * 0.2237)
    art = source.resize((body, body), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body - 1, body - 1), radius=radius, fill=255)
    art.putalpha(mask)
    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(shadow_mask).rounded_rectangle((inset, inset + 10, inset + body - 1, inset + body + 9), radius=radius, fill=110)
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(12)))
    master = shadow
    master.alpha_composite(art, (inset, inset))
    return master


def mac_icon(source):
    master = mac_master(source)
    entries = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"AppIcon-{points}@{scale}x.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(MAC_SET, name) if os.path.isdir(MAC_SET) else _mk(MAC_SET, name), optimize=True)
            entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_json(MAC_SET, {"images": entries, "info": {"author": "xcode", "version": 1}})
    write_json(os.path.dirname(MAC_SET), {"info": {"author": "xcode", "version": 1}})


def _mk(directory, name):
    os.makedirs(directory, exist_ok=True)
    return os.path.join(directory, name)


def menu_bar_icon():
    """SPEC §6.1: two rounded rectangles — trackpad outline and phone outline — as a template image."""
    def render(scale):
        size = 18 * scale
        super_sample = 8
        big = size * super_sample
        image = Image.new("L", (big, big), 0)
        draw = ImageDraw.Draw(image)
        stroke = round(1.5 * scale * super_sample)
        unit = scale * super_sample
        # Trackpad: wide rounded rectangle, lower-left.
        draw.rounded_rectangle((1 * unit, 5 * unit, 13 * unit, 15 * unit), radius=2 * unit, outline=255, width=stroke)
        # Phone: tall rounded rectangle, upper-right, drawn over a cleared area so the outlines do not merge.
        draw.rounded_rectangle((9.5 * unit, 1 * unit, 17 * unit, 12.5 * unit), radius=1.6 * unit, fill=0, outline=0, width=stroke * 2)
        draw.rounded_rectangle((10 * unit, 1.5 * unit, 16.5 * unit, 12 * unit), radius=1.5 * unit, outline=255, width=stroke)
        small = image.resize((size, size), Image.LANCZOS)
        out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        out.putalpha(small)
        return out

    entries = []
    for scale in (1, 2, 3):
        name = f"MenuBarIcon@{scale}x.png"
        render(scale).save(_mk(MENU_SET, name), optimize=True)
        entries.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    write_json(MENU_SET, {
        "images": entries,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    })


def main():
    if not os.path.exists(SOURCE):
        sys.exit(f"missing brand source {SOURCE}")
    source = square_source()
    ios_icon(source)
    mac_icon(source)
    menu_bar_icon()
    print("icons written")


if __name__ == "__main__":
    main()
