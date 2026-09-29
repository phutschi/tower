---
status: superseded by 0011
---

# tower is the record; the run dir is the fallback

Every run has one record. With tower installed it is tower's board and
transcript; the kit refuses a tower too old to take tasks during a run. Without
tower the run dir carries the task list (`tasks.tsv`), lane ownership
(`lanes.txt`) and the run note, and the console pane shows the git log. We
keep the fallback because the kit is installed on machines without tower, but
it is the degraded path: the scripts and docs are written tower-first and the
fallback is one branch, not a second design.
