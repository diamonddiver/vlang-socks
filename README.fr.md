# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

Une bibliothèque cliente et serveur SOCKS4/4a/5 pour [V](https://vlang.io), avec une ABI C pour une utilisation à partir d'autres langages.

**Note :** L'import V est `import socks`, mais le binaire et le référentiel sont nommés `vlang-socks`.

## Fonctionnalités

- Support SOCKS4, SOCKS4a et SOCKS5 (client et serveur)
- Authentification SOCKS5 par nom d'utilisateur/mot de passe
- UDP ASSOCIATE
- Serveur de boucle d'événements non bloquant avec contre-pression, délais d'expiration inactivité/poignée de main/connexion et limite de connexions
- ABI C (`libsocks`) avec en-tête généré, fichier pkg-config et compilations statiques/partagées pour linux/amd64, linux/arm64 et windows/amd64

Consultez [LIMITATIONS.md](LIMITATIONS.md) pour comprendre ce que cette bibliothèque renforce et ce qu'elle ne renforce pas avant de l'exposer à des clients non approuvés.

## Démarrage Rapide

### Test (aucune compilation requise)

Testez la bibliothèque localement sans installer quoi que ce soit :

```sh
# Avec Docker (l'hôte n'a besoin que de docker + sudo)
make test-all

# Ou testez un module
make test MODULE=socks5
```

Tous les tests réussissent sur Linux/amd64 et Linux/arm64. Consultez [TROUBLESHOOTING.md](TROUBLESHOOTING.md) si les tests échouent.

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

## Architecture

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

Le serveur accepte les clients SOCKS4/4a/5, analyse les poignées de main, se connecte à la cible et relaye les données de manière bidirectionnelle avec contre-pression, délais d'inactivité et limites de connexion. Consultez [LIMITATIONS.md](LIMITATIONS.md) pour comprendre ce qui n'est pas renforcé.

## Exemple de Serveur

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## ABI C

Une bibliothèque statique/partagée précompilée plus `socks.h` et fichier pkg-config est compilée avec `make lib` (cible unique) ou `make lib-all` (toutes les cibles pris en charge), sortie vers `out/<target>/`. Consultez `examples/c/main.c` pour l'utilisation en C et `examples/python/client.py` pour l'utilisation via `ctypes`.

## Développement

Ce projet utilise une chaîne d'outils V conteneurisée, l'hôte n'a donc besoin que de Docker :

```sh
make test MODULE=socks5   # tester un module
make test-all             # tester tous les modules
make vet                  # ce que CI vérifie (fmt-verify + vet)
make lib                  # compiler la bibliothèque ABI C pour linux/amd64
make lib-all              # compiler pour toutes les plates-formes prises en charge
make shell                # shell de développement interactif pour le débogage
```

Exécutez `make help` pour voir la liste complète des cibles.

Consultez [CONTRIBUTING.md](CONTRIBUTING.md) pour le support des plates-formes, la configuration et les conventions. Consultez [TROUBLESHOOTING.md](TROUBLESHOOTING.md) si les tests échouent.

### Compilation Croisée

La bibliothèque C est compilée pour Linux (amd64, arm64) et Windows (amd64) :

```sh
make lib-all              # compiler pour les trois cibles
ls out/*/libsocks.*       # sorties vers out/<target>/
```

Les artefacts de chaque plate-forme se trouvent dans `out/<platform>/` et incluent :
- `libsocks.a` (statique)
- `libsocks.so*` (partagé, Linux uniquement)
- `libsocks.lib` / `libsocks.dll` (Windows statique/dynamique)
- `socks.h` (en-tête de l'API C)
- `socks.pc` (fichier pkg-config)

Installez dans un sysroot cible avec :

```sh
make install PREFIX=/path/to/sysroot
```

**Note :** Les binaires Windows/amd64 sont compilés mais non testés à l'exécution. Les plates-formes Linux sont entièrement testées ; macOS est non testé.

Pas de pieds nus en production pour de vrais pentests. Réservé aux équipes rouges jusqu'à ce que cela devienne populaire 💎

## Licence

MIT, voir [LICENSE](LICENSE).
