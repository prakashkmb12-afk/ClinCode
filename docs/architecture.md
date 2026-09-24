# ClinCode — Architecture

## 1. Context

ClinCode handles two document classes: structured EHR exports (already sectioned) and scanned PDFs (needing OCR). Both converge on a single `clinical_notes` row with a stable character offset space, because every downstream evidence span is expressed as an offset pair against that text. M1 provisions storage and terminology; no model is trained yet.

## 2. Component Responsibilities

* **document-intake** — Receives a note or PDF, stores the original in MinIO, registers the encounter
* **nlp-extraction** — Segments the note, runs clinical NER, writes concept spans with offsets
* **code-suggester** — Maps extracted concepts to ICD-10-CM / CPT candidates with confidence
* **validation-agent** — Applies coding rules (excludes, laterality, sequencing) and flags conflicts
* **coder-api** — FastAPI service serving the coder worklist and accept/reject actions

## 3. Data Flow

1. `document-intake` writes the original to MinIO, normalises text, and stores the canonical note text so offsets are stable forever.
2. `nlp-extraction` segments by section header, runs NER, and writes `concept_spans` with `start_offset` / `end_offset` plus negation and historicity flags.
3. `code-suggester` embeds each span, queries Qdrant against embedded code descriptions, and writes ranked `code_suggestions` linked back to the span.
4. `validation-agent` applies the rule set and writes `validation_findings`.
5. `coder-api` exposes the worklist; every accept/reject writes to `coder_decisions`.

## 4. Non-Functional Targets

* Every suggested code must resolve to at least one evidence span or it is not shown
* Note text is immutable once stored; corrections create a new version
* No PHI in logs, in Git, or in MLflow artefacts
* Terminology is versioned: a suggestion records which code-set release produced it
