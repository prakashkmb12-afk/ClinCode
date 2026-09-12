# ClinCode Operational Runbook

This document provides step-by-step procedures for operating, monitoring, troubleshooting, and recovering the **ClinCode** platform services in local, staging, and production environments.

---

## 1. System Startup & Operational Environment

### 1.1 Local Development Stack Startup

The system stack is managed using Docker Compose and standard `make` target workflows:

```bash
# 1. Environment configuration setup
cp .env.example .env

# 2. Boot system infrastructure (PostgreSQL, Redis, Qdrant, MLflow, API, Workers, Frontend)
make up

# 3. Seed database, trigger ICD-10 table loading, build vector indexes, and enqueue demo charts
make seed
```

### 1.2 Verifying Service Status

Inspect running container containers and port bindings:

```bash
docker compose ps
```

Expected service ports:
* **API Service (`services/api`)**: `http://localhost:8000` (Docs: `http://localhost:8000/docs`)
* **Investigator Service (`services/investigator`)**: `http://localhost:8001`
* **Frontend Coder Console (`services/frontend`)**: `http://localhost:80`
* **Qdrant Vector DB**: `http://localhost:6333` (Dashboard: `http://localhost:6333/dashboard`)
* **MLflow Tracking Server**: `http://localhost:5000`
* **PostgreSQL Database**: `localhost:5432`
* **Redis Task Queue**: `localhost:6379`

---

## 2. Health Probes & Monitoring

### 2.1 Health Check Endpoints

Verify service liveness and component connectivity:

```bash
# General API health probe
curl -s http://localhost:8000/health | jq .

# Response format:
# {
#   "status": "healthy",
#   "database": "connected",
#   "redis": "connected",
#   "qdrant": "connected"
# }
```

### 2.2 System & Pipeline Metrics

Prometheus metrics are exposed at `/metrics` on the API service:

```bash
curl -s http://localhost:8000/metrics
```

Key operational metrics to monitor:
* `clincode_pipeline_stage_latency_seconds_bucket`: Histogram of per-stage execution times.
* `clincode_document_status_total`: Count of documents grouped by status (`received`, `processing`, `ready`, `failed`, `quarantined`).
* `clincode_auto_accept_rate`: Fraction of suggestions landing in the high-confidence auto-accept band.
* `clincode_grounding_failure_total`: Count of LLM justifications suppressed due to ungrounded sentence citations.
* `clincode_investigation_verifier_kills_total`: Count of draft agent recommendations rejected by the Adversarial Verifier.

---

## 3. Document Processing Lifecycle & Queue Management

### 3.1 Document Ingestion Flow

Documents transition through an immutable status workflow:

```
[received] ──► [processing] ──► [ready]
                    │
                    ├──► [failed]      (Stage crash / execution error)
                    └──► [quarantined] (Poison document / invalid format)
```

### 3.2 Inspecting Queue Backlog

Check Redis queue depth and active worker tasks:

```bash
# Query active pipeline task queue in Redis
docker compose exec redis redis-cli llen clincode_pipeline_queue
```

If queue depth accumulates, scale worker replicas horizontally:

```bash
docker compose up -d --scale pipeline=4
```

---

## 4. Troubleshooting Pipeline & Stage Failures

### 4.1 Identifying Failed Documents

Find documents in `failed` or `quarantined` state:

```sql
-- Query PostgreSQL database for failed document runs
SELECT d.id, d.external_ref, d.status, pr.stage, pr.error
FROM documents d
JOIN pipeline_runs pr ON d.id = pr.document_id
WHERE d.status IN ('failed', 'quarantined') AND pr.status = 'failed';
```

### 4.2 Handling Poison Documents

If a corrupted document causes recurring stage failures:
1. Document status is automatically updated to `quarantined`.
2. Error details are logged in `pipeline_runs`.
3. Neighboring queue tasks proceed without worker blockage.
4. To re-queue a quarantined document after fixing underlying input data or code:

