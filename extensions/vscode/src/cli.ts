import * as cp from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';

/** One client as reported by `udara_cli list-clients --json`. */
export interface ClientInfo {
  name: string;
  path: string;
  isDefault: boolean;
  appName?: string | null;
  bundleId?: string | null;
  hasFonts: boolean;
  envFiles: { env?: string; envTest?: string };
  env: Record<string, string>;
  envTest: Record<string, string>;
}

export interface HistoryEntry {
  timestamp: string;
  client: string;
  platform: string;
  type: string;
  version?: string | null;
  success: boolean;
  durationSeconds: number;
  error?: string;
  artifact?: string;
}

export interface UdaraConfig {
  cliPath: string;
  flutterPath: string;
  flutterRunArgs: string[];
  defaultBuildType: 'aab' | 'apk';
  maskSecrets: boolean;
  askForDevice: boolean;
  launchMode: 'native' | 'terminal';
}

export const HISTORY_FILE = '.udara_build_history.json';

export function getConfig(): UdaraConfig {
  const c = vscode.workspace.getConfiguration('udara');
  return {
    cliPath: c.get<string>('cliPath', 'udara_cli'),
    flutterPath: c.get<string>('flutterPath', 'flutter'),
    flutterRunArgs: c.get<string[]>('flutterRunArgs', []),
    defaultBuildType: c.get<'aab' | 'apk'>('defaultBuildType', 'aab'),
    maskSecrets: c.get<boolean>('maskSecrets', true),
    askForDevice: c.get<boolean>('askForDevice', true),
    launchMode: c.get<'native' | 'terminal'>('launchMode', 'native'),
  };
}

/**
 * The Flutter project the extension operates on: the first workspace folder
 * that has a `clients/` directory, else the first with a `pubspec.yaml`.
 */
export function findProjectRoot(): string | undefined {
  const folders = vscode.workspace.workspaceFolders ?? [];
  const withClients = folders.find((f) =>
    fs.existsSync(path.join(f.uri.fsPath, 'clients')),
  );
  if (withClients) {
    return withClients.uri.fsPath;
  }
  const withPubspec = folders.find((f) =>
    fs.existsSync(path.join(f.uri.fsPath, 'pubspec.yaml')),
  );
  return withPubspec?.uri.fsPath;
}

function execFile(
  command: string,
  args: string[],
  cwd: string,
  timeoutMs = 30_000,
): Promise<string> {
  return new Promise((resolve, reject) => {
    cp.execFile(
      command,
      args,
      {
        cwd,
        env: process.env,
        timeout: timeoutMs,
        maxBuffer: 16 * 1024 * 1024,
        // .bat shims on Windows need a shell to resolve.
        shell: process.platform === 'win32',
      },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr?.toString().trim() || error.message));
          return;
        }
        resolve(stdout.toString());
      },
    );
  });
}

export interface ClientListing {
  clients: ClientInfo[];
  /** `cli` when udara_cli answered, `fallback` when the folder was scanned. */
  source: 'cli' | 'fallback';
  cliError?: string;
}

/** Lists clients via the CLI, falling back to scanning `clients/` directly. */
export async function listClients(root: string): Promise<ClientListing> {
  const { cliPath } = getConfig();
  try {
    const out = await execFile(cliPath, ['list-clients', '--json'], root);
    const parsed = JSON.parse(out) as { clients: ClientInfo[] };
    return { clients: parsed.clients ?? [], source: 'cli' };
  } catch (e) {
    return {
      clients: scanClients(root),
      source: 'fallback',
      cliError: e instanceof Error ? e.message : String(e),
    };
  }
}

/** Reads `.udara_build_history.json`; newest first, empty when absent. */
export function readHistory(root: string): HistoryEntry[] {
  const file = path.join(root, HISTORY_FILE);
  if (!fs.existsSync(file)) {
    return [];
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(parsed) ? (parsed as HistoryEntry[]) : [];
  } catch {
    return [];
  }
}

/** Devices as reported by `flutter devices --machine`. */
export interface FlutterDevice {
  id: string;
  name: string;
  targetPlatform?: string;
  emulator?: boolean;
}

export async function listDevices(root: string): Promise<FlutterDevice[]> {
  const { flutterPath } = getConfig();
  try {
    const out = await execFile(flutterPath, ['devices', '--machine'], root, 60_000);
    // Flutter may print notices before the JSON; take the array only.
    const start = out.indexOf('[');
    const end = out.lastIndexOf(']');
    if (start < 0 || end < 0) {
      return [];
    }
    const parsed = JSON.parse(out.substring(start, end + 1));
    return Array.isArray(parsed) ? (parsed as FlutterDevice[]) : [];
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Fallback: read clients without the CLI (browsing still works when the CLI
// is not installed; run/build actions need it).
// ---------------------------------------------------------------------------

function scanClients(root: string): ClientInfo[] {
  const clientsDir = path.join(root, 'clients');
  if (!fs.existsSync(clientsDir)) {
    return [];
  }
  return fs
    .readdirSync(clientsDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort()
    .map((name) => {
      const dir = path.join(clientsDir, name);
      const envPath = path.join(dir, '.env');
      const envTestPath = path.join(dir, '.env_test');
      const env = fs.existsSync(envPath) ? parseEnv(fs.readFileSync(envPath, 'utf8')) : {};
      const envTest = fs.existsSync(envTestPath)
        ? parseEnv(fs.readFileSync(envTestPath, 'utf8'))
        : {};
      const fontsDir = path.join(dir, 'fonts');
      const hasFonts =
        fs.existsSync(fontsDir) &&
        fs.readdirSync(fontsDir).some((f) => !f.startsWith('.'));
      return {
        name,
        path: dir,
        isDefault: name === 'default',
        appName: env.APP_NAME_PROD ?? null,
        bundleId: env.BUNDLE_ID ?? null,
        hasFonts,
        envFiles: {
          ...(fs.existsSync(envPath) ? { env: envPath } : {}),
          ...(fs.existsSync(envTestPath) ? { envTest: envTestPath } : {}),
        },
        env,
        envTest,
      };
    });
}

/** Mirrors the CLI's dotenv rules: quotes, `export`, inline `#` comments. */
export function parseEnv(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (let line of content.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) {
      continue;
    }
    if (line.startsWith('export ')) {
      line = line.substring(7).trim();
    }
    const eq = line.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key = line.substring(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      continue;
    }
    result[key] = parseValue(line.substring(eq + 1).trim());
  }
  return result;
}

function parseValue(raw: string): string {
  if (!raw) {
    return '';
  }
  const quote = raw[0];
  if (quote === '"' || quote === "'") {
    const closing = raw.indexOf(quote, 1);
    return closing > 0 ? raw.substring(1, closing) : raw.substring(1);
  }
  const hash = raw.indexOf(' #');
  return (hash >= 0 ? raw.substring(0, hash) : raw).trim();
}

const SECRET_PATTERN = /(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|API_KEY|_KEY$|^KEY$)/i;

export function isSecretKey(key: string): boolean {
  return SECRET_PATTERN.test(key);
}
