import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_ui.dart';
import 'cloud_sources.dart';

const String _webDavConfigStorageKey = 'webdav.backup.config.v1';
const String _webDavPasswordKeystoreKey = 'webdav.backup.password.v1';

class WebDavSecretStorage {
  const WebDavSecretStorage._();

  static const MethodChannel channel = MethodChannel(
    'org.mewx.wenku8/cloud_sources',
  );
  static String _memoryFallbackPassword = '';

  @visibleForTesting
  static void resetForTesting() {
    _memoryFallbackPassword = '';
  }

  static Future<String> readPassword() async {
    try {
      final result = await channel.invokeMethod<String>('readSecret', {
        'key': _webDavPasswordKeystoreKey,
      });
      if (result != null) {
        _memoryFallbackPassword = result;
        return result;
      }
    } on MissingPluginException {
      return _memoryFallbackPassword;
    } on PlatformException {
      return _memoryFallbackPassword;
    }
    return _memoryFallbackPassword;
  }

  static Future<void> writePassword(String password) async {
    _memoryFallbackPassword = password;
    try {
      await channel.invokeMethod<void>('writeSecret', {
        'key': _webDavPasswordKeystoreKey,
        'value': password.isEmpty ? null : password,
      });
    } on MissingPluginException {
      // Non-Android test environments fall back to in-memory session storage.
    }
  }
}

@immutable
class WebDavBackupConfig {
  const WebDavBackupConfig({
    this.serverUrl = 'https://dav.jianguoyun.com/dav/',
    this.username = '',
    this.password = '',
    this.remoteFolder = 'shuyu_backup',
    this.autoBackup = false,
  });

  final String serverUrl;
  final String username;
  final String password;
  final String remoteFolder;
  final bool autoBackup;

  bool get isConfigured =>
      serverUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  static bool _hasInvalidSegments(Iterable<String> segments) {
    for (final segment in segments) {
      if (segment == '.' || segment == '..') return true;
      if (segment.runes.any((r) => r < 0x20 || r == 0x7f)) return true;
    }
    return false;
  }

  void validateServerUrl() {
    final raw = serverUrl.trim();
    if (raw.isEmpty) {
      throw const FormatException('WebDAV 服务器地址不能为空');
    }
    final normalizedBase = raw.endsWith('/') ? raw : '$raw/';
    final base = Uri.tryParse(normalizedBase);
    if (base == null || !base.hasAuthority || base.host.isEmpty) {
      throw const FormatException('WebDAV 服务器地址格式无效');
    }
    if (base.isScheme('http')) {
      throw const FormatException('WebDAV 备份仅支持 HTTPS 加密连接，已拒绝明文 HTTP');
    }
    if (!base.isScheme('https')) {
      throw const FormatException('WebDAV 服务器地址必须使用 https:// 协议');
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw const FormatException('WebDAV 服务器地址不能包含账号信息、查询参数或锚点');
    }
    if (_hasInvalidSegments(base.pathSegments)) {
      throw const FormatException('WebDAV 服务器路径包含非法段落');
    }
  }

