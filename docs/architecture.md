# ClinCode Architecture Specification

This document provides a detailed specification of the architecture, data flows, components, security controls, and design principles of **ClinCode** — an evidence-linked clinical documentation intelligence and medical coding automation platform with human-in-the-loop (HITL) review.

---

## 1. System Architecture Overview

ClinCode is designed as a decoupled, microservices-based system. It separates raw clinical document intake, heavy NLP/retrieval worker processing, autonomous agentic chart investigation, user-facing administrative/review APIs, and interactive coder review consoles.

```mermaid
graph TD
    Client[Client Apps / EHR Systems] -->|POST /documents| IntakeAPI[FastAPI Intake API]
    IntakeAPI -->|Persist Document & Enqueue| DB[(PostgreSQL DB)]
    IntakeAPI -->|Push Task| Queue[(Redis Queue)]

    subgraph Pipeline Workers [Horizontally Scaled Pipeline Workers]
        Queue -->|Fetch Task| Worker[Worker Orchestrator]
        Worker --> OCR[1. OpenCV & OCR Intake]
        Worker --> DeID[2. De-identification Gate]
        Worker --> Sec[3. Sectionizer & Span Alignment]
        Worker --> NER[4. Bio_ClinicalBERT NER]
        Worker --> Assert[5. Assertion Classifier]
        Worker --> Norm[6. Normalization & Abbrev Expansion]
        Worker --> Retr[7. Hybrid Retrieval]
        Worker --> Rank[8. Cross-Encoder Reranker & Hierarchy Rules]
        Worker --> Calib[9. Isotonic Calibration & Triage]
        Worker --> GenAI[10. Grounded Justification & CDI]
    end

    Retr -->|Dense & Sparse Vectors| Qdrant[(Qdrant Vector DB)]
    Worker -->|Checkpoints & Suggestions| DB

    subgraph Triage Split [Confidence-Based Triage]
        Calib -->|High / Standard Conf| Suggestions[Suggestions Store]
        Calib -->|Low Conf / Conflicting| AgentTeam[Multi-Agent Investigation Service]
    end

    subgraph Agentic Investigation Service [LangGraph 6-Agent Investigation Service]
        AgentTeam --> Sup[Supervisor Agent]
        Sup --> EA[Evidence Analyst]
        Sup --> GA[Guideline Analyst]
        Sup --> SA[Specificity Agent]
        Sup --> QD[Query Drafter]
        Sup --> AV[Adversarial Verifier]
        GA -->|Guideline RAG| Qdrant
        SA -->|Hierarchy Check| DB
        EA -->|Precedent Search| Qdrant
    end

    AgentTeam -->|InvestigationReport| DB

    subgraph Review & Export [Coder Console & Downstream Export]
        CoderConsole[React Review Console] -->|GET /suggestions| ReviewAPI[FastAPI Review API]
        ReviewAPI -->|Read Suggestions & Spans| DB
        CoderConsole -->|POST /action accept/reject/modify| ReviewAPI
        ReviewAPI -->|Record Feedback Label| DB
        ExportAPI[FastAPI Export API] -->|GET /export| ClaimExport[FHIR-flavored Claim JSON]
    end
```

---

## 2. End-to-End Data Flow

Document processing follows a 15-step immutable lifecycle, tracking provenance and stage checkpoints at every step:

