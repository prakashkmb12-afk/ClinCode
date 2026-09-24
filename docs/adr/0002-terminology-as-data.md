# ADR-0002: Terminology lives in the database, never in code

**Status:** Accepted
**Date:** 2026-09-11

## Context

ICD-10-CM is revised annually and CPT quarterly. Hard-coding code lists guarantees a stale system and makes historical re-coding impossible.

## Decision

`code_sets`, `codes` and `code_relations` are loaded from published release files. Every suggestion stores `code_set_version`, so an encounter coded in FY2026 can be reproduced exactly even after the FY2027 release lands.

## Consequences

* Annual updates are a data load, not a release.
* Retrospective audits reproduce the original suggestion set.

- Requires a loader script and a version column on every derived table.
