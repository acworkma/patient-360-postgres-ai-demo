-- ============================================================================
-- Migration 020: Functions for PHI Redaction and Note Ingestion
-- ============================================================================
-- Creates SQL functions that leverage azure_ai extension for:
-- 1. PHI-only redaction using Azure AI Language
-- 2. Note ingestion pipeline (raw -> redact -> embed -> store)
-- 3. Context retrieval for RAG (vector + keyword search)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: redact_phi
-- ----------------------------------------------------------------------------
-- Redacts Protected Health Information (PHI) from text using Azure AI Language.
-- Uses domain='phi' to only redact healthcare-specific identifiers.
-- 
-- Parameters:
--   note_text: The clinical note text to redact
--   language: Language code (default 'en')
--
-- Returns:
--   redacted_text: Text with PHI replaced by category markers
--   phi_entities: JSON array of detected entities with metadata
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION redact_phi(
    note_text TEXT,
    language TEXT DEFAULT 'en'
)
RETURNS TABLE (
    redacted_text TEXT,
    phi_entities JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    pii_result RECORD;
    entities JSONB := '[]'::jsonb;
    result_text TEXT;
    entity_record RECORD;
BEGIN
    -- Call Azure AI Language PII detection with PHI domain
    -- This only detects healthcare-specific identifiers, not general PII
    SELECT * INTO pii_result 
    FROM azure_cognitive.recognize_pii_entities(
        note_text,
        language,
        domain => 'phi'
    );
    
    -- Extract the redacted text (Azure AI returns this directly)
    result_text := pii_result.redacted_text;
    
    -- Build entities JSON from the recognition result
    -- Note: The azure_cognitive extension returns entities with these columns:
    -- text, category, subcategory, confidence_score
    -- (offset and length may not be present in all versions)
    BEGIN
        FOR entity_record IN 
            SELECT 
                e.text,
                e.category,
                e.subcategory,
                e.confidence_score
            FROM unnest(pii_result.entities) AS e
        LOOP
            entities := entities || jsonb_build_object(
                'text', entity_record.text,
                'category', entity_record.category,
                'subcategory', entity_record.subcategory,
                'confidence', entity_record.confidence_score
            );
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        -- If entity extraction fails, just return empty array
        entities := '[]'::jsonb;
    END;
    
    RETURN QUERY SELECT result_text, entities;
END;
$$;

COMMENT ON FUNCTION redact_phi IS 'Redacts PHI from clinical text using Azure AI Language (domain=phi)';

-- ----------------------------------------------------------------------------
-- Function: redact_phi_simple
-- ----------------------------------------------------------------------------
-- Simplified version that just returns redacted text (for use in expressions)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION redact_phi_simple(
    note_text TEXT,
    language TEXT DEFAULT 'en'
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    result RECORD;
BEGIN
    SELECT * INTO result FROM redact_phi(note_text, language);
    RETURN result.redacted_text;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: generate_embedding
-- ----------------------------------------------------------------------------
-- Generates vector embedding for text using Azure OpenAI.
-- Returns NULL if Azure OpenAI is not configured.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_embedding(
    input_text TEXT,
    deployment_name TEXT DEFAULT NULL
)
RETURNS vector(1536)
LANGUAGE plpgsql
AS $$
DECLARE
    embedding_result vector(1536);
    actual_deployment TEXT;
BEGIN
    -- Use provided deployment or try to get from settings
    actual_deployment := COALESCE(
        deployment_name,
        current_setting('app.embedding_deployment', true),
        'text-embedding-ada-002'
    );
    
    -- Attempt to generate embedding via Azure OpenAI
    BEGIN
        SELECT azure_openai.create_embeddings(
            actual_deployment,
            input_text
        )::vector(1536) INTO embedding_result;
        
        RETURN embedding_result;
    EXCEPTION WHEN OTHERS THEN
        -- Azure OpenAI not configured or error occurred
        -- Return NULL - the application will fall back to keyword search
        RAISE NOTICE 'Embedding generation failed: %. Falling back to keyword search.', SQLERRM;
        RETURN NULL;
    END;
END;
$$;

COMMENT ON FUNCTION generate_embedding IS 'Generates vector embedding using Azure OpenAI, returns NULL if unavailable';

-- ----------------------------------------------------------------------------
-- Function: ingest_note
-- ----------------------------------------------------------------------------
-- Ingests a clinical note through the PHI-safe pipeline:
-- 1. Store raw note in notes_raw
-- 2. Redact PHI using Azure AI Language
-- 3. Generate embedding (if Azure OpenAI configured)
-- 4. Store redacted note with embedding in notes_phi
--
-- Parameters:
--   p_patient_id: Patient identifier
--   p_encounter_id: Optional encounter reference
--   p_raw_text: Original clinical note text with PHI
--   p_note_type: Type of note (progress, discharge, etc.)
--   p_author: Note author name
--
-- Returns:
--   note_id: The ID of the created note
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_note(
    p_patient_id TEXT,
    p_encounter_id BIGINT DEFAULT NULL,
    p_raw_text TEXT DEFAULT NULL,
    p_note_type TEXT DEFAULT 'progress',
    p_author TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_note_id BIGINT;
    v_redacted_text TEXT;
    v_phi_entities JSONB;
    v_embedding vector(1536);
    v_redact_result RECORD;
BEGIN
    -- Validate patient exists
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Patient with ID % does not exist', p_patient_id;
    END IF;
    
    -- Validate encounter if provided
    IF p_encounter_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM encounters WHERE encounter_id = p_encounter_id
    ) THEN
        RAISE EXCEPTION 'Encounter with ID % does not exist', p_encounter_id;
    END IF;
    
    -- Insert raw note
    INSERT INTO notes_raw (patient_id, encounter_id, note_type, raw_text, author)
    VALUES (p_patient_id, p_encounter_id, p_note_type, p_raw_text, p_author)
    RETURNING note_id INTO v_note_id;
    
    -- Redact PHI from the note
    BEGIN
        SELECT * INTO v_redact_result FROM redact_phi(p_raw_text, 'en');
        v_redacted_text := v_redact_result.redacted_text;
        v_phi_entities := v_redact_result.phi_entities;
    EXCEPTION WHEN OTHERS THEN
        -- If PHI redaction fails, use a placeholder
        -- In production, you might want to fail the entire transaction
        RAISE WARNING 'PHI redaction failed: %. Using placeholder text.', SQLERRM;
        v_redacted_text := '[PHI REDACTION FAILED - TEXT WITHHELD]';
        v_phi_entities := '[]'::jsonb;
    END;
    
    -- Generate embedding for the redacted text
    v_embedding := generate_embedding(v_redacted_text);
    
    -- Insert PHI-redacted note
    INSERT INTO notes_phi (note_id, patient_id, encounter_id, redacted_text, phi_entities, embedding)
    VALUES (v_note_id, p_patient_id, p_encounter_id, v_redacted_text, v_phi_entities, v_embedding)
    ON CONFLICT (note_id) DO UPDATE SET
        redacted_text = EXCLUDED.redacted_text,
        phi_entities = EXCLUDED.phi_entities,
        embedding = EXCLUDED.embedding;
    
    RETURN v_note_id;
END;
$$;

COMMENT ON FUNCTION ingest_note IS 'Ingests clinical note: stores raw, redacts PHI, generates embedding';

-- ----------------------------------------------------------------------------
-- Function: retrieve_context
-- ----------------------------------------------------------------------------
-- Retrieves relevant context for RAG from notes, labs, and medications.
-- Uses vector similarity search when embeddings available, falls back to keyword search.
--
-- Parameters:
--   p_patient_id: Patient identifier
--   p_query_text: The query to search for
--   p_k: Maximum number of results to return (default 5)
--
-- Returns:
--   Table of sources with type, ID, label, snippet, score, and metadata
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retrieve_context(
    p_patient_id TEXT,
    p_query_text TEXT,
    p_k INT DEFAULT 5
)
RETURNS TABLE (
    source_type TEXT,
    source_id BIGINT,
    label TEXT,
    snippet TEXT,
    score DOUBLE PRECISION,
    metadata JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_query_embedding vector(1536);
    v_use_vector_search BOOLEAN := false;
    v_search_terms TEXT[];
BEGIN
    -- Try to generate embedding for the query
    v_query_embedding := generate_embedding(p_query_text);
    
    -- Check if we have any notes with embeddings
    IF v_query_embedding IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM notes_phi 
            WHERE patient_id = p_patient_id 
            AND embedding IS NOT NULL
            LIMIT 1
        ) INTO v_use_vector_search;
    END IF;
    
    -- Extract search terms for keyword fallback
    v_search_terms := regexp_split_to_array(lower(p_query_text), '\s+');
    
    RETURN QUERY
    WITH note_results AS (
        -- Vector search over notes (if available)
        SELECT 
            'note'::TEXT as src_type,
            np.note_id as src_id,
            'Note ' || to_char(np.created_at, 'YYYY-MM-DD') as src_label,
            LEFT(np.redacted_text, 300) as src_snippet,
            CASE 
                WHEN v_use_vector_search AND np.embedding IS NOT NULL THEN
                    1 - (np.embedding <=> v_query_embedding)  -- Cosine similarity
                ELSE
                    -- Keyword matching score (simple)
                    (
                        SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
                        FROM unnest(v_search_terms) term
                        WHERE lower(np.redacted_text) LIKE '%' || term || '%'
                    )
            END as src_score,
            jsonb_build_object(
                'encounter_id', np.encounter_id,
                'created_at', np.created_at,
                'phi_entity_count', jsonb_array_length(np.phi_entities)
            ) as src_metadata
        FROM notes_phi np
        WHERE np.patient_id = p_patient_id
    ),
    observation_results AS (
        -- Keyword search over observations (labs, vitals)
        SELECT 
            'lab'::TEXT as src_type,
            o.obs_id as src_id,
            o.display || ' (' || to_char(o.observed_at, 'YYYY-MM-DD') || ')' as src_label,
            COALESCE(o.value_text, o.value_num::text) || ' ' || COALESCE(o.unit, '') as src_snippet,
            (
                SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
                FROM unnest(v_search_terms) term
                WHERE lower(o.display) LIKE '%' || term || '%'
                   OR lower(COALESCE(o.value_text, '')) LIKE '%' || term || '%'
                   OR lower(o.code) LIKE '%' || term || '%'
            ) as src_score,
            jsonb_build_object(
                'code', o.code,
                'value_num', o.value_num,
                'unit', o.unit,
                'observed_at', o.observed_at,
                'encounter_id', o.encounter_id
            ) as src_metadata
        FROM observations o
        WHERE o.patient_id = p_patient_id
    ),
    medication_results AS (
        -- Keyword search over medications
        SELECT 
            'med'::TEXT as src_type,
            m.med_id as src_id,
            m.name || ' ' || COALESCE(m.dose, '') as src_label,
            m.name || ' ' || COALESCE(m.dose, '') || ' ' || COALESCE(m.frequency, '') || 
            ' (Status: ' || m.status || ')' as src_snippet,
            (
                SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
                FROM unnest(v_search_terms) term
                WHERE lower(m.name) LIKE '%' || term || '%'
                   OR lower(COALESCE(m.reason, '')) LIKE '%' || term || '%'
            ) as src_score,
            jsonb_build_object(
                'dose', m.dose,
                'frequency', m.frequency,
                'status', m.status,
                'start_date', m.start_date,
                'end_date', m.end_date,
                'prescriber', m.prescriber,
                'reason', m.reason
            ) as src_metadata
        FROM medications m
        WHERE m.patient_id = p_patient_id
    ),
    all_results AS (
        SELECT * FROM note_results
        UNION ALL
        SELECT * FROM observation_results  
        UNION ALL
        SELECT * FROM medication_results
    )
    SELECT 
        src_type,
        src_id,
        src_label,
        src_snippet,
        src_score,
        src_metadata
    FROM all_results
    WHERE src_score > 0
    ORDER BY src_score DESC
    LIMIT p_k;
END;
$$;

COMMENT ON FUNCTION retrieve_context(TEXT, TEXT, INT) IS 'Retrieves relevant context for RAG using vector/keyword search';

-- ----------------------------------------------------------------------------
-- Function: search_notes_vector
-- ----------------------------------------------------------------------------
-- Pure vector similarity search over notes for a patient.
-- Used when you want direct vector search without other sources.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION search_notes_vector(
    p_patient_id TEXT,
    p_query_embedding vector(1536),
    p_k INT DEFAULT 5
)
RETURNS TABLE (
    note_id BIGINT,
    redacted_text TEXT,
    similarity DOUBLE PRECISION,
    created_at TIMESTAMPTZ
)
LANGUAGE sql
AS $$
    SELECT 
        np.note_id,
        np.redacted_text,
        1 - (np.embedding <=> p_query_embedding) as similarity,
        np.created_at
    FROM notes_phi np
    WHERE np.patient_id = p_patient_id
    AND np.embedding IS NOT NULL
    ORDER BY np.embedding <=> p_query_embedding
    LIMIT p_k;
$$;

COMMENT ON FUNCTION search_notes_vector IS 'Vector similarity search over notes for a patient';

-- ----------------------------------------------------------------------------
-- Function: get_patient_snapshot
-- ----------------------------------------------------------------------------
-- Returns a comprehensive snapshot of patient data for the dashboard.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_patient_snapshot(p_patient_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'patient', (
            SELECT jsonb_build_object(
                'patient_id', p.patient_id,
                'display_name', p.display_name,
                'dob', p.dob,
                'sex', p.sex,
                'mrn', p.mrn,
                'age', EXTRACT(YEAR FROM age(p.dob))
            )
            FROM patients p
            WHERE p.patient_id = p_patient_id
        ),
        'problems', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'problem_id', pr.problem_id,
                'display', pr.display,
                'status', pr.status,
                'onset_date', pr.onset_date
            )), '[]'::jsonb)
            FROM problems pr
            WHERE pr.patient_id = p_patient_id AND pr.status = 'active'
        ),
        'allergies', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'allergy_id', a.allergy_id,
                'substance', a.substance,
                'reaction', a.reaction,
                'severity', a.severity
            )), '[]'::jsonb)
            FROM allergies a
            WHERE a.patient_id = p_patient_id AND a.status = 'active'
        ),
        'active_medications', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'med_id', m.med_id,
                'name', m.name,
                'dose', m.dose,
                'frequency', m.frequency
            )), '[]'::jsonb)
            FROM medications m
            WHERE m.patient_id = p_patient_id AND m.status = 'active'
        ),
        'key_vitals', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'code', o.code,
                'display', o.display,
                'value', COALESCE(o.value_text, o.value_num::text),
                'unit', o.unit,
                'observed_at', o.observed_at
            )), '[]'::jsonb)
            FROM (
                SELECT DISTINCT ON (code) *
                FROM observations
                WHERE patient_id = p_patient_id
                AND code IN ('BP', 'A1C', 'eGFR', 'HR', 'BMI', 'weight')
                ORDER BY code, observed_at DESC
            ) o
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_patient_snapshot IS 'Returns comprehensive patient snapshot for dashboard';

