# DMG Installer

`OpenClip.dmg` is a styled disk image: a rendered background, the app icon on the left, a
drop link to `/Applications` on the right, and an arrow between them. It is produced by
`scripts/make_dmg.sh`, which both `scripts/package_app.sh` and `scripts/release_update.sh`
call, so local packaging and CI releases always emit the same layout.

```bash
brew install create-dmg                                 # one-time
./scripts/make_dmg.sh /path/to/OpenClip.app build/OpenClip.dmg
```

## Editing the background

The background is **not a checked-in bitmap**. Its source of truth is
`assets/dmg/background.html`, plain HTML/CSS with an inline SVG arrow. Edit that file,
re-run the packaging script, and the PNG/TIFF are regenerated — no image editor, and the
diff stays reviewable.

`scripts/render_html_png.swift` rasterises it through WebKit at exact pixel dimensions:

```bash
swift scripts/render_html_png.swift assets/dmg/background.html /tmp/bg.png 660 420 2
```

The renderer takes `<input> <output.png> <width> <height> [scale]` and accepts any HTML or
SVG file, so it is also the right tool for other generated art in this repo.

`make_dmg.sh` renders at 1× and 2×, then merges both into one multi-representation TIFF
with `tiffutil -cathidpicheck`. Finder picks the 2× rendition on Retina displays, which is
what keeps the background from looking soft — a single 660×420 PNG is blurry on every
modern Mac, and a plain 1320×840 PNG is drawn at double size.

## Layout contract

These numbers appear in **two** places and must be changed together: the CSS custom
properties at the top of `assets/dmg/background.html` and the constants near the top of
`scripts/make_dmg.sh`.

| Value | Setting |
| --- | --- |
| Background canvas | 660 × 380 pt |
| Finder chrome allowance | 68 pt |
| Window size | 660 × 448 pt (canvas + chrome) |
| Icon size | 128 pt |
| Icon label text size | 13 pt |
| Icon row centre | y = 210 |
| `OpenClip.app` centre | x = 170 |
| `Applications` centre | x = 490 |

Finder positions are the **centre** of each icon, measured from the top-left of the window
content area. With a 128 pt icon the graphic spans ±64 pt around the centre and Finder
draws the label just below it, so the background must leave roughly y = 146…296 clear
across both icon columns.

### Why the window is taller than the canvas

Finder draws the background at its **natural size**, anchored to the top-left of the
content area — it never scales it. If the image is larger than that area, the window gets
scroll bars, which is the single most common way a styled DMG ends up looking broken.

`--window-size` covers the whole window frame, and Finder chrome eats into it: a 28 pt
title bar always, plus a ~36 pt tab bar for anyone who leaves **View → Show Tab Bar** on.
That setting belongs to the person opening the DMG, so the safe move is to size the window
for the worst case (`CHROME_H = 68`) and let the canvas be shorter than the content area.

The leftover margin is then covered by Finder's own white icon-view background, which is
why **the canvas must bleed to pure white at its outer edges**. Keep the tint and texture
away from the border; a coloured edge turns that margin into a visible seam.

## Design rules

- **Never draw the app icon or the Applications folder into the background.** Both are real
  Finder items placed on top of it; painting them in produces doubled icons. The background
  holds decoration only — headline, arrow, footer.
- **Keep the background light.** When a disk image has a custom background picture, Finder
  renders icon labels in light-mode black regardless of the user's appearance setting, so a
  dark background makes the "OpenClip" and "Applications" labels unreadable in Dark Mode.
- The volume icon is generated from `assets/app-icon.png` via `sips` + `iconutil`, so the
  mounted volume shows the app's icon in the Finder sidebar and on the desktop.
- The window is intentionally free of a toolbar and status bar, and the app's `.app`
  extension is hidden, so the window reads as a single instruction rather than a folder.

## Verifying a change

`create-dmg` drives Finder over AppleScript, so the layout is only really confirmed by
mounting the result:

```bash
./scripts/make_dmg.sh /path/to/OpenClip.app /tmp/OpenClip.dmg
open /tmp/OpenClip.dmg
```

To check the saved view settings without eyeballing them:

```bash
osascript -e 'tell application "Finder" to tell disk "OpenClip"
  {bounds of container window, icon size of icon view options of container window,
   position of item "OpenClip.app", position of item "Applications"}
end tell'
```

That should report bounds `{200, 120, 860, 568}` (a 660 × 448 window), icon size `128`, and
positions `{170, 210}` and `{490, 210}`. Open it with the Finder tab bar both on and off and
confirm neither state shows a scroll bar.
