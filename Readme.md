# ClinCode — Clinical Documentation Intelligence & Medical Coding Automation Platform

ClinCode is an AI-assisted medical coding and Clinical Documentation Intelligence (CDI) platform that automates the transformation of unstructured clinical text (discharge summaries, radiology reports) into evidence-backed, standardized ICD-10-CM code suggestions. Designed around a **retrieval-not-generation** architecture with **human-in-the-loop (HITL)** verification, ClinCode ensures zero free-form code hallucination while accelerating medical coding workflows from ~20 minutes down to under 7 minutes per chart.

---

## 1. Executive Summary & Core Thesis

Medical coding is a major operational bottleneck in healthcare. Coding errors account for over **$20B annually in US hospital claim denials**, compliance audit risks, and corrupted clinical statistics. Traditional Computer-Assisted Coding (CAC) tools rely on naive keyword matching that misses clinical context (e.g., coding "no evidence of pneumonia" as pneumonia), while pure Generative AI (LLM) approaches suffer from plausible but dangerous hallucinations—which in medical billing constitutes fraud.

**ClinCode's Thesis**: Medical coding automation is a **retrieval and verification problem, not a generation problem**. 

ClinCode solves this by extracting clinical entities using biomedical transformer models, resolving clinical assertions (negation, family history, temporal context), retrieving candidate ICD-10-CM codes via hybrid vector/keyword search, reranking candidates with cross-encoder models, calibrating confidence scores for selective prediction, and pinning **100% of suggested codes to exact sentence-level evidence** within the clinical note. For complex or low-confidence charts (~20% of cases), an autonomous 6-agent chart investigation team (powered by LangGraph) conducts deep chart reviews and guideline verification without ever inventing codes or modifying high-confidence predictions.

---

## 2. Key Capabilities & Technical Highlights

* **Clinical NER & Span Alignment**: Fine-tuned `Bio_ClinicalBERT` token classifier with `SciSpacy` fallback extracts medical conditions, procedures, medications, and anatomy while preserving exact character-span offsets end-to-end.
* **Assertion Detection**: Fine-tuned context classifier labels conditions as `present`, `absent` (negated), `possible`, `conditional`, `historical`, or `family-history`. Only present (and historical) entities proceed to code retrieval.
* **Hybrid ICD-10 Retrieval**: Dense embedding search (`bge-small-en-v1.5` / biomedical encoders) combined with BM25 sparse retrieval over Qdrant collections, fused via Reciprocal Rank Fusion (RRF).
* **Cross-Encoder Reranking & Hierarchy Logic**: Fine-tuned cross-encoder reranks top candidate codes, followed by deterministic post-processing enforcing ICD-10 hierarchy depth, laterality/acuity modifiers, and **Excludes1** conflict resolution.
* **Calibrated Selective Prediction**: Isotonic regression calibration splits suggestions into three triage bands:
  * **Auto-Accept Band**: High-confidence codes ($\ge 98\%$ precision target) requiring one-click coder confirmation.
  * **Review Band**: Standard confidence codes requiring sentence-evidence inspection.
  * **Low-Confidence / Conflicting Band**: Auto-routed to the multi-agent investigation team.
* **Sentence-Level Evidence Linking**: Every proposed code carries a direct citation chip; clicking a code instantly scrolls and highlights the exact supporting sentence in the clinical note.
* **Grounded LLM Justifications & CDI Query Drafting**: Groundedness-gated LLM layer provides 2–3 sentence code explanations and drafts compliant, non-leading physician queries for documentation gaps (e.g., missing laterality).
* **Agentic Chart Investigation Team**: LangGraph supervisor coordinating 5 specialist agents (Evidence Analyst, Guideline Analyst, Specificity Agent, Query Drafter, Adversarial Verifier) utilizing read-only tools, ICD-10 official guidelines RAG, and precedent memory.
* **Scanned Chart OCR Pipeline**: Computer-vision path using OpenCV (deskew, denoise, adaptive binarization) + OCR with per-line confidence flags for faxed or scanned documents.
* **PHI-Safe Privacy Engineering**: Regex and NER-based PHI scrubbing replaces identifiers with placeholders before search indexing or LLM prompting, backed by Fernet-encrypted mapping and CI leak canaries.

---

## 3. System Architecture & Component Overview

ClinCode is structured as a decoupled, microservices-based system built for horizontal scalability, high throughput, and strict regulatory compliance.