```sql
-- Reset document status and failed stage for retry
UPDATE pipeline_runs SET status = 'queued', error = NULL WHERE document_id = '<DOC_UUID>' AND stage = '<FAILED_STAGE>';
UPDATE documents SET status = 'received' WHERE id = '<DOC_UUID>';
```

---

## 5. Model Versioning & Quality Drift Management

### 5.1 Active Model Version Inspection

Verify currently active model versions and ONNX binary checksums:

```bash
curl -s http://localhost:8000/api/v1/admin/models -H "Authorization: Bearer <ADMIN_JWT>" | jq .
```

### 5.2 Chapter Acceptance Rate Monitoring

A drop in acceptance rate for specific ICD-10 chapters (e.g., Chapter 9: Diseases of the Circulatory System) signals model quality drift or shift in incoming chart documentation styles:

```bash
curl -s "http://localhost:8000/api/v1/admin/metrics?window=30d" -H "Authorization: Bearer <MANAGER_JWT>" | jq .acceptance_rate_by_chapter
```

### 5.3 Hot-Reloading Model Versions

When a new fine-tuned Bio_ClinicalBERT NER or cross-encoder reranker model is promoted in MLflow:
1. Update model artifact version references in `.env` (`NER_MODEL_VERSION`, `RERANKER_MODEL_VERSION`).
2. Trigger graceful worker reload without dropping active requests:

```bash
docker compose exec pipeline kill -HUP 1
```

---

## 6. Debugging Retrieval & Code Reranking Issues

If a valid condition mentioned in text fails to retrieve the correct ICD-10 code:

1. **Verify Qdrant Vector Collection Index**:
   ```bash
   curl -s http://localhost:6333/collections/icd10 | jq .
   ```
2. **Execute Manual Test Search**:
   Test hybrid retrieval for entity text directly against Qdrant:
   ```bash
   python -m clincode_ml.retrieval.test_query --mention "acute systolic heart failure"
   ```
3. **Inspect Reranker Hard Negatives**:
   Review top-20 cross-encoder input scores to verify whether confusable sibling codes (e.g., `I50.21` vs `I50.23`) are correctly scored.

---

## 7. Multi-Agent Investigation Inspection & Recovery

### 7.1 Inspecting Active Investigation State

For low-confidence or conflicting charts auto-routed to the multi-agent investigation team, inspect state execution:

```bash
curl -s http://localhost:8000/api/v1/investigations/<RUN_UUID> -H "Authorization: Bearer <CODER_JWT>" | jq .
```

### 7.2 Recovering Stalled Investigation Runs

If an investigation run stalls due to LLM provider timeouts or execution budget exhaustion ($\ge 12$ tool calls):
1. System automatically aborts agent loop.
2. Emits a partial `InvestigationReport` containing a dissent note.
3. Chart degrades gracefully to standard human review band without blocking the coder console.

---

## 8. PHI Security Incidents & Audit Logging

### 8.1 PHI Encryption Key Rotation

In the event of key rotation requirements or suspected credential exposure:

1. Generate new Fernet encryption key:
   ```bash
   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
   ```
2. Run database re-encryption utility:
   ```bash
   python -m clincode_api.db.reencrypt_phi --old-key "<OLD_KEY>" --new-key "<NEW_KEY>"
   ```
3. Update `PHI_ENCRYPTION_KEY` in environment config and restart services.

### 8.2 Executing Automated PHI-Leak Verification

Run CI leak canary test suite locally to verify zero PHI escapes into logs or vector DBs:

```bash
pytest tests/api/test_phi_leak_canary.py -v
```

---

## 9. Backup & Database Maintenance

### 9.1 PostgreSQL Backup & Restore

```bash
# Create database backup
docker compose exec postgres pg_dump -U postgres clincode_db > backup_clincode_$(date +%Y%m%d).sql

# Restore database backup
cat backup_clincode_20260911.sql | docker compose exec -T postgres psql -U postgres clincode_db
```

### 9.2 Qdrant Vector Index Snapshots

```bash
# Trigger snapshot creation for icd10 collection
curl -X POST http://localhost:6333/collections/icd10/snapshots
```
