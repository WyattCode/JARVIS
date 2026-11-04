#!/usr/bin/env bash
# Source this file for the Spark-only, isolated Android build environment.
export JAVA_HOME=/home/wyatt/.local/opt/jarvis-android-host/usr/lib/jvm/java-21-openjdk-arm64
export ANDROID_HOME=/home/wyatt/.local/opt/jarvis-android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_USER_HOME=/home/wyatt/.local/state/jarvis-android-gradle
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

export JARVIS_SIGNING_PROPERTIES=/home/wyatt/.local/share/jarvis-android-signing/signing.properties
