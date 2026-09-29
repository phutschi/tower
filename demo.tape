# VHS tape for the README recording. `brew install vhs`, `bun run build`, then
# `vhs demo.tape` from the repo root. It runs the tower built in dist/, in a
# throwaway repo named acme.
Output demo.gif
Set Shell bash
Set FontSize 14
Set Width 1100
Set Height 640
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type `K=$PWD; tower() { node "$K/dist/cli.js" "$@"; }; export XDG_STATE_HOME=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d)`
Enter
Type `cd "$(mktemp -d)" && git init -q acme && cd acme && git commit -q --allow-empty -m init && git checkout -qb feature/widgets`
Enter
Type `export TOWER_RUN=$(mktemp -d)/run && tower init --tasks "$K/demo/tasks.tsv" --title Widgets --lane A=1-4 --lane B=5-6 --run "$TOWER_RUN" >/dev/null && clear`
Enter
Show

Type "tower task 1 done committed 'feat: the widget model' --model sonnet-5"
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
