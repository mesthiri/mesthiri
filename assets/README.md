# mesthiri — mascot and marks

## The mascot

A **Great Hornbill** (*Buceros bicornis*) standing on a steel beam, sighting a
plumb line.

The name came first. *Mesthiri* (മേസ്തിരി) is Malayalam for the site foreman —
the person who directs a crew rather than laying the bricks. The mascot had to
be a creature that supervises, and it had to belong to the same place the word
does. The Great Hornbill is Kerala's state bird, and it arrives wearing the job:
the casque on its bill is a hard hat it grew itself, in the same amber the
Kaappi palette already uses. No costume, no clipboard, no borrowed props.

The plumb line is the other half of the idea. A foreman's authority is not that
he says the wall is straight; it is that he hangs a weight on a string and lets
gravity say so. That is [principle 2](../README.md#principles) — the evidence a
change is good is your CI running on the pull request, not the agent's account
of how it went. The bird is looking at the line, not at you.

The beam is the CI job the whole thing runs inside: mesthiri has no server to
perch on, so it stands on yours.

## Files

| File | Use |
|---|---|
| `mascot.svg` · `mascot-dark.svg` | The full character. READMEs, docs, slides, stickers. |
| `mascot.png` · `mascot-dark.png` | 900 px raster of the above, for surfaces that will not render SVG. |
| `logo.svg` · `logo-dark.svg` | Head mark, transparent. Headers, nav bars, anywhere the body would not fit. |
| `logo-mono.svg` | One colour, inherits `currentColor`. Knockouts are real holes, so it works on any ground — print, embroidery, a terminal splash. |
| `icon.svg` · `icon-dark.svg` | Rounded-square app icon. Favicons, avatars, package listings. |
| `icon-512.png` | 512 px raster for GitHub org/repo avatar upload, which will not take an SVG. |
| `wordmark.svg` · `wordmark-dark.svg` | Head mark + `mesthiri` lockup. Titles, banners, talk slides. |

Pick `-dark` on grounds darker than roughly `#4A3A2C`; the default files assume a
light ground. The `-dark` variants lift the plumage from near-black to a warm
charcoal so the bird does not dissolve into the background — the bill and casque
are unchanged, because amber carries either way.

## Palette

Shared with [Kaappi](https://kaappi-lang.org/), because mesthiri is written in it.

| Role | Light | Dark variant |
|---|---|---|
| Plumage, text | `#1A1410` dark roast | `#42342A` |
| Wing, beam | `#34281D` roast | `#59473A` |
| Neck, tail, eye | `#F3E9DB` cream | `#F3E9DB` |
| Casque, upper bill | `#E8B563` amber | `#E8B563` |
| Lower bill | `#D08B3C` deep amber | `#CE8B3E` |
| Feet, plumb bob | `#9A6520` ochre / `#B07530` brass | `#A87434` / `#C08A42` |
| Page ground | `#F5F0EB` | `#1A1410` |

## Typeface

The wordmark is **Baloo Chettan 2 Bold** ([SIL OFL 1.1](https://scripts.sil.org/OFL)),
converted to outlines — the SVG needs no font installed and no webfont request.

Baloo Chettan is the Malayalam cut of Ek Type's Baloo superfamily, and it is here
for the same reason the bird is: the project's name is Malayalam, so the letters
should come from a face drawn for that script rather than one that merely happens
to be installed. Its rounded terminals also match the mascot's geometry. The face
covers Latin and Malayalam from one family, so `mesthiri` and മേസ്തിരി can be set
together without a second typeface.

Set running text in whatever the surrounding document uses; only the lockup is
prescribed. To reset the wordmark, use the same face at Bold with `+0.5` tracking
at 100 px.

## Using the marks

- **Clear space**: keep a margin of one casque-height on every side. The files
  already carry it; do not crop into it.
- **Minimum size**: `icon.svg` is legible to about 24 px. Below that use a plain
  amber square — the bird becomes mush and reads as a smudge, which is worse than
  no mark.
- **Do not** recolour the bill (the amber *is* the recognition), flip the bird to
  face left (it would then be looking away from the plumb line, which is the
  whole joke), add a hard hat (it has one), or stretch any file non-uniformly.
- The mascot may be used to refer to this project. It is not a certification mark
  — putting it on your repository does not mean mesthiri reviewed anything.

## Licence

MIT, the same as the rest of the project. The Baloo Chettan 2 letterforms in the
wordmark remain under the SIL Open Font License 1.1, which permits exactly this
use.
