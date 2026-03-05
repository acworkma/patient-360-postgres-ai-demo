-- ============================================================================
-- Migration 060: Enhanced Retrieval with Semantic Reranking
-- ============================================================================
-- Upgrades retrieve_context to use two-stage retrieval:
-- Stage 1: Vector/keyword search to get candidate results
-- Stage 2: azure_ai.rank() for semantic reranking
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: retrieve_context (Enhanced with Semantic Reranking)
-- ----------------------------------------------------------------------------
-- Two-stage retrieval for better relevance:
-- 1. Initial retrieval using vector similarity or keyword search
-- 2. Semantic reranking using Cohere rerank via azure_ai.rank()
--
-- Parameters:
--   p_patient_id: Patient identifier
--   p_query_text: The query to search for
--   p_k: Maximum number of final results (default 5)
--   p_candidate_multiplier: How many candidates to retrieve before reranking (default 3x)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retrieve_context(
    p_patient_id TEXT,
    p_query_text TEXT,
    p_k INT DEFAULT 5,
    p_candidate_multiplier INT DEFAULT 3
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
    v_use_reranking BOOLEAN := false;
    v_search_terms TEXT[];
    v_candidate_count INT;
    v_ranking_endpoint TEXT;
BEGIN
    -- Calculate how many candidates to retrieve for reranking
    v_candidate_count := p_k * p_candidate_multiplier;
    
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
    
    -- Check if reranking is available (endpoint must be set AND non-empty)
    BEGIN
        v_ranking_endpoint := azure_ai.get_setting('azure_ml.serverless_ranking_endpoint');
        v_use_reranking := (v_ranking_endpoint IS NOT NULL AND v_ranking_endpoint <> '');
    EXCEPTION WHEN OTHERS THEN
        v_use_reranking := false;
    END;
    
    -- Extract search terms for keyword fallback
    v_search_terms := regexp_split_to_array(lower(p_query_text), '\s+');
    
    -- Stage 1: Get candidate results
    CREATE TEMP TABLE IF NOT EXISTS temp_candidates (
        src_type TEXT,
        src_id BIGINT,
        src_label TEXT,
        src_snippet TEXT,
        src_score DOUBLE PRECISION,
        src_metadata JSONB
    ) ON COMMIT DROP;
    
    DELETE FROM temp_candidates;
    
    -- Insert note candidates (JOIN notes_raw for note_type)
    INSERT INTO temp_candidates
    SELECT 
        'note'::TEXT,
        np.note_id,
        CASE 
            WHEN nr.note_type = 'progress' THEN 'Progress Note'
            WHEN nr.note_type = 'lab_review' THEN 'Lab Review'
            WHEN nr.note_type = 'telephone' THEN 'Phone Encounter'
            WHEN nr.note_type = 'education' THEN 'Education Note'
            WHEN nr.note_type = 'coordination' THEN 'Care Coordination'
            ELSE 'Clinical Note'
        END || ' (' || to_char(np.created_at, 'YYYY-MM-DD') || ')',
        LEFT(np.redacted_text, 500),  -- Larger snippet for reranking
        CASE 
            WHEN v_use_vector_search AND np.embedding IS NOT NULL THEN
                1 - (np.embedding <=> v_query_embedding)
            ELSE
                (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
                 FROM unnest(v_search_terms) term
                 WHERE lower(np.redacted_text) LIKE '%' || term || '%')
        END,
        jsonb_build_object(
            'encounter_id', np.encounter_id,
            'created_at', np.created_at,
            'note_type', nr.note_type,
            'phi_entity_count', jsonb_array_length(COALESCE(np.phi_entities, '[]'::jsonb))
        )
    FROM notes_phi np
    JOIN notes_raw nr ON nr.note_id = np.note_id
    WHERE np.patient_id = p_patient_id;
    
    -- Insert observation candidates
    INSERT INTO temp_candidates
    SELECT 
        'lab'::TEXT,
        o.obs_id,
        o.display || ' (' || to_char(o.observed_at, 'YYYY-MM-DD') || ')',
        o.display || ': ' || COALESCE(o.value_text, o.value_num::text) || ' ' || COALESCE(o.unit, ''),
        (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
         FROM unnest(v_search_terms) term
         WHERE lower(o.display) LIKE '%' || term || '%'
            OR lower(COALESCE(o.value_text, '')) LIKE '%' || term || '%'
            OR lower(o.code) LIKE '%' || term || '%'),
        jsonb_build_object(
            'code', o.code,
            'value_num', o.value_num,
            'unit', o.unit,
            'observed_at', o.observed_at,
            'encounter_id', o.encounter_id
        )
    FROM observations o
    WHERE o.patient_id = p_patient_id;
    
    -- Insert medication candidates
    INSERT INTO temp_candidates
    SELECT 
        'med'::TEXT,
        m.med_id,
        m.name || ' ' || COALESCE(m.dose, ''),
        m.name || ' ' || COALESCE(m.dose, '') || ' ' || COALESCE(m.frequency, '') || 
        '. Reason: ' || COALESCE(m.reason, 'Not specified') || '. Status: ' || m.status,
        (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
         FROM unnest(v_search_terms) term
         WHERE lower(m.name) LIKE '%' || term || '%'
            OR lower(COALESCE(m.reason, '')) LIKE '%' || term || '%'),
        jsonb_build_object(
            'dose', m.dose,
            'frequency', m.frequency,
            'status', m.status,
            'start_date', m.start_date,
            'end_date', m.end_date,
            'prescriber', m.prescriber,
            'reason', m.reason
        )
    FROM medications m
    WHERE m.patient_id = p_patient_id;
    
    -- Stage 2: Rerank using azure_ai.rank() if available
    IF v_use_reranking THEN
        -- Get top candidates for reranking
        RETURN QUERY
        WITH top_candidates AS (
            SELECT * FROM temp_candidates
            WHERE src_score > 0
            ORDER BY src_score DESC
            LIMIT v_candidate_count
        ),
        candidate_array AS (
            SELECT 
                array_agg(src_snippet ORDER BY src_score DESC) as snippets,
                array_agg(src_id::text ORDER BY src_score DESC) as ids
            FROM top_candidates
        ),
        reranked AS (
            SELECT 
                r.id::BIGINT as reranked_id,
                r.rank as rerank_position,
                r.score as rerank_score
            FROM candidate_array ca,
            LATERAL azure_ai.rank(
                query => p_query_text,
                document_contents => ca.snippets,
                document_ids => ca.ids,
                model => 'Cohere-rerank-v4.0-fast'
            ) r
            WHERE array_length(ca.snippets, 1) > 0
        )
        SELECT 
            tc.src_type,
            tc.src_id,
            tc.src_label,
            LEFT(tc.src_snippet, 300),  -- Trim snippet for output
            COALESCE(rr.rerank_score, tc.src_score),
            tc.src_metadata
        FROM top_candidates tc
        LEFT JOIN reranked rr ON tc.src_id = rr.reranked_id
        ORDER BY COALESCE(rr.rerank_position, 999), COALESCE(rr.rerank_score, tc.src_score) DESC
        LIMIT p_k;
    ELSE
        -- Fallback: Return without reranking
        RETURN QUERY
        SELECT 
            src_type,
            src_id,
            src_label,
            LEFT(src_snippet, 300),
            src_score,
            src_metadata
        FROM temp_candidates
        WHERE src_score > 0
        ORDER BY src_score DESC
        LIMIT p_k;
    END IF;
END;
$$;

COMMENT ON FUNCTION retrieve_context(TEXT, TEXT, INT, INT) IS 'Two-stage RAG retrieval with semantic reranking via azure_ai.rank()';

-- ----------------------------------------------------------------------------
-- Function: retrieve_context_simple (Without reranking - for comparison)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retrieve_context_simple(
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
    
    IF v_query_embedding IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM notes_phi 
            WHERE patient_id = p_patient_id 
            AND embedding IS NOT NULL
            LIMIT 1
        ) INTO v_use_vector_search;
    END IF;
    
    v_search_terms := regexp_split_to_array(lower(p_query_text), '\s+');
    
    RETURN QUERY
    WITH note_results AS (
        SELECT 
            'note'::TEXT as src_type,
            np.note_id as src_id,
            'Note ' || to_char(np.created_at, 'YYYY-MM-DD') as src_label,
            LEFT(np.redacted_text, 300) as src_snippet,
            CASE 
                WHEN v_use_vector_search AND np.embedding IS NOT NULL THEN
                    1 - (np.embedding <=> v_query_embedding)
                ELSE
                    (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
                     FROM unnest(v_search_terms) term
                     WHERE lower(np.redacted_text) LIKE '%' || term || '%')
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
        SELECT 
            'lab'::TEXT as src_type,
            o.obs_id as src_id,
            o.display || ' (' || to_char(o.observed_at, 'YYYY-MM-DD') || ')' as src_label,
            COALESCE(o.value_text, o.value_num::text) || ' ' || COALESCE(o.unit, '') as src_snippet,
            (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
             FROM unnest(v_search_terms) term
             WHERE lower(o.display) LIKE '%' || term || '%'
                OR lower(COALESCE(o.value_text, '')) LIKE '%' || term || '%'
                OR lower(o.code) LIKE '%' || term || '%') as src_score,
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
        SELECT 
            'med'::TEXT as src_type,
            m.med_id as src_id,
            m.name || ' ' || COALESCE(m.dose, '') as src_label,
            m.name || ' ' || COALESCE(m.dose, '') || ' ' || COALESCE(m.frequency, '') || 
            ' (Status: ' || m.status || ')' as src_snippet,
            (SELECT COUNT(*)::float / GREATEST(array_length(v_search_terms, 1), 1)
             FROM unnest(v_search_terms) term
             WHERE lower(m.name) LIKE '%' || term || '%'
                OR lower(COALESCE(m.reason, '')) LIKE '%' || term || '%') as src_score,
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

COMMENT ON FUNCTION retrieve_context_simple IS 'Simple RAG retrieval without reranking (for comparison/fallback)';
