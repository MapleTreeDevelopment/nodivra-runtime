# Nodivra Runtime

A local execution service for Nodivra block automations on Home Assistant OS.

**Early preview · 0.1.0.** The macOS editor is a separate application. This repository contains only the runtime, its shared Swift engine, and protocol tests. It does not contain user projects or credentials.

## Install

Use the installation assistant in Nodivra. It checks Home Assistant OS and administrator access, creates and verifies the metadata of a full local backup, adds this repository, installs the matching runtime, saves its access key in the Mac Keychain, and checks the connection. Each step remains visible and interrupted requests are reconciled before continuing.

Repository URL: `https://github.com/MapleTreeDevelopment/nodivra-runtime`

For manual installation, add this URL under Home Assistant Settings → Apps → App store → Repositories, install Nodivra Runtime, set a random access key of at least 32 characters, then start it. The API listens on local port 8668. Keep that port on a trusted local network; do not expose it directly to the internet. Local HTTP requires explicit permission in Nodivra. The runtime requires a supported, healthy Home Assistant OS installation and amd64 or aarch64 hardware. It never updates the OS.

The initial installation builds the image from source and needs internet access and sufficient free memory and disk space. Linux CI builds the same image and runs protocol tests on both supported architectures; check the latest workflow result before using a revision.

## First automation

Start with Nodivra's log-only example. Transfers create a disabled revision. Observation mode reads actual Home Assistant states but does not call device actions. Execution must be enabled separately. Fixed service calls, logic gates, entity states, time windows and delays are supported; general templates, blueprints and arbitrary scripts are not supported in this preview.

## Recovery

Before installation, keep a full Home Assistant backup and download a copy to another device. The installer verifies backup metadata and size; it does not perform a restore test. Its installation journal contains no access keys. If a request times out, use “Status prüfen & fortsetzen”; do not repeat the installation manually until the server status is known.

The runtime stores revision history and SQLite backups in its app data. Stopping the app stops its automations without deleting them. After restart or loss of the Home Assistant connection, programs pause and must be explicitly resumed. Previous automation revisions can be restored from Nodivra. A full HA restore can also revert unrelated changes made since that backup.

## Development checks

```sh
docker build -t nodivra-runtime ./nodivra_runtime
docker run --rm --entrypoint /opt/nodivra/venv/bin/python \
  -e NODIVRA_TEST_ENGINE=/usr/local/bin/NodivraEngine \
  -v "$PWD:/tests:ro" -w /tests nodivra-runtime \
  -m unittest discover -s tests -v
```

Tests use local fake Home Assistant services and never operate actual devices. Dependencies are pinned in the package and requirements file. Third-party dependencies retain their own licenses.
