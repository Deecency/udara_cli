package com.deecency.udara.ui

import com.deecency.udara.actions.BuildClientAction
import com.deecency.udara.actions.CleanAction
import com.deecency.udara.actions.DiffAction
import com.deecency.udara.actions.DoctorAction
import com.deecency.udara.actions.RunClientAction
import com.deecency.udara.actions.RunClientTestAction
import com.deecency.udara.actions.SetupClientsAction
import com.deecency.udara.actions.WhitelabelAction
import com.deecency.udara.cli.ClientInfo
import com.deecency.udara.cli.ClientListing
import com.deecency.udara.cli.EnvParser
import com.deecency.udara.cli.HistoryEntry
import com.deecency.udara.cli.UdaraCli
import com.deecency.udara.settings.UdaraSettings
import com.intellij.icons.AllIcons
import com.intellij.ide.actions.RevealFileAction
import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DataSink
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.PlatformDataKeys
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.SimpleToolWindowPanel
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.openapi.vfs.newvfs.BulkFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.PopupHandler
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTabbedPane
import com.intellij.ui.table.JBTable
import com.intellij.ui.treeStructure.Tree
import com.intellij.util.Alarm
import com.intellij.util.ui.JBUI
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.io.File
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.JTree
import javax.swing.table.DefaultTableModel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel
import javax.swing.tree.TreePath
import javax.swing.tree.TreeSelectionModel

