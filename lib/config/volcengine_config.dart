import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// 火山引擎豆包 API 凭证，运行时优先从 [FlutterSecureStorage] 读取，不入库、不打包。
class VolcengineCredentials {
  const VolcengineCredentials({
    required this.appKey,
    required this.accessKey,
    required this.resourceId,
  });

  final String appKey;
  final String accessKey;
  final String resourceId;

  bool get isValid =>
      appKey.isNotEmpty && accessKey.isNotEmpty && resourceId.isNotEmpty;
}

const String _keyAppKey = 'volc_app_key';
const String _keyAccessKey = 'volc_access_key';
const String _keyResourceId = 'volc_resource_id';

const FlutterSecureStorage _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// 从安全存储读取豆包凭证；若未配置且为 Debug，尝试从应用支持目录的 volcengine.json 读取。
Future<VolcengineCredentials> loadVolcengineCredentials() async {
  final String? appKey = await _storage.read(key: _keyAppKey);
  final String? accessKey = await _storage.read(key: _keyAccessKey);
  final String? resourceId = await _storage.read(key: _keyResourceId);

  if (appKey != null &&
      appKey.isNotEmpty &&
      accessKey != null &&
      accessKey.isNotEmpty &&
      resourceId != null &&
      resourceId.isNotEmpty) {
    return VolcengineCredentials(
      appKey: appKey,
      accessKey: accessKey,
      resourceId: resourceId,
    );
  }

  if (kDebugMode) {
    final VolcengineCredentials? fromFile = await _loadFromFileInDebug();
    if (fromFile != null && fromFile.isValid) return fromFile;
  }

  return const VolcengineCredentials(
    appKey: '',
    accessKey: '',
    resourceId: '',
  );
}

/// Debug 下从 [getApplicationSupportDirectory]/volcengine.json 读取（开发者可手动放置，不随包分发）。
Future<VolcengineCredentials?> _loadFromFileInDebug() async {
  try {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File('${dir.path}/volcengine.json');
    if (!await file.exists()) return null;
    final String raw = await file.readAsString();
    final Map<String, dynamic> json =
        jsonDecode(raw) as Map<String, dynamic>;
    return VolcengineCredentials(
      appKey: (json['app_key'] as String?) ?? '',
      accessKey: (json['access_key'] as String?) ?? '',
      resourceId: (json['resource_id'] as String?) ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// 将豆包凭证写入安全存储（设置页保存时调用）。
Future<void> saveVolcengineCredentials(VolcengineCredentials cred) async {
  await _storage.write(key: _keyAppKey, value: cred.appKey);
  await _storage.write(key: _keyAccessKey, value: cred.accessKey);
  await _storage.write(key: _keyResourceId, value: cred.resourceId);
}
