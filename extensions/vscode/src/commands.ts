import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { ClientInfo, cliVersion, compareVersions, getConfig, listDevices, readHistory } from './cli';
import { ClientItem, ClientsTreeProvider, EnvEntryItem, EnvFileItem } from './clientsTree';
import { HistoryItem, HistoryTreeProvider } from './historyTree';
import { newProgressFile, withBuildProgress } from './buildProgress';
import { readPubspecVersion, VERSION_PATTERN, writePubspecVersion } from './pubspecVersion';
import { buildCommandLine, runCliTask, runInTerminal } from './runner';

/** workspaceState key holding the version to put back if VS Code closes mid-build. */
export const PENDING_VERSION_KEY = 'udara.pendingVersionRestore';

interface PendingVersionRestore {
  root: string;
  original: string;
  override: string;
}

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
    reg('udara.buildMultiple', (node?: ClientItem) => buildMultiple(ctx, node)),
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

/** The oldest udara_cli with every option this extension passes. */
const MIN_CLI_VERSION = '1.4.0';

async function ensureCli(ctx: CommandContext): Promise<boolean> {
  const listing = await ctx.clients.ensureLoaded();
  const { cliPath } = getConfig();
  let tooOld = /--json/.test(listing.cliError ?? '');
  if (listing.source === 'cli') {
    const root = ctx.getRoot();
    const version = root ? await cliVersion(root) : undefined;
    if (!version || compareVersions(version, MIN_CLI_VERSION) >= 0) {
      return true;
    }
    tooOld = true;
  }
  const message = tooOld
    ? `udara_cli is too old for this extension (needs ${MIN_CLI_VERSION} or newer). Upgrade it.`
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

  const { flutterPath, flutterRunArgs, askForDevice, launchMode } = getConfig();
  // Only projects that still bundle .env need to tell the app which file to
  // load; generated config is compiled in.
  const listing = await ctx.clients.ensureLoaded();
  const envDefine = listing.appConfigMode === 'generated' ? [] : ['--dart-define=CLIENT_ENV=.env'];
  const sessionName = `Udara: ${client.name}${isTest ? ' (test)' : ''}`;

  if (launchMode === 'native' && isDartExtensionInstalled()) {
    // Hand the launch to the Dart/Flutter extension so the usual debug
    // toolbar, hot reload on save, breakpoints and DevTools all work. The
    // device comes from the Flutter device selector in the status bar.
    const folder =
      vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root)) ??
      vscode.workspace.workspaceFolders?.[0];
    const started = await vscode.debug.startDebugging(folder, {
      type: 'dart',
      request: 'launch',
      name: sessionName,
      cwd: root,
      program: path.join(root, 'lib', 'main.dart'),
      toolArgs: [...envDefine, ...flutterRunArgs],
    });
    if (!started) {
      vscode.window.showErrorMessage(
        `Could not start a Flutter session for "${client.name}". Check the Debug Console.`,
      );
    }
    return;
  }

  if (launchMode === 'native') {
    vscode.window.showInformationMessage(
      'Install the Flutter extension (Dart-Code) to get the standard hot reload controls. Using a terminal for now.',
    );
  }

  const device = askForDevice ? await pickDevice(root) : undefined;
  const runArgs = [
    'run',
    ...envDefine,
    ...(device ? ['-d', device] : []),
    ...flutterRunArgs,
  ];
  runInTerminal(`flutter run · ${sessionName.substring(7)}`, root, buildCommandLine(flutterPath, runArgs));
}

