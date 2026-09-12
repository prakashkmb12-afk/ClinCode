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
