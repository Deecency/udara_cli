import * as cp from 'child_process';

/** A branch `build --ref` can build instead of the working copy. */
export interface BranchChoice {
  /** Passed to `--ref`. */
  ref: string;
  kind: 'local' | 'remote';
}

/**
 * The branches to offer, in the order given (most recently committed
 * first): local branches except the current one, then remote branches
 * without a local branch of the same name. The CLI builds a local branch as
 * it is on the remote when it hasn't been pulled, so `origin/stable` next
 * to `stable` would only be a duplicate.
 */
export function branchChoices(current: string | undefined, local: string[], remote: string[]): BranchChoice[] {
  const localNames = new Set(local);
  const choices: BranchChoice[] = local.filter((b) => b !== current).map((ref) => ({ ref, kind: 'local' }));
  for (const ref of remote) {
    const name = ref.slice(ref.indexOf('/') + 1);
    if (ref.endsWith('/HEAD') || !ref.includes('/') || localNames.has(name) || name === current) {
      continue;
    }
    choices.push({ ref, kind: 'remote' });
  }
  return choices;
}

function git(args: string[], cwd: string): Promise<string> {
  return new Promise((resolve, reject) => {
    cp.execFile('git', args, { cwd, timeout: 15_000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) =>
      error ? reject(error) : resolve(stdout.toString()),
    );
  });
}

/** The checked-out branch, or undefined outside git or on a detached HEAD. */
export async function currentBranch(root: string): Promise<string | undefined> {
  try {
    const name = (await git(['rev-parse', '--abbrev-ref', 'HEAD'], root)).trim();
    return name && name !== 'HEAD' ? name : undefined;
  } catch {
    return undefined;
  }
}

/** The current branch and the others; no choices outside git. */
export async function listBranches(root: string): Promise<{ current?: string; choices: BranchChoice[] }> {
  try {
    const refs = (namespace: string) =>
      git(['for-each-ref', '--sort=-committerdate', '--format=%(refname:short)', namespace], root).then((out) =>
        out
          .split('\n')
          .map((l) => l.trim())
          .filter(Boolean),
      );
    const [current, local, remote] = await Promise.all([
      currentBranch(root),
      refs('refs/heads'),
      refs('refs/remotes'),
    ]);
    return { current, choices: branchChoices(current, local, remote) };
  } catch {
    return { choices: [] };
  }
}

/** The `version:` in pubspec.yaml on [ref], or undefined. */
export async function pubspecVersionAt(root: string, ref: string): Promise<string | undefined> {
  try {
    const pubspec = await git(['show', `${ref}:./pubspec.yaml`], root);
    return /^version:[ \t]*["']?([^"'\s#]+)/m.exec(pubspec)?.[1];
  } catch {
    return undefined;
  }
}
