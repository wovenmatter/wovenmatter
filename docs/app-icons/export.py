#!/usr/bin/env python3
"""Export the selected icon masters. Requires Pillow (tested with 11.3)."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parents[1] / 'app/App/Assets.xcassets'

for color, name in [('green', 'AppIcon'), ('cognac', 'AppIconDev')]:
    source = Image.open(HERE / f'{color}-original.png').convert('RGBA')
    assert source.size == (1254, 1254), 'Mask coordinates require the selected 1254px masters'
    # Inset just inside the original tile edge to exclude its neutral exterior.
    scale = 4
    mask = Image.new('L', (1254 * scale, 1254 * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        tuple(v * scale for v in (84, 84, 1170, 1170)),
        radius=194 * scale, fill=255,
    )
    source.putalpha(mask.resize(source.size, Image.Resampling.LANCZOS))
    catalog = ASSETS / f'{name}.appiconset'
    entries = json.loads((catalog / 'Contents.json').read_text())['images']
    for entry in entries:
        pixels = int(entry['size'].split('x')[0]) * int(entry['scale'][:-1])
        source.resize((pixels, pixels), Image.Resampling.LANCZOS).save(catalog / entry['filename'])
    print(f'{color}: exported {len({e["filename"] for e in entries})} files to {catalog.name}')
