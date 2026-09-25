import * as path from 'path';
import * as vscode from 'vscode';
import { ClientInfo, ClientListing, getConfig, isSecretKey, listClients } from './cli';

export type ClientNode = ClientItem | EnvFileItem | EnvEntryItem | FontsItem;

export class ClientItem extends vscode.TreeItem {
  constructor(public readonly client: ClientInfo) {
    super(client.name, vscode.TreeItemCollapsibleState.Collapsed);
    this.contextValue = 'client';
    this.iconPath = new vscode.ThemeIcon(client.isDefault ? 'star-full' : 'organization');
    const parts = [client.appName, client.bundleId].filter(Boolean);
    this.description = parts.join(' · ') || 'no .env';
    this.tooltip = new vscode.MarkdownString(
      [
        `**${client.name}**${client.isDefault ? ' (default fallback)' : ''}`,
        client.appName ? `App name: ${client.appName}` : undefined,
        client.bundleId ? `Bundle id: ${client.bundleId}` : undefined,
        `Path: ${client.path}`,
      ]
        .filter(Boolean)
        .join('  \n'),
    );
  }
}

export class EnvFileItem extends vscode.TreeItem {
  constructor(
    public readonly client: ClientInfo,
    public readonly filePath: string,
    public readonly vars: Record<string, string>,
    public readonly isTest: boolean,
  ) {
    super(path.basename(filePath), vscode.TreeItemCollapsibleState.Collapsed);
    this.contextValue = 'envFile';
    this.resourceUri = vscode.Uri.file(filePath);
    this.iconPath = new vscode.ThemeIcon(isTest ? 'beaker' : 'settings-gear');
    this.description = `${Object.keys(vars).length} keys`;
    this.tooltip = filePath;
    this.command = {
      command: 'vscode.open',
      title: 'Open',
      arguments: [this.resourceUri],
    };
  }
}

export class EnvEntryItem extends vscode.TreeItem {
  constructor(
    public readonly filePath: string,
    public readonly key: string,
    public readonly value: string,
  ) {
    super(key, vscode.TreeItemCollapsibleState.None);
    this.contextValue = 'envEntry';
    const masked = getConfig().maskSecrets && isSecretKey(key) && value.length > 0;
    this.description = masked ? '••••••••' : value || '(empty)';
    this.tooltip = masked ? `${key} (masked; use Copy Value)` : `${key}=${value}`;
    this.iconPath = new vscode.ThemeIcon(masked ? 'lock' : 'symbol-key');
    this.command = {
      command: 'udara.openEnv',
      title: 'Open at key',
      arguments: [this],
    };
  }
}

export class FontsItem extends vscode.TreeItem {
  constructor(public readonly client: ClientInfo) {
    super('fonts', vscode.TreeItemCollapsibleState.None);
    this.contextValue = 'fonts';
    this.iconPath = new vscode.ThemeIcon('text-size');
    this.resourceUri = vscode.Uri.file(path.join(client.path, 'fonts'));
    this.description = 'custom fonts';
    this.command = {
      command: 'revealInExplorer',
      title: 'Reveal',
      arguments: [this.resourceUri],
    };
  }
}

export class ClientsTreeProvider implements vscode.TreeDataProvider<ClientNode> {
  private readonly emitter = new vscode.EventEmitter<ClientNode | undefined>();
  readonly onDidChangeTreeData = this.emitter.event;

  private listing: ClientListing = { clients: [], source: 'fallback' };
  private loaded = false;

  constructor(private readonly getRoot: () => string | undefined) {}

  get clients(): ClientInfo[] {
    return this.listing.clients;
  }

  get lastListing(): ClientListing {
    return this.listing;
  }

  refresh(): void {
    this.loaded = false;
    this.emitter.fire(undefined);
  }

  getTreeItem(element: ClientNode): vscode.TreeItem {
    return element;
  }

  async getChildren(element?: ClientNode): Promise<ClientNode[]> {
    if (!element) {
      await this.ensureLoaded();
      return this.listing.clients.map((c) => new ClientItem(c));
    }

    if (element instanceof ClientItem) {
      const c = element.client;
      const nodes: ClientNode[] = [];
      if (c.envFiles.env) {
        nodes.push(new EnvFileItem(c, c.envFiles.env, c.env, false));
      }
      if (c.envFiles.envTest) {
        nodes.push(new EnvFileItem(c, c.envFiles.envTest, c.envTest, true));
      }
      if (c.hasFonts) {
        nodes.push(new FontsItem(c));
      }
      return nodes;
    }

    if (element instanceof EnvFileItem) {
      return Object.entries(element.vars).map(
        ([key, value]) => new EnvEntryItem(element.filePath, key, value),
      );
    }

    return [];
  }

  /** Loads clients once per refresh so expanding nodes does not re-run the CLI. */
  async ensureLoaded(): Promise<ClientListing> {
    if (this.loaded) {
      return this.listing;
    }
    const root = this.getRoot();
    this.listing = root ? await listClients(root) : { clients: [], source: 'fallback' };
    this.loaded = true;
    await vscode.commands.executeCommand(
      'setContext',
      'udara.hasClients',
      this.listing.clients.length > 0,
    );
    return this.listing;
  }
}
