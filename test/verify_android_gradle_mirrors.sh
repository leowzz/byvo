#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

forbidden_pattern='google\(\)|mavenCentral\(\)|gradlePluginPortal\(\)'
files="$ROOT_DIR/android/settings.gradle $ROOT_DIR/android/build.gradle"

if rg -n "$forbidden_pattern" $files >/dev/null; then
  echo "Forbidden direct Gradle repositories found in Android build config." >&2
  rg -n "$forbidden_pattern" $files >&2
  exit 1
fi

required_repos='https://maven.aliyun.com/repository/google|https://maven.aliyun.com/repository/central|https://maven.aliyun.com/repository/gradle-plugin'

if ! rg -n "$required_repos" $files >/dev/null; then
  echo "Expected mirror repositories are missing from Android build config." >&2
  exit 1
fi

echo "Android Gradle mirror configuration looks correct."
