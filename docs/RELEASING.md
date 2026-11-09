# 书屿构建与发布

开发环境：Flutter 3.41.5 / Dart 3.11.3、JDK 17。

## 日常验证

主分支提交与 PR 执行静态检查、Flutter 测试和 Python 工具测试。主分支还使用固定证书构建 ARM64 APK，见 Build Local APK 的 Artifacts。PR 不接触签名密钥。

## 正式发布

1. 同步更新 `pubspec.yaml`、`lib/updates/app_updates.dart` 中的版本、构建号及说明，以及 `CHANGELOG.md`。遵循标准语义化版本号（SemVer），构建号必须严格大于已发布版本。
2. 配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 四项签名 Secrets，以及经核实授权的 `ANDROID_API_RUNTIME_ARM64_BASE64` 运行库 Secret。使用现有长期密钥，保留安全备份。
3. 执行 `flutter pub get`、`flutter analyze`、`flutter test` 和 Python 工具测试。
4. 将包含 `pubspec.yaml` 版本更新的提交推送到 `main` 分支（或在 Actions 中手动运行 `Prepare Release`，可指定 `main` 或匹配版本的 `v*` 标签）。`Prepare Release` 会验证版本、注入并校验 `libcpp.so`、构建固定签名的 ARM64 APK、校验同包名升级身份、导出匹配源码并创建草稿 Release（`--draft`）。
5. 检查草稿附件、许可条件与真机覆盖安装效果后，在 GitHub 手动发布草稿。只有已发布的正式 Release 会进入应用更新检查；工作流不直接监听 tag push，避免发布草稿生成标签时重复触发构建。

主分支 `pubspec.yaml` 推送及手动触发均只创建草稿（`gh release create --draft`），不会直接公开正式版。已有同名 Release（包括草稿）时创建步骤会失败，不会替换已有附件。需要修订附件时增加构建号，生成新的版本与标签。

`Prepare Release` 在创建草稿前使用 Android SDK 验证候选 APK 与已发布的同包名基准版 `v1.8.14+61`（`shuyu-v1.8.14+61-arm64-v8a.apk`，包名均为 `app.shuyu.reader`）的实际包名和签名证书一致，且版本与本次配置匹配、构建号递增，同时通过 `tools/verify_apk_runtime.py` 检查最终 APK 内嵌的 `lib/arm64-v8a/libcpp.so` 未缺失且未被剥离符号。基准包下载失败、运行库缺失、签名无效或身份不兼容时停止发布。该检查不替代真机数据与覆盖安装验收。

## 应用身份与签名

当前应用包名（`applicationId` / `namespace`）为 `app.shuyu.reader`，Flutter 项目包名为 `shuyu`（`v1.8.2+49` 及更早历史版本使用旧包名 `org.mewx.wenku8_flutter`）。由于 Android 将不同 `applicationId` 视为独立应用，旧包名 `org.mewx.wenku8_flutter` 的安装无法通过相同签名直接原地覆盖升级到 `app.shuyu.reader`，其私有目录数据也不会自动迁移；仅 `app.shuyu.reader` 各版本之间支持原地覆盖升级。正式构建缺少签名配置时失败；调试使用独立后缀。新建证书无法覆盖旧证书的安装。

更新源默认 `sushi342119/Shuyu`；工作流明确传入当前仓库。APK 安装前验证包名、版本和签名。

发布附件使用 `shuyu-<标签>-arm64-v8a.apk` 命名；更新器同时兼容 `shuyu-` 与历史 `wenku8-` 前缀及对应 ABI 后缀。

### 发布前兼容性验收

1. 下载基准正式 APK 和候选 APK，使用 Android SDK 的 `apkanalyzer manifest application-id`、`apkanalyzer manifest version-code` 读取包名与构建号，使用 `apksigner verify --verbose --print-certs` 验证签名并记录证书 SHA-256 指纹。候选包必须使用 `app.shuyu.reader` 和现有发布证书，构建号严格增加。不得用 APK 文件本身的 SHA-256 摘要代替证书指纹。
2. 历史书屿 APK 与上游 APK 的证书分别核对；固定使用同一套 Secrets 不等于已证明与上游签名隔离。不得为隔离上游直接新建或替换发布证书。历史临时签名安装需单独验证。
3. 在测试设备安装正式旧版，导入 TXT、EPUB、PDF，建立书架、阅读进度、书签和标签并导出备份；随后直接覆盖安装候选包，不卸载、不清除数据。检查上述记录、小说正文、文件夹授权、重启后读取、备份导出与恢复以及应用内更新。
4. 验收完成后才手动发布草稿；未完成的证书或真机检查应明确记录，不能仅凭构建和单元测试通过声称升级兼容。

### 备份与换包限制

普通 JSON 备份包含书架、书籍元数据快照（`novel_meta_<id>`）、阅读进度、书签批注、标签及阅读设置，不包含本地书库 `local_books/index.json`、ID 分配状态 `local_library_next`、小说原书文件或离线正文缓存，也不能转移 Android 文件夹授权。

更换 `applicationId` 或在新设备安装会创建独立应用，新应用不能自动读取旧应用的私有数据。重新扫描本地文件夹可能分配新的本地书籍数字 ID；恢复备份时，若目标设备已导入并扫描同书名与作者的本地书籍，备份恢复会按 `novel_meta_<id>` 中的书名与作者自动将进度、书签、书架与标签重映射到新本地书籍 ID，并跳过与其它无关本地书发生 ID 冲突的未导入记录。但备份本身仍不携带原书文件，跨包名或跨设备恢复前需先重新授权并扫描导入对应原书文件。

外部小说文件可以仍然存在，但新应用需要重新授权；旧应用私有目录中的原书、导入副本和正文不能自动接管。不要在迁移实现并验收前引导用户卸载旧应用或清除数据，这可能删除仅存于旧应用专属目录的文件。系统备份和设备迁移也不能作为跨包名恢复的保证。

## 第三方组件

保留 `LICENSE`、`NOTICE`、`assets/licenses`、字体许可与修改说明。公开源码仓库默认不跟踪闭源二进制 `android/app/src/main/jniLibs/<abi>/libcpp.so`，其独立授权依据需由维护者核实并留存；不能把工程源码归档描述成该二进制的完整对应源码。维护者在核实授权后可通过本地放置该文件或配置 `ANDROID_API_RUNTIME_ARM64_BASE64` Secret 供 CI 注入，并由 `tools/verify_apk_runtime.py` 校验最终 APK。参见 [THIRD_PARTY.md](THIRD_PARTY.md)。仅源码审阅可用 `tools/export_public_source.py` 的 `--source-only` 参数导出。
