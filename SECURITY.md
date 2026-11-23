# Security Policy

## Reporting a vulnerability

Use GitHub private vulnerability reporting on `wolfeidau/buildkite-release-plugins`: open the Security tab and choose "Report a vulnerability". Do not open public issues for security problems.

## Supported versions

Only the latest commit on `main` is supported. Consumers pin plugins by full 40-character commit SHA and should update to the fixing SHA once a fix lands.

## Scope

The plugin hooks in this repository. Secrets are handled through Buildkite cluster secrets and OIDC; the plugins do not store credentials.
