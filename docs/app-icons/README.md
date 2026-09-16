# App icons

- **Production / Release:** sage green (`AppIcon`).
- **Dev / Debug:** pale cognac (`AppIconDev`).

The original design masters are the selected **A11 Larger** and **C4 Larger**
(round 9) from the wovenmatter.com logo exploration on September 16, 2026.
The PNGs here preserve those originals. The existing Xcode configuration selects
which icon catalog each build uses; there is no runtime theme switching.

Run `python3 docs/app-icons/export.py` from the repository with Pillow installed
(tested with 11.3). It removes only the neutral exterior using an antialiased
rounded-tile alpha mask and exports all sizes referenced by the existing asset
catalogs, from 16 to 1024 pixels. The cube, tile colors and internal shadow come
from the original pixels, without generative edits. The small inset excludes the
original neutral edge. The full square canvas and its padding are retained.
