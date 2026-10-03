# Garden — App icon plan (Icon Composer)

This follows the team guide *App Icons with Icon Composer (macOS 26+/Xcode 26+)*.

## Concept

A **sprout growing from a coin**: money you look after grows. It's a simple silhouette, has no text, and stays readable at 16 pt on the Mac.

| Group (front → back) | Artwork (SVG, 1024², no shadows/blur/bg) | Icon Composer treatment |
|---|---|---|
| 1 · Sprout | Two leaves meeting on a short stem, centered above the coin | glass on; fill white (light/tinted), pale mint (dark) |
| 2 · Coin | A coin seen from the side (top ellipse with a rim, plus the coin's edge), lower third; the stem stands on it | glass on, opacity 0.55, translucency 0.4 |
| 3 · Dark Background | Full-bleed rect `Background.svg` | **dark only**, linear-gradient deep forest (`0.06,0.24,0.15` → `0.02,0.10,0.06`); hidden for light + tinted (guide §5 fix) |
| doc `fill` | — | linear gradient `0.30,0.66,0.42` → `0.13,0.41,0.25` (Default appearance) |

File: `Garden/Garden.icon/` (`icon.json` + `Assets/Sprout.svg`, `Coin.svg`, `Background.svg`).
Build setting: `ASSETCATALOG_COMPILER_APPICON_NAME = Garden` (Debug + Release). Remove `AppIcon` from `Assets.xcassets` if present.

## Verification

```bash
ICT="/Applications/Icon Composer.app/Contents/Executables/ictool"
for p in iOS macOS; do for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$ICT" Garden/Garden.icon --export-image --output-file "out/$p-$r.png" \
    --platform $p --rendition $r --width 512 --height 512 --scale 1
done; done
md5 -q out/*.png   # compare before and after each change
```

The **Dark** rendition must keep a green background, not a near-black square. After building, check `plutil -p …/Info.plist | grep -i icon` and `assetutil --info Assets.car | grep -A1 IconImageStack`, which should list 3 stacks.

## Status (2026-10-03)

The icon is built in `Garden/Garden.icon`. All 6 renditions are verified with `ictool`, and the compiled app has `CFBundleIconName = Garden` and 3 `IconImageStack`s.
Design note: the first draft, a stem dropping into a ring, read as the **power symbol ⏻**. It was redrawn as a sprout standing on a coin seen from the side.