-- ----------------------------------------------------------------------------
-- Function: get_patient_timeline
-- ----------------------------------------------------------------------------
-- Returns timeline of clinical events for a patient.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_patient_timeline(
    p_patient_id TEXT,
    p_limit INT DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'event_type', event_type,
                'event_id', event_id,
                'event_time', event_time,
                'event_subtype', event_subtype,
                'description', description,
                'details', details
            ) ORDER BY event_time DESC
        ), '[]'::jsonb)
        FROM (
            -- Encounters
            SELECT 
                'encounter' as event_type,
                encounter_id as event_id,
                start_time as event_time,
                encounter_type as event_subtype,
                reason as description,
                jsonb_build_object(
                    'provider', provider_name,
                    'facility', facility,
                    'end_time', end_time
                ) as details
            FROM encounters
            WHERE patient_id = p_patient_id
            
            UNION ALL
            
            -- Notes (PHI-redacted)
            SELECT 
                'note' as event_type,
                note_id as event_id,
                created_at as event_time,
                'clinical_note' as event_subtype,
                LEFT(redacted_text, 150) || '...' as description,
                jsonb_build_object(
                    'encounter_id', encounter_id,
                    'phi_count', jsonb_array_length(phi_entities)
                ) as details
            FROM notes_phi
            WHERE patient_id = p_patient_id
            
            UNION ALL
            
            -- Labs/Observations
            SELECT 
                'observation' as event_type,
                obs_id as event_id,
                observed_at as event_time,
                code as event_subtype,
                display || ': ' || COALESCE(value_text, value_num::text) || ' ' || COALESCE(unit, '') as description,
                jsonb_build_object(
                    'code', code,
                    'value_num', value_num,
                    'unit', unit
                ) as details
            FROM observations
            WHERE patient_id = p_patient_id
            
            UNION ALL
            
            -- Medication changes
            SELECT 
                'medication' as event_type,
                med_id as event_id,
                start_date::timestamptz as event_time,
                status as event_subtype,
                name || ' ' || COALESCE(dose, '') || ' started' as description,
                jsonb_build_object(
                    'dose', dose,
                    'frequency', frequency,
                    'prescriber', prescriber,
                    'reason', reason
                ) as details
            FROM medications
            WHERE patient_id = p_patient_id
        ) events
        LIMIT p_limit
    );
END;
$$;

COMMENT ON FUNCTION get_patient_timeline IS 'Returns chronological timeline of clinical events';
