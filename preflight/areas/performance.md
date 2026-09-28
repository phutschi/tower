# Area: performance

Where the changed code does work that grows. For each hotspot, give a
bound: how big the input gets, what one pass costs, what the total is.

Walk every changed file for:

- Loops over input of unknown size, and nested loops.
- A query, request, process start or file read inside a loop.
- Work repeated on every call that could run once.
- Unbounded memory: reading a whole file, collecting every row.
- Waits: sleeps, polls, timeouts, anything that can hang.

Report only what fails its bound:

- Slow or unbounded at the sizes the spec or the repo expects: `must-fix`.
- Fine today, bad if one number grows: `watchpoint`, naming the number.

A hotspot with a sound bound is not a finding: write the bound in your
report and move on.
