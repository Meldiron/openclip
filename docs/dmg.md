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

### Hidden items and the horizontal scroll bar

A styled image carries two invisible items at its root: `.background/` (holding the image)
and `.VolumeIcon.icns`. `create-dmg` parks them at `window_right + 100` to keep them out of
sight, but Finder still counts them towards the scrollable area — so anyone browsing with
hidden files shown (**Cmd-Shift-.**) gets a horizontal scroll bar across the bottom of an
otherwise finished-looking window.

`make_dmg.sh` therefore pins both with explicit `--icon` flags, in the **same two columns as
the real icons** (`APP_X` and `DROP_X`, at `HIDDEN_Y`). Reusing those columns is deliberate:

- An item further right widens the content box and the scroll bar comes back.
- An item nearer the left edge makes Finder nudge *every* icon inwards to fit the label
  cell — placing one at x = 80 shifted all four icons 25 pt right, sliding the app and the
  drop link out of alignment with the artwork behind them.

Finder resolves invisible items by name in AppleScript even though it will not enumerate
them, which is why `--icon ".background" …` works at all. With hidden files shown the two
icons sit above the app and the folder; that is the cost of keeping the window scroll-free,
and it is invisible in the default Finder configuration.

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
positions `{170, 210}` and `{490, 210}`.

The invisible items do not show up there, so read their saved positions straight out of the
`.DS_Store` — this is the check that catches a returning scroll bar:

```bash
python3 - <<'EOF'
import re, struct
d = open('/Volumes/OpenClip/.DS_Store', 'rb').read()
for name in ['.background', '.VolumeIcon.icns', 'OpenClip.app', 'Applications']:
    for m in re.finditer(re.escape(name.encode('utf-16-be')), d):
        tail = d[m.end():m.end() + 40]
        if tail[:4] == b'Iloc':
            print(name, struct.unpack('>ii', tail[12:20]))
EOF
```

Every x must come back under `660 - 64`, and every y under `384 - 84`. Then open the image
four ways — Finder tab bar on and off, hidden files shown and not — and confirm none of them
shows a scroll bar.
