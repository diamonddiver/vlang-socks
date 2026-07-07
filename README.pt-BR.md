# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

Uma biblioteca cliente e servidor SOCKS4/4a/5 para [V](https://vlang.io), com ABI C para uso em outras linguagens.

**Nota:** O import V é `import socks`, mas o binário e o repositório são nomeados como `vlang-socks`.

## Características

- Suporte a SOCKS4, SOCKS4a e SOCKS5 (cliente e servidor)
- Autenticação de nome de usuário/senha SOCKS5
- UDP ASSOCIATE
- Servidor de loop de eventos não bloqueante com contrapressão, timeouts de inatividade/handshake/conexão e limite de conexões
- ABI C (`libsocks`) com header gerado, arquivo pkg-config e builds estático/compartilhado para linux/amd64, linux/arm64 e windows/amd64

Consulte [LIMITATIONS.md](LIMITATIONS.md) para entender o que esta biblioteca reforça e o que não reforça antes de expô-la a clientes não confiáveis.

## Início Rápido

### Teste (sem necessidade de compilação)

Teste a biblioteca localmente sem instalar nada:

```sh
# Com Docker (o host precisa apenas de docker + sudo)
make test-all

# Ou teste um módulo
make test MODULE=socks5
```

Todos os testes passam em Linux/amd64 e Linux/arm64. Consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md) se os testes falharem.

## Instalação (V)

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

## Arquitetura

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

O servidor aceita clientes SOCKS4/4a/5, analisa handshakes, conecta ao alvo e retransmite dados bidirecionalmente com contrapressão, timeouts de inatividade e limites de conexão. Consulte [LIMITATIONS.md](LIMITATIONS.md) para entender o que não é reforçado.

## Exemplo de Servidor

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## ABI C

Uma biblioteca estática/compartilhada pré-construída mais `socks.h` e arquivo pkg-config é construída com `make lib` (alvo único) ou `make lib-all` (todos os alvos suportados), com saída para `out/<target>/`. Consulte `examples/c/main.c` para uso em C e `examples/python/client.py` para uso via `ctypes`.

## Desenvolvimento

Este projeto usa uma toolchain V containerizada, portanto o host precisa apenas de Docker:

```sh
make test MODULE=socks5   # teste um módulo
make test-all             # teste todos os módulos
make vet                  # o que CI verifica (fmt-verify + vet)
make lib                  # compile a biblioteca ABI C para linux/amd64
make lib-all              # compile para todas as plataformas suportadas
make shell                # shell de desenvolvimento interativo para debug
```

Execute `make help` para ver a lista completa de alvos.

Consulte [CONTRIBUTING.md](CONTRIBUTING.md) para suporte de plataforma, configuração e convenções. Consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md) se os testes falharem.

### Compilação Cruzada

A biblioteca C é construída para Linux (amd64, arm64) e Windows (amd64):

```sh
make lib-all              # compilar para todos os três alvos
ls out/*/libsocks.*       # saídas para out/<target>/
```

Os artefatos de cada plataforma estão em `out/<platform>/` e incluem:
- `libsocks.a` (estático)
- `libsocks.so*` (compartilhado, apenas Linux)
- `libsocks.lib` / `libsocks.dll` (Windows estático/dinâmico)
- `socks.h` (header da API C)
- `socks.pc` (arquivo pkg-config)

Instale em um sysroot alvo com:

```sh
make install PREFIX=/path/to/sysroot
```

**Nota:** Binários Windows/amd64 são construídos mas não testados em tempo de execução. Plataformas Linux são totalmente testadas; macOS não foi testado.

Sem pés descalços em produção para pentests reais. Apenas para red team, até ficar popular 💎

## Licença

MIT, consulte [LICENSE](LICENSE).
