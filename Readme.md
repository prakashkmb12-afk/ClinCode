# ClinCode — Clinical Documentation & Medical Coding Automation

ClinCode automates the first pass of inpatient and outpatient medical coding.

Every suggested code carries the exact text span that justifies it, so a certified coder reviews evidence rather than a black-box label.

## Problem Statement

Manual coding of a discharge summary takes 15–25 minutes and is a major source of claim denials.

Fully automatic coding is not acceptable to compliance teams because a code without documented justification cannot survive an audit.

ClinCode therefore treats evidence extraction as the primary product and the code as a derived artefact:

- NLP extracts clinical concepts with character-offset spans.
- The code suggester maps those spans to candidate ICD-10-CM / CPT codes.
- The validation layer enforces structural coding rules.
- A human coder reviews the evidence and makes the final decision.

## Architecture (M1 Baseline)

```text
note / PDF upload
       |
       v
[document-intake] --MinIO--> original
       |
       +------------PostgreSQL--> encounter + note
       |
       v
[nlp-extraction] --> concept_spans
                     (offset, text, concept, negation)
       |
       v
[code-suggester] --Qdrant--> nearest code descriptions
       |
       v
                 code_suggestions
       |
       v
[validation-agent] --> rule violations,
                       sequencing,
                       principal diagnosis
       |
       v
[coder-api] --> coder worklist
               (accept / reject / amend)

## Milestones
| Milestone | Focus | |-----------|-------| |
 M1 | Architecture, infrastructure, schema and terminology foundation |
| M2 | Clinical NER model training and concept normalisation |
| M3 | Code suggestion service with confidence calibration |
| M4 | RAG-backed coding copilot over guidelines and coding clinic advice |
| M5 | Coder review console with evidence highlighting |
| M6 | Deployment, audit reporting and drift monitoring |

## Quick Start
```bash cp .env.example .env make up          # start the full infrastructure stack
make db-init     # apply schema (auto-applied on first boot)
make seed        # load reference + demo data
make verify      # M1 acceptance checks ```

## Repository Layout
- `libs/clincode_domain/`
— pure code validation and coding rules- `services/`
— one container per agent- `scripts/`
— schema, terminology loader, dataset ETL, seeding, verification- `config/`
— coding rule parameters and note section headers- `docs/adr/`
— architecture decision records

## Tech Stack
- **PostgreSQL** — Encounters, notes, terminology and coder decisions
- **Qdrant** — Vector index over note chunks and code descriptions (RAG from M4)
- **MinIO** — Object store for original documents and OCR output
- **Redis** — Task queue and extraction cache
- **MLflow** — NER / classifier experiment tracking from M2

## License
MIT
