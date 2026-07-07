# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

Una biblioteca cliente y servidor SOCKS4/4a/5 para [V](https://vlang.io), con una ABI C para su uso en otros lenguajes.

**Nota:** La importación de V es `import socks`, pero el binario y el repositorio se nombran como `vlang-socks`.

## Características

- Soporte para SOCKS4, SOCKS4a y SOCKS5 (cliente y servidor)
- Autenticación de nombre de usuario/contraseña SOCKS5
- UDP ASSOCIATE
- Servidor de bucle de eventos no bloqueante con contrapresión, tiempos de espera de inactividad/apretón de manos/conexión y límite de conexiones
- ABI C (`libsocks`) con encabezado generado, archivo pkg-config y compilaciones estáticas/compartidas para linux/amd64, linux/arm64 y windows/amd64

Consulte [LIMITATIONS.md](LIMITATIONS.md) para entender qué refuerza esta biblioteca y qué no antes de exponerla a clientes no confiables.

## Inicio Rápido

### Prueba (sin necesidad de compilar)

Pruebe la biblioteca localmente sin instalar nada:

```sh
# Con Docker (el host solo necesita docker + sudo)
make test-all

# O pruebe un módulo
make test MODULE=socks5
```

Todas las pruebas pasan en Linux/amd64 y Linux/arm64. Consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md) si las pruebas fallan.

## Instalación (V)

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

## Arquitectura

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

El servidor acepta clientes SOCKS4/4a/5, analiza los saludos, se conecta al objetivo y retransmite datos bidireccionales con contrapresión, tiempos de espera de inactividad y límites de conexión. Consulte [LIMITATIONS.md](LIMITATIONS.md) para entender qué no se refuerza.

## Ejemplo de Servidor

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## ABI C

Una biblioteca estática/compartida precompilada más `socks.h` y archivo pkg-config se compila con `make lib` (destino único) o `make lib-all` (todos los destinos admitidos), con salida a `out/<target>/`. Consulte `examples/c/main.c` para el uso en C y `examples/python/client.py` para el uso a través de `ctypes`.

## Desarrollo

Este proyecto utiliza una cadena de herramientas V containerizada, por lo que el host solo necesita Docker:

```sh
make test MODULE=socks5   # prueba un módulo
make test-all             # prueba todos los módulos
make vet                  # lo que CI verifica (fmt-verify + vet)
make lib                  # compilar la biblioteca ABI C para linux/amd64
make lib-all              # compilar para todas las plataformas admitidas
make shell                # shell de desarrollo interactivo para depuración
```

Ejecute `make help` para ver la lista completa de objetivos.

Consulte [CONTRIBUTING.md](CONTRIBUTING.md) para soporte de plataforma, configuración y convenciones. Consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md) si las pruebas fallan.

### Compilación Cruzada

La biblioteca C se compila para Linux (amd64, arm64) y Windows (amd64):

```sh
make lib-all              # compilar para los tres destinos
ls out/*/libsocks.*       # salidas a out/<target>/
```

Los artefactos de cada plataforma se encuentran en `out/<platform>/` e incluyen:
- `libsocks.a` (estático)
- `libsocks.so*` (compartido, solo Linux)
- `libsocks.lib` / `libsocks.dll` (Windows estático/dinámico)
- `socks.h` (encabezado de API C)
- `socks.pc` (archivo pkg-config)

Instale en un sysroot de destino con:

```sh
make install PREFIX=/path/to/sysroot
```

**Nota:** Los binarios Windows/amd64 se compilan pero no se prueban en tiempo de ejecución. Las plataformas Linux se prueban completamente; macOS no se ha probado.

Sin pies desnudos en producción para pentests reales. Solo para red team, hasta que se haga popular 💎

## Licencia

MIT, consulte [LICENSE](LICENSE).
