# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

Eine SOCKS4/4a/5-Client- und Server-Bibliothek für [V](https://vlang.io) mit einer C ABI zur Verwendung in anderen Sprachen.

**Hinweis:** Der V-Import heißt `import socks`, aber die Binärdatei und das Repository heißen `vlang-socks`.

## Funktionen

- SOCKS4-, SOCKS4a- und SOCKS5-Unterstützung (Client und Server)
- SOCKS5 Benutzername/Passwort-Authentifizierung
- UDP ASSOCIATE
- Non-Blocking-Event-Loop-Server mit Backpressure, Idle/Handshake/Connect-Timeouts und Verbindungsobergrenze
- C ABI (`libsocks`) mit generiertem Header, pkg-config-Datei und statischen/gemeinsamen Builds für linux/amd64, linux/arm64 und windows/amd64

Siehe [LIMITATIONS.md](LIMITATIONS.md), um zu erfahren, welche Sicherheitsaspekte diese Bibliothek behandelt und welche nicht, bevor sie untrusted Clients ausgesetzt wird.

## Schnellstart

### Test (kein Build erforderlich)

Die Bibliothek lokal ohne Installation testen:

```sh
# Mit Docker (Host benötigt nur docker + sudo)
make test-all

# Oder ein Modul testen
make test MODULE=socks5
```

Alle Tests bestehen unter Linux/amd64 und Linux/arm64. Siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md), wenn Tests fehlschlagen.

## Installation (V)

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

## Architektur

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

Der Server akzeptiert SOCKS4/4a/5-Clients, analysiert Handshakes, verbindet sich mit dem Ziel und leitet Daten bidirektional mit Backpressure, Idle-Timeouts und Verbindungslimits weiter. Siehe [LIMITATIONS.md](LIMITATIONS.md), um zu erfahren, welche Sicherheitsaspekte nicht berücksichtigt werden.

## Server-Beispiel

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## C ABI

Eine vorgefertigte statische/gemeinsame Bibliothek plus `socks.h` und pkg-config-Datei wird mit `make lib` (einzelnes Ziel) oder `make lib-all` (alle unterstützten Ziele) erstellt, Ausgabe nach `out/<target>/`. Siehe `examples/c/main.c` für die Verwendung aus C und `examples/python/client.py` für die Verwendung über `ctypes`.

## Entwicklung

Dieses Projekt verwendet eine containerisierte V-Toolchain, daher benötigt der Host nur Docker:

```sh
make test MODULE=socks5   # ein Modul testen
make test-all             # alle Module testen
make vet                  # was CI überprüft (fmt-verify + vet)
make lib                  # C ABI-Bibliothek für linux/amd64 erstellen
make lib-all              # für alle unterstützten Plattformen erstellen
make shell                # interaktive Entwicklungs-Shell zum Debuggen
```

Führen Sie `make help` aus, um die komplette Zielenliste zu sehen.

Siehe [CONTRIBUTING.md](CONTRIBUTING.md) für Plattformunterstützung, Setup und Konventionen. Siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md), wenn Tests fehlschlagen.

### Cross-Compilation

Die C-Bibliothek wird für Linux (amd64, arm64) und Windows (amd64) erstellt:

```sh
make lib-all              # für alle drei Ziele erstellen
ls out/*/libsocks.*       # Ausgaben nach out/<target>/
```

Artefakte jeder Plattform befinden sich in `out/<platform>/` und umfassen:
- `libsocks.a` (statisch)
- `libsocks.so*` (geteilt, nur Linux)
- `libsocks.lib` / `libsocks.dll` (Windows statisch/dynamisch)
- `socks.h` (C API Header)
- `socks.pc` (pkg-config Datei)

Installation in einen Ziel-Sysroot:

```sh
make install PREFIX=/path/to/sysroot
```

**Hinweis:** Windows/amd64-Binärdateien werden erstellt, aber nicht zur Laufzeit getestet. Linux-Plattformen werden vollständig getestet; macOS ist ungetestet.

Keine bloßen Füße in der Produktion für echte Pentests. Nur für Red Team, bis es populär wird 💎

## Lizenz

MIT, siehe [LICENSE](LICENSE).
