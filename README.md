# op-load-secrets-lite

A pure-bash rewrite of [1password/load-secrets-action](https://github.com/1Password/load-secrets-action). No Node runtime required.

## Platforms

Linux and macOS. **Windows is not supported.**

## Usage

```yaml
- uses: sigming/op-load-secrets-lite@main
  with:
    export-env: true
  env:
    OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
    MY_SECRET: op://vault-name/item-name/field-name

- run: echo "secret length is ${#MY_SECRET}"
  # $MY_SECRET will be shown as *** in logs
```

With `export-env: false` (the default), secrets are written to step outputs instead of env vars: `${{ steps.<id>.outputs.MY_SECRET }}`.

## Inputs

| Input | Default | Description |
|---|---|---|
| `export-env` | `false` | `true` writes to `$GITHUB_ENV` (visible to later steps); `false` writes to `$GITHUB_OUTPUT` |
| `unset-previous` | `false` | When `true`, clears variables injected by a previous run of this action |
| `version` | `latest` | op CLI version: `latest` / `latest-beta` / `2.34.0` |
| `install-dir` | `$RUNNER_TEMP/op-cli` | Where to install the op CLI. Skipped if `op` is already on PATH |

## Cleanup (self-hosted runners)

`$RUNNER_TEMP` is wiped by the runner agent automatically, so usually you don't need to do anything. For belt-and-suspenders cleanup (e.g. when a job is force-cancelled), add this step:

```yaml
- name: Cleanup op CLI
  if: always() && env.OP_CLI_INSTALL_DIR != ''
  shell: bash
  run: rm -rf "$OP_CLI_INSTALL_DIR"
```

The `env.OP_CLI_INSTALL_DIR != ''` guard prevents accidental deletion when `op` was already present on the runner (this action skips installation and leaves the variable unset in that case).

## License

MIT
