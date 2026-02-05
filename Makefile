# Flutter 常用命令

.PHONY: get run clean build-apk build-appbundle analyze test

get:
	flutter pub get

run:
	flutter run

clean:
	flutter clean
	flutter pub get

build:
	flutter build apk

build-apk:
	flutter build apk

build-appbundle:
	flutter build appbundle

analyze:
	flutter analyze

test:
	flutter test

# 默认目标
.DEFAULT_GOAL := run
