# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

用 [V](https://vlang.io) 编写的 SOCKS4/4a/5 客户端和服务器库，并提供 C ABI 供其他语言调用。

**注意：** V 导入名称为 `import socks`，但二进制文件和仓库名为 `vlang-socks`。

## 功能特性

- SOCKS4、SOCKS4a 和 SOCKS5 支持（客户端和服务器）
- SOCKS5 用户名/密码认证
- UDP 关联（UDP ASSOCIATE）
- 非阻塞事件循环服务器，支持背压、空闲/握手/连接超时和连接数上限
- C ABI (`libsocks`)，包含生成的头文件、pkg-config 文件以及 linux/amd64、linux/arm64 和 windows/amd64 的静态/共享库构建

详见 [LIMITATIONS.md](LIMITATIONS.md) 了解此库在暴露给不受信任客户端前的安全加固情况。

## 快速开始

### 测试（无需构建）

在本地测试库，无需安装任何东西：

```sh
# 使用 Docker（主机仅需 docker + sudo）
make test-all

# 或测试单个模块
make test MODULE=socks5
```

所有测试在 Linux/amd64 和 Linux/arm64 上通过。如果测试失败，请参考 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

## 安装（V）

```sh
v install --git https://github.com/diamonddiver/vlang-socks
```

```v
import socks

cfg := socks.ClientConfig{
	proxy_addr: '127.0.0.1:1080'
	version: .v5
}
mut conn := socks.dial(cfg, 'example.com:80')!
```

## 架构

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

服务器接受 SOCKS4/4a/5 客户端，解析握手协议，拨号目标，并以背压、空闲超时和连接限制进行双向数据中继。详见 [LIMITATIONS.md](LIMITATIONS.md) 了解其不提供的安全加固。

## 服务器示例

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## C ABI

使用 `make lib`（单个目标）或 `make lib-all`（所有支持的目标）构建预构建的静态/共享库加 `socks.h` 和 pkg-config 文件，输出到 `out/<target>/`。参考 `examples/c/main.c` 了解 C 用法，`examples/python/client.py` 了解通过 `ctypes` 的用法。

## 开发

本项目使用容器化 V 工具链，因此主机仅需要 Docker：

```sh
make test MODULE=socks5   # 测试单个模块
make test-all             # 测试所有模块
make vet                  # CI 检查内容（fmt-verify + vet）
make lib                  # 为 linux/amd64 构建 C ABI 库
make lib-all              # 为所有支持的平台构建
make shell                # 用于调试的交互式开发 shell
```

运行 `make help` 查看完整的目标列表。

详见 [CONTRIBUTING.md](CONTRIBUTING.md) 了解平台支持、设置和约定。如果测试失败，请参考 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

### 交叉编译

C 库为 Linux（amd64、arm64）和 Windows（amd64）构建：

```sh
make lib-all              # 为所有三个目标构建
ls out/*/libsocks.*       # 输出到 out/<target>/
```

每个平台的制品位于 `out/<platform>/` 并包含：
- `libsocks.a`（静态库）
- `libsocks.so*`（共享库，仅限 Linux）
- `libsocks.lib` / `libsocks.dll`（Windows 静态/动态库）
- `socks.h`（C API 头文件）
- `socks.pc`（pkg-config 文件）

安装到目标 sysroot：

```sh
make install PREFIX=/path/to/sysroot
```

**注意：** Windows/amd64 二进制文件已构建但未进行运行时测试。Linux 平台已完全测试；macOS 未测试。

生产环境中无裸足。仅用于红队测试，直到它变得流行 💎

## 许可证

MIT，详见 [LICENSE](LICENSE)。
