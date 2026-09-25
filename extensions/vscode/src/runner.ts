import * as vscode from 'vscode';
import { getConfig } from './cli';

/**
 * Runs `udara_cli <args>` as a VS Code task (output in the terminal panel)
 * and resolves with the process exit code once it finishes.
 */
export async function runCliTask(
  label: string,
  args: string[],
  cwd: string,
): Promise<number | undefined> {
  const { cliPath } = getConfig();
  const execution = new vscode.ShellExecution(cliPath, args, { cwd });
  const task = new vscode.Task(
    { type: 'udara', label },
    vscode.TaskScope.Workspace,
    label,
    'udara',
    execution,
  );
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always,
    panel: vscode.TaskPanelKind.Dedicated,
    clear: true,
    showReuseMessage: false,
  };

  const running = await vscode.tasks.executeTask(task);
  return new Promise((resolve) => {
    const disposable = vscode.tasks.onDidEndTaskProcess((e) => {
      if (e.execution === running) {
        disposable.dispose();
        resolve(e.exitCode);
      }
    });
  });
}

/** Opens a fresh interactive terminal and runs a command line in it. */
export function runInTerminal(name: string, cwd: string, commandLine: string): vscode.Terminal {
  const terminal = vscode.window.createTerminal({ name, cwd });
  terminal.show();
  terminal.sendText(commandLine, true);
  return terminal;
}

/** Quotes a single argument for the user's default shell. */
export function quoteArg(arg: string): string {
  if (/^[A-Za-z0-9_./=:@+-]+$/.test(arg)) {
    return arg;
  }
  if (process.platform === 'win32') {
    return `"${arg.replace(/"/g, '\\"')}"`;
  }
  return `'${arg.replace(/'/g, `'\\''`)}'`;
}

export function buildCommandLine(command: string, args: string[]): string {
  return [command, ...args].map(quoteArg).join(' ');
}
