# 发布流程

本文是「从一个可运行的源码到 GitHub 上可下载的 Release」的完整步骤。仓库里的
`tool/pack_archive.py` 与根目录的 `.bat` 只是本地辅助，**发布判断标准以 `flutter test` 与
`flutter build` 的实际输出为准**。

## 一、版本号规则

- 功能版本：`1.51.0`（新增账号名）→ 小版本号 +1
- 缺陷修复：`1.51.1`（修 1.51 的 bug，行为不变）
- 协议版本独立演进：`pnote-sync/8`。**协议主版本变化时两端必须一起升级**，Release 说明里要写清楚

`pubspec.yaml` 的 `version` 同时决定 Windows 文件版本与 Android `versionName`/`versionCode`：

```yaml
version: 1.51.0+15100   # 语义版本 + 构建号（Android 靠 +N 判断升级）
```

每次发版 `+N` 必须比上一个安装包大，否则 Android 不允许覆盖安装。

## 二、发布前检查

```bash
flutter pub get
flutter analyze          # 必须 No issues found
flutter test             # 必须全部通过（当前 354 条）
```

同时确认：

- [ ] `docs/CHANGELOG.md` 顶部有新版本小节（写「用户能看到的变化」，不写内部重构流水账）
- [ ] `README.md` 的特性/限制没有过期
- [ ] `pubspec.yaml` 的 `version` 已改，且构建号比上一版大
- [ ] 协议有变化时，`docs/SYNC-PROTOCOL.md` 与 Release 说明都写了「两端必须同版本」
- [ ] `git status` 干净，CI 在 `main` 上是绿的（README 顶部有徽章）

## 三、构建两个安装包

Windows（产物在 `build/windows/x64/runner/Release/`）：

```bash
flutter build windows --release
```

打包成 zip（保持目录结构，解压即用）：

```powershell
Compress-Archive -Path 'build\windows\x64\runner\Release\*' `
                 -DestinationPath "PNote-<版本>-windows-x64.zip"
```

Android（arm64 覆盖绝大多数手机；v7a 给老机器）：

```bash
flutter build apk --release --split-per-abi
```

产物：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。发布时改名为
`PNote-<版本>-android-arm64-v8a.apk`，方便人看。

> 构建前记得设置 `FLUTTER_STORAGE_BASE_URL` / `PUB_HOSTED_URL`（国内网络）与
> `ANDROID_HOME` / `JAVA_HOME`，细节见 [BUILD.md](BUILD.md)。

记录校验和（写进 Release 说明，方便别人核对）：

```powershell
Get-FileHash PNote-<版本>-windows-x64.zip -Algorithm SHA256
Get-FileHash PNote-<版本>-android-arm64-v8a.apk -Algorithm SHA256
```

## 四、提交与打标签

```bash
git add -A
git commit -m "release: <版本>"
git push origin main
git tag -a v<版本> -m "PNote <版本> - <一句话主题>"
git push origin v<版本>
```

标签名统一 `v` + 语义版本（`v1.51.0`），Release 会自动关联到它对应的提交。

## 五、创建 Release（网页操作）

1. 打开 <https://github.com/ZhanJN/PNote/releases/new>
2. **Choose a tag** 选刚推上去的 `v1.51.0`（若没有就手填，GitHub 会在发布时创建）
3. **Release title**：`PNote 1.51.0 — 账号名（同步分组）`
4. **Describe this release**：写三段即可
   - 这一版多了什么（用户视角）
   - 怎么装（Windows 解压双击 / Android 直接装）
   - 兼容性（协议版本、要不要两端一起升）、SHA-256
5. 把两个安装包拖进 **Attach binaries**（zip 与 apk）
6. 保持 **Set as the latest release**；不要勾 pre-release（除非是测试版）
7. 点 **Publish release**

## 六、创建 Release（命令行，等价操作）

装好 [GitHub CLI](https://cli.github.com/) 并 `gh auth login` 之后：

```bash
gh release create v1.51.0 \
  --title "PNote 1.51.0 — 账号名（同步分组）" \
  --notes-file docs/release-notes/1.51.0.md \
  PNote-1.51.0-windows-x64.zip \
  PNote-1.51.0-android-arm64-v8a.apk
```

没有 `gh` 时也可以用 REST API（需要 `repo` 权限的 token）：

```bash
curl -X POST -H "Authorization: token $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/ZhanJN/PNote/releases \
     -d @release.json         # {"tag_name":"v1.51.0","name":"...","body":"...","draft":false}

curl -X POST -H "Authorization: token $TOKEN" \
     -H "Content-Type: application/zip" \
     --data-binary @PNote-1.51.0-windows-x64.zip \
     "https://uploads.github.com/repos/ZhanJN/PNote/releases/<release_id>/assets?name=PNote-1.51.0-windows-x64.zip"
```

## 七、发布后

- 打开 Release 页面确认两个资产都能下载、大小与上面记录一致
- 确认 `main` 的 CI 仍是绿的（README 徽章来自 `.github/workflows/ci.yml`）
- 本地归档副本用 `tool/pack_archive.py` 重建（它做清单 + SHA-256 校验，见 README「构建」一节）
- 把「下一个版本要做什么」记进 `docs/CHANGELOG.md` 的待办或 issue

## 八、常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `push` 报 `schannel: server closed abruptly` | 走了 gh-proxy 之类的只读镜像，或系统代理没开 | 检查 `git remote -v` 别用镜像地址；必要时设 `HTTPS_PROXY` |
| `! [rejected] main -> main (fetch first)` | 远端有 GitHub 自动生成的初始提交 | `git pull --rebase origin main` 后重推，或确认要覆盖时用 `--force-with-lease` |
| `flutter build apk` 报 `No Android SDK found` | 没设 `ANDROID_HOME` | 见 [BUILD.md](BUILD.md) |
| Windows 包双击打不开、或数据库报错 | 放在「工作区/低完整性」目录里运行 | 挪到普通目录（例如 `D:\PNote`）再运行 |
| 新版本装不上手机 | `versionCode` 没变大 | 改 `pubspec.yaml` 的 `+N` |
