import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:mtbbs/core/app/app_capabilities.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// 非图片文件保存结果
enum FileSaveOutcome { saved, canceled, unavailable, failed }

/// 非图片文件「另存为」/「选择目录」适配器。
///
/// **唯一** 供非图片文件 import `file_picker.saveFile/getDirectoryPath`
/// 的地方（图片见 `image_save.dart`，选择文件见 `file_pick.dart`）。
/// 插件无当前平台实现时返回 [FileSaveOutcome.unavailable] 并关闭能力开关。
abstract final class FileSave {
  FileSave._();

  /// Android / iOS 的「另存为」由原生侧完成写入，Dart 侧不能再写一遍。
  ///
  /// `file_picker` 在这两个平台上：
  /// - **强制要求** `bytes` 非空（否则抛 `ArgumentError`，见
  ///   `file_picker_io.dart` 的 `saveFile`），因为写盘是原生做的；
  /// - 原生 `ACTION_CREATE_DOCUMENT` 拿到用户选的 `Uri` 后自己
  ///   `openOutputStream(uri).write(bytes)`；
  /// - 回传的「路径」只是 `Downloads/文件名` 这种**推测值**，不是真实
  ///   落盘位置（用户可能在 SAF 里选了任意目录），Dart 侧按它写盘会在
  ///   分区存储下直接 Permission denied。
  ///
  /// 所以移动端必须传 bytes，且成功后不再回写。
  static bool get _nativeWritesBytes => Platform.isAndroid || Platform.isIOS;

  /// 选择保存路径并写入文本（导出 JSON 等）
  static Future<FileSaveOutcome> saveText(
    String content, {
    required String fileName,
    String dialogTitle = '保存文件',
    List<String>? allowedExtensions,
  }) => _save(
    Uint8List.fromList(utf8.encode(content)),
    fileName: fileName,
    dialogTitle: dialogTitle,
    allowedExtensions: allowedExtensions,
  );

  /// 选择保存路径并写入二进制
  static Future<FileSaveOutcome> saveBytes(
    Uint8List bytes, {
    required String fileName,
    String dialogTitle = '保存文件',
    List<String>? allowedExtensions,
  }) => _save(
    bytes,
    fileName: fileName,
    dialogTitle: dialogTitle,
    allowedExtensions: allowedExtensions,
  );

  /// 选择保存路径并把已有文件复制过去（原始缓存库备份）
  ///
  /// 统一按字节读取后走 [_save]：Android 侧只能靠 bytes 落盘，
  /// 直接 `File.copy` 到插件回传的推测路径必然失败。
  static Future<FileSaveOutcome> copyFile(
    String sourcePath, {
    required String fileName,
    String dialogTitle = '保存文件',
    List<String>? allowedExtensions,
  }) async {
    final Uint8List bytes;
    try {
      bytes = await File(sourcePath).readAsBytes();
    } catch (e) {
      AppLogger.w('PAGE', '读取待复制文件失败：$e');
      return FileSaveOutcome.failed;
    }
    return _save(
      bytes,
      fileName: fileName,
      dialogTitle: dialogTitle,
      allowedExtensions: allowedExtensions,
    );
  }

  /// 选择目录（导出原始文件的伴随文件时使用）；取消返回 null
  static Future<String?> pickDirectory({String dialogTitle = '选择目录'}) async {
    if (!AppCapabilities.isAvailable(AppCapability.filePicker)) return null;
    try {
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
    } on MissingPluginException {
      AppLogger.w('PAGE', 'file_picker 无当前平台实现');
      AppCapabilities.disable(AppCapability.filePicker);
      return null;
    } on UnimplementedError {
      AppLogger.w('PAGE', 'file_picker 无当前平台实现');
      AppCapabilities.disable(AppCapability.filePicker);
      return null;
    } catch (e) {
      AppLogger.w('PAGE', '选择目录失败：$e');
      return null;
    }
  }

  /// 弹「另存为」并把 [bytes] 落盘。
  ///
  /// 桌面端插件只返回路径、由本方法写盘；移动端由原生写盘，本方法跳过回写。
  static Future<FileSaveOutcome> _save(
    Uint8List bytes, {
    required String fileName,
    required String dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    if (!AppCapabilities.isAvailable(AppCapability.filePicker)) {
      return FileSaveOutcome.unavailable;
    }
    final String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: allowedExtensions == null || allowedExtensions.isEmpty
            ? FileType.any
            : FileType.custom,
        allowedExtensions: allowedExtensions,
        // 移动端必传（原生据此写盘）；桌面端忽略该参数
        bytes: bytes,
      );
    } on MissingPluginException {
      AppLogger.w('PAGE', 'file_picker.saveFile 无当前平台实现');
      AppCapabilities.disable(AppCapability.filePicker);
      return FileSaveOutcome.unavailable;
    } on UnimplementedError {
      AppLogger.w('PAGE', 'file_picker.saveFile 无当前平台实现');
      AppCapabilities.disable(AppCapability.filePicker);
      return FileSaveOutcome.unavailable;
    } catch (e) {
      AppLogger.w('PAGE', '另存为失败：$e');
      return FileSaveOutcome.failed;
    }

    // 用户取消（含移动端原生 RESULT_CANCELED 回传的 null）
    if (path == null || path.isEmpty) return FileSaveOutcome.canceled;

    // 移动端：原生已写入用户选择的 Uri，按回传路径再写会失败
    if (_nativeWritesBytes) return FileSaveOutcome.saved;

    try {
      await File(path).writeAsBytes(bytes);
      return FileSaveOutcome.saved;
    } catch (e) {
      AppLogger.w('PAGE', '写入文件失败：$e');
      return FileSaveOutcome.failed;
    }
  }
}
