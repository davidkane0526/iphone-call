# 原生 arm64e 构建包

静态转换版在手机通用 arm64 Python 进程自测成功，但注入实际 SpringBoard 时在 dyld 符号绑定阶段触发 SIGBUS，未获得任何来电回调。该二进制已封存，注入助手已禁止再次注入。短信服务未受影响。

此包仅包含诊断源码、原生 Xcode 构建脚本、ABI 元数据检查器和独立的 iOS arm64e 测试程序。不含手机短信、通话记录、崩溃报告、Bark/SSH 密钥、密码、个人配置或失败的二进制。

## 使用自己的 Mac

需要带 iPhoneOS SDK 的 Xcode。把本包解压到独立目录，然后获取固定版本的 Logos：

```sh
git clone https://github.com/theos/logos.git tooling/logos
git -C tooling/logos checkout 365a4e7028234e90bc2cbc724e5c87607130d3b3
bash build-native.sh
```

产物在 dist/，包括诊断动态库、独立的 iOS 测试程序、哈希和 ABI 检查结果。构建过程不需要手机配置、Apple 开发者证书或任何用户密钥。

## GitHub Actions

工作流支持 workflow_dispatch 手动触发，也会在 main 分支上的诊断源码、构建脚本、ABI 检查器或工作流文件变更时自动构建。首次上传这些文件会触发首轮构建。工作流须位于仓库默认分支才能手动运行。上传和运行前，仍需用户确认具体仓库及授权，当前没有上传或运行。[GitHub 官方手动工作流说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

工作流使用标准 macos-15 runner，仅申请 contents:read，超时 20 分钟，产物保留 7 天。公开仓库的标准 GitHub-hosted runner 计算免费；产物存储按 GitHub 账户规则计量。上传工件目录仅为 dist/。[GitHub 官方计量说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

## 手机端后续门槛

1. 获取原生构建产物并核对 SHA-256，拒绝旧的未版本化 arm64e ABI。
2. 在手机独立的原生 arm64e 进程中运行 NativeSmoke，对加载、指针认证、ARC、block 及合成类方法替换/恢复进行测试。
3. 只有独立进程测试通过并取得用户对新产物的再次测试批准后，才考虑 SpringBoard 注入。
4. 实际来电测试仍然必须证明回调出现在接听或挂断前，不能以通话记录轮询替代。

原生构建只用于排除静态转换兼容问题，不能预先保证注入路径或系统进程兼容性。当前尚未完成原生构建或真实来电验收。
