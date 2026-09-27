package com.deecency.udara.actions

import com.deecency.udara.cli.ClientInfo
import com.deecency.udara.cli.PubspecVersion
import com.deecency.udara.run.FlutterRunConfigs
import com.deecency.udara.cli.UdaraCli
import com.deecency.udara.cli.UdaraRunner
import com.deecency.udara.settings.UdaraSettings
import com.deecency.udara.ui.ActiveClient
import com.deecency.udara.ui.BatchBuildDialog
import com.deecency.udara.ui.BuildDialog
import com.deecency.udara.ui.ClientChooser
import com.deecency.udara.ui.UdaraDataKeys
import com.deecency.udara.ui.UdaraNotifications
import com.deecency.udara.ui.UdaraPanel
import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.openapi.wm.ToolWindowManager
import com.intellij.ui.SimpleListCellRenderer
import com.intellij.util.execution.ParametersListUtil
import java.io.File
import java.time.LocalDateTime
import javax.swing.Icon

abstract class UdaraActionBase(text: String, description: String?, icon: Icon?) :
    DumbAwareAction(text, description, icon) {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        e.presentation.isEnabled = e.project?.let { UdaraCli.projectRoot(it) } != null
    }

    protected fun withRoot(e: AnActionEvent, block: (Project, File) -> Unit) {
        val project = e.project ?: return
        val root = UdaraCli.projectRoot(project)
        if (root == null) {
            UdaraNotifications.warn(project, "No Flutter project", "Open a project containing pubspec.yaml.")
            return
        }
        block(project, root)
    }

    /** Uses the tool window selection when present, otherwise asks. */
    protected fun withClient(e: AnActionEvent, title: String, block: (Project, File, ClientInfo) -> Unit) {
        withRoot(e) { project, root ->
            val selected = e.getData(UdaraDataKeys.CLIENT)
            if (selected != null) block(project, root, selected)
            else ClientChooser.choose(project, title) { block(project, root, it) }
        }
    }

    protected fun refreshPanel(project: Project) {
        UdaraPanel.forProject(project)?.scheduleRefresh()
    }

    /** Checks the installed CLI is new enough (off the UI thread), then runs [then] on the UI thread. */
    protected fun requireCliVersion(project: Project, root: File, then: () -> Unit) {
        ApplicationManager.getApplication().executeOnPooledThread {
            val version = UdaraCli.cliVersion(root)
            ApplicationManager.getApplication().invokeLater({
                if (version != null && !UdaraCli.isAtLeast(version, UdaraCli.MIN_CLI_VERSION)) {
                    UdaraNotifications.cliTooOld(project, version)
                } else {
                    then()
                }
            }, project.disposed)
        }
    }
}

/** Whitelabels the project as the client, then starts `flutter run` in the Terminal. */
object RunFlow {
    private class DeviceChoice(val id: String?, val label: String)

