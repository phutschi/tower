# VHS tape for the README recording. `brew install vhs`, then `vhs demo.tape`.
Output demo.gif
Set FontSize 14
Set Width 1100
Set Height 640
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "export TOWER_RUN=$(mktemp -d)/run && tower init --tasks demo/tasks.tsv --lane A=1-4 --lane B=5-6 --run $TOWER_RUN >/dev/null && clear"
Enter
Show

Type "tower task 1 done committed 'feat: the shared shortcuts' --model sonnet-5"
Enter
Sleep 600ms
Type "tower task 2 in_progress implementing --model sonnet-5"
Enter
Sleep 600ms
Type "tower block 5 'needs the test database created'"
Enter
Sleep 800ms
Type "tower"
Enter
Sleep 4s
Type "q"
Sleep 500ms
