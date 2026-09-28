<!-- preflight's default PR body. Fill every {{PLACEHOLDER}}; delete these
comments. Merge-ready tone: the reader should conclude "ready to merge".
Every trade-off reads as decided and accepted, with its reason. An area
with nothing to say keeps its row and a one-line TLDR. -->

<!-- The spec issue or plan this PR implements, as a link; "No spec linked" when none. -->
{{SPEC_LINK}}

## Verdict

| Check           | Status | Headline |
|-----------------|--------|----------|
| Static baseline | {{STATIC_STATUS}} | {{STATIC_HEADLINE}} |
| Full suite      | {{SUITE_STATUS}} | {{SUITE_HEADLINE}} |
| Spec            | {{SPEC_STATUS}} | {{SPEC_HEADLINE}} |
| Between lanes   | {{LANES_STATUS}} | {{LANES_HEADLINE}} |
| Security        | {{SEC_STATUS}} | {{SEC_HEADLINE}} |
| Performance     | {{PERF_STATUS}} | {{PERF_HEADLINE}} |
| Error handling  | {{ERR_STATUS}} | {{ERR_HEADLINE}} |

<!-- Status: ✅ pass, ⚠️ accepted findings or a warn row, ⏭️ skipped (say why).
One row per suite step in the Full suite details. Add a row per repo area. -->

## Summary

<!-- Two to four short paragraphs: what the branch changes and why it is ready. -->
{{SUMMARY}}

## Implementation

<!-- How it works, part by part, citing files. From the diff and the commits. -->
{{IMPLEMENTATION}}

<!-- One section per area, in the Verdict's order. TLDR: one line. DETAIL:
the area's verdict row `detail` (look.json's rows for the static baseline
and the full suite), then its findings with their outcomes. -->

## Static baseline

> **TLDR**: {{STATIC_TLDR}}

<details>
<summary>semgrep and gitleaks</summary>

{{STATIC_DETAIL}}

</details>

## Full suite

> **TLDR**: {{SUITE_TLDR}}

<details>
<summary>Every step</summary>

{{SUITE_DETAIL}}

</details>

## Spec

> **TLDR**: {{SPEC_TLDR}}

<details>
<summary>Every acceptance criterion</summary>

{{SPEC_DETAIL}}

</details>

## Between lanes

> **TLDR**: {{LANES_TLDR}}

<details>
<summary>Seams, duplicates, vocabulary</summary>

{{LANES_DETAIL}}

</details>

## Security

> **TLDR**: {{SEC_TLDR}}

<details>
<summary>What was checked</summary>

{{SEC_DETAIL}}

</details>

## Performance

> **TLDR**: {{PERF_TLDR}}

<details>
<summary>Every hotspot and its bound</summary>

{{PERF_DETAIL}}

</details>

## Error handling

> **TLDR**: {{ERR_TLDR}}

<details>
<summary>Every failure point</summary>

{{ERR_DETAIL}}

</details>

## Trade-offs we accept

<!-- Findings triaged `accept`: what, why it is fine to merge, what limits it. -->

{{TRADE_OFFS}}

## Out of scope

<!-- Deliberate exclusions, each with its reason: the spec's out-of-scope
list, and what the diff leaves alone on purpose. -->

{{OUT_OF_SCOPE}}

## Follow-ups

<!-- Findings triaged `follow-up`: one line and the issue link each. -->

{{FOLLOW_UPS}}

## Test plan

<!-- What proves it works: the suite steps that ran, the tests the branch
adds, and any check a human should repeat by hand. -->
{{TEST_PLAN}}