```mermaid
sequenceDiagram
    autonumber
    actor EHR as EHR / Integration Key
    participant API as Intake API
    participant DB as PostgreSQL
    participant Redis as Redis Queue
    participant Worker as Pipeline Worker
    participant Qdrant as Qdrant Vector DB
    participant Agent as Investigator Service
    actor Coder as Human Medical Coder

    EHR->>API: POST /api/v1/documents (Note / PDF / FHIR JSON)
    API->>DB: Persist document (Encrypted PHI, Status: Received)
    API->>Redis: Enqueue document processing task
    API-->>EHR: 202 Accepted {document_id, status: received}

    Redis->>Worker: Consume processing task
    Worker->>Worker: Stage 1: OpenCV deskew/denoise + OCR (if PDF/scanned)
    Worker->>Worker: Stage 2: De-identification (regex + NER scrub, Fernet encrypted map)
    Worker->>Worker: Stage 3: Rule-based sectionization (character-span preserved)
    Worker->>Worker: Stage 4: Bio_ClinicalBERT NER (ONNX runtime token classification)
    Worker->>Worker: Stage 5: Assertion classification (present/absent/possible/history/family)
    Worker->>Worker: Stage 6: Abbreviation expansion & UMLS-lite concept normalization
    Worker->>Qdrant: Stage 7: Hybrid retrieval (dense bge-small + BM25, RRF fusion)
    Qdrant-->>Worker: Top-20 candidate codes per entity
    Worker->>Worker: Stage 8: Cross-encoder reranking + Excludes1 / hierarchy post-processing
    Worker->>Worker: Stage 9: Isotonic calibration & triage assignment (auto/review/low)
    Worker->>Worker: Stage 10: Grounded LLM justification & CDI query generation
    Worker->>DB: Store pipeline_runs checkpoint, entities, code_suggestions, cdi_queries

    alt Chart flagged low-confidence or conflicting (~20%)
        Worker->>Agent: Trigger async chart investigation run
        Agent->>Qdrant: Guideline RAG & Precedent search
        Agent->>Agent: Adversarial Verifier claim check
        Agent->>DB: Store InvestigationReport
    end

    Worker->>DB: Update document status → ready

    Coder->>API: GET /api/v1/documents/{id}/suggestions
    API->>DB: Fetch suggestions, evidence spans & investigation report
    API-->>Coder: Render NoteViewer + CodePanel in Console
    Coder->>API: POST /api/v1/suggestions/{id}/action (accept/reject/modify)
    API->>DB: Store review_actions (feedback label)
    Coder->>API: POST /api/v1/documents/{id}/submit
    API->>DB: Finalize submission & sample for QA
    EHR->>API: GET /api/v1/documents/{id}/export
    API-->>EHR: FHIR-flavored Claim JSON
```

---

## 3. Service Architecture

### 3.1 Services Breakdown

1. **Intake & Review API (`services/api`)**:
   * Built with FastAPI and Pydantic v2.
   * Exposes stateless REST endpoints for intake, document status, coder review operations, CDI query interactions, FHIR exports, and admin metrics.
   * Enforces JWT authentication and Role-Based Access Control (RBAC).

2. **Pipeline Workers (`services/pipeline`)**:
   * Asynchronous, queue-driven Python workers scaled horizontally off a Redis queue.
   * Executes the 10-stage NLP, normalization, retrieval, reranking, calibration, and grounding pipeline.
   * Persists stage-by-stage checkpoints to PostgreSQL (`pipeline_runs` table) to guarantee idempotent execution and fault recovery.

3. **Investigator Service (`services/investigator`)**:
   * Multi-agent execution engine built using LangGraph.
   * Manages stateful, asynchronous chart investigation runs triggered by low-confidence scores, assertion conflicts, or Excludes1 collisions.
   * Operates exclusively through read-only tools, guideline RAG, precedent memory, and an adversarial verifier gate.
   * Exposes coding knowledge tools via a Model Context Protocol (MCP) server interface on de-identified data.

4. **Frontend Coder Console (`services/frontend`)**:
   * Single-page application built with React 18, TypeScript, and Vite.
   * Features interactive dual-pane view: `NoteViewer` with layered entity highlights and `CodePanel` with confidence band badges, evidence chips, and CDI cards.

### 3.2 Infrastructure & Persistence Layer

* **PostgreSQL 15**: Primary relational database handling transactional storage for documents, pipeline checkpoints, extracted entities, code suggestions, review actions, CDI queries, user accounts, and audit trails.
* **Redis**: In-memory message broker managing asynchronous job queues for pipeline workers and investigation runs.
* **Qdrant**: High-performance vector database hosting three specialized vector collections:
  * `icd10`: ICD-10-CM code descriptions, synonyms, and inclusion/exclusion notes (dense + sparse vectors).
  * `coding_guidelines`: Clause-level official CMS coding guidelines with section metadata.
  * `chart_precedents`: De-identified embeddings of coder-approved chart codings and rejected suggestions.
