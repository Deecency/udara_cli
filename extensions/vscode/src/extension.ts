import * as path from 'path';
import * as vscode from 'vscode';
import { findProjectRoot, HISTORY_FILE } from './cli';
import { ClientsTreeProvider } from './clientsTree';
import { registerCommands, restorePendingVersion } from './commands';
import { HistoryTreeProvider } from './historyTree';

export function activate(context: vscode.ExtensionContext): void {
  // A build interrupted by closing VS Code may have left an overridden version.
  restorePendingVersion(context);

  let root = findProjectRoot();
  const getRoot = () => root;

  const clients = new ClientsTreeProvider(getRoot);
  const history = new HistoryTreeProvider(getRoot);

  const clientsView = vscode.window.createTreeView('udara.clients', {
    treeDataProvider: clients,
    showCollapseAll: true,
  });
  const historyView = vscode.window.createTreeView('udara.history', {
    treeDataProvider: history,
  });

  const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusBar.command = 'udara.run';
  const active = context.workspaceState.get<string>('udara.activeClient');
  if (active) {
    statusBar.text = `$(paintcan) Udara: ${active}`;
    statusBar.tooltip = `Project is whitelabeled as "${active}". Click to run it.`;
    statusBar.show();
  }

  context.subscriptions.push(
    clientsView,
    historyView,
    statusBar,
    ...registerCommands({ context, clients, history, getRoot, statusBar }),
  );

  // Keep the views in sync with the files on disk.
  const watchers: vscode.FileSystemWatcher[] = [];
  const armWatchers = () => {
    watchers.forEach((w) => w.dispose());
    watchers.length = 0;
    if (!root) {
      return;
    }
    const clientsWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(root, 'clients/**'),
    );
    const historyWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(root, HISTORY_FILE),
    );
    const debounced = debounce(() => clients.refresh(), 300);
    clientsWatcher.onDidChange(debounced);
    clientsWatcher.onDidCreate(debounced);
    clientsWatcher.onDidDelete(debounced);
    const refreshHistory = debounce(() => history.refresh(), 300);
    historyWatcher.onDidChange(refreshHistory);
    historyWatcher.onDidCreate(refreshHistory);
    historyWatcher.onDidDelete(refreshHistory);
    watchers.push(clientsWatcher, historyWatcher);
  };
  armWatchers();

  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(() => {
      root = findProjectRoot();
      armWatchers();
      clients.refresh();
      history.refresh();
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('udara')) {
        clients.refresh();
      }
    }),
    { dispose: () => watchers.forEach((w) => w.dispose()) },
  );

  if (root) {
    clientsView.title = `Clients · ${path.basename(root)}`;
  }
}

export function deactivate(): void {
  // Nothing to clean up: terminals and tasks are owned by VS Code.
}

function debounce(fn: () => void, ms: number): () => void {
  let handle: NodeJS.Timeout | undefined;
  return () => {
    if (handle) {
      clearTimeout(handle);
    }
    handle = setTimeout(fn, ms);
  };
}
