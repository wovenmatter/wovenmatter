# App icons

- **Production / Release:** sage green (`AppIcon`).
- **Dev / Debug:** pale cognac (`AppIconDev`).

Both variants use **one shared foreground**, traced from the original green
**A11 Larger** design: identical cube pixels, shadow pixels, geometry, placement,
and canvas padding. The cognac original (**C4 Larger**) is retained only as a
background color reference; its independently generated cube and shadow are not
used. These source designs came from the wovenmatter.com round 9 exploration on
September 16, 2026.

Run `python3 docs/app-icons/export.py` with Pillow installed (tested with 11.3).
It samples a background-only patch in both originals and transfers the RGB color
difference to the green master outside the shared cube-and-shadow mask. This
preserves the master's subtle background texture. The same antialiased rounded
tile mask removes the neutral exterior from both variants. All existing asset
catalog sizes from 16 to 1024 pixels are exported with Lanczos resampling.
Antialiased boundary pixels naturally blend with their respective backgrounds;
the foreground artwork itself is shared, not regenerated.

Xcode's existing build settings select the appropriate catalog. There is no
runtime theme switching and no generative editing in the export process.
