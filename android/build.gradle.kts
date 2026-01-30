allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")

    val applyNamespace = {
        val android = project.extensions.findByName("android")
        if (android != null && android is com.android.build.gradle.BaseExtension) {
            if (android.namespace == null) {
                android.namespace = "com.unspecified.pkg.${project.name.replace("-", "_")}"
            }
        }
    }

    if (project.state.executed) {
        applyNamespace()
    } else {
        project.afterEvaluate { applyNamespace() }
    }
}

// Final fix for AGP 8+ compatibility: Strip 'package' attribute from plugin manifests
subprojects {
    plugins.withType<com.android.build.gradle.api.AndroidBasePlugin> {
        project.extensions.configure<com.android.build.gradle.BaseExtension> {
            val android = this
            project.tasks.withType<com.android.build.gradle.tasks.ProcessLibraryManifest>().configureEach {
                doFirst {
                    val manifestFile = mainManifest.get().asFile
                    if (manifestFile.exists()) {
                        val content = manifestFile.readText()
                        if (content.contains("package=")) {
                            val updatedContent = content.replace(Regex("""package="[^"]*""""), "")
                            manifestFile.writeText(updatedContent)
                        }
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