```
Intake API (FastAPI) ──► PostgreSQL (documents, immutable versions)
      │
      ▼ enqueue (Redis queue)
NLP Pipeline Workers (Python, horizontally scaled)
  1. OCR Intake (OpenCV + OCR w/ line confidence)
  2. De-identify (PHI scrub + encrypted map)
  3. Sectionize (span-preserving header match)
  4. NER (Bio_ClinicalBERT ONNX runtime)
  5. Assertion classification (context window)
  6. Normalize & filter entities
  7. Retrieve codes ──► Qdrant (ICD-10 index: dense+sparse)
  8. Rerank (cross-encoder) + hierarchy rules + calibration
  9. LLM justifications + CDI queries (groundedness-gated)
      │  per-stage checkpoints → PostgreSQL
      │  low-confidence / conflicting charts
      ▼
Investigation Team (LangGraph: supervisor + 5 agents, tools, precedent memory)
      │
      ▼
Suggestions store ──► Review API ──► React Coder Console
                                         │ accept/reject/modify (feedback labels)
                                         ▼
                           Feedback dataset ─► recalibration & NER fine-tune jobs (MLflow)
Export API ─► FHIR-flavored claim JSON ─► downstream billing systems
```

### Major Services & Packages

| Component | Tech Stack | Location | Role & Description |
| :--- | :--- | :--- | :--- |
| **API Service** | FastAPI, SQLAlchemy, Pydantic, PyJWT | `services/api` | Serves REST endpoints for document ingestion, suggestions, coder reviews, CDI queries, FHIR exports, and administrative metrics. |
| **Pipeline Workers** | Python, ONNX Runtime, OpenCV, Qdrant | `services/pipeline` | Queue-based asynchronous worker package executing the 10-stage NLP, normalization, retrieval, reranking, calibration, and grounding pipeline. |
| **Investigator Service** | LangGraph, Qdrant, AsyncIO | `services/investigator` | Autonomous multi-agent chart investigation service for low-confidence, assertion-conflicting, or Excludes1-colliding charts. |
| **Review Console** | React 18, TypeScript, Vite | `services/frontend` | Medical coder UI featuring layered note entity highlighting, interactive evidence-jump scrolling, code acceptance panels, and CDI query cards. |
| **ML Package** | PyTorch, Hugging Face, Scikit-learn, ONNX | `ml` | Data preparation, model training (NER, assertion, cross-encoder reranker), calibration fitting, index building, and offline evaluation scripts. |
| **Database** | PostgreSQL, Alembic | `db` | Primary transactional store for documents, pipeline checkpoints, entities, code suggestions, review feedback, CDI queries, and audit logs. |
| **Vector Engine** | Qdrant | Vector Storage | Stores dense/sparse embeddings for `icd10` code records, `coding_guidelines` chunks, and `chart_precedents` memory. |

---

## 4. End-to-End Workflow

```
[Clinical Document] ──► Intake API ──► PostgreSQL (Status: Received)
                             │
                             ▼ (Enqueued to Redis)
                  [NLP Pipeline Stage 1-10]
                  • OpenCV / OCR (if scanned)
                  • PHI Scrub & Fernet Encryption
                  • Sectionization (Offset Math)
                  • Bio_ClinicalBERT NER
                  • Assertion Detection (Filter non-present)
                  • UMLS / Abbrev Normalization
                  • Qdrant Hybrid Code Search
                  • Cross-Encoder Rerank & Excludes1 Rules
                  • Isotonic Calibration & Triage Banding
                  • Grounded LLM Justification & CDI Queries
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
   [High / Standard Conf]            [Low Conf / Conflicting]
            │                                 │
            │                                 ▼
            │                   [Agentic Investigation Team]
            │                   • LangGraph Supervisor + 5 Agents
            │                   • Guideline RAG + Precedent Memory
            │                   • Adversarial Verifier Gate
            │                                 │
            └────────────────┬────────────────┘
                             ▼
                [Suggestions Store (PostgreSQL)]
                             │
                             ▼
                [React Coder Review Console]
                • Evidence-Jump Highlight
                • Accept / Reject / Modify Actions
                             │
                             ▼
                [Chart Submit & Export API]
                • FHIR-flavored Claim JSON
                • Feedback Recorded for Model Retraining
```

---

## 5. Technology Stack & Dependencies

