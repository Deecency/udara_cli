import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { ClientInfo, getConfig, listDevices, readHistory } from './cli';
import { ClientItem, ClientsTreeProvider, EnvEntryItem, EnvFileItem } from './clientsTree';
import { HistoryItem, HistoryTreeProvider } from './historyTree';
import { buildCommandLine, runCliTask, runInTerminal } from './runner';

export interface CommandContext {
  context: vscode.ExtensionContext;
  clients: ClientsTreeProvider;
  history: HistoryTreeProvider;
  getRoot: () => string | undefined;
  statusBar: vscode.StatusBarItem;
}

export function registerCommands(ctx: CommandContext): vscode.Disposable[] {
  const reg = (id: string, handler: (...args: any[]) => unknown) =>
    vscode.commands.registerCommand(id, handler);

  return [
    reg('udara.refresh', () => {
      ctx.clients.refresh();
      ctx.history.refresh();
    }),
    reg('udara.run', (node?: ClientItem) => runClient(ctx, node, false)),
    reg('udara.runTest', (node?: ClientItem) => runClient(ctx, node, true)),
    reg('udara.build', (node?: ClientItem) => buildClient(ctx, node)),
    reg('udara.whitelabel', (node?: ClientItem) => whitelabelClient(ctx, node)),
    reg('udara.doctor', (node?: ClientItem) => doctor(ctx, node)),
    reg('udara.clean', () => clean(ctx)),
    reg('udara.diff', () => diffClients(ctx)),
    reg('udara.setupClients', () => setupClients(ctx)),
    reg('udara.openEnv', (node: EnvEntryItem | EnvFileItem) => openEnv(node)),
    reg('udara.copyValue', (node: EnvEntryItem) => copyValue(node)),
    reg('udara.revealArtifact', (node: HistoryItem) => revealArtifact(node)),
    reg('udara.copyError', (node: HistoryItem) => copyError(node)),
    reg('udara.clearHistory', () => clearHistory(ctx)),
    reg('udara.installCli', () => installCli(ctx)),
  ];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function requireRoot(ctx: CommandContext): Promise<string | undefined> {
  const root = ctx.getRoot();
  if (!root) {
    vscode.window.showErrorMessage(
      'Udara: open a Flutter project (a folder with pubspec.yaml) first.',
    );
  }
  return root;
}

async function ensureCli(ctx: CommandContext): Promise<boolean> {
  const listing = await ctx.clients.ensureLoaded();
  if (listing.source === 'cli') {
    return true;
  }
  const { cliPath } = getConfig();
  const tooOld = /--json/.test(listing.cliError ?? '');
  const message = tooOld
    ? 'udara_cli is too old for this extension (needs 1.2.0+ with "list-clients --json"). Upgrade it.'
    : `udara_cli could not be run as "${cliPath}". Install it or point "udara.cliPath" at it.`;
  const choice = await vscode.window.showWarningMessage(
    message,
    tooOld ? 'Upgrade' : 'Install',
    'Open Settings',
    'Details',
  );
  if (choice === 'Install' || choice === 'Upgrade') {
    await installCli(ctx);
  } else if (choice === 'Open Settings') {
    await vscode.commands.executeCommand('workbench.action.openSettings', 'udara.cliPath');
  } else if (choice === 'Details') {
    vscode.window.showErrorMessage(listing.cliError ?? 'unknown error');
  }
  return false;
}

async function pickClient(
  ctx: CommandContext,
  node: ClientItem | undefined,
  placeHolder: string,
): Promise<ClientInfo | undefined> {
  if (node?.client) {
    return node.client;
  }
  const listing = await ctx.clients.ensureLoaded();
  if (listing.clients.length === 0) {
    const choice = await vscode.window.showInformationMessage(
      'No clients found. Create some first.',
      'Set Up Clients',
    );
    if (choice) {
      await setupClients(ctx);
    }
    return undefined;
  }
  const picked = await vscode.window.showQuickPick(
    listing.clients.map((c) => ({
      label: c.name,
      description: [c.appName, c.bundleId].filter(Boolean).join(' · '),
      client: c,
    })),
    { placeHolder },
  );
  return picked?.client;
}

async function pickDevice(root: string): Promise<string | undefined> {
  const devices = await listDevices(root);
  if (devices.length === 0) {
    return undefined;
  }
  const items = [
    { label: '$(zap) Default', description: 'Let flutter choose', id: undefined as string | undefined },
    ...devices.map((d) => ({
      label: `$(${d.emulator ? 'vm' : 'device-mobile'}) ${d.name}`,
      description: `${d.id}${d.targetPlatform ? ` · ${d.targetPlatform}` : ''}`,
      id: d.id,
    })),
  ];
  const picked = await vscode.window.showQuickPick(items, {
    placeHolder: 'Run on which device?',
  });
  return picked?.id;
}

function setActiveClient(ctx: CommandContext, client: string | undefined): void {
  ctx.context.workspaceState.update('udara.activeClient', client);
  if (client) {
    ctx.statusBar.text = `$(paintcan) Udara: ${client}`;
    ctx.statusBar.tooltip = `Project is whitelabeled as "${client}". Click to run it.`;
    ctx.statusBar.show();
  } else {
    ctx.statusBar.hide();
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function runClient(ctx: CommandContext, node: ClientItem | undefined, isTest: boolean) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const client = await pickClient(ctx, node, 'Run which client?');
  if (!client) {
    return;
  }

  const args = ['whitelabel', '--client', client.name, '--keep', ...(isTest ? ['--test'] : [])];
  const code = await runCliTask(`whitelabel ${client.name}`, args, root);
  ctx.clients.refresh();
  if (code !== 0) {
    const choice = await vscode.window.showErrorMessage(
      `Whitelabel for "${client.name}" failed (exit code ${code ?? '?'}).`,
      'Run Doctor',
    );
    if (choice) {
      await doctor(ctx, node);
    }
    return;
  }
  setActiveClient(ctx, client.name);

  const { flutterPath, flutterRunArgs, askForDevice } = getConfig();
  const device = askForDevice ? await pickDevice(root) : undefined;
  const runArgs = [
    'run',
    '--dart-define=CLIENT_ENV=.env',
    ...(device ? ['-d', device] : []),
    ...flutterRunArgs,
  ];
  runInTerminal(
    `flutter run · ${client.name}${isTest ? ' (test)' : ''}`,
    root,
    buildCommandLine(flutterPath, runArgs),
  );
}

async function whitelabelClient(ctx: CommandContext, node: ClientItem | undefined) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const client = await pickClient(ctx, node, 'Whitelabel the project as which client?');
  if (!client) {
    return;
  }
  const env = await vscode.window.showQuickPick(
    [
      { label: 'Production (.env)', isTest: false },
      { label: 'Test (.env_test)', isTest: true },
    ],
    { placeHolder: 'Which environment?' },
  );
  if (!env) {
    return;
  }
  const args = ['whitelabel', '--client', client.name, '--keep', ...(env.isTest ? ['--test'] : [])];
  const code = await runCliTask(`whitelabel ${client.name}`, args, root);
  ctx.clients.refresh();
  if (code === 0) {
    setActiveClient(ctx, client.name);
    vscode.window.showInformationMessage(
      `Project is now branded as "${client.name}". Run it with: flutter run --dart-define=CLIENT_ENV=.env`,
    );
  } else {
    vscode.window.showErrorMessage(`Whitelabel failed (exit code ${code ?? '?'}). See the terminal.`);
  }
}

async function buildClient(ctx: CommandContext, node: ClientItem | undefined) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const client = await pickClient(ctx, node, 'Build which client?');
  if (!client) {
    return;
  }

  const platform = await vscode.window.showQuickPick(
    [
      { label: '$(device-mobile) Android', value: 'android' },
      { label: '$(device-mobile) iOS', value: 'ios' },
    ],
    { placeHolder: 'Platform' },
  );
  if (!platform) {
    return;
  }

  let type: string | undefined;
  if (platform.value === 'android') {
    const { defaultBuildType } = getConfig();
    const types = [
      { label: 'AAB (app bundle)', value: 'aab' },
      { label: 'APK', value: 'apk' },
    ].sort((a) => (a.value === defaultBuildType ? -1 : 1));
    const picked = await vscode.window.showQuickPick(types, { placeHolder: 'Build type' });
    if (!picked) {
      return;
    }
    type = picked.value;
  }

  const env = await vscode.window.showQuickPick(
    [
      { label: 'Production (.env)', isTest: false },
      { label: 'Test (.env_test)', isTest: true },
    ],
    { placeHolder: 'Environment' },
  );
  if (!env) {
    return;
  }

  const args = [
    'build',
    '--client',
    client.name,
    '--platform',
    platform.value,
    ...(type ? ['--type', type] : []),
    ...(env.isTest ? ['--test'] : []),
  ];
  const label = `build ${client.name} ${platform.value}${type ? ` ${type}` : ''}`;
  const code = await runCliTask(label, args, root);
  ctx.history.refresh();
  ctx.clients.refresh();

  if (code === 0) {
    const latest = readHistory(root)[0];
    const artifact = latest?.artifact;
    const choice = await vscode.window.showInformationMessage(
      `Build for "${client.name}" succeeded.${artifact ? ` ${path.basename(artifact)}` : ''}`,
      ...(artifact ? ['Reveal Artifact'] : []),
    );
    if (choice && artifact) {
      await vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(artifact));
    }
  } else {
    const choice = await vscode.window.showErrorMessage(
      `Build for "${client.name}" failed (exit code ${code ?? '?'}).`,
      'Run Doctor',
      'Show History',
    );
    if (choice === 'Run Doctor') {
      await doctor(ctx, node);
    } else if (choice === 'Show History') {
      await vscode.commands.executeCommand('udara.history.focus');
    }
  }
}

