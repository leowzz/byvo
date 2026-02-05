import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const String kModelAssetName = 'assets/sensevoice/model.int8.onnx';
const String kTokensAssetName = 'assets/sensevoice/tokens.txt';

/// 若 assets 中存在 SenseVoice 模型文件，则复制到应用支持目录并返回该目录路径；否则返回 null。
Future<String?> ensureSenseVoiceModelFromAssets() async {
  final Directory dir = await getApplicationSupportDirectory();
  final String sensevoiceDir = '${dir.path}/sensevoice';
  final Directory sensevoiceDirFile = Directory(sensevoiceDir);
  if (!sensevoiceDirFile.existsSync()) {
    sensevoiceDirFile.createSync(recursive: true);
  }
  final String modelPath = '$sensevoiceDir/model.int8.onnx';
  final String tokensPath = '$sensevoiceDir/tokens.txt';
  if (File(modelPath).existsSync() && File(tokensPath).existsSync()) {
    return sensevoiceDir;
  }
  try {
    final ByteData modelData = await rootBundle.load(kModelAssetName);
    await File(modelPath).writeAsBytes(modelData.buffer.asUint8List());
  } catch (_) {
    return null;
  }
  try {
    final ByteData tokensData = await rootBundle.load(kTokensAssetName);
    await File(tokensPath).writeAsBytes(tokensData.buffer.asUint8List());
  } catch (_) {
    File(modelPath).deleteSync();
    return null;
  }
  return sensevoiceDir;
}
