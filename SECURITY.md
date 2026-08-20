# Security Policy

## Reporting a Vulnerability

If you find a security vulnerability in this project, please **do not** open a
public issue. Contact the maintainer privately through GitHub (e.g. file a
private security advisory or DM the repo owner).

## Scope

- This is a small, personal documentation/scripting project. It contains **no
  real credentials** and **no server-side code**.
- The `scripts/*.ps1` verification scripts read an API key from the
  `OPENCODE_GO_API_KEY` environment variable or a local
  `~/.dsh/.credentials.yaml` file. They never hardcode or log the key value.

## API Key Handling

> **Never commit API keys, OAuth tokens, credentials, or `.env` files.**

- Configure the key via environment variable or a local (gitignored) file.
- If a credential is ever committed:
  1. **Rotate the key immediately** (the old key is compromised even after the
     file is removed from the repo).
  2. Remove the secret from the working tree **and** Git history
     (e.g. `git filter-repo` or `git-filter-branch`), then force-push if and
     only if the repository owner explicitly authorizes a history rewrite.

## Supported

Since this is a hobby project, there is no formal support SLA. Issues are
handled on a best-effort basis.
