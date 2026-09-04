# PlayDooh Screen Health public releases

This repository contains only generic, credential-free updater metadata, release packages, schemas, and documentation.

Never publish Screen IDs, receiver.private.json, API keys, tokens, Google credentials, local config.json or state.json, logs, reports, history, backups, or anything copied from C:\ProgramData\PlayDooh.

## Monitor package contract

The ZIP root contains exactly VERSION.txt, ScreenHealth.ps1, and ScreenHealth.Core.psm1.

Publish a release asset named PlayDooh-ScreenHealth-v2.zip, calculate its SHA-256, then update metadata/latest.json. The package deliberately excludes the installer and receiver credential.

## Updater package contract

The ZIP root contains exactly VERSION.txt, Updater.ps1, and Updater.Core.psm1. Publish it separately and update metadata/updater-latest.json. PCs stage a verified updater and activate it on the next run; the stable launcher and Scheduled Task remain in place.

Both metadata and package URLs must use HTTPS. Version values are strictly v1, v2, v3, and so on.
