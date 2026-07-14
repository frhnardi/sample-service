# VHS tape — a clean, scripted alternative to record.sh for producing the demo
# GIF (https://github.com/charmbracelet/vhs). Deterministic framing/timing, good
# for a polished loop. Run against a live cluster:  vhs rogue-deploy.tape
#
# record.sh (asciinema) captures a real run verbatim; this tape drives the same
# script but with controlled terminal size and typing speed. Pick whichever
# gives the cleaner result for your README/LinkedIn.

Output rogue-deploy.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 760
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 55ms

Type "# Paved Road — you cannot deploy an image nobody signed."
Enter
Sleep 1500ms
Type "# Push an unsigned image by hand, then try to run it. Watch the cluster say no."
Enter
Sleep 1500ms
Type "./rogue-deploy.sh"
Enter

# The script builds, pushes unsigned, gets denied, then deploys the signed
# digest. Give it room to run; trim/loop the resulting GIF as needed.
Sleep 120s
