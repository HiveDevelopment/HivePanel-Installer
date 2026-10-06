# HivePanel Installer

Managed production installer and host updater for HivePanel.

## Linux

```bash
curl -fsSL https://get.hivepanel.dev | sudo bash
```

The installer supports apt- and dnf-based Linux distributions, installs Docker Engine and Docker Compose when required, resolves the latest stable HivePanel release, deploys the official GHCR images, creates the first Super Administrator, and installs the host-side update runner.

The default installation directory is `/opt/hivepanel`.

## Windows

Windows requires PowerShell 7 and Docker Desktop configured for Linux containers.

```powershell
irm https://raw.githubusercontent.com/HiveDevelopment/HivePanel-Installer/main/install.ps1 | iex
```

Linux is the recommended production platform.

## Repository responsibilities

This repository owns host-level installation and update orchestration. The HivePanel repository owns the application, Docker images, `compose.yaml`, update request/status API, and admin UI.

The web application does not receive access to the Docker socket. It writes an approved update request to the shared runtime directory; the privileged host updater consumes that request and performs the deployment update.

## Environment overrides

- `HIVEPANEL_INSTALL_DIR` — installation directory, default `/opt/hivepanel`
- `HIVEPANEL_REPOSITORY` — panel repository, default `HiveDevelopment/HivePanel`
- `HIVEPANEL_INSTALLER_REPOSITORY` — installer repository, default `HiveDevelopment/HivePanel-Installer`
- `HIVEPANEL_VERSION` — install a specific HivePanel version instead of latest stable
