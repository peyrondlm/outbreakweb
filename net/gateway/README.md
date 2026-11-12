# reo-gateway

Bridges the browser game's emulated PS2 network adapter (DEV9/SMAP) to real services. The page sends raw Ethernet frames over a WebSocket (`/eth`); the gateway answers DHCP, ARP and DNS itself and forwards TCP/UDP only to the upstreams listed in the `allow` list of its config (the lobby server's ports). Everything else is dropped.

```bash
go build ./cmd/reo-gateway
go test ./...
```

`config.example.json` is for local use. `run-local.sh` writes its own config. With `--all` or `--address`, the gateway stays on `127.0.0.1`, and `serve.py` proxies `/eth` to it. See [../../docs/network.md](../../docs/network.md).