* **MLflow**: Centralized registry tracking model experiments, parameters, metrics, artifacts, and ONNX model binary versions.
* **DVC (Data Version Control)**: Versioning framework managing raw clinical note corpora (`mtsamples/`), parsed ICD-10 code tables (`icd10cm/`), and gold evaluation charts (`gold_charts/`).

---

## 4. Machine Learning & Clinical NLP Architecture

```mermaid
graph LR
    SubGraph1[Raw Clinical Text] --> Sec[Sectionizer]
    Sec --> BioBERT[Bio_ClinicalBERT NER]
    Sec --> SciSpacy[SciSpacy Fallback]
    BioBERT --> Entities[Extracted Entities w/ Character Spans]
    SciSpacy --> Entities
    Entities --> Assert[Assertion Classifier]
    Assert -->|Filter Non-Present| PresentEntities[Present & Historical Entities]
    PresentEntities --> Norm[Abbreviation & UMLS Normalization]
    Norm --> Retr[Hybrid Qdrant Retrieval]
```

### 4.1 Named Entity Recognition (NER)
* **Model**: Fine-tuned `Bio_ClinicalBERT` (`emilyalsentzer/Bio_ClinicalBERT`) token classifier trained with BIO-tagging schema (`B-COND`, `I-COND`, `B-PROC`, `I-PROC`, `B-MED`, `I-MED`, `B-ANAT`, `I-ANAT`).
* **Fallback & Alignment**: `SciSpacy` biomedical pipeline serves as fallback for unclassified spans. Exact character-start and character-end offsets are mapped to original text spans.
* **Export**: Model exported to ONNX format for accelerated CPU inference in worker containers.

### 4.2 Assertion Classifier
* **Architecture**: Fine-tuned sequence classification head over `Bio_ClinicalBERT` consuming entity text surrounded by a $\pm 2$-sentence context window.
* **Target Classes**:
  1. `present`: Active condition diagnosed or confirmed.
  2. `absent`: Negated mention (e.g., "no evidence of pneumonia").
  3. `possible`: Equivocal or suspected mention (e.g., "rule out sepsis").
  4. `conditional`: Dependent mention (e.g., "if symptoms persist").
  5. `historical`: Past condition no longer active.
  6. `family`: Family medical history (e.g., "mother had breast cancer").
* **Filtering Gate**: Only entities labeled `present` (and configurably `historical`) proceed to ICD-10 code retrieval. Negated, possible, and family history mentions are filtered out.

### 4.3 Entity Normalization
* **Abbreviation Expansion**: Custom biomedical clinical dictionary expands acronyms (e.g., "HTN" $\rightarrow$ "hypertension", "DM2" $\rightarrow$ "type 2 diabetes mellitus").
* **Concept Mapping**: UMLS-lite concept lookup table maps clinical synonyms to standardized concept identifiers before candidate code retrieval.

---

## 5. ICD-10 Code Retrieval & Ranking Architecture

```mermaid
graph TD
    Mention[Normalized Entity Mention + Context] --> Dense[Dense Vector Search bge-small-en-v1.5]
    Mention --> Sparse[Sparse BM25 Term Search]
    Dense -->|Top-50 Hits| RRF[Reciprocal Rank Fusion RRF]
    Sparse -->|Top-50 Hits| RRF
    RRF -->|Top-20 Fused Candidates| Reranker[Cross-Encoder Reranker]
    Reranker -->|Top-5 Ranked Codes| Rules[Hierarchy & Excludes1 Engine]
    Rules -->|Post-Processed Candidate Set| Calib[Isotonic Calibration]
```

### 5.1 Knowledge Indexing (Qdrant)
* Code records constructed from official CMS ICD-10-CM code tables, containing code string, full description, synonyms, chapter/block/category hierarchy metadata, billable flags, and Excludes1 lists.
* **Embeddings**: Dual dense vectors generated using `bge-small-en-v1.5` (benchmarked against biomedical encoders like `S-PubMedBert`) and sparse vectors for BM25 keyword matching.

