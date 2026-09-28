# tower is the record; the run dir is the fallback

Every run has one record. With tower installed (0.2.0 or later) it is tower's
board and transcript; the kit refuses an older tower rather than running with
a board that cannot take on-the-fly tasks. Without tower the run dir carries
the task list (`tasks.tsv`), lane ownership (`lanes.txt`) and the run note,
and the console pane shows the git log. We keep the fallback because the kit
is installed on machines without tower, but it is the degraded path: the
scripts and docs are written tower-first and the fallback is one branch, not a
second design.