    fun run(project: Project, root: File, client: ClientInfo, isTest: Boolean, debug: Boolean = false) {
        // Preferred: a Flutter plugin run configuration whose "before launch"
        // step whitelabels the client, so the normal Flutter controls apply.
        if (UdaraSettings.getInstance().state.useFlutterRunConfigs && FlutterRunConfigs.isAvailable()) {
            val settings = FlutterRunConfigs.ensure(project, root, client.name, isTest)
            if (settings != null) {
                FlutterRunConfigs.launch(settings, debug)
                return
            }
        }
        if (UdaraSettings.getInstance().state.useFlutterRunConfigs) {
            UdaraNotifications.info(
                project, "Flutter plugin not found",
                "Install the Flutter plugin for the standard hot reload and debug controls. Using the Run console for now.",
            )
        }

        val args = mutableListOf("whitelabel", "--client", client.name, "--keep")
        if (isTest) args += "--test"
        UdaraRunner.runCli(project, root, "udara whitelabel ${client.name}", args) { code ->
            if (code != 0) {
                UdaraNotifications.error(
                    project, "Whitelabel for \"${client.name}\" failed",
                    "Exit code $code. Run Doctor to check the client setup.",
                )
                return@runCli
            }
            ActiveClient.set(project, client.name)
            val settings = UdaraSettings.getInstance().state
            val launch = { device: String? ->
                val runArgs = mutableListOf("run", "--dart-define=CLIENT_ENV=.env")
                if (device != null) runArgs += listOf("-d", device)
                runArgs += ParametersListUtil.parse(settings.flutterRunArgs)
                UdaraRunner.runFlutterInteractive(
                    project, root,
                    "flutter run · ${client.name}${if (isTest) " (test)" else ""}",
                    runArgs,
                )
            }
            if (!settings.askForDevice) {
                launch(null)
                return@runCli
            }
            ApplicationManager.getApplication().executeOnPooledThread {
                val devices = UdaraCli.listDevices(root)
                ApplicationManager.getApplication().invokeLater({
                    if (devices.isEmpty()) {
                        launch(null)
                        return@invokeLater
                    }
                    val choices = listOf(DeviceChoice(null, "Default (let flutter choose)")) +
                        devices.map { DeviceChoice(it.id, "${it.name}   ${it.id}") }
                    JBPopupFactory.getInstance()
                        .createPopupChooserBuilder(choices)
                        .setTitle("Run \"${client.name}\" on which device?")
                        .setRenderer(SimpleListCellRenderer.create<DeviceChoice> { label, value, _ -> label.text = value.label })
                        .setItemChosenCallback { launch(it.id) }
                        .createPopup()
                        .showCenteredInCurrentWindow(project)
                }, project.disposed)
            }
        }
    }
}

class RunClientAction : UdaraActionBase(
    "Run Client…", "Whitelabel the project as a client and start flutter run", AllIcons.Actions.Execute,
) {
    override fun actionPerformed(e: AnActionEvent) =
        withClient(e, "Run which client?") { project, root, client -> RunFlow.run(project, root, client, false) }
}

class DebugClientAction : UdaraActionBase(
    "Debug Client…", "Whitelabel the project as a client and start it in the Flutter debugger", AllIcons.Actions.StartDebugger,
) {
    override fun actionPerformed(e: AnActionEvent) =
        withClient(e, "Debug which client?") { project, root, client -> RunFlow.run(project, root, client, false, debug = true) }
}

class RunClientTestAction : UdaraActionBase(
    "Run Client with Test Env…", "Whitelabel using .env_test and start flutter run", AllIcons.Actions.RunAll,
) {
    override fun actionPerformed(e: AnActionEvent) =
        withClient(e, "Run which client (test env)?") { project, root, client -> RunFlow.run(project, root, client, true) }
}

class BuildClientAction : UdaraActionBase(
    "Build Client…", "Build a whitelabeled APK, AAB or IPA", AllIcons.Actions.Compile,
) {
    override fun actionPerformed(e: AnActionEvent) =
        withClient(e, "Build which client?") { project, root, client ->
            requireCliVersion(project, root) {
                val dialog = BuildDialog(project, client.name, PubspecVersion.read(root))
                if (!dialog.showAndGet()) return@requireCliVersion
                val version = dialog.version?.let { " v$it" } ?: ""
                TrackedBuild.run(
                    project, root,
                    title = "udara build ${client.name} ${dialog.platform}$version",
                    label = "Building ${client.name} (${dialog.platform})$version",
                    args = dialog.cliArgs(),
                ) { code ->
                    if (code == TrackedBuild.CANCELLED) {
                        UdaraNotifications.info(project, "Build for \"${client.name}\" cancelled")
                    } else {
                        val artifact = UdaraCli.readHistory(root).firstOrNull()?.artifact
                        UdaraNotifications.buildFinished(project, client.name, code, artifact) {
                            UdaraRunner.runCli(project, root, "udara doctor ${client.name}", listOf("doctor", "--client", client.name))
                        }
                    }
                    refreshPanel(project)
                }
            }
        }
}