function isDartExtensionInstalled(): boolean {
  return (
    vscode.extensions.getExtension('Dart-Code.dart-code') !== undefined ||
    vscode.extensions.getExtension('Dart-Code.flutter') !== undefined
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
      `Project is now branded as "${client.name}". Run it with: flutter run${
        (await ctx.clients.ensureLoaded()).appConfigMode === 'generated' ? '' : ' --dart-define=CLIENT_ENV=.env'
      }`,
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
  const title = `Build "${client.name}"`;

  const platform = await vscode.window.showQuickPick(
    [
      { label: '$(device-mobile) Android', value: 'android' },
      { label: '$(device-mobile) iOS', value: 'ios' },
    ],
    { title, placeHolder: 'Platform' },
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
    const picked = await vscode.window.showQuickPick(types, { title, placeHolder: 'Build type' });
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
    { title, placeHolder: 'Environment' },
  );
  if (!env) {
    return;
  }

  const version = await askVersion(root, title, `App version for "${client.name}" (optional)`);
  if (version === undefined) {
    return; // Escape cancels the build.
  }

  const args = [
    'build',
    '--client',
    client.name,
    '--platform',
    platform.value,
    ...(type ? ['--type', type] : []),
    ...(env.isTest ? ['--test'] : []),
    ...(version ? ['--build-version', version] : []),
  ];
  const label = `build ${client.name} ${platform.value}${type ? ` ${type}` : ''}${version ? ` v${version}` : ''}`;
  const code = await runTrackedBuild(root, label, `Building ${client.name}`, args);
  ctx.history.refresh();
  ctx.clients.refresh();

  if (code === 0) {
    const latest = readHistory(root)[0];
    const artifact = latest?.artifact;
    const choice = await vscode.window.showInformationMessage(
      `Build for "${client.name}"${latest?.version ? ` v${latest.version}` : ''} succeeded.${
        artifact ? ` ${path.basename(artifact)}` : ''
      }`,
      ...(artifact ? ['Reveal Artifact'] : []),
    );
    if (choice && artifact) {
      await vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(artifact));
    }
  } else if (code !== CANCELLED) {
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

async function buildMultiple(ctx: CommandContext, node: ClientItem | undefined) {
  const root = await requireRoot(ctx);
  if (!root || !(await ensureCli(ctx))) {
    return;
  }
  const listing = await ctx.clients.ensureLoaded();
  if (listing.clients.length === 0) {
    vscode.window.showInformationMessage('No clients found. Create some first.');
    return;
  }

  const title = 'Build Multiple Clients';
  const clients = await vscode.window.showQuickPick(
    listing.clients.map((c) => ({
      label: c.name,
      description: [c.appName, c.bundleId].filter(Boolean).join(' · '),
      picked: c.name === node?.client.name,
    })),
    { title, placeHolder: 'Select the clients to build (Space to toggle)', canPickMany: true },
  );
  if (!clients || clients.length === 0) {
    return;
  }

  const platforms = await vscode.window.showQuickPick(
    [
      { label: 'Android', value: 'android', picked: true },
      { label: 'iOS', value: 'ios', picked: false },
    ],
    { title, placeHolder: 'Platforms', canPickMany: true },
  );
  if (!platforms || platforms.length === 0) {
    return;
  }

  let types: string[] = [];
  if (platforms.some((p) => p.value === 'android')) {
    const { defaultBuildType } = getConfig();
    const picked = await vscode.window.showQuickPick(
      [
        { label: 'AAB (app bundle)', value: 'aab', picked: defaultBuildType === 'aab' },
        { label: 'APK', value: 'apk', picked: defaultBuildType === 'apk' },
      ],
      { title, placeHolder: 'Android build types', canPickMany: true },
    );
    if (!picked || picked.length === 0) {
      return;
    }
    types = picked.map((t) => t.value);
  }

  const versions = await askBatchVersions(root, title, clients.map((c) => c.label));
  if (versions === undefined) {
    return;
  }

  // One job per client and platform; these are what run in parallel.
  const jobCount = clients.length * platforms.length;
  let parallel = '1';
  if (jobCount > 1) {
    const choice = await vscode.window.showQuickPick(
      [
        { label: 'Auto', description: 'Recommended: 1 to 4 at a time, based on RAM and CPU', value: 'auto' },
        { label: '1', description: 'One at a time', value: '1' },
        { label: '2', description: 'Two at a time', value: '2' },
        { label: '3', description: 'Three at a time', value: '3' },
        { label: '4', description: 'Four at a time', value: '4' },
      ].filter((o) => o.value === 'auto' || Number(o.value) <= jobCount),
      {
        title,
        placeHolder: `How many of the ${jobCount} jobs (client × platform) should build at the same time?`,
      },
    );
    if (!choice) {
      return;
    }
    parallel = choice.value;
  }

  const options = await vscode.window.showQuickPick(
    [
      { label: 'Use test environment (.env_test)', value: '--test', picked: false },
      { label: 'Stop at the first failed build', value: '--fail-fast', picked: false },
    ],
    { title, placeHolder: 'Options (optional, press Enter to continue)', canPickMany: true },
  );
  if (!options) {
    return;
  }

  const args = [
    'build',
    '--client',
    clients.map((c) => c.label).join(','),
    '--platform',
    platforms.map((p) => p.value).join(','),
    ...(types.length ? ['--type', types.join(',')] : []),
    ...(versions.length ? ['--build-version', versions.join(',')] : []),
    '--parallel',
    parallel,
    ...options.map((o) => o.value),
  ];
  const buildCount =
    clients.length * (types.length + (platforms.some((p) => p.value === 'ios') ? 1 : 0));
  const label = `batch build (${buildCount} builds)`;

  // History timestamps are local ISO strings without a zone; Date parses them as local.
  const startedAt = Date.now() - 1000;
  const code = await runTrackedBuild(root, label, `Building ${buildCount} builds`, args);
  ctx.history.refresh();
  ctx.clients.refresh();
  if (code === CANCELLED) {
    vscode.window.showWarningMessage('Batch build cancelled. Finished artifacts are in build/udara/.');
    return;
  }

  const entries = readHistory(root).filter((e) => Date.parse(e.timestamp) >= startedAt);
  const succeeded = entries.filter((e) => e.success).length;
  const failed = entries.length - succeeded;
  const outputDir = path.join(root, 'build', 'udara');
  const actions = [
    ...(fs.existsSync(outputDir) ? ['Open Artifacts Folder'] : []),
    ...(failed ? ['Open Logs'] : []),
    'Show History',
  ];
  const message = `Batch build finished: ${succeeded} succeeded${failed ? `, ${failed} failed` : ''}.`;
  const choice = failed
    ? await vscode.window.showWarningMessage(message, ...actions)
    : await vscode.window.showInformationMessage(message, ...actions);
  if (choice === 'Open Artifacts Folder') {
    await vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(outputDir));
  } else if (choice === 'Open Logs') {
    await vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(path.join(outputDir, 'logs')));
  } else if (choice === 'Show History') {
    await vscode.commands.executeCommand('udara.history.focus');
  }
}

