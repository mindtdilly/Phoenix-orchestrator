# EPC Roadmap ↔ OpenClaw Skill Crosswalk

This document maps EPC security/operations requirements to the currently referenced OpenClaw skill-group configuration in the architecture notes.

## Assumptions and source constraints
- The repository currently contains only high-level architecture fragments and no full 48-skill manifest file.
- The source payload references **10 worker classes** with domain specialties and an `epc-to-openclaw` mapping block.
- Because a full skill manifest is absent, this crosswalk is a practical alignment matrix based on the provided architecture text.

## Crosswalk matrix

| EPC Requirement | Description | OpenClaw mapping (from architecture) | Primary worker class | Gap status |
|---|---|---|---|---|
| SEC-001 | Stripe webhook signature verification | `SEC-001/2 -> claw-v1 (security)` | `claw-v1` | Needs concrete webhook middleware in Swarm |
| SEC-002 | Tap webhook HMAC verification | `SEC-001/2 -> claw-v1 (security)` | `claw-v1` | Needs dual-provider verifier implementation |
| SEC-003 | Signed session tokens (JWT) | Align with bearer token model for v7 endpoints | `claw-v3` + `claw-v1` | Partially defined |
| SEC-004 | CSP + iframe sandboxing | Checkout embedding hardening | `claw-v10` (docs/diagnostics) + frontend skill set | Not yet codified in repo |
| REL-001 | Redis/Postgres reliability profile | `REL-001 -> claw-v3 (data-persistence)` | `claw-v3` | Operational spec needed |
| OBS-001 | Pino logging and diagnostics | `OBS-001 -> claw-v10 (docs/diagnostics)` | `claw-v10` | Requires shared log schema |

## Recommendations
1. Add a `skills-manifest.json` to the repo that explicitly lists all 48 skills, owners, and interfaces.
2. Add verification test fixtures for SEC-001/SEC-002 in the Swarm API test suite.
3. Attach REL-001 and OBS-001 acceptance criteria to CI checks (latency, durability, and log quality gates).
