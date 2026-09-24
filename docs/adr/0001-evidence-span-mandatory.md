# ADR-0001: Every code suggestion must carry an evidence span

**Status:** Accepted
**Date:** 2026-09-11

## Context

Compliance will not accept a code that cannot be traced to documentation.

A classifier that predicts codes directly from the whole note gives no such trace.

## Decision

The pipeline is span-first. `code_suggestions` has a NOT NULL foreign key to `concept_spans`. A model that cannot point at text cannot emit a suggestion; it can only emit a 'possible missing documentation' finding instead.

## Consequences

* Every suggestion is auditable and reviewable in the console.
* Coder feedback becomes span-level training data for M2.

- Rules out end-to-end multi-label classifiers as the primary path.
- Requires offset-stable text storage from M1 onward.
