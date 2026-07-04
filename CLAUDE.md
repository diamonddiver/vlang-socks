# vlang-socks

## Docker

The Docker daemon on this host is only reachable via `sudo` — the current
user is not in the `docker` group. `sudo docker ...` works passwordlessly.
Always prefix Docker and Docker Compose commands with `sudo`, including in
the `Makefile` (`docker build`, `docker run`, `docker volume rm`, etc.) and
in any `Run:` step from the implementation plan that invokes `make ...` or
`docker ...` directly.
