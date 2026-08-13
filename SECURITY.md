# Security Policy

## Supported versions

Only the latest released version receives security fixes. Security
announcements and fixes are published through GitHub Releases and the
[CHANGELOG](CHANGELOG.md).

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| < latest| :x:                |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report them privately using GitHub's
[private vulnerability reporting](https://github.com/chy3xyz/zent/security/advisories/new)
("Report a vulnerability" under the Security tab). This lets us coordinate a
fix and a release before the details become public.

A useful report includes:

- A minimal reproduction (schema + code, or a raw SQL snippet).
- The affected version(s) and the driver (SQLite / PostgreSQL / MySQL).
- The impact (e.g. SQL injection, data exposure, denial of service).

## What to expect

1. We will acknowledge the report within a few days and confirm the severity.
2. We will work on a fix in private and prepare a patch release.
3. Once the fix ships, we credit the reporter (unless you prefer to stay
   anonymous) and publish the details in the CHANGELOG.

## Scope

Security applies to the library itself and to the generated SQL path. We are
most interested in:

- SQL injection through predicates, field values, or EntQL expressions.
- Argument/sql mismatch in the builder (`?` / `$n` placeholders).
- Resource leaks or use-after-free in the driver and pool layers that can be
  triggered by untrusted input.

Thank you for helping keep zent safe.
