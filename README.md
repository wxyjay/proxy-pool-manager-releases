# PPM Releases

`main` is stable. `debug` is debug.

## Swift Backend

Stable:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --install
```

Debug:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/debug/install-ppm-swift-backend.sh | bash -s -- --branch debug --install
```

Migrate old data:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --install --migrate-legacy
```

Skip VPNGate deps:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --install --skip-vpngate-deps
```

Status:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --status
```

Uninstall and keep data:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --uninstall
```

Purge:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --purge
```

Purge with VPNGate deps installed by this script:

```bash
curl -fsSL https://raw.githubusercontent.com/wxyjay/proxy-pool-manager-releases/main/install-ppm-swift-backend.sh | bash -s -- --branch main --purge --purge-vpngate-deps
```
