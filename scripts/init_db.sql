-- ============================================================
-- ClinCode — M1 schema
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm; -- fuzzy code description search

-- ============================================================
-- DOCUMENT & ENCOUNTER LAYER
-- ============================================================

CREATE TABLE IF NOT EXISTS patients (
    patient_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deid_ref VARCHAR(64) UNIQUE NOT NULL, -- never a real MRN
    birth_year INT CHECK (birth_year BETWEEN 1900 AND 2030),
    sex CHAR(1) CHECK (sex IN ('M','F','O','U')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS encounters (
    encounter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    external_ref VARCHAR(64) UNIQUE NOT NULL,
    encounter_type VARCHAR(20) NOT NULL
        CHECK (encounter_type IN ('inpatient','outpatient','emergency','observation')),
    admitted_at TIMESTAMPTZ NOT NULL,
    discharged_at TIMESTAMPTZ,
    discharge_disposition VARCHAR(40),
    payer VARCHAR(60),
    coding_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (coding_status IN ('pending','extracted','suggested','in_review','coded','billed'))
);

CREATE INDEX IF NOT EXISTS idx_enc_status
    ON encounters(coding_status, admitted_at DESC);

CREATE TABLE IF NOT EXISTS clinical_notes (
    note_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id UUID NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    note_type VARCHAR(40) NOT NULL, -- discharge_summary, progress, op_note, consult
    authored_at TIMESTAMPTZ NOT NULL,
    source_uri TEXT, -- s3://clinical-documents/...
    body TEXT NOT NULL, -- canonical, offset-stable text
    char_length INT GENERATED ALWAYS AS (length(body)) STORED,
    version INT NOT NULL DEFAULT 1,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (encounter_id, note_type, authored_at, version)
);

CREATE INDEX IF NOT EXISTS idx_notes_encounter
    ON clinical_notes(encounter_id);

CREATE TABLE IF NOT EXISTS note_sections (
    section_id BIGSERIAL PRIMARY KEY,
    note_id UUID NOT NULL REFERENCES clinical_notes(note_id) ON DELETE CASCADE,
    section_name VARCHAR(40) NOT NULL,
    start_offset INT NOT NULL CHECK (start_offset >= 0),
    end_offset INT NOT NULL,
    CHECK (end_offset > start_offset)
);

CREATE INDEX IF NOT EXISTS idx_sections_note
    ON note_sections(note_id, start_offset);

-- ============================================================
-- TERMINOLOGY REFERENCE
-- ============================================================

CREATE TABLE IF NOT EXISTS code_sets (
    code_set_id VARCHAR(40) PRIMARY KEY, -- 'ICD10CM-FY2026', 'CPT-2026'
    system VARCHAR(20) NOT NULL
        CHECK (system IN ('ICD10CM','ICD10PCS','CPT','HCPCS')),
    release_year INT NOT NULL,
    effective_from DATE NOT NULL,
    effective_to DATE,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS codes (
    code_set_id VARCHAR(40) NOT NULL
        REFERENCES code_sets(code_set_id) ON DELETE CASCADE,
    code VARCHAR(12) NOT NULL,
    short_desc VARCHAR(120) NOT NULL,
    long_desc TEXT,
    chapter VARCHAR(80),
    is_billable BOOLEAN NOT NULL DEFAULT TRUE,
    is_manifestation BOOLEAN NOT NULL DEFAULT FALSE,
    requires_laterality BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (code_set_id, code)
);

CREATE INDEX IF NOT EXISTS idx_codes_desc_trgm
    ON codes USING gin (long_desc gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_codes_billable
    ON codes(code_set_id, is_billable);

CREATE TABLE IF NOT EXISTS code_relations (
    id BIGSERIAL PRIMARY KEY,
    code_set_id VARCHAR(40) NOT NULL,
    code VARCHAR(12) NOT NULL,
    related_code VARCHAR(12) NOT NULL,
    relation_type VARCHAR(20) NOT NULL
        CHECK (relation_type IN ('excludes1','excludes2','parent','code_first','use_additional')),
    FOREIGN KEY (code_set_id, code)
        REFERENCES codes(code_set_id, code) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_relations_code
    ON code_relations(code_set_id, code, relation_type);

-- ============================================================
-- CODING OUTPUT
-- ============================================================

CREATE TABLE IF NOT EXISTS concept_spans (
    span_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id UUID NOT NULL REFERENCES clinical_notes(note_id) ON DELETE CASCADE,
    start_offset INT NOT NULL,
    end_offset INT NOT NULL,
    surface_text TEXT NOT NULL,
    concept_type VARCHAR(30) NOT NULL
        CHECK (concept_type IN ('diagnosis','procedure','medication','finding','anatomy')),
    is_negated BOOLEAN NOT NULL DEFAULT FALSE,
    is_historical BOOLEAN NOT NULL DEFAULT FALSE,
    is_hypothetical BOOLEAN NOT NULL DEFAULT FALSE,
    subject VARCHAR(20) NOT NULL DEFAULT 'patient',
    extractor_version VARCHAR(40) NOT NULL DEFAULT 'm1-placeholder',
    extracted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (end_offset > start_offset)
);

CREATE INDEX IF NOT EXISTS idx_spans_note
    ON concept_spans(note_id, start_offset);

CREATE TABLE IF NOT EXISTS code_suggestions (
    suggestion_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    span_id UUID NOT NULL REFERENCES concept_spans(span_id) ON DELETE CASCADE,
    encounter_id UUID NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    code_set_id VARCHAR(40) NOT NULL,
    code VARCHAR(12) NOT NULL,
    confidence DOUBLE PRECISION NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    rank INT NOT NULL,
    suggester_version VARCHAR(40) NOT NULL DEFAULT 'm1-placeholder',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (code_set_id, code)
        REFERENCES codes(code_set_id, code)
);

CREATE INDEX IF NOT EXISTS idx_sugg_encounter
    ON code_suggestions(encounter_id, rank);

CREATE TABLE IF NOT EXISTS validation_findings (
    finding_id BIGSERIAL PRIMARY KEY,
    encounter_id UUID NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    rule_code VARCHAR(40) NOT NULL,
    severity VARCHAR(10) NOT NULL
        CHECK (severity IN ('info','warning','error')),
    message TEXT NOT NULL,
    involved_codes TEXT[] NOT NULL DEFAULT '{}',
    raised_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_findings_enc
    ON validation_findings(encounter_id, severity);

CREATE TABLE IF NOT EXISTS coder_decisions (
    decision_id BIGSERIAL PRIMARY KEY,
    suggestion_id UUID REFERENCES code_suggestions(suggestion_id) ON DELETE SET NULL,
    encounter_id UUID NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    coder_id VARCHAR(80) NOT NULL,
    action VARCHAR(20) NOT NULL
        CHECK (action IN ('accept','reject','amend','add_manual')),
    final_code VARCHAR(12),
    rationale TEXT,
    decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_decisions_enc
    ON coder_decisions(encounter_id);

CREATE TABLE IF NOT EXISTS encounter_codes (
    encounter_id UUID NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    code_set_id VARCHAR(40) NOT NULL,
    code VARCHAR(12) NOT NULL,
    sequence_no INT NOT NULL CHECK (sequence_no >= 1),
    is_principal BOOLEAN NOT NULL DEFAULT FALSE,
    present_on_admission CHAR(1),
    finalised_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (encounter_id, code_set_id, code)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_one_principal
    ON encounter_codes(encounter_id)
    WHERE is_principal;

CREATE TABLE IF NOT EXISTS audit_log (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor VARCHAR(80) NOT NULL,
    action VARCHAR(50) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id VARCHAR(100) NOT NULL,
    detail JSONB NOT NULL DEFAULT '{}'
);