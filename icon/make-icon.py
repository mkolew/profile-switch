"""Draws the app icon and writes icon/AppIcon.icns. Needs Pillow and macOS's iconutil.

The icon is our own drawing of the idea behind the menu bar symbol (two people on a stack of squares);
Apple's SF Symbols themselves may not be used as app icons.
Run it only to change the icon: the .icns is committed, so a normal build doesn't need Pillow.
"""
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

SCALE = 2  # drawn at twice the size, then shrunk, for smooth edges
SIZE = 1024 * SCALE
NAVY, TEAL, WHITE = (24, 38, 66, 255), (38, 166, 154, 255), (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
# The front square on the 1024 grid.
SQUARE = (262, 352, 762, 812)
SQUARE_RADIUS = 96


def box(left, top, right, bottom):
    """Converts a rectangle on the 1024 grid to drawing pixels."""
    return [int(value * SCALE) for value in (left, top, right, bottom)]


def person(pen, centre, head_top, head_radius, shoulder, fill, grow=0):
    """Draws a head and shoulders; the body runs down past the square and is clipped later.

    Args:
        pen: the drawing to add to.
        centre: the person's horizontal centre on the 1024 grid.
        head_top: the top of the head.
        head_radius: the head's radius.
        shoulder: half the width of the body.
        fill: the colour.
        grow: extra thickness all round, for the gap that separates the front person from the back one.
    """
    head_centre = head_top + head_radius
    pen.ellipse(box(centre - head_radius - grow, head_centre - head_radius - grow,
                    centre + head_radius + grow, head_centre + head_radius + grow), fill=fill)
    body_top = head_top + head_radius * 2 + 28
    pen.rounded_rectangle(box(centre - shoulder - grow, body_top - grow, centre + shoulder + grow, 1000),
                          radius=int((shoulder + grow) * SCALE), fill=fill)


image = Image.new("RGBA", (SIZE, SIZE), CLEAR)
pen = ImageDraw.Draw(image)
# macOS icon grid: an 824-point rounded square centred on a 1024 canvas.
pen.rounded_rectangle(box(100, 100, 924, 924), radius=185 * SCALE, fill=NAVY)

# The stack: the top edges of two more squares behind the front one, each narrower and fainter.
pen.rounded_rectangle(box(342, 212, 682, 250), radius=19 * SCALE, fill=(255, 255, 255, 110))
pen.rounded_rectangle(box(302, 282, 722, 320), radius=19 * SCALE, fill=(255, 255, 255, 180))

# The front square with two people on it, clipped to the square.
layer = Image.new("RGBA", image.size, CLEAR)
front = ImageDraw.Draw(layer)
front.rounded_rectangle(box(*SQUARE), radius=SQUARE_RADIUS * SCALE, fill=WHITE)
person(front, centre=612, head_top=432, head_radius=58, shoulder=112, fill=TEAL)
person(front, centre=452, head_top=452, head_radius=68, shoulder=132, fill=WHITE, grow=16)
person(front, centre=452, head_top=452, head_radius=68, shoulder=132, fill=NAVY)
mask = Image.new("L", image.size, 0)
ImageDraw.Draw(mask).rounded_rectangle(box(*SQUARE), radius=SQUARE_RADIUS * SCALE, fill=255)
image.paste(layer, (0, 0), mask)

here = os.path.dirname(os.path.abspath(__file__))
with tempfile.TemporaryDirectory() as folder:
    iconset = os.path.join(folder, "AppIcon.iconset")
    os.mkdir(iconset)
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            image.resize((points * factor, points * factor), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "AppIcon.icns")], check=True)
