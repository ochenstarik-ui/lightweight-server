# Security Policy

## Supported Versions

The `main` branch is the active development line. For production use, prefer a reviewed release archive or a pinned commit instead of running scripts directly from a mutable branch.

## Reporting a Vulnerability

Please report security issues privately through GitHub private vulnerability reporting when it is enabled for this repository. If that channel is unavailable, open a minimal GitHub issue that does not include exploit details or secrets, and request a private contact channel.

Include:

- affected script and commit SHA;
- expected and actual behavior;
- impact and required privileges;
- safe reproduction steps;
- whether any secret, host, or user data may have been exposed.

## Installer Trust

These scripts can run as `root`, change firewall rules, create users, configure SSH, and install third-party software. Do not execute an installer until you have reviewed the exact commit or release archive you intend to run.

## Secrets

Do not paste private keys, API tokens, Telegram bot tokens, VPN links, or server passwords into public issues, pull requests, screenshots, or logs.