* **Core Backend & APIs**: Python 3.11, FastAPI, Pydantic v2, SQLAlchemy 2.0, AsyncIO, PyJWT, Alembic.
* **Clinical NLP & Machine Learning**: Bio_ClinicalBERT (`emilyalsentzer/Bio_ClinicalBERT`), SciSpacy, PyTorch, Hugging Face Transformers & Trainer, ONNX Runtime, Scikit-learn (Isotonic Regression).
* **Search & Vector Storage**: Qdrant (dense vectors + sparse BM25 vectors), Reciprocal Rank Fusion (RRF).
* **Agentic Workflows & GenAI**: LangGraph, LangChain core abstractions, Groundedness NLI models, Model Context Protocol (MCP) server.
* **Computer Vision & OCR**: OpenCV (deskewing, noise reduction, adaptive binarization), Tesseract OCR / per-line confidence parser.
* **Frontend UI**: React 18, TypeScript, Vite, CSS Modules / Vanilla CSS design tokens.
* **Data Processing & MLOps**: DVC (Data Version Control), MLflow (Experiment & Model Registry), Redis (Job Queue), PostgreSQL 15.
* **Containerization & CI**: Docker, Docker Compose, GitHub Actions.

---

## 6. Datasets & Knowledge Collections

1. **MTSamples & MIMIC-IV-Note Demo Corpus**: De-identified clinical notes (discharge summaries, progress notes, radiology reports) versioned using DVC under `data/mtsamples/`.
2. **Gold Evaluation Charts**: Curated dataset of gold-coded clinical charts used for end-to-end evaluation gates in `data/gold_charts/`.
3. **Official ICD-10-CM Knowledge Base**: Parsed official CMS code tables containing code descriptions, synonyms, chapter/block/category hierarchy, billable status, and Excludes1 rules indexed under `data/icd10cm/` and mirrored into Qdrant (`icd10` collection).
4. **Official ICD-10-CM Coding Guidelines**: Clause-level chunked official guidelines with metadata (`section`, `chapter_scope`, `rule_type`) stored in Qdrant (`coding_guidelines` collection).
5. **Approved Chart Precedents**: Vector collection storing de-identified embeddings of past coder-approved chart codings and rejected suggestions (`chart_precedents` collection).

---

## 7. API Reference Overview

The API service (`services/api`) provides RESTful endpoints with strict JWT authentication and role-based access control (RBAC).

| Endpoint | Method | Role | Description |
| :--- | :--- | :--- | :--- |
| `/api/v1/auth/login` | `POST` | Public | Authenticates user credentials and returns a signed JWT. |
| `/api/v1/documents` | `POST` | Integration | Ingests clinical notes (raw text, PDF, FHIR DocumentReference JSON). |
| `/api/v1/documents/{id}` | `GET` | Coder+ | Returns processing status and stage-by-stage pipeline progress. |
| `/api/v1/documents/{id}/suggestions` | `GET` | Coder+ | Retrieves extracted entities, suggested codes, confidence bands, evidence spans, and justifications. |
| `/api/v1/suggestions/{id}/action` | `POST` | Coder | Records coder decision (`accept`, `reject`, `modify`) with reason and final code. |
| `/api/v1/documents/{id}/submit` | `POST` | Coder | Finalizes chart coding set and routes chart for double-blind QA sampling. |
| `/api/v1/documents/{id}/queries` | `GET/POST`| CDI Specialist+| Fetches generated CDI physician queries or marks queries sent/answered/dismissed. |
| `/api/v1/documents/{id}/export` | `GET` | Integration | Exports final approved code set as FHIR-flavored Claim JSON. |
| `/api/v1/documents/{id}/investigate` | `POST` | Coder+ | Asynchronously triggers the multi-agent investigation workflow for complex charts. |
| `/api/v1/investigations/{run_id}` | `GET` | Coder+ | Retrieves investigation status and typed `InvestigationReport`. |
| `/api/v1/admin/metrics` | `GET` | Manager | Returns coder throughput, auto-accept rates, chapter drift, and system metrics. |
| `/api/v1/admin/models` | `GET` | Admin | Returns currently active stage model versions, ONNX checksums, and evaluation metrics. |
| `/health`, `/metrics` | `GET` | Public | Readiness/liveness probes and Prometheus metrics endpoints. |

---

## 8. Security & Privacy Engineering

* **De-identification Gate**: Philter-style regex rules and NER scrubbers strip PHI (names, dates, MRNs, phone numbers) before any text enters search indexes or LLM prompts.
* **Fernet Encryption**: Reversible PHI mapping is Fernet-encrypted per document using keys stored securely in environment variables.
* **Audit Logging**: Every view, recommendation, coder action, and export is recorded in an immutable PostgreSQL `audit_log` table.
* **CI PHI-Leak Canaries**: Automated CI tests assert that canary PHI strings never leak into Qdrant collections, application logs, or LLM request payloads.

---

## 9. MLOps & CI Evaluation Gates