/** Exit code the CLI uses when a build is cancelled. */
const CANCELLED = 130;

/**
 * Runs a build task with a progress notification (percent, ETA, running
 * jobs) fed by the CLI's --progress-file. Cancelling the notification stops
 * the task, which stops every worker the CLI started.
 */
async function runTrackedBuild(
  root: string,
  label: string,
  title: string,
  args: string[],
): Promise<number | undefined> {
  const progressFile = newProgressFile();
  return withBuildProgress(title, progressFile, (onCancel) =>
    runCliTask(label, [...args, '--progress-file', progressFile], root, (execution) =>
      onCancel(() => execution.terminate()),
    ),
  );
}

/**
 * Asks for an optional version. Returns undefined when cancelled, '' to keep
 * the pubspec version, or the version to pass to --build-version.
 */
async function askVersion(root: string, title: string, prompt: string): Promise<string | undefined> {
  const currentVersion = readPubspecVersion(root);
  const input = await vscode.window.showInputBox({
    title,
    prompt: `${prompt}. Leave empty to keep the pubspec version. Without +build number, the current one is kept.`,
    placeHolder: currentVersion ? `Leave empty for ${currentVersion}. e.g. 1.4.0 or 1.4.0+12` : 'e.g. 1.4.0 or 1.4.0+12',
    validateInput: (v) =>
      !v.trim() || VERSION_PATTERN.test(v.trim()) ? undefined : 'Use x.y.z or x.y.z+build, e.g. 1.4.0 or 1.4.0+12',
  });
  return input === undefined ? undefined : input.trim();
}

/**
 * Asks how to version a batch. Returns undefined when cancelled, otherwise
 * the --build-version values (empty list keeps the pubspec version).
 */
async function askBatchVersions(
  root: string,
  title: string,
  clients: string[],
): Promise<string[] | undefined> {
  const current = readPubspecVersion(root);
  const mode = await vscode.window.showQuickPick(
    [
      { label: 'Keep the pubspec version', description: current ? `v${current} for every client` : '', value: 'keep' },
      { label: 'Same version for all clients…', value: 'same' },
      { label: 'Different version per client…', value: 'each' },
    ],
    { title, placeHolder: 'App version' },
  );
  if (!mode) {
    return undefined;
  }
  if (mode.value === 'keep') {
    return [];
  }
  if (mode.value === 'same') {
    const v = await askVersion(root, title, 'App version for every client');
    return v === undefined ? undefined : v ? [v] : [];
  }
  const values: string[] = [];
  for (const client of clients) {
    const v = await askVersion(root, `${title}: ${client}`, `App version for "${client}"`);
    if (v === undefined) {
      return undefined;
    }
    if (v) {
      values.push(`${client}=${v}`);
    }
  }
  return values;
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

/** Puts back a version overridden by an interrupted build. Safe to call anytime. */
export function restorePendingVersion(context: vscode.ExtensionContext): void {
  const pending = context.workspaceState.get<PendingVersionRestore>(PENDING_VERSION_KEY);
  if (!pending) {
    return;
  }
  try {
    // Only restore if nobody changed the version since we overrode it.
    if (readPubspecVersion(pending.root) === pending.override) {
      writePubspecVersion(pending.root, pending.original);
    }
  } catch (e) {
    vscode.window.showWarningMessage(
      `Udara could not restore pubspec version ${pending.original}: ${e instanceof Error ? e.message : e}`,
    );
  }
  void context.workspaceState.update(PENDING_VERSION_KEY, undefined);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
