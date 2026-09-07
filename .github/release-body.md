## [0.3.0] — 2026-09-07

### Changed

- The board is two sections under the theme's own labels — AIRBORNE and
  ON THE GROUND in airport — so a running flight is never hidden behind a
  pending one on a short pane. Everything landed collapses to one line.
- Every row in a section shares one column layout; a blocked row's note
  starts in the model column instead of shifting the lane and area columns.
- The runway strip wraps into evenly filled rows when the lanes overflow the
  width, with the unit labels aligned in columns.
- `tower theme check` requires the pending label in the preview, since every
  board now prints it.
