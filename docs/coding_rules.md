# ADR-0001: Every Code Suggestion Must Carry an Evidence Span

**Status:** Accepted

**Date:** 2026-09-11

---

## Context

Compliance will not accept a code that cannot be traced to documentation.

A classifier that predicts codes directly from the whole note provides no direct trace to the supporting clinical text.

ClinCode therefore requires every code suggestion to be connected to an evidence span.

---

## Decision

The ClinCode pipeline is **span-first**.

The `code_suggestions` table has a `NOT NULL` foreign key to `concept_spans`.

```text
Clinical Note
      |
      v
concept_span
      |
      v
code_suggestion
