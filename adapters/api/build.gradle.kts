// `adapters/api`: the Connector interface every adapter implements (doc 08 §3).
// Nothing else in an adapter is public (doc 18 §2).
plugins {
    `java-library`
}

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}
