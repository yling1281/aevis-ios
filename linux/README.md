# Aevis Linux 资源包

App 启动时会从下面三条线路并行测速，选最快的一条拉 `manifest.json`：

- `https://raw.githubusercontent.com/yling1281/aevis-ios/main/linux/manifest.json`
- `https://cdn.jsdelivr.net/gh/yling1281/aevis-ios@main/linux/manifest.json`
- `https://ghproxy.net/https://raw.githubusercontent.com/yling1281/aevis-ios/main/linux/manifest.json`

## 目录

- `manifest.json`：资源清单（版本、ABI、大小、sha256、多镜像）
- `aevis-rootfs-arm64.zip`：rootfs 包（当前还没上传）

## 发布流程

1. 把 rootfs 打成 zip，根目录直接是 `bin/ etc/ usr/ …`，不要多套一层。
2. 文件小于 100 MB 可以直接放本目录；超过 100 MB 用 Release 资产：
   `https://github.com/yling1281/aevis-ios/releases/download/linux-v1/aevis-rootfs-arm64.zip`
3. 算 `sha256sum aevis-rootfs-arm64.zip` 和字节数。
4. 更新 `manifest.json` 的 `version`、`size`、`sha256`、`mirrors`。
5. 提交后等 1-2 分钟 jsDelivr 缓存刷新。

## manifest 规则

- `arch`: `arm64` / `arm` / `x86_64` / `any`
- `kind`: `rootfs` 会交给安装器解压；`asset` 落到 `files/resources/`
- `required: true` 的资源会在首次启动时全部下完
- `sha256` 为空则跳过校验；正式包必须填
- `size` 用于进度条；未知填 0