async function doctor(ctx: CommandContext, node: ClientItem | undefined) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const args = ['doctor', ...(node?.client ? ['--client', node.client.name] : [])];
  const code = await runCliTask(node?.client ? `doctor ${node.client.name}` : 'doctor', args, root);
  if (code === 0) {
    vscode.window.showInformationMessage('Udara doctor: no blocking issues.');
  } else {
    vscode.window.showWarningMessage('Udara doctor found problems. See the terminal.');
  }
}

async function clean(ctx: CommandContext) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const code = await runCliTask('clean', ['clean'], root);
  ctx.clients.refresh();
  if (code === 0) {
    setActiveClient(ctx, undefined);
    vscode.window.showInformationMessage('Udara: project restored and cleaned.');
  }
}

async function diffClients(ctx: CommandContext) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const a = await pickClient(ctx, undefined, 'First client');
  if (!a) {
    return;
  }
  const b = await pickClient(ctx, undefined, `Compare "${a.name}" with…`);
  if (!b) {
    return;
  }
  const mode = await vscode.window.showQuickPick(
    [
      { label: 'Only keys that differ (.env)', args: [] as string[] },
      { label: 'All keys (.env)', args: ['--all'] },
      { label: 'Only keys that differ (.env_test)', args: ['--test'] },
      { label: 'All keys (.env_test)', args: ['--test', '--all'] },
    ],
    { placeHolder: 'Diff mode' },
  );
  if (!mode) {
    return;
  }
  await runCliTask(
    `diff ${a.name} ${b.name}`,
    ['diff', '--client-a', a.name, '--client-b', b.name, ...mode.args],
    root,
  );
}

