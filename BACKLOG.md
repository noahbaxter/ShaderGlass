# ShaderGlass macOS Port — Backlog

Tracking all work needed before submitting PR to upstream (issue #144).

## P0 — Blockers (no PR without these)

- [x] Add GPL v3 headers to all 8 source files (match upstream format)
- [x] Remove .DS_Store from git tracking, add macOS entries to root .gitignore
- [x] About dialog — custom panel with GPL v3 info and repo link
- [x] Update README.md with macOS section (requirements, build, limitations)

## P1 — Should Fix

- [x] Screen Recording permission denial dialog (NSAlert instead of black screen)
- [x] Remove hardcoded 1920x1080 in MetalRenderer.mm (init to 0)
- [ ] Don't include dev-only files in PR (CLAUDE.md, TODO.md, BACKLOG.md)

## P2 — Feature Work

- [x] Settings persistence (UserDefaults: shader, window pos/size, toggles, fullscreen)
- [x] Shader parameters — expose adjustable uniforms per shader via menu/panel
- [x] More shaders — 101 total (was 63), covering handheld LCD, artistic, CRT variants, etc.

## P3 — Polish

- [ ] Code style alignment (PascalCase for C++ public methods)
- [ ] Split shader name list out of main.mm inline code
- [ ] Brief inline comments at module boundaries

## Git History

- [ ] Create `feature/macos-port-clean` from `origin/master`
- [ ] Rebuild as 8 clean commits (infra → components → integration → features)
- [ ] Bake all fixes into relevant commits (no fix-up commits)

## Follow-up PRs (mention in description)

- macOS CI job in GitHub Actions
- Device capture (webcam/capture card via AVFoundation)
- Window-specific capture (pick a window instead of whole display)
- Profile save/load system
- Runtime shader loading
