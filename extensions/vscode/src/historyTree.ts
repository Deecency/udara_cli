import * as path from 'path';
import * as vscode from 'vscode';
import { HistoryEntry, readHistory } from './cli';

export class HistoryItem extends vscode.TreeItem {
  constructor(public readonly entry: HistoryEntry, root: string) {
    super(
      `${entry.client} · ${entry.platform}/${entry.type} · v${entry.version ?? '?'}`,
      vscode.TreeItemCollapsibleState.None,
    );
    const when = formatTimestamp(entry.timestamp);
    this.description = `${when} · ${entry.durationSeconds}s`;
    this.iconPath = entry.success
      ? new vscode.ThemeIcon('pass', new vscode.ThemeColor('testing.iconPassed'))
      : new vscode.ThemeIcon('error', new vscode.ThemeColor('testing.iconFailed'));
    this.contextValue = entry.success
      ? entry.artifact
        ? 'historyArtifact'
        : 'historySuccess'
      : 'historyFailed';

    const lines = [
      `**${entry.success ? 'Succeeded' : 'Failed'}** at ${when}`,
      `Client: ${entry.client}`,
      `Platform: ${entry.platform} (${entry.type})`,
      `Duration: ${entry.durationSeconds}s`,
    ];
    if (entry.artifact) {
      lines.push(`Artifact: ${path.relative(root, entry.artifact)}`);
    }
    if (entry.error) {
      lines.push('', `\`\`\`\n${entry.error}\n\`\`\``);
    }
    this.tooltip = new vscode.MarkdownString(lines.join('  \n'));
  }
}

export class HistoryTreeProvider implements vscode.TreeDataProvider<HistoryItem> {
  private readonly emitter = new vscode.EventEmitter<HistoryItem | undefined>();
  readonly onDidChangeTreeData = this.emitter.event;

  constructor(private readonly getRoot: () => string | undefined) {}

  refresh(): void {
    this.emitter.fire(undefined);
  }

  getTreeItem(element: HistoryItem): vscode.TreeItem {
    return element;
  }

  async getChildren(): Promise<HistoryItem[]> {
    const root = this.getRoot();
    const entries = root ? readHistory(root) : [];
    await vscode.commands.executeCommand('setContext', 'udara.hasHistory', entries.length > 0);
    return root ? entries.map((e) => new HistoryItem(e, root)) : [];
  }
}

function formatTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) {
    return 'unknown time';
  }
  const two = (n: number) => n.toString().padStart(2, '0');
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
}