### 5.2 Retrieval & Fusion
* Candidate retrieval executes per normalized entity mention.
* Parallel dense vector search and sparse BM25 search pull top-50 candidates each from Qdrant.
* **Reciprocal Rank Fusion (RRF)** fuses dense and sparse candidate lists:
  $$RRF\_Score(d) = \sum_{m \in \{dense, sparse\}} \frac{1}{k + r_m(d)}$$
  where $k = 60$ and $r_m(d)$ is the rank of candidate code $d$ in list $m$.

### 5.3 Cross-Encoder Reranking
* Top-20 candidates from RRF pass through a cross-encoder model trained on `(mention_context, icd10_description)` pairs.
* Hard negatives are mined from confusable sibling codes (codes sharing the same category but differing in specificity) during training.
* Outputs refined relevance scores for top-5 candidates.

### 5.4 Hierarchy Post-Processing & Excludes1 Rules
* **Depth Specificity**: System prefers maximally specific billable codes (7-character codes over 3-character category codes).
* **Excludes1 Conflicts**: Deterministic rule validator checks Excludes1 constraints; mutually exclusive codes are filtered or flagged.
* **Modifier Fusion**: Text search merges laterality (left/right/bilateral) and encounter-type (initial/subsequent/sequela) modifiers into candidate code selection.

---

## 6. Human-in-the-Loop & Selective Prediction Architecture

```
                                [Code Candidates]
                                        │
                                        ▼
                           [Isotonic Calibration]
                                        │
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
   Calibrated Conf ≥ 0.85     0.50 ≤ Calibrated Conf < 0.85   Calibrated Conf < 0.50
   [AUTO-ACCEPT BAND]              [REVIEW BAND]             [LOW-CONF / CONFLICT]
   • Target Precision: ≥98%   • Interactive Review       • Auto-Routed to Agent
   • Coverage Target: ≥30%    • Evidence-Jump Highlight    Investigation Team
   • Coder 1-Click Submit     • Accept / Modify / Reject • Typed InvestigationReport
```

### 6.1 Calibration & Selective Prediction
* Raw cross-encoder scores are calibrated using Isotonic Regression fit on a held-out validation set of coded charts.
* Calibrated confidence scores map to three operational triage bands:
  1. **Auto-Accept Band** ($\ge 0.85$ calibrated confidence): High-confidence predictions targeting $\ge 98\%$ precision. Coder performs one-click confirmation on submission.
  2. **Review Band** ($0.50 - 0.84$ calibrated confidence): Standard suggestions requiring human coder evidence verification.
  3. **Low-Confidence / Conflicting Band** ($< 0.50$ calibrated confidence or Excludes1 collision): Automatically routed to the multi-agent investigation team.

### 6.2 Coder Feedback Loop
* Every action in the review console (`accept`, `reject`, `modify`) is recorded in the `review_actions` PostgreSQL table with reason codes and final coder-selected codes.
* Weekly job processes feedback data:
  * Rejects and modifications serve as hard negatives for cross-encoder retraining.
  * Approved codings update the isotonic calibration mapping.
  * De-identified approved chart codings are embedded into the Qdrant `chart_precedents` collection.

---

## 7. Autonomous Agentic Investigation Architecture

For the ~20% of complex charts flagged low-confidence or conflicting, ClinCode invokes an autonomous multi-agent chart investigation team orchestrated using **LangGraph**.

```mermaid
graph TD
    Trigger[Low-Confidence / Conflict Trigger] --> Sup[Supervisor Agent]

    subgraph LangGraph State Machine [Shared ChartInvestigationState]
        Sup -->|Dispatch| EA[Evidence Analyst Agent]
        Sup -->|Dispatch| GA[Guideline Analyst Agent]
        Sup -->|Dispatch| SA[Specificity Agent]
        Sup -->|Dispatch| QD[Query Drafter Agent]

        EA -->|Evidence Findings| State[(Shared State)]
        GA -->|Guideline Findings| State
        SA -->|Hierarchy Findings| State
        QD -->|Draft Physician Query| State

        State --> AV[Adversarial Verifier Agent]
        AV -->|Pass| Report[Emit InvestigationReport]
        AV -->|Fail: < 2 Revisions| Sup
        AV -->|Fail: Max Revisions| Dissent[Emit Report with Dissent Note]
    end
```

