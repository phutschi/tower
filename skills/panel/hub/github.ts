/** The only module of the hub that runs gh. */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface GhIssue {
  number: number;
  title: string;
  labels: { name: string }[];
}

/** An issue in some repo: a closing reference or a blocker may be in another. */
export interface IssueRef {
  repo: string;
  number: number;
}

/** Whether two owner/name strings name one repo: GitHub ignores case. */
export const sameRepo = (a: string, b: string) =>
  a.toLowerCase() === b.toLowerCase();

export class GitHub {
  /** `timeoutMs`: a gh that hangs is killed, so it cannot hold every poll and move. */
  constructor(
    private readonly bin = "gh",
    private readonly timeoutMs = 120_000,
  ) {}

  private async gh(args: string[]): Promise<string> {
    const { stdout } = await run(this.bin, args, {
      maxBuffer: 64 * 1024 * 1024,
      timeout: this.timeoutMs,
      killSignal: "SIGKILL",
    });
    return stdout;
  }

  /** Every page of a REST list, as one list. */
  private async pages<T>(path: string): Promise<T[]> {
    const out = await this.gh(["api", "--paginate", "--slurp", path]);
    return (JSON.parse(out) as T[][]).flat();
  }

  /** shortcut: the first 1000 open issues only, page with gh api once a repo has more. */
  async openIssues(repo: string): Promise<GhIssue[]> {
    const out = await this.gh([
      "issue",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--limit",
      "1000",
      "--json",
      "number,title,labels",
    ]);
    return JSON.parse(out) as GhIssue[];
  }

  /** An issue's labels as GitHub has them now. */
  async labels(repo: string, number: number): Promise<string[]> {
    const out = await this.gh([
      "issue",
      "view",
      String(number),
      "--repo",
      repo,
      "--json",
      "labels",
    ]);
    return (JSON.parse(out) as Pick<GhIssue, "labels">).labels.map(
      (l) => l.name,
    );
  }

  /**
   * The issues of `repo` each ready pull request closes, and when it was
   * opened: the open non-draft ones, and the merged ones (a merge between two
   * polls closes its issues before the hub sees the PR ready).
   */
  async readyPulls(repo: string): Promise<
    {
      number: number;
      closes: number[];
      createdAt: string;
      merged: boolean;
    }[]
  > {
    // shortcut: the newest 200 open and 50 merged PRs; a run's PR is among
    // them unless a repo opens or merges more between a run and its PR.
    const list = (state: string, limit: string) =>
      this.gh([
        "pr",
        "list",
        "--repo",
        repo,
        "--state",
        state,
        "--limit",
        limit,
        "--json",
        "number,isDraft,state,createdAt,closingIssuesReferences",
      ]);
    const out = JSON.stringify([
      ...(JSON.parse(await list("open", "200")) as unknown[]),
      ...(JSON.parse(await list("merged", "50")) as unknown[]),
    ]);
    const pulls = JSON.parse(out) as {
      number: number;
      isDraft: boolean;
      state: "OPEN" | "MERGED" | "CLOSED";
      createdAt: string;
      closingIssuesReferences: {
        number: number;
        repository: { name: string; owner: { login: string } };
      }[];
    }[];
    return pulls
      .filter((p) => p.state === "MERGED" || (p.state === "OPEN" && !p.isDraft))
      .map((p) => ({
        number: p.number,
        createdAt: p.createdAt,
        merged: p.state === "MERGED",
        closes: p.closingIssuesReferences
          .filter((i) =>
            sameRepo(`${i.repository.owner.login}/${i.repository.name}`, repo),
          )
          .map((i) => i.number),
      }));
  }

  async editLabels(
    repo: string,
    number: number,
    add: string[],
    remove: string[],
  ): Promise<void> {
    const args = ["issue", "edit", String(number), "--repo", repo];
    for (const label of add) args.push("--add-label", label);
    for (const label of remove) args.push("--remove-label", label);
    await this.gh(args);
  }

  /** The commit main's head is on now; the sha media type spares the commit's body. */
  async head(repo: string): Promise<string> {
    const out = await this.gh([
      "api",
      "-H",
      "Accept: application/vnd.github.sha",
      `repos/${repo}/commits/HEAD`,
    ]);
    return out.trim();
  }

  /**
   * Whether the repo names its contexts in a CONTEXT-MAP.md at its root: its
   * issue areas. Any answer but GitHub's 404 is an error.
   */
  async hasContextMap(repo: string): Promise<boolean> {
    try {
      await this.gh(["api", `repos/${repo}/contents/CONTEXT-MAP.md`]);
      return true;
    } catch (err) {
      if (/HTTP 404/.test(String(err))) return false;
      throw err;
    }
  }

  /** The issues `issue` waits on, as GitHub's native issue dependencies. */
  private async blockedBy(repo: string, issue: number) {
    const all = await this.pages<{
      number: number;
      state: string;
      repository_url: string;
    }>(`repos/${repo}/issues/${issue}/dependencies/blocked_by`);
    return all.map((b) => ({
      repo: b.repository_url.replace(/^.*\/repos\//, ""),
      number: b.number,
      open: b.state === "open",
    }));
  }

  /** The open issues `issue` waits on, in any repo. */
  async openBlockers(repo: string, issue: number): Promise<IssueRef[]> {
    return (await this.blockedBy(repo, issue))
      .filter((b) => b.open)
      .map(({ repo, number }) => ({ repo, number }));
  }

  /**
   * Makes `issue` wait on each of `blockers` (issues of `repo`), as GitHub's
   * native issue dependencies; one it waits on already is left as it is.
   */
  async addBlockedBy(repo: string, issue: number, blockers: number[]) {
    const path = `repos/${repo}/issues/${issue}/dependencies/blocked_by`;
    const has = (await this.blockedBy(repo, issue))
      .filter((b) => sameRepo(b.repo, repo))
      .map((b) => b.number);
    for (const blocker of blockers.filter((b) => !has.includes(b))) {
      const { id } = JSON.parse(
        await this.gh(["api", `repos/${repo}/issues/${blocker}`]),
      ) as { id: number };
      await this.gh(["api", "-X", "POST", path, "-F", `issue_id=${id}`]);
    }
  }
}
