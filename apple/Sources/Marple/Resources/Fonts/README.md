# Bundled reading fonts

The font files in this folder are **not committed** — they're large (~42MB) and
some (方正 / FZ) are commercial faces that can't be redistributed with the repo.
This README keeps the folder tracked so the SwiftPM target's `Bundle.module`
resource exists (`FontRegistration` and `Package.swift`'s `.copy("Resources/Fonts")`
depend on it). With no font files present the app simply falls back to system
faces — the custom 阅读字体 options just won't resolve.

To enable the bundled reading fonts, drop these into this folder (they're
git-ignored):

- `LXGWWenKaiMonoScreen.ttf` — 霞鹜文楷(屏阅), SIL OFL
- `LXGWNeoZhiSongPlus.ttf` — 霞鹜新致宋, SIL OFL
- `FZPingXianYaSong.ttf` — 方正屏显雅宋 (commercial)
- `FZYouHei.ttf` — 方正悠黑 (commercial)