  Uri? folderUri() {
    final raw = serverUrl.trim();
    if (raw.isEmpty) return null;
    final normalizedBase = raw.endsWith('/') ? raw : '$raw/';
    final base = Uri.tryParse(normalizedBase);
    if (base == null ||
        !base.isScheme('https') ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        _hasInvalidSegments(base.pathSegments)) {
      return null;
    }
    final cleanFolder = remoteFolder.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleanFolder.isEmpty) return base;
    final folderSegments = cleanFolder
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (folderSegments.isEmpty || _hasInvalidSegments(folderSegments)) {
      return null;
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...folderSegments,
        '',
      ],
    );
  }

  Uri? fileUri(String fileName) {
    final folder = folderUri();
    if (folder == null) return null;
    final cleanName = fileName.trim().replaceAll(RegExp(r'^/+'), '');
    if (cleanName.isEmpty ||
        cleanName.contains('/') ||
        cleanName.contains(r'\') ||
        _hasInvalidSegments([cleanName])) {
      return null;
    }
    return folder.replace(
      pathSegments: [
        ...folder.pathSegments.where((s) => s.isNotEmpty),
        cleanName,
      ],
    );
  }

  WebDavBackupConfig copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? remoteFolder,
    bool? autoBackup,
  }) => WebDavBackupConfig(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    remoteFolder: remoteFolder ?? this.remoteFolder,
    autoBackup: autoBackup ?? this.autoBackup,
  );

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'username': username,
    'remoteFolder': remoteFolder,
    'autoBackup': autoBackup,
  };

  factory WebDavBackupConfig.fromJson(
    Map<String, dynamic> json, {
    String? passwordOverride,
  }) => WebDavBackupConfig(
    serverUrl:
        (json['serverUrl'] as String?) ?? 'https://dav.jianguoyun.com/dav/',
    username: (json['username'] as String?) ?? '',
    password: passwordOverride ?? (json['password'] as String?) ?? '',
    remoteFolder: (json['remoteFolder'] as String?) ?? 'shuyu_backup',
    autoBackup: (json['autoBackup'] as bool?) ?? false,
  );

  static WebDavBackupConfig load(SharedPreferences? prefs) {
    final raw = prefs?.getString(_webDavConfigStorageKey);
    if (raw == null || raw.isEmpty) {
      return WebDavBackupConfig(
        password: WebDavSecretStorage._memoryFallbackPassword,
      );
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return WebDavBackupConfig.fromJson(
        decoded,
        passwordOverride:
            (decoded['password'] as String?) ??
            WebDavSecretStorage._memoryFallbackPassword,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('WebDavBackupConfig.load failed: $e');
      return const WebDavBackupConfig();
    }
  }

  static Future<WebDavBackupConfig> loadAsync(SharedPreferences? prefs) async {
    final secretPassword = await WebDavSecretStorage.readPassword();
    final raw = prefs?.getString(_webDavConfigStorageKey);
    if (raw == null || raw.isEmpty) {
      return WebDavBackupConfig(password: secretPassword);
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final legacyPlaintextPassword = decoded['password'] as String?;
      final effectivePassword = secretPassword.isNotEmpty
          ? secretPassword
          : (legacyPlaintextPassword ?? '');
      final config = WebDavBackupConfig.fromJson(
        decoded,
        passwordOverride: effectivePassword,
      );
      if (decoded.containsKey('password')) {
        if (legacyPlaintextPassword != null &&
            legacyPlaintextPassword.isNotEmpty &&
            secretPassword.isEmpty) {
          await WebDavSecretStorage.writePassword(legacyPlaintextPassword);
        }
        await prefs?.setString(
          _webDavConfigStorageKey,
          jsonEncode(config.toJson()),
        );
      }
      return config;
    } catch (e) {
      if (kDebugMode) debugPrint('WebDavBackupConfig.loadAsync failed: $e');
      return WebDavBackupConfig(password: secretPassword);
    }
  }

  Future<void> save(SharedPreferences? prefs) async {
    await WebDavSecretStorage.writePassword(password);
    await prefs?.setString(_webDavConfigStorageKey, jsonEncode(toJson()));
  }
}

/// WebDAV backup client reusing [CloudHttp] and [WebDavBookClient] XML/Auth helpers.
class WebDavBackupClient {
  const WebDavBackupClient(this.config);

  final WebDavBackupConfig config;
  static const int maxResponseBytes = 32 * 1024 * 1024;

  Uri _requireFolder() {
    if (!config.isConfigured) {
      throw const FormatException('请先填写完整的 WebDAV 地址、账号与密码');
    }
    config.validateServerUrl();
    final folder = config.folderUri();
    if (folder == null) throw const FormatException('WebDAV 服务器地址或远程目录格式无效');
    return folder;
  }

  Map<String, String> _headers(Uri uri, Uri base, [Map<String, String>? extra]) => {
    ...WebDavBookClient.basicAuthHeaders(
      uri,
      base,
      config.username.trim(),
      config.password,
    ),
    ...?extra,
  };

  Future<T> _withCloudHttp<T>(Future<T> Function(CloudHttp http, Uri folder) action) async {
    final folder = _requireFolder();
    final http = CloudHttp();
    try {
      return await action(http, folder);
    } on CloudSourceFailure catch (e) {
      throw FormatException(e.message);
    } finally {
      http.close();
    }
  }

