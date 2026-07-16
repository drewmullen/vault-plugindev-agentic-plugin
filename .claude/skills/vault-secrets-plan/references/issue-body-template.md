# {ENGINE_NAME}

**Target API**: {TARGET_API}
**Branch**: {FEATURE}
**Date**: {DATE}

## Description

{DESCRIPTION — one paragraph summarizing what the secrets engine manages and why}

## Requirements

### Credential Model

{Static rotation, dynamic ephemeral, or both — with a one-line rationale}

### Vault Paths

{Bulleted list of planned backend paths — e.g. config, roles/<name>, creds/<name>, rotate endpoints — including any hierarchical parent/child layout}

### Security

{Bulleted list of security decisions made during Phase 1 clarification — e.g. "Default TTL: 1h, max 24h", "Config path seal-wrapped", "Root credential scope: least-privilege token with user-management only"}

### Scope Boundary

{What is explicitly out of scope}

## Clarification Summary

{Brief summary of questions asked and answers received during Phase 1. Omit if no clarification was needed.}

## Status

- [x] Phase 1: Clarify
- [ ] Phase 2: Design
- [ ] Phase 3: Implement
- [ ] Phase 4: Validate