ClinCode enforces evaluation-gated CI/CD pipelines (`.github/workflows/ci.yml`). Pull requests are blocked if model metrics regress below production benchmarks:

* **NER Token Classification**: Span-level $F_1 \ge 0.80$.
* **Assertion Detection**: Overall $F_1 \ge 0.90$ (zero tolerance for missed negations in auto-accept band).
* **ICD-10 Retrieval**: Recall@5 $\ge 85\%$, Top-1 Accuracy $\ge 65\%$.
* **Selective Prediction Calibration**: Auto-accept band precision $\ge 98\%$ covering $\ge 30\%$ of suggestions.
* **LLM Justification Grounding**: Faithfulness pass rate $\ge 95\%$.
* **Adversarial Verifier Gate**: $100\%$ kill-rate on planted invalid recommendations in test charts.

---

## 10. Project Directory Structure

```text
clincode/
├── README.md
├── docker-compose.yml               # postgres, redis, qdrant, mlflow, api, workers, frontend
├── Makefile
├── .env.example
├── .pre-commit-config.yaml
├── .github/
│   └── workflows/
│       └── ci.yml
├── dvc.yaml
├── params.yaml
├── data/                            # DVC: mtsamples/, icd10cm/, gold_charts/
├── docs/
│   ├── architecture.md
│   ├── adr/
│   │   ├── 0001-retrieval-not-generation.md
│   │   └── 0002-deid-strategy.md
│   ├── coding_rules.md
│   └── runbook.md
├── services/
│   ├── api/                         # FastAPI intake, review, export, admin endpoints
│   ├── pipeline/                    # Asynchronous 10-stage worker package
│   ├── investigator/                # Multi-agent LangGraph investigation service
│   └── frontend/                    # React 18 coder review console
├── ml/                              # Data preparation, model training, evaluation, calibration
├── db/                              # Alembic migrations & seed scripts
└── tests/                           # Unit, integration, API contract, and E2E test suites
```

---

## 11. Milestone Roadmap

* **M1: Repository & Infrastructure Scaffolding**: Folder scaffold, documentation, environment config, DVC setup, Alembic database migrations, seed scripts.
* **M2: Clinical NLP Pipeline**: Bio_ClinicalBERT NER fine-tuning, ONNX Runtime export, assertion classifier, abbreviation normalization, span alignment unit tests.
* **M3: ICD-10 Knowledge Base & Hybrid Retrieval**: Qdrant indexing, BM25 + dense hybrid search, cross-encoder reranker training with hard-negative mining, hierarchy rules.
* **M4: Calibration, Workers & Core API**: Isotonic calibration fitting, Redis queue worker execution with stage checkpoints, FastAPI document and suggestions endpoints.
* **M5: Review Console & Agentic Investigation**: React frontend (NoteViewer, CodePanel, evidence-jump UX), feedback logging, LangGraph 6-agent investigation team with guideline RAG and adversarial verifier.
* **M6: End-to-End Integration & Quality Hardening**: CI evaluation gates, manager dashboards, double-blind QA routing, PHI leak security hardening, FHIR claim export API.

---

## 12. Local Development & Testing

### Prerequisites
* Docker & Docker Compose v2+
* Python 3.11+
* Node.js 18+ & npm 9+

### Quick Start
```bash
# Clone the repository
git clone https://github.com/organization/clincode.git
cd clincode

# Copy environment variables
cp .env.example .env

# Spin up infrastructure (PostgreSQL, Redis, Qdrant, MLflow, API, Workers, Frontend)
make up

# Seed database, load ICD-10 tables, build vector indexes, and enqueue demo charts
make seed
```

### Running Tests
```bash
# Run unit tests
pytest tests/unit

# Run integration tests using Testcontainers
pytest tests/integration

# Run API contract & security tests
pytest tests/api

# Run end-to-end chart lifecycle tests
pytest tests/e2e
```

---

## 13. Future Enhancements

1. **CPT & HCPCS Procedure Coding**: Expanding retrieval and ranking pipelines to cover outpatient procedural coding.
2. **DRG Grouping Integration**: Linking ICD-10 diagnosis codes to Diagnosis Related Groups (DRG) for inpatient reimbursement calculation.
3. **Multi-Note Encounter-Level Coding**: Aggregating clinical evidence across multiple notes within a single patient encounter.
4. **Active Learning Feedback Loop**: Automated prioritization of uncertain coder modifications for continuous reranker and NER retrain passes.
5. **Native FHIR R4 Server Integration**: Supporting direct FHIR `Bundle` and `Claim` resources over standard FHIR REST interfaces.