async function setupClients(ctx: CommandContext) {
  const root = await requireRoot(ctx);
  if (!root) {
    return;
  }
  const input = await vscode.window.showInputBox({
    prompt: 'Client names to create (comma-separated). A "default" client is always added.',
    placeHolder: 'acme,beta',
    validateInput: (v) =>
      /^[A-Za-z0-9_-]+(\s*,\s*[A-Za-z0-9_-]+)*$/.test(v.trim())
        ? undefined
        : 'Use letters, digits, "_" and "-" separated by commas.',
  });
  if (!input) {
    return;
  }
  const names = input
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .join(',');
  const code = await runCliTask('setup clients', ['setup', '--clients', names], root);
  ctx.clients.refresh();
  if (code === 0) {
    vscode.window.showInformationMessage(
      `Created clients: ${names}. Replace the placeholder logos and edit each .env.`,
    );
  }
}

async function openEnv(node: EnvEntryItem | EnvFileItem) {
  const filePath = node.filePath;
  const doc = await vscode.workspace.openTextDocument(filePath);
  const editor = await vscode.window.showTextDocument(doc, { preview: true });
  if (node instanceof EnvEntryItem) {
    const pattern = new RegExp(`^\\s*(export\\s+)?${escapeRegExp(node.key)}\\s*=`);
    for (let line = 0; line < doc.lineCount; line++) {
      if (pattern.test(doc.lineAt(line).text)) {
        const range = doc.lineAt(line).range;
        editor.selection = new vscode.Selection(range.start, range.end);
        editor.revealRange(range, vscode.TextEditorRevealType.InCenter);
        break;
      }
    }
  }
}

async function copyValue(node: EnvEntryItem) {
  await vscode.env.clipboard.writeText(node.value);
  vscode.window.setStatusBarMessage(`Copied value of ${node.key}`, 2000);
}

async function revealArtifact(node: HistoryItem) {
  const artifact = node.entry.artifact;
  if (!artifact) {
    return;
  }
  if (!fs.existsSync(artifact)) {
    vscode.window.showWarningMessage(`Artifact no longer exists: ${artifact}`);
    return;
  }
  await vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(artifact));
}

async function copyError(node: HistoryItem) {
  await vscode.env.clipboard.writeText(node.entry.error ?? '');
  vscode.window.setStatusBarMessage('Copied build error', 2000);
}

async function clearHistory(ctx: CommandContext) {
  const root = await requireRoot(ctx);
  if (!root) {
    return;
  }
  const confirm = await vscode.window.showWarningMessage(
    'Clear the recorded build history for this project?',
    { modal: true },
    'Clear',
  );
  if (confirm !== 'Clear') {
    return;
  }
  if (await ensureCli(ctx)) {
    await runCliTask('history clear', ['history', '--clear'], root);
  } else {
    const file = path.join(root, '.udara_build_history.json');
    if (fs.existsSync(file)) {
      fs.unlinkSync(file);
    }
  }
  ctx.history.refresh();
}

async function installCli(ctx: CommandContext) {
  const root = ctx.getRoot() ?? process.cwd();
  runInTerminal('install udara_cli', root, 'dart pub global activate udara_cli');
  vscode.window.showInformationMessage(
    'Installing udara_cli. Make sure ~/.pub-cache/bin is on your PATH, then click Refresh.',
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
