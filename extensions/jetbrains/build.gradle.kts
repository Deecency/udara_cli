plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.1.20"
    id("org.jetbrains.intellij.platform") version "2.5.0"
}

group = "com.deecency.udara"
version = "0.1.1"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        // Android Studio Ladybug and newer are built on the 2024.2 platform;
        // building against IntelliJ Community keeps the download small.
        intellijIdeaCommunity("2024.2.5")
    }
}

intellijPlatform {
    pluginConfiguration {
        id = "com.deecency.udara"
        name = "Udara Whitelabel"
        version = project.version.toString()
        ideaVersion {
            sinceBuild = "242"
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = false

    // For updates after the first (manual) Marketplace upload:
    //   JETBRAINS_MARKETPLACE_TOKEN=... ./gradlew publishPlugin
    publishing {
        token = providers.environmentVariable("JETBRAINS_MARKETPLACE_TOKEN")
    }
}

kotlin {
    jvmToolchain(17)
}