  Future<void> _ensureFolder(CloudHttp http, Uri folder) async {
    final res = await http.request(
      'MKCOL',
      folder,
      headers: (u) => _headers(u, folder),
      redirects: true,
      allowedStatuses: const {200, 201, 301, 405},
      authenticationMessage: 'WebDAV 账号或应用密码认证失败（401/403）',
    );
    await res.drain<void>();
  }

  Future<String> uploadBackup(String jsonText) => _withCloudHttp((http, folder) async {
    await _ensureFolder(http, folder);
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final datedFile = 'shuyu-backup-$date.json';
    final payload = utf8.encode(jsonText);
    for (final name in [datedFile, 'shuyu-backup-latest.json']) {
      final uri = config.fileUri(name);
      if (uri == null) throw const FormatException('WebDAV 目标路径无效');
      final res = await http.request(
        'PUT',
        uri,
        headers: (u) => _headers(
          u,
          folder,
          const {'Content-Type': 'application/json; charset=utf-8'},
        ),
        body: payload,
        redirects: true,
      );
      await res.drain<void>();
    }
    return datedFile;
  });

  Future<List<String>> listBackups() => _withCloudHttp((http, folder) async {
    await _ensureFolder(http, folder);
    final res = await http.request(
      'PROPFIND',
      folder,
      headers: (u) => _headers(
        u,
        folder,
        const {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      ),
      body: utf8.encode(WebDavBookClient.propfindBody),
      redirects: true,
    );
    final xml = utf8.decode(
      await http.bytes(res, limit: maxResponseBytes),
      allowMalformed: true,
    );
    final files = <String>{};
    for (final (_, href) in WebDavBookClient.parseMultistatusHrefs(xml)) {
      String decoded;
      try {
        decoded = Uri.decodeFull(href.trim());
      } on ArgumentError {
        continue;
      }
      final parts = decoded.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      final last = parts.last;
      if (last.toLowerCase().endsWith('.json') &&
          !WebDavBackupConfig._hasInvalidSegments([last])) {
        files.add(last);
      }
    }
    return files.toList()..sort((a, b) => b.compareTo(a));
  });

  Future<String> downloadBackup([
    String fileName = 'shuyu-backup-latest.json',
  ]) => _withCloudHttp((http, folder) async {
    final uri = config.fileUri(fileName);
    if (uri == null) throw const FormatException('WebDAV 目标路径无效');
    final res = await http.request(
      'GET',
      uri,
      headers: (u) => _headers(u, folder),
      redirects: true,
    );
    return utf8.decode(
      await http.bytes(res, limit: maxResponseBytes),
      allowMalformed: true,
    );
  });
}

Future<void> showWebDavBackupSheet({
  required BuildContext context,
  required bool reduceMotion,
  required SharedPreferences? preferences,
  required Future<String> Function() createBackupJson,
  required Future<void> Function(String jsonText) onRestoreBackupJson,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  builder: (_) => _WebDavBackupSheet(
    preferences: preferences,
    createBackupJson: createBackupJson,
    onRestoreBackupJson: onRestoreBackupJson,
  ),
);

class _WebDavBackupSheet extends StatefulWidget {
  const _WebDavBackupSheet({
    required this.preferences,
    required this.createBackupJson,
    required this.onRestoreBackupJson,
  });

  final SharedPreferences? preferences;
  final Future<String> Function() createBackupJson;
  final Future<void> Function(String jsonText) onRestoreBackupJson;

  @override
  State<_WebDavBackupSheet> createState() => _WebDavBackupSheetState();
}

class _WebDavBackupSheetState extends State<_WebDavBackupSheet> {
  late WebDavBackupConfig _config = WebDavBackupConfig.load(widget.preferences);
  late final _urlController = TextEditingController(text: _config.serverUrl);
  late final _userController = TextEditingController(text: _config.username);
  late final _passController = TextEditingController(text: _config.password);
  late final _folderController = TextEditingController(text: _config.remoteFolder);
  String? _busy;
  String? _status;
  bool _isError = false;
  List<String> _remoteFiles = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadSecureConfig());
  }

