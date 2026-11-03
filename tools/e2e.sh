#!/bin/zsh
# End-to-end test of the INSTALLED Holler: drives TextEdit, presses Fn by software, feeds a spoken test file
# instead of the microphone (testAudioFile hook), and checks what lands in the document, the clipboard and media.
# This live test controls other apps. Evidence goes to build/e2e/.
set -u
cd "${0:A:h}/.."
OUT=$PWD/build/e2e; rm -rf $OUT; mkdir -p $OUT
FN=$PWD/build/fn-press
swiftc -O tools/fn-press.swift -o $FN 2>/dev/null || { echo "FAIL build fn-press"; exit 1; }
pgrep -x Holler >/dev/null || { echo "FAIL Holler is not running"; exit 1; }
pass=0; fail=0
ok()  { print "PASS $1"; ((pass++)); }
bad() { print "FAIL $1"; ((fail++)); }
doc() { osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null }
count() { print -r -- "$1" | grep -o "the garden" | wc -l | tr -d ' ' }
logmark() { wc -l < ~/Library/Logs/Holler/holler.log | tr -d ' ' }
newlog() { tail -n +$(( $1 + 1 )) ~/Library/Logs/Holler/holler.log }

pbpaste > $OUT/original-clipboard.txt 2>/dev/null
say -o $OUT/speech.aiff "Testing Holler in the garden"
defaults write com.github.homefront-tech.holler testAudioFile "$OUT/speech.aiff"
trap 'defaults delete com.github.homefront-tech.holler testAudioFile 2>/dev/null; pbcopy < $OUT/original-clipboard.txt' EXIT

osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1.5
printf 'CLIP-SENTINEL' | pbcopy

# 1. Hold Fn 2.5 s -> the sentence lands in TextEdit; clipboard comes back.
m=$(logmark)
$FN hold 2.5 &
sleep 1.4; screencapture -x $OUT/1-ghost-while-holding.png
wait; sleep 3
d=$(doc); print -r -- "$d" > $OUT/1-doc.txt
[[ $(count "$d") == 1 ]] && ok "hold-to-talk typed the sentence" || bad "hold-to-talk: doc=[$d]"
[[ "$(pbpaste)" == CLIP-SENTINEL ]] && ok "clipboard restored after paste" || bad "clipboard not restored: [$(pbpaste)]"
newlog $m > $OUT/1-log.txt

# 2. Quick Fn tap -> nothing typed.
before=$(doc); $FN tap; sleep 2
[[ "$(doc)" == "$before" ]] && ok "quick Fn tap types nothing" || bad "quick tap changed the doc"

# 3. Hold, then Esc -> cancelled, nothing typed, no stray Esc effect.
before=$(doc); m=$(logmark)
$FN seq fn+ sleep:1.0 esc sleep:0.3 fn-; sleep 3
[[ "$(doc)" == "$before" ]] && ok "Esc cancels (nothing typed)" || bad "Esc cancel typed something"
newlog $m | grep -q "recording cancelled" && ok "log shows cancel" || bad "no cancel in log"

# 4. Fn+Space hands-free: keeps recording after Fn is released, next Fn press finishes; Space not typed.
m=$(logmark)
$FN seq fn+ sleep:0.1 space sleep:0.1 fn- sleep:2.0
screencapture -x $OUT/4-ghost-handsfree.png
$FN seq fn+ sleep:0.05 fn-; sleep 3.5
d=$(doc); print -r -- "$d" > $OUT/4-doc.txt
[[ $(count "$d") == 2 ]] && ok "hands-free typed the sentence" || bad "hands-free: doc=[$d]"
[[ "$d" != *"  "* ]] && ok "no stray space from Fn+Space" || bad "double space found"
[[ "$d" == *"garden"*" "*"Testing"* || "$d" == *"garden."*" Testing"* ]] && ok "leading space added between dictations" || bad "missing space between dictations: [$d]"
newlog $m > $OUT/4-log.txt

# 5. Cmd+Ctrl+V pastes the last dictation again.
$FN seq pastelast; sleep 2
[[ $(count "$(doc)") == 3 ]] && ok "Cmd+Ctrl+V pasted last text" || bad "paste-last: doc=[$(doc)]"
[[ "$(pbpaste)" == CLIP-SENTINEL ]] && ok "clipboard restored after paste-last" || bad "clipboard not restored after paste-last"

# 6. Media: QuickTime plays a quiet file; Holler pauses it while talking and resumes it after.
say -o $OUT/music.aiff "$(printf 'la %.0s' {1..400})"
osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$OUT/music.aiff\"" \
          -e 'tell application "QuickTime Player" to set audio volume of document 1 to 0.05' \
          -e 'tell application "QuickTime Player" to play document 1' >/dev/null 2>&1
sleep 1.5
media-control get > $OUT/6-before.json
if grep -q '"playing":true' $OUT/6-before.json; then
  osascript -e 'tell application "TextEdit" to activate' >/dev/null; sleep 1
  $FN hold 3 &
  sleep 1.8; media-control get > $OUT/6-during.json
  wait; sleep 3; media-control get > $OUT/6-after.json
  grep -q '"playing":false' $OUT/6-during.json && ok "media paused while talking" || bad "media not paused: $(cat $OUT/6-during.json)"
  grep -q '"playing":true' $OUT/6-after.json && ok "media resumed after" || bad "media not resumed: $(cat $OUT/6-after.json)"
else
  print "SKIP media test: QuickTime did not register as Now Playing ($(cat $OUT/6-before.json | head -c 200))"
fi
osascript -e 'tell application "QuickTime Player" to close every document saving no' -e 'tell application "QuickTime Player" to quit' >/dev/null 2>&1

# 7. Memory.
print "Holler RSS now: $(( $(ps -o rss= -p $(pgrep -x Holler)) / 1024 )) MB" | tee $OUT/7-memory.txt

osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null 2>&1
print "\n$pass passed, $fail failed" | tee $OUT/summary.txt
[[ $fail == 0 ]]
