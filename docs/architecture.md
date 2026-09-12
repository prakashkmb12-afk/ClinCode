# ClinCode — Architecture

## 1. Context

ClinCode handles two document classes:

1. **Structured EHR exports**
   - Already sectioned
   - Can be processed directly

2. **Scanned PDFs**
   - Require OCR
   - Text is normalised before downstream processing

Both document classes converge on a single `clinical_notes` row with a stable character-offset space.

### Why Stable Character Offsets?

Every downstream evidence span is expressed as an offset pair against the canonical note text.

```text
Clinical Note
     |
     v
Canonical Text
     |
     +-- start_offset
     |
     +-- end_offset
     |
     v
Evidence Span
