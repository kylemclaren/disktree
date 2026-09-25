# disktree — agent guide

A native macOS treemap explorer for disk usage, in Swift: AppKit for the
window and the painted mosaic, SwiftUI for the screens. Read `README.md` for
the product; this file is the working contract.

## What this is

Find what is eating a volume, mark paths, review the list, and hand it over —
to Finder, or as one command copied for Terminal — with the volume's free
space live on screen the whole time. Two phases: explore (treemap, the trail,
the legend, the side panel) and review (the marked list, the command, the
hand-over). disktree never deletes, moves or trashes anything itself: marking
is never destructive, and neither is anything else it does.

## Commands

```sh
make build                      # release build, bundled as build/disktree.app
make run                        # build and run, scanning $HOME (ARGS=... to change)
make install                    # ~/Applications/disktree.app and ~/.local/bin/disktree
make install APPDIR=/Applications
make uninstall
make lint                       # swift format --strict, columns, warnings-as-errors build, plutil
make test                       # core and app tests; fails unless every test ran
make ci                         # lint, then test
make fmt                        # format in place
make icon                       # redraw assets/disktree.icns from the mark
```

`make lint` is the gate. It must be green before anything is called done, and
it must not fix anything: a red local run is the same signal CI gives. `make
test` checks for Swift Testing's "Test run with N tests … passed" line, not
only the exit status: a test that stops the main run loop ends the runner's
own loop, and `swift test` then exits 0 with tests unfinished.

`make build` assembles the bundle with `scripts/bundle.sh` (Info.plist from
`packaging/Info.plist` with `VERSION`, the icon, an ad-hoc signature). The app
must not use SwiftPM resources (`Bundle.module`): the script refuses a bundle
that would need them.

## House rules

* **Strict by default.** Swift 6 language mode (strict concurrency) with
  `ExistentialAny`; `swift format lint --strict` with the repository's
  `.swift-format` (no force unwraps, no force `try`, no implicitly unwrapped
  optionals); every warning an error in `make lint`. No third-party packages.
* **80 columns**, 4-space indent, by `.swift-format`; `scripts/columns.sh`
  counts the columns of what it cannot rewrap, comments and strings, in the
  sources and scripts.
* **Comments say why.** The code says what. Any non-obvious number, ordering or
  boundary deserves the reason next to it.
* **Tests live beside the promise they make.** `DisktreeCoreTests` test size
  accounting, layout, the volume rules and the removal guards against real
  temporary trees (and a real disk image for the volume rules);
  `DisktreeAppTests` drive the state machine and host the real screens in
  offscreen windows — draw a frame, press keys, send mouse and trackpad
  events — so a screen that crashes while drawing fails a test. Tests never
  touch the real pasteboard, Finder or Quick Look: `AppState` has hooks for
  each.
* **Never delete anything.** The app hands paths to Finder or to a command
  the person runs; `Removal.swift` decides which paths may be handed over at
  all, and those guards are load-bearing and tested.
* **Never read state you write in a layout pass.** On macOS 26 AppKit
  observes what `layout()` and `draw(_:)` read; a view that reads an
  `@Observable` property there and writes it back schedules layout passes
  until AppKit throws. Report sizes write-only; draw through
  `withObservationTracking`; keep memo fields `@ObservationIgnored`.
* **Privacy prompts block.** Never walk `/` or a home directory from a test or
  a script, and never read `~/Library`, `~/Desktop`, `~/Documents`,
  `~/Downloads` or `~/.Trash` there: a TCC prompt stalls the process until
  someone answers it. The one test that runs the real `trash` command, and
  so takes its file back out of `~/.Trash`, is opt-in:
  `DISKTREE_TEST_TRASH=1 make test`.

## Invariants

1. **Sizes come from `st_blocks * 512` unless apparent size was asked for.**
   That is the number that comes back when a file is deleted.
2. **`ownBytes`/`ownFiles` are derived, never tracked.** `aggregate` computes
   the totals from the children. Hardlink de-duplication rewrites a leaf's
   weight and re-aggregates; anything that patches `bytes` directly will be
   overwritten.
3. **A directory is only built when its own scan *and* every subdirectory task
   has finished.** That is the `+1` sentinel in `PendingDir.pending`. Building
   early silently drops whole subtrees — it has happened once.
