// `adapters/postgres`: the M0 Postgres connector (doc 08 §5.1, §5.2).
plugins {
    `java-library`
}

dependencies {
    api(project(":api"))
    implementation(libs.hikaricp)
    implementation(libs.postgresql)
    implementation(libs.slf4j.api)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.jqwik)
    testRuntimeOnly(libs.junit.platform.launcher)
}
