# VHS tape for the README recording. Do not run it by hand: demo/record.sh
# builds the isolated herdr and the acme run it needs, then runs vhs on it.
Output demo.gif
Set Shell bash
Set FontSize 13
Set Width 1400
Set Height 900
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

Hide
Type "cd $DEMO_DIR/acme && herdr"
Enter
Sleep 4s
Type "$DEMO_ROOT/demo/stage.sh"
Enter
Sleep 1500ms
Show
Sleep 41s
