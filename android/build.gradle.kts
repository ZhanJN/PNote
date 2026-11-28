allprojects {
    repositories {
        // 国内镜像：阿里云，放在官方仓库前面，避免访问 google() 超时
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

// 1.64：appflowy_editor 带进来的一些 Android 插件（keyboard_height_plugin 等）
// 仍把 compileSdk 写死在 31/34，而项目其他依赖要求 36，Gradle 会在
// checkReleaseAarMetadata 阶段直接失败。这里在库模块应用 Android 插件时，
// 用反射把 compileSdk 统一抬到 36（只影响构建参数，不改插件源码）。
subprojects {
    plugins.withId("com.android.library") {
        afterEvaluate {
            val ext = extensions.findByName("android") ?: return@afterEvaluate
            val candidates = listOf("setCompileSdk", "setCompileSdkVersion", "compileSdkVersion")
            val intTypes = listOf(Int::class.javaPrimitiveType, Integer::class.java)
            for (name in candidates) {
                for (t in intTypes) {
                    val m = ext.javaClass.methods.firstOrNull {
                        it.name == name && it.parameterTypes.size == 1 && it.parameterTypes[0] == t
                    }
                    if (m != null) {
                        runCatching { m.invoke(ext, 36) }
                        return@afterEvaluate
                    }
                }
            }
        }
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
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
