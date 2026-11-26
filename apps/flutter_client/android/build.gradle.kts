// 0.1.3：本地补丁版 libbox 的 Maven 仓。uri 必须在这里先算成绝对地址
// 再进 allprojects：allprojects 的闭包对每个 project 各跑一遍，
// 在里面写 uri("../packages/...") 会按 :app 的目录（android/app/）
// 解析、找不到；根 project 这一层算好，:app 解析传递依赖时也对。
val libboxMavenRepo = uri("../packages/flutter_sing_box/android/libs/maven-repo")

allprojects {
    repositories {
        google()
        mavenCentral()
        // flutter_sing_box's libbox used to come from JitPack
        // (com.github.singbox-android:libbox); 0.1.3 起改走本地补丁版
        //（见下面），JitPack 只留作其他依赖的后备源。
        maven("https://jitpack.io")
        // 0.1.3：本地补丁版 libbox（io.nekohasekai:libbox:1.14.4-patched，
        // 插件内的本地 Maven 仓，tools/build-patched-libbox.sh 第 7 步生成）。
        // 必须放在这里（根 build 文件的 allprojects）：插件模块自己的
        // allprojects 声明不会进 :app 的解析（实测 0.1.3 连败两次都是
        // 在这里没声明）。不要改回 files("libs/*.aar")——AGP 拒绝
        // library 模块直接依赖本地 .aar。
        maven { url = libboxMavenRepo }
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
