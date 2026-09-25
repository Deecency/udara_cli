package com.deecency.udara.run

import com.deecency.udara.cli.UdaraCli
import com.deecency.udara.settings.UdaraSettings
import com.deecency.udara.ui.ActiveClient
import com.deecency.udara.ui.UdaraNotifications
import com.intellij.execution.BeforeRunTask
import com.intellij.execution.BeforeRunTaskProvider
import com.intellij.execution.configurations.RunConfiguration
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.execution.runners.ExecutionEnvironment
import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.DataContext
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.util.Key
import javax.swing.Icon

/**
 * "Before launch" step on the Flutter run configurations the plugin creates:
 * runs `udara_cli whitelabel --client <name> --keep` so pressing the normal
 * Run / Debug button always launches the right client.
 */
class UdaraBeforeRunTask : BeforeRunTask<UdaraBeforeRunTask>(UdaraBeforeRunTaskProvider.ID),
    PersistentStateComponent<UdaraBeforeRunTask.State> {

    class State {
        var client: String = ""
        var test: Boolean = false
    }

    private var myState = State()

    var client: String
        get() = myState.client
        set(value) { myState.client = value }

    var test: Boolean
        get() = myState.test
        set(value) { myState.test = value }

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    override fun clone(): BeforeRunTask<*> {
        val copy = super.clone() as UdaraBeforeRunTask
        copy.myState = State().also {
            it.client = client
            it.test = test
        }
        return copy
    }

    override fun equals(other: Any?): Boolean =
        other is UdaraBeforeRunTask && other.client == client && other.test == test && other.isEnabled == isEnabled

    override fun hashCode(): Int = (client.hashCode() * 31 + test.hashCode()) * 31 + isEnabled.hashCode()
}

class UdaraBeforeRunTaskProvider : BeforeRunTaskProvider<UdaraBeforeRunTask>() {
    companion object {
        val ID: Key<UdaraBeforeRunTask> = Key.create("Udara.Whitelabel")
    }

    override fun getId(): Key<UdaraBeforeRunTask> = ID

    override fun getName(): String = "Udara: whitelabel client"

    override fun getIcon(): Icon = AllIcons.Actions.Edit

    override fun getDescription(task: UdaraBeforeRunTask): String =
        "Udara: whitelabel as \"${task.client}\"${if (task.test) " (test env)" else ""}"

    /** Disabled by default so it is only active where the plugin adds it. */
    override fun createTask(runConfiguration: RunConfiguration): UdaraBeforeRunTask =
        UdaraBeforeRunTask().also { it.isEnabled = false }

    override fun executeTask(
        context: DataContext,
        configuration: RunConfiguration,
        environment: ExecutionEnvironment,
        task: UdaraBeforeRunTask,
    ): Boolean {
        val project = configuration.project
        val root = UdaraCli.projectRoot(project) ?: return false
        if (task.client.isBlank()) return true

        val args = mutableListOf("whitelabel", "--client", task.client, "--keep")
        if (task.test) args += "--test"
        val cli = UdaraSettings.getInstance().state.cliPath

        val run = {
            try {
                CapturingProcessHandler(UdaraCli.commandLine(root, cli, args)).runProcess(10 * 60 * 1000)
            } catch (e: Exception) {
                null.also { UdaraNotifications.cliMissing(project, e.message ?: cli) }
            }
        }
        // The platform runs before-launch steps on a background thread, so
        // blocking here until the CLI finishes is expected.
        val output = run() ?: return false

        if (output.isTimeout || output.exitCode != 0) {
            val tail = (output.stdout + "\n" + output.stderr).lines().filter { it.isNotBlank() }.takeLast(12)
            UdaraNotifications.whitelabelFailed(project, root, task.client, output.exitCode, tail.joinToString("\n"))
            return false
        }
        ActiveClient.set(project, task.client)
        return true
    }
}