class BuildMultipleAction : UdaraActionBase(
    "Build Multiple Clients…", "Build several clients, platforms and types, in parallel", AllIcons.Actions.Compile,
) {
    override fun actionPerformed(e: AnActionEvent) = withRoot(e) { project, root ->
        val preselected = e.getData(UdaraDataKeys.CLIENT)?.name
        ApplicationManager.getApplication().executeOnPooledThread {
            val clients = UdaraCli.listClients(root).clients
            val version = UdaraCli.cliVersion(root)
            ApplicationManager.getApplication().invokeLater({
                if (version != null && !UdaraCli.isAtLeast(version, UdaraCli.MIN_CLI_VERSION)) {
                    UdaraNotifications.cliTooOld(project, version)
                    return@invokeLater
                }
                if (clients.isEmpty()) {
                    UdaraNotifications.warn(project, "No clients found", "Use Set Up Clients… to create some.")
                    return@invokeLater
                }
                val dialog = BatchBuildDialog(project, clients, preselected, PubspecVersion.read(root))
                if (!dialog.showAndGet()) return@invokeLater

                // History timestamps are local time without a zone, like LocalDateTime.
                val startedAt = LocalDateTime.now().minusSeconds(1)
                TrackedBuild.run(
                    project, root,
                    title = "udara batch build (${dialog.buildCount} builds)",
                    label = "Building ${dialog.buildCount} builds",
                    args = dialog.cliArgs(),
                ) { code ->
                    if (code == TrackedBuild.CANCELLED) {
                        UdaraNotifications.info(project, "Batch build cancelled", "Finished artifacts are in build/udara/.")
                    } else {
                        val entries = UdaraCli.readHistory(root).filter {
                            runCatching { LocalDateTime.parse(it.timestamp).isAfter(startedAt) }.getOrDefault(false)
                        }
                        UdaraNotifications.batchFinished(
                            project, root,
                            succeeded = entries.count { it.success },
                            failed = entries.count { !it.success },
                        ) {
                            UdaraRunner.runCli(project, root, "udara doctor", listOf("doctor"))
                        }
                    }
                    refreshPanel(project)
                }
            }, project.disposed)
        }
    }
}

/**
 * Runs a build with its progress (percent, ETA, per-job steps) shown in the
 * Udara tool window, fed by the CLI's --progress-file.
 */
object TrackedBuild {
    /** Exit code the CLI uses when a build is cancelled. */
    const val CANCELLED = 130

    fun run(
        project: Project,
        root: File,
        title: String,
        label: String,
        args: List<String>,
        onFinished: (Int) -> Unit,
    ): Boolean {
        val progressFile = File(System.getProperty("java.io.tmpdir"), "udara-progress-${System.nanoTime()}.json")
        ToolWindowManager.getInstance(project).getToolWindow("Udara")?.show {
            UdaraPanel.forProject(project)?.buildProgress?.start(progressFile, label)
        }
        val started = UdaraRunner.runCli(project, root, title, args + listOf("--progress-file", progressFile.path)) { code ->
            UdaraPanel.forProject(project)?.buildProgress?.stop(
                when (code) {
                    0 -> "Finished"
                    CANCELLED -> "Cancelled"
                    else -> "Finished with errors (exit code $code)"
                },
            )
            progressFile.delete()
            File("${progressFile.path}.tmp").delete()
            onFinished(code)
        }
        if (!started) UdaraPanel.forProject(project)?.buildProgress?.stop("Could not start udara_cli")
        return started
    }
}

