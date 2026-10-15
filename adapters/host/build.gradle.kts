// `adapters/host`: the thin gRPC host that loads adapter jars and exposes
// `steward.adapter.v1.Adapter` on a Unix domain socket (doc 08 §3.1, §6).
plugins {
    application
}

dependencies {
    implementation(project(":api"))
    implementation(libs.slf4j.api)
    runtimeOnly(libs.slf4j.simple)
    runtimeOnly(project(":postgres"))
}

application {
    mainClass.set("io.steward.adapters.host.Main")
    applicationName = "steward-adapter-host"
}
