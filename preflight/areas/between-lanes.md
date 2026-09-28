# Area: between-lanes

Problems that only show when separately written work meets: lanes of a
run, or branches merged into this one. Alone on a branch with no merged
branches (`git log --merges <merge-base>..HEAD` is empty), write a `skip`
row, note `one line of work`, and go on.

Find the parts: inside a run, each lane's branch and task ids from the pane
map and the plan; alone, the merged branches from `git log --merges`.

Look for:

- **Seams**: one part calls another's function, script or file format. Do
  both sides agree on names, arguments, output shape and exit codes?
- **Duplicates**: two parts added the same helper, fixture, test or doc
  section under different names.
- **Vocabulary**: the same thing named two ways, or a word used against the
  repo's glossary (`CONTEXT.md` or its equivalent).
- **Merge leftovers**: conflict markers, both sides of a resolved conflict
  kept by mistake, a section duplicated in a shared file.
- **Order**: one part assumes the other's change landed first, or a shared
  setting changed under the other.

Every finding cites both sides: `file:line` of each part.
