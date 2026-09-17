# {PLUGIN_NAME}

**Target System**: {TARGET_SYSTEM}
**Branch**: {FEATURE}
**Date**: {DATE}

## Description

{DESCRIPTION — one paragraph summarizing which system's users the database plugin manages and why}

## Requirements

### Credential Features

{Dynamic users / static-role rotation / renewal (expiration) / root self-rotation — and the credential types (password, rsa_private_key, client_certificate) — with a one-line rationale}

### Statements Contract

{SQL templates, JSON schema, or defaults-only; behavior when statements are empty}

### Security

{Bulleted list of security decisions made during Phase 1 clarification — e.g. "TLS via ca_cert, insecure_tls default false", "verify_connection performs a ping", "Root account: CREATEROLE only"}

### Scope Boundary

{What is explicitly out of scope}

## Clarification Summary

{Brief summary of questions asked and answers received during Phase 1. Omit if no clarification was needed.}

## Status

- [x] Phase 1: Clarify
- [ ] Phase 2: Design
- [ ] Phase 3: Implement
- [ ] Phase 4: Validate
