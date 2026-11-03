# Holler map
reviewed: 2026-11-02

- `Sources/`: the app (Swift, AppKit). Pure decision logic (`HotkeyMachine`, `Transcript`, `Spacing`, `MediaPlan`,
  `UpdatePlan`) has no AppKit dependency and is covered by `Tests/SelfTest.swift` (`Holler --selftest`).
- `build.sh`: build, sign with the stable identity in `.signing/`, `--test`, `--install`, `--open`.
- `tools/release`: publish a release (installed copies self-update). `tools/e2e.sh` + `tools/fn-press.swift`: live test.
- `VERSION`: current version; only `tools/release` changes it.
- Rules: never log or store dictated text or text-field contents; never swallow modifier (flagsChanged) events;
  every release is signed by the same identity; keep the self-tests passing.
- `build/`, `.signing/`, `local/` are gitignored and never published.