### 7.1 Agent Roles & Responsibilities

1. **Supervisor Agent**: Plans the investigation strategy based on the trigger reason (low confidence, assertion conflict, Excludes1 collision). Dispatches specialist agents, enforces execution budgets ($\le 12$ total tool calls, $\le 2$ revision loops), and maintains state.
2. **Evidence Analyst Agent**: Uses `note_tools` (`search_note_sections`, `get_entities`) to re-examine text context surrounding uncertain entities, identifying subtle clinical cues (e.g., active medications implying unstated conditions).
3. **Guideline Analyst Agent**: Performs advanced RAG via `guideline_tools` (`guideline_search`) over official CMS ICD-10-CM guidelines in Qdrant. Retrieves sequencing rules, combination-code clauses, and chapter conventions.
4. **Specificity Agent Agent**: Uses `hierarchy_tools` (`icd10_hierarchy`) and `rules_tools` (`coding_rules_check`) to inspect parent/child/sibling code nodes, check laterality/acuity, and resolve Excludes1 collisions.
5. **Query Drafter Agent**: When an investigation reveals a documentation gap (e.g., unspecified heart failure acuity), drafts a compliant, non-leading CDI physician query.
6. **Adversarial Verifier Agent**: Acts as a strict quality gate attacking draft recommendations. Every proposed code must satisfy three mandatory checks:
   - Must carry an exact evidence span from the note.
   - Must carry a supporting guideline citation or hierarchy justification.
   - Must have zero Excludes1 conflicts.
   - Recommendations failing any check are rejected back to the Supervisor for revision.

### 7.2 Read-Only Tool & Precedent Constraints
* Agents interact strictly through whitelisted, read-only python functions.
* Agents can **never** modify the auto-accept band, **never** generate codes outside the retrieved candidate set, and **never** touch production database records directly.
* **Precedent Memory**: Agents query the Qdrant `chart_precedents` collection to cite past coder-approved chart patterns and avoid re-proposing previously rejected code patterns.

---

## 8. Security & Privacy Architecture

```mermaid
graph LR
    Ingest[Clinical Document] --> DeID[De-identification Gate Regex + NER]
    DeID -->|Scrubbed Text| Index[Search Indexing & LLM Prompts]
    DeID -->|Reversible Map| Fernet[Fernet Encryption Key from Env]
    Fernet --> DB[(PostgreSQL BYTEA)]

    subgraph CI Quality Gates [CI Pipeline Security Checks]
        Canary[Canary PHI Strings] --> LeakTest[PHI-Leak Test Suite]
        LeakTest -->|Assert Missing| AuditPass[Build Approved]
    end
```

1. **PHI Scrubbing & De-identification**: Raw clinical documents pass through regex rules and NER scrubbing prior to search indexing or LLM prompting. Names, MRNs, dates, phone numbers, and addresses are replaced with typed placeholders (e.g., `[NAME_1]`).
2. **Fernet Encryption**: Reversible PHI lookup maps and raw text BYTEA columns are Fernet-encrypted using keys managed via environment variables.
3. **RBAC & Authentication**: JWT tokens with role scopes:
   * `coder`: Access assigned worklists, perform review actions, submit charts.
   * `cdi_specialist`: Review, edit, and send CDI physician queries.
   * `manager`: View throughput, acceptance rate, chapter drift dashboards.
   * `admin`: View system metrics, ONNX model versions, trigger retrain runs.
4. **Audit Trail**: Every chart access, code modification, query creation, and FHIR export writes an immutable record to `audit_log`.
5. **CI PHI-Leak Canaries**: CI test suites inject synthetic PHI canaries and assert their complete absence from vector databases, application logs, and test fixtures.

---

## 9. Database & Persistence Architecture

### 9.1 PostgreSQL Relational Schema