4. **Only paths under the scanned root may be handed over**, and mount points
   and firmlinks, directories with a volume mounted inside them, the root,
   the home directory and what holds it, `~/Library` itself, paths behind a
   symlink, names that are not UTF-8 or that hold a control character, and
   system trees are refused. A copied command names only the plan's targets,
   each absolute and single-quoted, and `rm` runs with `-x`.
5. **Marks are keyed by absolute path**, not tree position, so they survive a
   re-scan; a re-scan drops the marks whose paths are gone from disk and
   re-reads the sizes of the rest.
6. **The treemap is painted, not composed of views.** Thousands of rectangles
   belong in one `draw(_:)`; labels are CoreText lines drawn there too, each
   clipped to its own tile.
7. **Tile crumbs are absolute.** `layout` takes the drawn node's crumbs and
   every tile extends them, so a tile resolves from the scanned root at any
   depth. Relative crumbs look right at `~` and silently point at other
   directories after descending — including for marks. Any code that turns a
   path into crumbs walks from the scanned root, too.
8. **The view transform is the only thing zoom changes.** Layout runs in
   base-space points and is cached; `screen = (base - origin) * scale`.
9. **The screen never claims a saving it cannot measure.** Projections come
   from marked bytes and say so; the gain comes from `statfs` before the first
   mark and after the marks are gone.
10. **A volume is decided by path, not by device.** APFS firmlinks carry the
    Data volume's device into `/`; the scan keeps what the root's volume
    reaches through them and leaves out `/System/Volumes/Data` itself, so no
    byte is counted twice.

## Where changes belong

| change | where |
| --- | --- |
| measurement, filtering, parallelism | `Sources/DisktreeCore/Scan.swift` |
| what a node is, or a derived total | `Sources/DisktreeCore/Tree.swift` |
| what a directory is, or whether it can go | `Sources/DisktreeCore/Classify.swift` |
| tile geometry, nesting, the merged tail | `Sources/DisktreeCore/Treemap.swift` |
| what may be handed over, and the command | `Sources/DisktreeCore/Removal.swift` |
| free space, mounts, volumes | `Sources/DisktreeCore/Space.swift` |
| a key, a screen transition, a mark, a gesture's outcome | `Sources/DisktreeApp/AppState+*.swift` |
| spacing, type and size | `Sources/DisktreeApp/UI.swift` — tokens only, no raw points in layout |
| the palette and what colour means | `Sources/DisktreeApp/Theme.swift`, `Palette.swift`, `Backdrop.swift` |
| the mosaic's painting, labels, pointer and trackpad | `Sources/DisktreeApp/TreemapNSView.swift`, `MosaicRaster.swift`, `Haptics.swift` |
| layout of a screen | `Sources/DisktreeApp/*View.swift`, `SidePanel*.swift`, `Toolbar.swift`, `Trail.swift`, … |
| corner radii, cards, chips, glass and its fallbacks | `Sources/DisktreeApp/Widgets.swift` (`Rounding`), `Toast.swift` (`glassPlate`) |
| the window, menus, keys, CLI | `MainWindowController.swift`, `Menus.swift`, `KeyStroke+NSEvent.swift`, `CLI.swift` |

## Verification expectations

* Size accounting, hardlinks, symlinks, hidden entries, depth limits, the
  volume rules, the removal guards, the command's quoting (run through sh,
  bash and zsh, and pasted through a pseudo-terminal's line discipline) and
  squarified layout are covered by `DisktreeCoreTests` against real
  temporary trees.
* The screens are covered by `DisktreeAppTests` that host them in real
  windows in both appearances, including one that marks a directory, copies
  the command, runs it, and checks the files are gone while unmarked
  neighbours are untouched.
* Rendering is checked by those tests and by `--snapshot FILE.png [--keys
  "space c"]`, which renders the real window once the first scan lands; it
  has not been eyeballed at every interface zoom step and every accent.
  A snapshot is drawn as the active window, but on the plain surfaces a
  window nobody sees gets: Liquid Glass exists only on screen, and shown
  off screen it blanks the window. So is a scroll view that reaches up
  behind the toolbar — keep the panel's clear of it off screen. What a
  person sees on macOS 26 is only checked by a capture of the real window.
  The README's `assets/screenshot-dark.png` and `screenshot-light.png` are
  `--snapshot` renders all the same, by the owner's choice: regenerate both
  together, over a made-up home folder (sparse files, `-a`, `HOME` pointed
  at it), never over a real one, and know they show the plain surfaces.
