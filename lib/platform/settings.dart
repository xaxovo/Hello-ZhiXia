/// 本机设置：模型接口地址、密钥、模型名。
///
/// 密钥只保存在本机应用数据目录，不经过任何服务器。代价是它**没有加密** ——
/// 在手机上是应用私有目录，在桌面上是当前用户目录。这一点在设置页里如实写明，
/// 而不是让用户以为它进了系统钥匙串。
library;

import 'dart:convert';
import 'dart:io';

final class LlmSettings {
  const LlmSettings({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-chat',
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  LlmSettings copyWith({String? baseUrl, String? apiKey, String? model}) => LlmSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, Object?> toJson() => {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory LlmSettings.fromJson(Map<String, Object?> json) => LlmSettings(
        baseUrl: (json['baseUrl'] as String?) ?? 'https://api.deepseek.com/v1',
        apiKey: (json['apiKey'] as String?) ?? '',
        model: (json['model'] as String?) ?? 'deepseek-chat',
      );
}

final class SettingsStore {
  SettingsStore(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}${Platform.pathSeparator}settings.json');

  Future<LlmSettings> load() async {
    if (!await _file.exists()) return const LlmSettings();
    try {
      final raw = await _file.readAsString();
      if (raw.trim().isEmpty) return const LlmSettings();
      return LlmSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on FormatException {
      return const LlmSettings();
    }
  }

  Future<void> save(LlmSettings settings) async {
    await directory.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await temp.rename(_file.path);
  }
}
