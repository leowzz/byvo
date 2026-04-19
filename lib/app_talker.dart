import 'package:flutter/foundation.dart';
import 'package:talker/talker.dart';

final Talker appTalker = Talker();

void logDebug(String message) {
  if (!kDebugMode) return;
  appTalker.debug(message);
}

void logInfo(String message) {
  if (!kDebugMode) return;
  appTalker.info(message);
}

void logWarning(String message) {
  if (!kDebugMode) return;
  appTalker.warning(message);
}

void logError(
  Object error, [
  StackTrace? stackTrace,
  String? message,
]) {
  if (!kDebugMode) return;
  appTalker.handle(error, stackTrace, message);
}
