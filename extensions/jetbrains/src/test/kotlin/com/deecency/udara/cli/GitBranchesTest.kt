package com.deecency.udara.cli

import org.junit.Assert.assertEquals
import org.junit.Test

/** Same cases as extensions/vscode/test/gitBranches.test.js. */
class GitBranchesTest {
    private fun local(ref: String) = GitBranches.Choice(ref, remote = false)
    private fun remote(ref: String) = GitBranches.Choice(ref, remote = true)

    @Test
    fun offersOtherLocalBranchesThenRemoteOnlyOnes() {
        val choices = GitBranches.choices(
            "dev",
            listOf("dev", "stable", "feature/cards"),
            listOf("origin/HEAD", "origin/dev", "origin/stable", "origin/release", "upstream/hotfix"),
        )
        assertEquals(
            listOf(local("stable"), local("feature/cards"), remote("origin/release"), remote("upstream/hotfix")),
            choices,
        )
    }

    @Test
    fun neverOffersTheCheckedOutBranch() {
        assertEquals(emptyList<GitBranches.Choice>(), GitBranches.choices("stable", listOf("stable"), listOf("origin/stable")))
    }

    @Test
    fun onDetachedHeadEveryBranchIsOffered() {
        assertEquals(
            listOf(local("main"), remote("origin/x")),
            GitBranches.choices(null, listOf("main"), listOf("origin/main", "origin/x")),
        )
    }
}