* `documents`: `id` (UUID PK), `external_ref`, `doc_type`, `raw_text_encrypted` (BYTEA), `deid_text` (TEXT), `phi_map_encrypted` (BYTEA), `status` (`received`, `processing`, `ready`, `failed`, `quarantined`), `version`, `created_at`.
* `pipeline_runs`: `id` (UUID PK), `document_id` (FK), `stage`, `status`, `model_versions` (JSONB), `started_at`, `finished_at`, `error`.
* `entities`: `id` (UUID PK), `document_id` (FK), `text`, `label`, `start_char`, `end_char`, `section`, `assertion`, `concept_id`, `ner_conf`.
* `code_suggestions`: `id` (UUID PK), `document_id` (FK), `entity_id` (FK), `icd10_code`, `description`, `rank`, `raw_score`, `calibrated_conf`, `band` (`auto`, `review`, `low`), `justification_md`, `grounded` (BOOL), `evidence_spans` (JSONB), `provenance` (JSONB).
* `review_actions`: `id` (UUID PK), `suggestion_id` (FK), `coder_id` (FK), `action` (`accept`, `reject`, `modify`), `final_code`, `reason`, `at` (TIMESTAMPTZ).
* `chart_submissions`: `id` (UUID PK), `document_id` (FK), `coder_id` (FK), `final_codes` (JSONB), `qa_pair_id`, `submitted_at`.
* `cdi_queries`: `id` (UUID PK), `document_id` (FK), `gap_type`, `query_md`, `status` (`draft`, `sent`, `answered`, `dismissed`), `created_at`.
* `icd10_codes`: `code` (PK), `description`, `chapter`, `block`, `category`, `billable` (BOOL), `excludes1` (JSONB), `synonyms` (JSONB).
* `investigation_runs`: `id` (UUID PK), `document_id` (FK), `trigger`, `status`, `report` (JSONB), `agent_versions` (JSONB), `verifier_pass` (BOOL), `started_at`, `finished_at`.

### 9.2 Qdrant Vector Collections

| Collection Name | Vector Specs | Payload Data | Purpose |
| :--- | :--- | :--- | :--- |
| `icd10` | Dense (384-d `bge-small-en-v1.5`) + Sparse BM25 | `{code, chapter, block, category, billable, excludes1[]}` | Code candidate retrieval per entity mention. |
| `coding_guidelines` | Dense (384-d) + Sparse BM25 | `{section, chapter_scope, rule_type, text}` | Clause-level official coding guideline RAG. |
| `chart_precedents` | Dense (384-d) | `{document_id, codes[], outcome, evidence_summary}` | Precedent memory of approved and rejected chart patterns. |

---

## 10. Deployment Architecture

ClinCode uses a multi-container Docker Compose setup for local development and staging deployments. Production environments map services to managed cloud equivalents (e.g., AWS RDS PostgreSQL, AWS SQS / ElastiCache Redis, ECS container tasks) behind Caddy reverse proxy with TLS termination.

```yaml
# Conceptual Container Architecture
services:
  postgres:      # Database store (Port 5432)
  redis:         # Task queue & cache (Port 6379)
  qdrant:        # Vector DB (Port 6333)
  mlflow:        # Experiment tracking (Port 5000)
  api:           # FastAPI backend service (Port 8000)
  pipeline:      # Worker replicas consuming Redis tasks
  investigator:  # Multi-agent investigation service (Port 8001)
  frontend:      # Nginx serving React SPA (Port 80)
```

---

## 11. Core Engineering Principles

1. **Retrieval, Not Generation**: LLMs are never permitted to generate ICD-10 code strings freely. All suggested codes originate from the official retrieval index.
2. **Assertion-Aware Extraction**: Code candidate generation is strictly gated by assertion detection to eliminate false positives from negated or family history mentions.
3. **Claim-Level Evidence Pinning**: Every suggestion must link directly to character offsets in the clinical text, giving human coders instant verification capability.
4. **Calibrated Selective Prediction**: Confidence scores are calibrated to separate high-precision auto-confirmations from complex cases requiring deep review.
5. **Risk-Tiered Agent Routing**: Heavy multi-agent investigation is reserved for the ~20% of low-confidence or conflicting charts, preventing unnecessary compute overhead.
6. **Evaluation-Gated MLOps**: System deployments and model upgrades are strictly gated by automated regression tests in CI.
