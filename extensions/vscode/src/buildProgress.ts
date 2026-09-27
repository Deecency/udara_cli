import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

/** Shape of the file written by `udara_cli build --progress-file`. */
interface ProgressSnapshot {
  percent: number;
  etaSeconds: number;
  elapsedSeconds: number;
  parallel: number;
  jobsTotal: number;
  jobsDone: number;
  jobsFailed: number;
  finished: boolean;
  jobs: {
    client: string;
    platform: string;
    types: string;
    state: 'queued' | 'running' | 'succeeded' | 'failed' | 'skipped';
    step?: string;
    percent: number;
    remainingSeconds: number;
  }[];
}

export function newProgressFile(): string {
  return path.join(os.tmpdir(), `udara-progress-${process.pid}-${Date.now()}.json`);
}

export function formatSeconds(total: number): string {
  if (total >= 3600) {
    return `${Math.floor(total / 3600)}h ${String(Math.floor((total % 3600) / 60)).padStart(2, '0')}m`;
  }
  if (total >= 60) {
    return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
  }
  return `${total}s`;
}

function read(file: string): ProgressSnapshot | undefined {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as ProgressSnapshot;
  } catch {
    return undefined; // not written yet, or mid-rename
  }
}

function describe(s: ProgressSnapshot): string {
  const pct = s.finished ? 100 : Math.min(99, Math.floor(s.percent));
  const eta = s.finished ? 'finishing' : `ETA ~${formatSeconds(s.etaSeconds)}`;
  const running = s.jobs
    .filter((j) => j.state === 'running')
    .map((j) => `${j.client} ${j.platform}: ${j.step ?? 'starting'}`);
  const counts =
    s.jobsTotal > 1
      ? ` · ${s.jobsDone}/${s.jobsTotal} jobs${s.jobsFailed ? `, ${s.jobsFailed} failed` : ''}`
      : '';
  return `${pct}% · ${eta}${counts}${running.length ? ` · ${running.slice(0, 2).join(' · ')}` : ''}`;
}

/**
 * Shows a build's progress from its progress file as a cancellable
 * notification with percent and ETA, plus a status bar item. [start] runs
 * the build and gets a callback to register how to cancel it.
 */
export async function withBuildProgress<T>(
  title: string,
  progressFile: string,
  start: (onCancel: (cancel: () => void) => void) => Promise<T>,
): Promise<T> {
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 49);
  status.text = `$(sync~spin) ${title}`;
  status.tooltip = 'Udara build in progress';
  status.command = 'workbench.action.terminal.focus';
  status.show();

  try {
    return await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title, cancellable: true },
      async (progress, token) => {
        let reported = 0;
        let cancel: (() => void) | undefined;
        token.onCancellationRequested(() => cancel?.());

        const timer = setInterval(() => {
          const snapshot = read(progressFile);
          if (!snapshot) {
            return;
          }
          const pct = snapshot.finished ? 100 : Math.min(99, snapshot.percent);
          const message = describe(snapshot);
          progress.report({ increment: Math.max(0, pct - reported), message });
          reported = Math.max(reported, pct);
          status.text = `$(sync~spin) Udara ${Math.floor(pct)}%${
            snapshot.finished ? '' : ` · ~${formatSeconds(snapshot.etaSeconds)}`
          }`;
          status.tooltip = message;
        }, 1000);

        try {
          return await start((c) => (cancel = c));
        } finally {
          clearInterval(timer);
        }
      },
    );
  } finally {
    status.dispose();
    fs.rm(progressFile, { force: true }, () => undefined);
    fs.rm(`${progressFile}.tmp`, { force: true }, () => undefined);
  }
}
