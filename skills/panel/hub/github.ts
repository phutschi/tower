/** The only module of the hub that runs gh. */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface GhIssue {
  number: number;
  title: string;
  labels: { name: string }[];
}

export class GitHub {
  constructor(private readonly bin = "gh") {}

  private async gh(args: string[]): Promise<string> {
    const { stdout } = await run(this.bin, args, {
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
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
}
