import { expect, test } from "bun:test";
import type { PanelIssue } from "../types.ts";
import { renderPanel, type PanelData } from "./panel-page.ts";

const issue = (n: number, more: Partial<PanelIssue> = {}): PanelIssue => ({
  repo: "acme/widgets",
  number: n,
  title: `Issue ${n}`,
  stage: "needs-triage",
  issueArea: null,
  bundleId: null,
  blockedBy: [],
  stuck: false,
  jobId: null,
  ...more,
});

const data = (more: Partial<PanelData> = {}): PanelData => ({
  issues: [],
  stuckReasons: {},
  repos: ["acme/widgets"],
  stations: [],
  jobs: [],
  advice: null,
  usage: { rows: [], source: "usage-report", pausedUntil: null },
  bundles: [],
  group: "stage",
  ...more,
});

test("the Panel is dark by default and loads nothing from outside the page", () => {
  const html = renderPanel(data());
  expect(html).toContain("color-scheme: dark");
  expect(html).toContain('<meta name="color-scheme" content="dark">');
  expect(html).toMatch(/:root\s*\{[^}]*--bg:/);
  expect(html).not.toMatch(/<link[^>]*rel=["']?stylesheet/i);
  expect(html).not.toMatch(/<script[^>]*\ssrc=/i);
  expect(html).not.toContain("@import");
  expect(html).not.toMatch(/url\(\s*["']?(https?:)?\/\//i);
});

test("each limit carries a bar as full as its percent, kept between 0 and 100", () => {
  const html = renderPanel(
    data({
      usage: {
        rows: [
          { kind: "session", percent: 42.4, resetsAt: "15:00" },
          { kind: "weekly_all", percent: 130, resetsAt: "Mon" },
        ],
        source: "usage-report",
        pausedUntil: null,
      },
    }),
  );
  expect(html).toContain("5-hour window: 42%");
  expect(html).toContain('style="--p:42%"');
  expect(html).toContain('style="--p:100%"');
});

test("a stuck issue and one that waits on another are marked on their card", () => {
  const html = renderPanel(
    data({
      issues: [
        issue(1, { stage: "in-progress", stuck: true, jobId: "j1" }),
        issue(2, { stage: "ready-for-agent", blockedBy: ["#1"] }),
      ],
      stuckReasons: { j1: "no progress" },
    }),
  );
  expect(html).toMatch(/<li class="card is-stuck">.*?stuck: no progress/s);
  expect(html).toMatch(/<li class="card is-waiting">.*?waits on #1/s);
  expect(html).toContain("1 stuck");
});

test("the group the page shows is marked in its nav", () => {
  expect(renderPanel(data({ group: "area" }))).toContain(
    '<nav class="groups g-area"',
  );
});
