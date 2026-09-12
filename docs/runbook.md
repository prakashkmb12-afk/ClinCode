# ADR-0002: Terminology Lives in the Database, Never in Code

**Status:** Accepted

**Date:** 2026-09-11

---

## Context

ICD-10-CM is revised annually and CPT is revised quarterly.

Hard-coding code lists guarantees a stale system and makes historical re-coding impossible.

ClinCode therefore treats terminology as versioned data.

---

## Decision

The following terminology entities are loaded from published release files:

```text
code_sets
codes
code_relations
