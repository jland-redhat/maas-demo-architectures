# Lab hacks (not part of official install)

One-off / skew workarounds for broken EA clusters. **Do not** wire these into
`install-infra.sh` or `setup-*.sh`. Prefer fixing the product (image pin, operator
args) when you can.

| Hack | When |
|------|------|
| [perses-tls-skew.hack.sh](perses-tls-skew.hack.sh) | Perses CrashLoop on `--web.tls-min-version`; or cleanup of the old `perses-tls-workaround` keeper |

```bash
# From repo root — read the script header first
./infra/hacks/perses-tls-skew.hack.sh cleanup   # remove keeper, restore operator
./infra/hacks/perses-tls-skew.hack.sh strip-args  # one-shot STS arg strip only
```
