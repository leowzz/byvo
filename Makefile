# Flutter 常用命令

.PHONY: get run clean build build-apk build-appbundle analyze test

get:
	flutter pub get

run:
	flutter run

clean:
	flutter clean
	flutter pub get

# 仅构建 arm64，避免在 Windows 上为 android-arm 生成 AOT 快照时崩溃 (exit -1073741819)
build:
	flutter build apk --target-platform android-arm64

build-apk:
	flutter build apk --target-platform android-arm64

# 构建所有 ABI（在 Windows 上可能触发 android-arm 快照器崩溃）
build-apk-full:
	flutter build apk

build-appbundle:
	flutter build appbundle

analyze:
	flutter analyze

test:
	flutter test

# 默认目标
.DEFAULT_GOAL := run