class WhitelabelAction : UdaraActionBase(
    "Whitelabel Project as Client…", "Apply a client's branding and keep it applied", AllIcons.Actions.Edit,
) {
    override fun actionPerformed(e: AnActionEvent) =
        withClient(e, "Whitelabel as which client?") { project, root, client ->
            val useTest = Messages.showYesNoDialog(
                project, "Use the test environment (.env_test) for \"${client.name}\"?",
                "Whitelabel \"${client.name}\"", "Test Env", "Production Env", null,
            ) == Messages.YES
            val args = mutableListOf("whitelabel", "--client", client.name, "--keep")
            if (useTest) args += "--test"
            UdaraRunner.runCli(project, root, "udara whitelabel ${client.name}", args) { code ->
                if (code == 0) {
                    ActiveClient.set(project, client.name)
                    UdaraNotifications.info(
                        project, "Project is now branded as \"${client.name}\"",
                        "Run it with: flutter run --dart-define=CLIENT_ENV=.env",
                    )
                } else {
                    UdaraNotifications.error(project, "Whitelabel failed", "Exit code $code. See the Run tool window.")
                }
                refreshPanel(project)
            }
        }
}

class DoctorAction : UdaraActionBase(
    "Doctor", "Validate the project and client setup", AllIcons.Actions.Lightning,
) {
    override fun actionPerformed(e: AnActionEvent) = withRoot(e) { project, root ->
        val client = e.getData(UdaraDataKeys.CLIENT)
        val args = mutableListOf("doctor")
        if (client != null) args += listOf("--client", client.name)
        UdaraRunner.runCli(project, root, "udara doctor", args) { code ->
            if (code == 0) UdaraNotifications.info(project, "Udara doctor: no blocking issues")
            else UdaraNotifications.warn(project, "Udara doctor found problems", "See the Run tool window.")
        }
    }
}

class CleanAction : UdaraActionBase(
    "Clean (Restore Project State)", "Restore backed-up files, remove generated branding, run flutter clean", AllIcons.Actions.GC,
) {
    override fun actionPerformed(e: AnActionEvent) = withRoot(e) { project, root ->
        UdaraRunner.runCli(project, root, "udara clean", listOf("clean")) { code ->
            if (code == 0) {
                ActiveClient.set(project, null)
                UdaraNotifications.info(project, "Project restored and cleaned")
            }
            refreshPanel(project)
        }
    }
}

class DiffAction : UdaraActionBase(
    "Diff Two Clients…", "Compare env configuration between two clients", AllIcons.Actions.Diff,
) {
    override fun actionPerformed(e: AnActionEvent) = withRoot(e) { project, root ->
        ClientChooser.choose(project, "First client") { a ->
            ClientChooser.choose(project, "Compare \"${a.name}\" with…") { b ->
                UdaraRunner.runCli(
                    project, root, "udara diff ${a.name} ${b.name}",
                    listOf("diff", "--client-a", a.name, "--client-b", b.name),
                )
            }
        }
    }
}

class SetupClientsAction : UdaraActionBase(
    "Set Up Clients…", "Scaffold client folders with env templates and placeholder logos", AllIcons.General.Add,
) {
    override fun actionPerformed(e: AnActionEvent) = withRoot(e) { project, root ->
        val input = Messages.showInputDialog(
            project,
            "Client names to create (comma-separated). A \"default\" client is always added.",
            "Set Up Clients", null, "acme,beta", null,
        )?.trim() ?: return@withRoot
        val names = input.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        if (names.isEmpty() || names.any { !Regex("^[A-Za-z0-9_-]+$").matches(it) }) {
            UdaraNotifications.warn(project, "Invalid client names", "Use letters, digits, \"_\" and \"-\".")
            return@withRoot
        }
        UdaraRunner.runCli(project, root, "udara setup clients", listOf("setup", "--clients", names.joinToString(","))) { code ->
            if (code == 0) UdaraNotifications.info(project, "Created clients: ${names.joinToString(", ")}",
                "Replace the placeholder logos and edit each .env.")
            refreshPanel(project)
        }
    }
}
