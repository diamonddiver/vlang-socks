# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

[V](https://vlang.io)로 작성된 SOCKS4/4a/5 클라이언트 및 서버 라이브러리로, 다른 언어에서 사용할 수 있는 C ABI를 제공합니다.

**참고:** V 임포트는 `import socks`이지만, 바이너리와 리포지토리는 `vlang-socks`로 명명되어 있습니다.

## 기능

- SOCKS4, SOCKS4a, SOCKS5 지원 (클라이언트 및 서버)
- SOCKS5 사용자 이름/비밀번호 인증
- UDP ASSOCIATE
- 백프레셔, 유휴/핸드셰이크/연결 타임아웃 및 연결 제한을 갖춘 논블로킹 이벤트 루프 서버
- C ABI (`libsocks`) - 생성된 헤더, pkg-config 파일, linux/amd64, linux/arm64, windows/amd64의 정적/공유 라이브러리 빌드 포함

신뢰할 수 없는 클라이언트에 노출하기 전에 이 라이브러리가 무엇을 강화하고 무엇을 강화하지 않는지 [LIMITATIONS.md](LIMITATIONS.md)를 참조하세요.

## 빠른 시작

### 테스트 (빌드 필요 없음)

아무것도 설치하지 않고 로컬에서 라이브러리를 테스트하세요:

```sh
# Docker 사용 (호스트는 docker + sudo만 필요)
make test-all

# 또는 한 개 모듈 테스트
make test MODULE=socks5
```

모든 테스트는 Linux/amd64 및 Linux/arm64에서 통과합니다. 테스트가 실패하면 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)를 참조하세요.

## 설치 (V)

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

## 아키텍처

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

서버는 SOCKS4/4a/5 클라이언트를 수락하고 핸드셰이크를 파싱하며 대상에 다이얼하고 백프레셔, 유휴 타임아웃, 연결 제한을 포함한 양방향 데이터 릴레이를 수행합니다. [LIMITATIONS.md](LIMITATIONS.md)를 참조하여 강화되지 않는 부분을 확인하세요.

## 서버 예제

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## C ABI

`make lib` (단일 대상) 또는 `make lib-all` (모든 지원 대상)을 사용하여 사전 구축된 정적/공유 라이브러리와 `socks.h` 및 pkg-config 파일을 빌드하고 `out/<target>/`으로 출력합니다. C 사용법은 `examples/c/main.c`를 참조하고 `ctypes`를 통한 사용법은 `examples/python/client.py`를 참조하세요.

## 개발

이 프로젝트는 컨테이너화된 V 도구 체인을 사용하므로 호스트는 Docker만 필요합니다:

```sh
make test MODULE=socks5   # 한 모듈 테스트
make test-all             # 모든 모듈 테스트
make vet                  # CI가 확인하는 것 (fmt-verify + vet)
make lib                  # linux/amd64용 C ABI 라이브러리 빌드
make lib-all              # 지원되는 모든 플랫폼용으로 빌드
make shell                # 디버깅용 대화형 개발 셸
```

완전한 대상 목록을 보려면 `make help`를 실행하세요.

플랫폼 지원, 설정 및 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)를 참조하세요. 테스트가 실패하면 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)를 참조하세요.

### 크로스 컴파일

C 라이브러리는 Linux (amd64, arm64) 및 Windows (amd64)용으로 빌드됩니다:

```sh
make lib-all              # 세 가지 대상 모두에 대해 빌드
ls out/*/libsocks.*       # out/<target>/으로 출력
```

각 플랫폼의 아티팩트는 `out/<platform>/`에 있으며 다음을 포함합니다:
- `libsocks.a` (정적)
- `libsocks.so*` (공유, Linux만)
- `libsocks.lib` / `libsocks.dll` (Windows 정적/동적)
- `socks.h` (C API 헤더)
- `socks.pc` (pkg-config 파일)

대상 sysroot에 설치:

```sh
make install PREFIX=/path/to/sysroot
```

**참고:** Windows/amd64 바이너리는 빌드되지만 런타임 테스트되지 않습니다. Linux 플랫폼은 완전히 테스트되었고 macOS는 테스트되지 않았습니다.

실제 펜테스트를 위해 프로덕션에서 맨발로 금지합니다. 인기가 될 때까지 레드팀용만 💎

## 라이선스

MIT, [LICENSE](LICENSE)를 참조하세요.
