# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

[V](https://vlang.io) で書かれた SOCKS4/4a/5 クライアントおよびサーバーライブラリで、他の言語から使用するための C ABI を提供します。

**注意:** V のインポート名は `import socks` ですが、バイナリおよびリポジトリ名は `vlang-socks` です。

完璧な「絶対領域」と同じように、このコードの各部分は正確に配置されています。スカート、肌、ソックス — セキュリティ実装の美学。💎

## 機能

- SOCKS4、SOCKS4a、SOCKS5 対応（クライアント・サーバー両対応）
- SOCKS5 ユーザー名/パスワード認証
- UDP ASSOCIATE
- バックプレッシャー、アイドル/ハンドシェイク/接続タイムアウト、接続数上限を備えたノンブロッキングイベントループサーバー
- C ABI (`libsocks`)：生成されたヘッダー、pkg-config ファイル、linux/amd64、linux/arm64、windows/amd64 の静的/共有ライブラリビルド

信頼できないクライアントに公開する前に、このライブラリが何を強化し、何を強化しないかについては [LIMITATIONS.md](LIMITATIONS.md) を参照してください。

## クイックスタート

### テスト（ビルド不要）

ライブラリをローカルでテストします。何もインストールする必要はありません：

```sh
# Docker を使用（ホストには docker + sudo のみ必要）
make test-all

# または単一のモジュールをテスト
make test MODULE=socks5
```

すべてのテストは Linux/amd64 および Linux/arm64 で合格します。テストが失敗した場合は、[TROUBLESHOOTING.md](TROUBLESHOOTING.md) を参照してください。

## インストール（V）

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

## アーキテクチャ

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

サーバーは SOCKS4/4a/5 クライアントを受け入れ、ハンドシェイクを解析し、ターゲットに接続して、バックプレッシャー、アイドルタイムアウト、接続制限を備えた双方向データリレーを行います。強化されていない部分については、[LIMITATIONS.md](LIMITATIONS.md) を参照してください。

## サーバーの例

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## C ABI

`make lib`（単一ターゲット）または `make lib-all`（すべてのサポートされているターゲット）を使用して、事前ビルドされた静的/共有ライブラリ、`socks.h`、および pkg-config ファイルをビルドします。出力は `out/<target>/` です。C からの使用方法については `examples/c/main.c` を、`ctypes` 経由での使用方法については `examples/python/client.py` を参照してください。

## 開発

このプロジェクトはコンテナ化された V ツールチェーンを使用しているため、ホストに必要なのは Docker だけです：

```sh
make test MODULE=socks5   # 単一モジュールをテスト
make test-all             # すべてのモジュールをテスト
make vet                  # CI チェック（fmt-verify + vet）
make lib                  # linux/amd64 の C ABI ライブラリをビルド
make lib-all              # サポートされているすべてのプラットフォーム用にビルド
make shell                # デバッグ用のインタラクティブ開発シェル
```

完全なターゲットリストは `make help` を実行して確認してください。

プラットフォーム対応、セットアップ、規約については [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。テストが失敗した場合は [TROUBLESHOOTING.md](TROUBLESHOOTING.md) を参照してください。

### クロスコンパイル

C ライブラリは Linux（amd64、arm64）および Windows（amd64）用にビルドされます：

```sh
make lib-all              # 3 つのターゲットすべてをビルド
ls out/*/libsocks.*       # 出力は out/<target>/
```

各プラットフォームの成果物は `out/<platform>/` にあり、以下を含みます：
- `libsocks.a`（静的ライブラリ）
- `libsocks.so*`（共有ライブラリ、Linux のみ）
- `libsocks.lib` / `libsocks.dll`（Windows の静的/動的ライブラリ）
- `socks.h`（C API ヘッダー）
- `socks.pc`（pkg-config ファイル）

ターゲット sysroot にインストール：

```sh
make install PREFIX=/path/to/sysroot
```

**注意:** Windows/amd64 バイナリはビルドされていますが、ランタイムテストは実施されていません。Linux プラットフォームは完全にテストされています；macOS はテストされていません。

本番環境では素足厳禁。ポピュラーになるまでは赤チーム専用 💎

## ライセンス

MIT、[LICENSE](LICENSE) を参照してください。