class UdaraPanel(private val project: Project, parentDisposable: Disposable) :
    SimpleToolWindowPanel(true, true), Disposable {

    private class EnvFileNode(val client: ClientInfo, val path: String, val vars: Map<String, String>, val isTest: Boolean)
    private class EnvEntryNode(val filePath: String, val key: String, val value: String)
    private class FontsNode(val client: ClientInfo)

    private val rootNode = DefaultMutableTreeNode("clients")
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel)
    private val historyModel = object : DefaultTableModel(
        arrayOf("Status", "Client", "Platform", "Type", "Version", "Duration", "When", "Artifact / Error"), 0,
    ) {
        override fun isCellEditable(row: Int, column: Int) = false
    }
    private val historyTable = JBTable(historyModel)
    private val statusLabel = JBLabel()
    private val alarm = Alarm(Alarm.ThreadToUse.SWING_THREAD, this)

    private var history: List<HistoryEntry> = emptyList()
    private var warnedAboutCli = false

    init {
        Disposer.register(parentDisposable, this)
        toolbar = buildToolbar()

        tree.isRootVisible = false
        tree.showsRootHandles = true
        tree.selectionModel.selectionMode = TreeSelectionModel.SINGLE_TREE_SELECTION
        tree.cellRenderer = Renderer()
        tree.emptyText.text = "No clients found. Use Set Up Clients… to create some."
        tree.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (e.clickCount == 2) openSelected()
            }
        })
        PopupHandler.installPopupMenu(tree, popupGroup(), "UdaraTreePopup")

        historyTable.setShowGrid(false)
        historyTable.emptyText.text = "No builds recorded yet."
        historyTable.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (e.clickCount == 2) revealSelectedHistory()
            }
        })

        val tabs = JBTabbedPane()
        tabs.addTab("Clients", JBScrollPane(tree))
        tabs.addTab("History", JBScrollPane(historyTable))

        statusLabel.border = JBUI.Borders.empty(4, 8)
        val content = JPanel(BorderLayout())
        content.add(statusLabel, BorderLayout.NORTH)
        content.add(tabs, BorderLayout.CENTER)
        setContent(content)

        project.messageBus.connect(this).subscribe(VirtualFileManager.VFS_CHANGES, object : BulkFileListener {
            override fun after(events: List<VFileEvent>) {
                if (events.any { it.path.contains("/clients/") || it.path.endsWith(UdaraCli.HISTORY_FILE) }) {
                    scheduleRefresh()
                }
            }
        })

        refresh()
    }

    // -----------------------------------------------------------------------
    // Data for actions
    // -----------------------------------------------------------------------

    fun selectedClient(): ClientInfo? {
        var node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        while (true) {
            when (val obj = node.userObject) {
                is ClientInfo -> return obj
                is EnvFileNode -> return obj.client
                is FontsNode -> return obj.client
            }
            node = node.parent as? DefaultMutableTreeNode ?: return null
        }
    }

    override fun uiDataSnapshot(sink: DataSink) {
        super.uiDataSnapshot(sink)
        sink.set(UdaraDataKeys.CLIENT, selectedClient())
        sink.set(UdaraDataKeys.PANEL, this)
        sink.set(PlatformDataKeys.PROJECT, project)
    }

    // -----------------------------------------------------------------------
    // Loading
    // -----------------------------------------------------------------------

    fun scheduleRefresh() {
        alarm.cancelAllRequests()
        alarm.addRequest({ refresh() }, 300)
    }

    fun refresh() {
        val root = UdaraCli.projectRoot(project)
        if (root == null) {
            statusLabel.text = "Open a Flutter project (folder with pubspec.yaml)."
            rootNode.removeAllChildren()
            treeModel.reload()
            return
        }
        ApplicationManager.getApplication().executeOnPooledThread {
            val listing = UdaraCli.listClients(root)
            val entries = UdaraCli.readHistory(root)
            ApplicationManager.getApplication().invokeLater({
                if (!project.isDisposed) render(listing, entries)
            }, project.disposed)
        }
    }

    private fun render(listing: ClientListing, entries: List<HistoryEntry>) {
        val expanded = expandedClientNames()
        rootNode.removeAllChildren()
        for (client in listing.clients) {
            val node = DefaultMutableTreeNode(client)
            client.envFile?.let { node.add(envFileNode(client, it, client.env, false)) }
            client.envTestFile?.let { node.add(envFileNode(client, it, client.envTest, true)) }
            if (client.hasFonts) node.add(DefaultMutableTreeNode(FontsNode(client), false))
            rootNode.add(node)
        }
        treeModel.reload()
        for (i in 0 until rootNode.childCount) {
            val child = rootNode.getChildAt(i) as DefaultMutableTreeNode
            if ((child.userObject as ClientInfo).name in expanded) {
                tree.expandPath(TreePath(child.path))
            }
        }

        history = entries
        historyModel.rowCount = 0
        for (e in entries) {
            historyModel.addRow(
                arrayOf(
                    if (e.success) "✔ success" else "✘ failed",
                    e.client, e.platform, e.type, e.version ?: "?",
                    "${e.durationSeconds}s",
                    e.timestamp.replace('T', ' ').take(16),
                    e.artifact?.let { File(it).name } ?: e.error ?: "",
                )
            )
        }

        val active = ActiveClient.get(project)
        statusLabel.text = buildString {
            append("${listing.clients.size} client(s)")
            if (active != null) append("  ·  branded as \"$active\"")
            if (listing is ClientListing.Fallback) append("  ·  udara_cli not available (browsing only)")
        }
        if (listing is ClientListing.Fallback && !warnedAboutCli) {
            warnedAboutCli = true
            UdaraNotifications.cliMissing(project, listing.cliError)
        }
    }

    private fun envFileNode(client: ClientInfo, path: String, vars: Map<String, String>, isTest: Boolean): DefaultMutableTreeNode {
        val node = DefaultMutableTreeNode(EnvFileNode(client, path, vars, isTest))
        for ((k, v) in vars) node.add(DefaultMutableTreeNode(EnvEntryNode(path, k, v), false))
        return node
    }

    private fun expandedClientNames(): Set<String> {
        val names = HashSet<String>()
        for (i in 0 until rootNode.childCount) {
            val child = rootNode.getChildAt(i) as DefaultMutableTreeNode
            if (tree.isExpanded(TreePath(child.path))) {
                names.add((child.userObject as ClientInfo).name)
            }
        }
        return names
    }

    // -----------------------------------------------------------------------
    // Navigation
    // -----------------------------------------------------------------------

    private fun openSelected() {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return
        when (val obj = node.userObject) {
            is EnvFileNode -> openFile(obj.path, null)
            is EnvEntryNode -> openFile(obj.filePath, obj.key)
            is FontsNode -> RevealFileAction.openFile(File(obj.client.path, "fonts"))
        }
    }

    private fun openFile(path: String, key: String?) {
        val vf = LocalFileSystem.getInstance().refreshAndFindFileByIoFile(File(path)) ?: return
        var line = 0
        if (key != null) {
            val pattern = Regex("^\\s*(export\\s+)?${Regex.escape(key)}\\s*=")
            val idx = File(path).readLines().indexOfFirst { pattern.containsMatchIn(it) }
            if (idx >= 0) line = idx
        }
        OpenFileDescriptor(project, vf, line, 0).navigate(true)
    }

    private fun revealSelectedHistory() {
        val row = historyTable.selectedRow
        if (row < 0 || row >= history.size) return
        val entry = history[row]
        val artifact = entry.artifact?.let { File(it) }
        if (artifact != null && artifact.exists()) {
            RevealFileAction.openFile(artifact)
        } else if (entry.error != null) {
            UdaraNotifications.error(project, "Build failed: ${entry.client}", entry.error)
        }
    }

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    private fun buildToolbar(): JComponent {
        val group = DefaultActionGroup()
        group.add(object : DumbAwareAction("Refresh", "Reload clients and history", AllIcons.Actions.Refresh) {
            override fun actionPerformed(e: AnActionEvent) = refresh()
            override fun getActionUpdateThread() = ActionUpdateThread.EDT
        })
        group.addSeparator()
        group.add(RunClientAction())
        group.add(RunClientTestAction())
        group.add(BuildClientAction())
        group.add(WhitelabelAction())
        group.addSeparator()
        group.add(DoctorAction())
        group.add(CleanAction())
        group.add(DiffAction())
        group.add(SetupClientsAction())
        group.addSeparator()
        group.add(object : DumbAwareAction("Settings", "Configure udara_cli and flutter paths", AllIcons.General.Settings) {
            override fun actionPerformed(e: AnActionEvent) {
                ShowSettingsUtil.getInstance().showSettingsDialog(project, "Udara Whitelabel")
            }
            override fun getActionUpdateThread() = ActionUpdateThread.EDT
        })
        val toolbar = ActionManager.getInstance().createActionToolbar("UdaraToolbar", group, true)
        toolbar.targetComponent = this
        return toolbar.component
    }

    private fun popupGroup(): DefaultActionGroup {
        val group = DefaultActionGroup()
        group.add(RunClientAction())
        group.add(RunClientTestAction())
        group.add(BuildClientAction())
        group.add(WhitelabelAction())
        group.addSeparator()
        group.add(DoctorAction())
        group.add(object : DumbAwareAction("Open", "Open the selected file", AllIcons.Actions.MenuOpen) {
            override fun actionPerformed(e: AnActionEvent) = openSelected()
            override fun getActionUpdateThread() = ActionUpdateThread.EDT
        })
        return group
    }

    override fun dispose() {
        // The alarm and message bus connection are registered against this disposable.
    }

    // -----------------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------------

    private inner class Renderer : ColoredTreeCellRenderer() {
        override fun customizeCellRenderer(
            tree: JTree, value: Any?, selected: Boolean, expanded: Boolean,
            leaf: Boolean, row: Int, hasFocus: Boolean,
        ) {
            val node = value as? DefaultMutableTreeNode ?: return
            when (val obj = node.userObject) {
                is ClientInfo -> {
                    icon = if (obj.isDefault) AllIcons.Nodes.Favorite else AllIcons.Nodes.Module
                    append(obj.name, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
                    if (obj.summary.isNotEmpty()) append("  ${obj.summary}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    else append("  no .env", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
                is EnvFileNode -> {
                    icon = AllIcons.FileTypes.Config
                    append(File(obj.path).name)
                    append("  ${obj.vars.size} keys", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
                is EnvEntryNode -> {
                    val masked = UdaraSettings.getInstance().state.maskSecrets &&
                        EnvParser.isSecret(obj.key) && obj.value.isNotEmpty()
                    icon = if (masked) AllIcons.Nodes.Padlock else AllIcons.Nodes.Variable
                    append(obj.key)
                    append(" = ", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    append(
                        if (masked) "••••••••" else obj.value.ifEmpty { "(empty)" },
                        if (masked) SimpleTextAttributes.GRAYED_ATTRIBUTES else SimpleTextAttributes.REGULAR_ATTRIBUTES,
                    )
                }
                is FontsNode -> {
                    icon = AllIcons.FileTypes.Font
                    append("fonts")
                    append("  custom fonts", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
                else -> append(obj?.toString() ?: "")
            }
        }
    }
}
