#!/usr/bin/env python3
"""Export one shared cube and shadow with two tile colors (requires Pillow)."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageStat

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parents[1] / 'app/App/Assets.xcassets'
MASTER_SIZE = (1254, 1254)
SCALE = 4


def mask_for(draw_shape):
    mask = Image.new('L', tuple(v * SCALE for v in MASTER_SIZE), 0)
    draw_shape(ImageDraw.Draw(mask))
    return mask.resize(MASTER_SIZE, Image.Resampling.LANCZOS)


def polygon(draw, points):
    draw.polygon([(x * SCALE, y * SCALE) for x, y in points], fill=255)


def render_masters():
    green = Image.open(HERE / 'green-original.png').convert('RGB')
    reference = Image.open(HERE / 'cognac-original.png').convert('RGB')
    assert green.size == reference.size == MASTER_SIZE
    # Trace the green source once. Both variants use these exact foreground pixels.
    def foreground_shapes(draw):
        polygon(draw, [(239, 1012), (470, 967), (628, 1083)])
        polygon(draw, [(628, 138), (1002, 393), (1002, 806),
                       (628, 1083), (252, 805), (252, 393)])
    foreground = mask_for(foreground_shapes)
    # Sample a background-only patch from each original. Transfer only its color
    # difference, retaining the green master's background texture and geometry.
    patch = (120, 500, 200, 750)
    means = [ImageStat.Stat(im.crop(patch)).mean for im in (green, reference)]
    delta = [round(b - a) for a, b in zip(*means)]
    tinted = Image.merge('RGB', [
        channel.point([max(0, min(255, value + offset)) for value in range(256)])
        for channel, offset in zip(green.split(), delta)
    ])
    cognac = Image.composite(green, tinted, foreground)
    tile = mask_for(lambda draw: draw.rounded_rectangle(
        tuple(v * SCALE for v in (84, 84, 1170, 1170)),
        radius=194 * SCALE, fill=255,
    ))
    for image in (green, cognac):
        image.putalpha(tile)
    return green, cognac, foreground


def main():
    green, cognac, _ = render_masters()
    for source, name in [(green, 'AppIcon'), (cognac, 'AppIconDev')]:
        catalog = ASSETS / f'{name}.appiconset'
        entries = json.loads((catalog / 'Contents.json').read_text())['images']
        for entry in entries:
            pixels = int(entry['size'].split('x')[0]) * int(entry['scale'][:-1])
            source.resize((pixels, pixels), Image.Resampling.LANCZOS).save(catalog / entry['filename'])
        print(f'Exported {len({e["filename"] for e in entries})} files to {catalog.name}')


if __name__ == '__main__':
    main()
