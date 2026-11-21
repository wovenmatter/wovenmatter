# App icons

- **Release:** sage green (`AppIcon`).
- **Debug and development instances:** pale cognac (`AppIconDev`).

Both catalogs are in `app/App/Assets.xcassets`, and the Xcode build settings
pick one per configuration. There is no runtime switching.

Both variants use one shared foreground, traced from the original green
**A11 Larger** design: the same cube and shadow pixels, geometry, placement and
canvas padding. The cognac original (**C4 Larger**) is kept only as a
background colour reference; its own cube and shadow are not used. Both
originals came from the wovenmatter.com round 9 exploration on September 16,
2026.

Run `python3 docs/app-icons/export.py` with Pillow installed (tested with
11.3). It samples a background-only patch in both originals and moves the
colour difference onto the green master outside the shared cube-and-shadow
mask, which keeps the master's background texture. The neutral exterior is
filled with the sampled background colour, giving fully opaque square artwork;
macOS applies the outer icon shape. The canvas is never cropped, scaled up or
moved. Every catalog size from 16 to 1024 pixels is exported with Lanczos
resampling.

The script also writes the production artwork to the iPhone and iPad catalog in
`ios/`, which is not built.
