# Holler

**Hold Fn, talk, let go. Your words land in whatever text box you're in.**

Holler is a tiny macOS menu-bar app for dictation anywhere: Messages, Mail, Slack, your browser, a terminal, a code
editor. It uses Apple's on-device speech recognition, so nothing you say leaves your Mac, there's no account and no
subscription, and it idles at about 35 MB of memory.

- **Hold Fn** and talk. Your words appear greyed out at the text cursor as you speak, the way voice mode works in
  chat apps. Let go and the text is typed in for real.
- **Fn+Space** for hands-free: let go of Fn and keep talking; press Fn again to finish.
- **Esc** cancels. **Cmd+Ctrl+V** pastes your last dictation again.
- **Music and videos pause while you talk** and pick up again when you're done (optional, see below).
- **Word for word.** Holler types exactly what Apple hears, with Apple's punctuation. No AI rewriting.
- **Updates itself** from this repo's releases.

## Requirements

- An Apple Silicon Mac with **macOS 26 or later** (Holler uses Apple's newer on-device dictation engine).
- A keyboard with an **Fn / Globe key** (Apple keyboards and MacBooks).
- Optional: [Homebrew](https://brew.sh) and `brew install media-control` for pausing and resuming media.

## Install

1. Download `Holler-x.y.z.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag **Holler.app** into **Applications**.
3. Open it. Holler is free and open source but not notarized by Apple, so the first time macOS will refuse to open
   it. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Holler.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Holler.app`, then open it.)
4. Allow the **Microphone** and **Speech Recognition** prompts.
5. In **System Settings → Privacy & Security → Accessibility**, switch **Holler** on. That lets it hear the Fn key
   and type into other apps. It starts working within a couple of seconds, no restart needed.

Holler adds itself to your login items so it's always there. Turn that off from its menu.

**If pressing Fn opens the emoji picker** or switches keyboards: **System Settings → Keyboard → "Press 🌐 key to"
→ Do Nothing.**

## Using it

| Do this | What happens |
|---|---|
| Hold **Fn** (a quarter second or longer) | Holler listens. Grey words follow your cursor. |
| Let go of **Fn** | The text is typed where your cursor is. |
| Quick Fn tap, Fn+arrow keys, Fn+Delete... | Work exactly as before. Holler only reacts to a held Fn. |
| **Fn+Space**, then let go | Hands-free. Press **Fn** again to finish. |
| **Esc** while listening | Cancels. Nothing is typed. |
| **Cmd+Ctrl+V** | Pastes your last dictation again (handy if you clicked away). |

Where an app doesn't report its text cursor (some terminals and custom editors), the grey words show in a small
bubble under the text box instead.

**How the text gets in.** Holler briefly puts the text on the clipboard, presses Cmd+V for you, then puts back
whatever you had copied before. It marks that moment as private so clipboard managers skip it.

**Media.** With `media-control` installed, whatever is playing (YouTube in a browser, Spotify, Music, podcasts)
pauses while you talk and resumes after. Holler only resumes what it paused. Anything else still making sound is
muted while you talk, except during calls (if another app is using the microphone, Holler never mutes).

**Better spelling for names.** Menu → **Edit word list…** opens a plain text file
(`~/Library/Application Support/Holler/words.txt`). Put names and jargon there, one per line, and Apple's recogniser
will favour them.

**Let an app keep Fn.** If another app of yours uses a held Fn for its own push-to-talk, tell Holler to stand aside
while that app is in front:

```sh
defaults write com.github.homefront-tech.holler fnExcludedApps -array com.example.otherapp
```

(Find an app's id with `osascript -e 'id of app "App Name"'`.)

## Updates

Holler checks this repo's releases every 6 hours. When there's a new version it downloads it, checks that it's
signed by the same key as the copy you're running, swaps it in while you're not dictating, and restarts. Your
permissions carry over. Turn off **Install updates automatically** in the menu to update by hand
(**Check for Updates…**).

## Privacy

- Speech is recognised on your Mac by Apple's on-device engine. Audio is never recorded to disk or sent anywhere.
- Holler keeps your last dictation in memory only (for Cmd+Ctrl+V) and never writes what you say to disk or logs.
- The only network traffic is the update check against the GitHub API and downloading a release.
  (The first time you use it, macOS may download its English dictation model from Apple.)
- Logs (`~/Library/Logs/Holler/holler.log`) contain events and timings only.

## Troubleshooting

- **Nothing happens when I hold Fn:** check Accessibility is on for Holler (menu → **Permissions…** shows what's
  missing). Another app that grabs Fn (a keyboard utility, another dictation app) can also get in the way.
- **"Couldn't type here":** the app you were in didn't accept a paste (or you switched apps). Press Cmd+Ctrl+V in
  the right box.
- **No grey words, only the bubble:** that app doesn't expose its text cursor to macOS. Typing still works.
- **Media doesn't pause:** install `media-control` (`brew install media-control`). Only apps that show up in
  macOS's Now Playing can be paused.

## Build from source

You need Apple's Command Line Tools (`xcode-select --install`). No Xcode project, no dependencies.

```sh
git clone https://github.com/HomeFront-tech/holler.git && cd holler
./build.sh --test     # build and run the self-tests
./build.sh --open     # build, test, install to ~/Applications/Holler.app and launch
```

The first build creates a private, self-signed signing identity in `.signing/` (gitignored; it never touches your
login keychain). Signing every build with the same identity is what keeps macOS permissions across rebuilds.
A copy you built yourself is signed by your own identity, so it won't install the official releases; update it with
`git pull && ./build.sh --open`.

Other handy modes: `Holler --selftest`, `Holler --transcribe file.aiff` (transcribe an audio file and print it),
`Holler --ghost-demo` (show the overlay for a few seconds). `tools/e2e.sh` is a live end-to-end test that drives
TextEdit and QuickTime and presses Fn by software (`tools/fn-press.swift`).

## Releasing (maintainers)

```sh
tools/release 1.1.0 "What changed"
```

It refuses unless the tree is clean and on `main`, bumps `VERSION`, builds and self-tests, refuses an unsigned or
ad-hoc build, zips the app, tags, pushes and creates the GitHub release. Installed copies pick it up within 6 hours.

**Back up `.signing/`.** Every release must be signed by the same identity. If it's lost, existing installs will
reject new releases and people will have to reinstall by hand and grant permissions again.

## How it works

| File | Job |
|---|---|
| `Sources/Hotkeys.swift`, `HotkeyMachine.swift` | A keyboard event tap on its own thread; a pure state machine decides hold / hands-free / cancel. |
| `Sources/Dictation.swift`, `Transcript.swift` | Microphone → Apple `SpeechAnalyzer` + `DictationTranscriber`, live and final text. |
| `Sources/Caret.swift`, `Ghost.swift` | Finds the text cursor through Accessibility and draws the grey words in a click-through overlay. |
| `Sources/Inserter.swift`, `Spacing.swift` | Clipboard save, a lazy paste promise that confirms the paste landed, Cmd+V, clipboard restore. |
| `Sources/Media.swift`, `MediaPlan.swift` | Pause/resume via `media-control`, Core Audio check for anything else playing, safe mute and restore. |
| `Sources/Updater.swift`, `UpdatePlan.swift` | Release check, download, signature check, swap and relaunch. |
| `Tests/SelfTest.swift` | Self-tests compiled into the app (`Holler --selftest`). |

## License

MIT. See [LICENSE](LICENSE).