  Future<void> _loadSecureConfig() async {
    final loaded = await WebDavBackupConfig.loadAsync(widget.preferences);
    if (!mounted) return;
    setState(() {
      _config = loaded;
      if (_passController.text.isEmpty && loaded.password.isNotEmpty) {
        _passController.text = loaded.password;
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  Future<WebDavBackupConfig> _saveCurrentConfig() async {
    final next = _config.copyWith(
      serverUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passController.text,
      remoteFolder: _folderController.text.trim().isEmpty
          ? 'shuyu_backup'
          : _folderController.text.trim(),
    );
    _config = next;
    await next.save(widget.preferences);
    return next;
  }

  Future<void> _runTask(String label, Future<void> Function() task) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _status = null;
      _isError = false;
    });
    try {
      await task();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _status = e.message;
          _isError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '连接 WebDAV 失败，请检查网络、服务器地址或应用密码';
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'WebDAV 云端备份与同步',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                GlassTextButton(
                  onPressed: () =>
                      _urlController.text = 'https://dav.jianguoyun.com/dav/',
                  child: const Text('填入坚果云地址', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '支持坚果云、Nextcloud、Alist / OpenList 等标准 WebDAV 网盘，将书架、阅读进度、书签与净化规则一键备份到云端。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('webdav-url-input'),
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '服务器地址 (Server URL)',
                hintText: 'https://dav.jianguoyun.com/dav/',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('webdav-user-input'),
                    controller: _userController,
                    decoration: const InputDecoration(
                      labelText: '账号 (Username)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey('webdav-pass-input'),
                    controller: _passController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '应用密码 (Password)',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webdav-folder-input'),
              controller: _folderController,
              decoration: const InputDecoration(
                labelText: '远程备份目录',
                hintText: 'shuyu_backup',
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                GlassTextButton(
                  key: const ValueKey('webdav-backup-upload'),
                  onPressed: _busy == null
                      ? () => _runTask('正在上传备份到 WebDAV…', () async {
                          final client = WebDavBackupClient(await _saveCurrentConfig());
                          final fileName = await client.uploadBackup(
                            await widget.createBackupJson(),
                          );
                          final files = await client.listBackups();
                          if (mounted) {
                            setState(() {
                              _remoteFiles = files;
                              _status = '已成功备份至云端：$fileName';
                            });
                          }
                        })
                      : null,
                  child: const Text('立即备份到 WebDAV'),
                ),
                GlassTextButton(
                  key: const ValueKey('webdav-backup-restore'),
                  onPressed: _busy == null
                      ? () => _runTask('正在从 WebDAV 读取最新备份…', () async {
                          final client = WebDavBackupClient(await _saveCurrentConfig());
                          final files = await client.listBackups();
                          if (files.isEmpty) {
                            throw const FormatException('云端目录中暂无备份文件');
                          }
                          final target = files.contains('shuyu-backup-latest.json')
                              ? 'shuyu-backup-latest.json'
                              : files.first;
                          final jsonText = await client.downloadBackup(target);
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          await widget.onRestoreBackupJson(jsonText);
                        })
                      : null,
                  child: const Text('从 WebDAV 恢复最新备份'),
                ),
                GlassTextButton(
                  key: const ValueKey('webdav-list-files'),
                  onPressed: _busy == null
                      ? () => _runTask('正在获取云端备份列表…', () async {
                          final files = await WebDavBackupClient(
                            await _saveCurrentConfig(),
                          ).listBackups();
                          if (mounted) {
                            setState(() {
                              _remoteFiles = files;
                              _status = files.isEmpty
                                  ? '连接成功，云端目录暂无历史备份'
                                  : '已获取 ${files.length} 个云端备份文件';
                            });
                          }
                        })
                      : null,
                  child: const Text('刷新云端列表'),
                ),
              ],
            ),
            if (_busy != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _busy!,
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _status!,
                  key: const ValueKey('webdav-status-text'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _isError ? scheme.error : scheme.primary,
                  ),
                ),
              ),
            if (_remoteFiles.isNotEmpty) ...[
              const Divider(height: 22),
              Text(
                '云端备份文件（点击可读取并预览恢复）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final file in _remoteFiles.take(8))
                GlassTextButton(
                  onPressed: _busy == null
                      ? () => _runTask('正在下载 $file…', () async {
                          final jsonText = await WebDavBackupClient(
                            await _saveCurrentConfig(),
                          ).downloadBackup(file);
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          await widget.onRestoreBackupJson(jsonText);
                        })
                      : null,
                  child: Row(
                    children: [
                      const ArchiveIcon(Icons.cloud_download_outlined, size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(file, style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
