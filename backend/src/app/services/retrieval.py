"""
Patient 360 Backend - Retrieval Service

Provides context retrieval using vector similarity and keyword search.
"""

import json
import logging
from typing import Tuple

from app.db import execute_query
from app.settings import get_settings

logger = logging.getLogger(__name__)


async def retrieve_context(
    patient_id: str,
    query: str,
    max_results: int = 5
) -> Tuple[list[dict], str]:
    """
    Retrieve relevant context for a patient query.
    
    Uses the retrieve_context SQL function which handles:
    - Vector similarity search over notes (if embeddings available)
    - Keyword search fallback
    - Merged results from notes, labs, and medications
    
    Returns:
        Tuple of (results list, retrieval method used)
    """
    settings = get_settings()
    
    try:
        # Call the database retrieval function
        results = await execute_query(
            """
            SELECT 
                source_type,
                source_id,
                label,
                snippet,
                score,
                metadata
            FROM retrieve_context($1::text, $2::text, $3::integer, $4::integer)
            """,
            patient_id, query, max_results, 3
        )
        
        # Determine retrieval method used
        # Check if any notes came from vector search (higher scores typically)
        has_vector_results = False
        for r in results:
            if r.get("source_type") == "note" and r.get("score", 0) > 0.5:
                has_vector_results = True
                break
        
        retrieval_method = "vector" if has_vector_results else "keyword"
        
        # Process results
        processed_results = []
        for r in results:
            metadata = r.get("metadata", {})
            if isinstance(metadata, str):
                metadata = json.loads(metadata)
            
            processed_results.append({
                "source_type": r.get("source_type"),
                "source_id": r.get("source_id"),
                "label": r.get("label"),
                "snippet": r.get("snippet"),
                "score": float(r.get("score", 0)),
                "metadata": metadata
            })
        
        logger.info(
            f"Retrieved {len(processed_results)} results for patient {patient_id} "
            f"using {retrieval_method} search"
        )
        
        return processed_results, retrieval_method
        
    except Exception as e:
        logger.error(f"Error retrieving context: {str(e)}")
        # Return empty results on error
        return [], "error"


async def retrieve_notes_only(
    patient_id: str,
    query: str,
    max_results: int = 5
) -> list[dict]:
    """
    Retrieve only notes using vector or keyword search.
    
    Simpler retrieval for note-focused queries.
    """
    try:
        # Try vector search first
        results = await execute_query(
            """
            SELECT 
                note_id,
                redacted_text,
                created_at,
                CASE 
                    WHEN embedding IS NOT NULL THEN 
                        1 - (embedding <=> (SELECT generate_embedding($1)))
                    ELSE 0.5
                END as similarity
            FROM notes_phi
            WHERE patient_id = $2
            AND (
                embedding IS NOT NULL 
                OR redacted_text ILIKE $3
            )
            ORDER BY similarity DESC
            LIMIT $4
            """,
            query, patient_id, f"%{query}%", max_results
        )
        
        return [
            {
                "source_type": "note",
                "source_id": r.get("note_id"),
                "label": f"Note {r.get('created_at', '').strftime('%Y-%m-%d') if r.get('created_at') else 'Unknown'}",
                "snippet": r.get("redacted_text", "")[:300],
                "score": float(r.get("similarity", 0))
            }
            for r in results
        ]
        
    except Exception as e:
        logger.error(f"Error retrieving notes: {str(e)}")
        return []


async def retrieve_labs(
    patient_id: str,
    codes: list[str] = None,
    limit: int = 10
) -> list[dict]:
    """Retrieve lab observations for a patient."""
    
    if codes:
        query = """
            SELECT 
                obs_id,
                code,
                display,
                COALESCE(value_text, value_num::text) as value,
                unit,
                observed_at
            FROM observations
            WHERE patient_id = $1 AND code = ANY($2)
            ORDER BY observed_at DESC LIMIT $3
        """
        results = await execute_query(query, patient_id, codes, limit)
    else:
        query = """
            SELECT 
                obs_id,
                code,
                display,
                COALESCE(value_text, value_num::text) as value,
                unit,
                observed_at
            FROM observations
            WHERE patient_id = $1
            ORDER BY observed_at DESC LIMIT $2
        """
        results = await execute_query(query, patient_id, limit)
    
    return [
        {
            "source_type": "lab",
            "source_id": r.get("obs_id"),
            "label": f"{r.get('display')} ({r.get('observed_at', '').strftime('%Y-%m-%d') if r.get('observed_at') else 'Unknown'})",
            "snippet": f"{r.get('value', 'N/A')} {r.get('unit', '')}",
            "score": 1.0,
            "metadata": {
                "code": r.get("code"),
                "value": r.get("value"),
                "unit": r.get("unit")
            }
        }
        for r in results
    ]


async def retrieve_medications(
    patient_id: str,
    status: str = None,
    limit: int = 10
) -> list[dict]:
    """Retrieve medications for a patient."""
    
    if status:
        query = """
            SELECT 
                med_id,
                name,
                dose,
                frequency,
                status,
                start_date,
                end_date,
                reason
            FROM medications
            WHERE patient_id = $1 AND status = $2
            ORDER BY start_date DESC LIMIT $3
        """
        results = await execute_query(query, patient_id, status, limit)
    else:
        query = """
            SELECT 
                med_id,
                name,
                dose,
                frequency,
                status,
                start_date,
                end_date,
                reason
            FROM medications
            WHERE patient_id = $1
            ORDER BY start_date DESC LIMIT $2
        """
        results = await execute_query(query, patient_id, limit)
    
    return [
        {
            "source_type": "med",
            "source_id": r.get("med_id"),
            "label": f"{r.get('name')} {r.get('dose', '')}",
            "snippet": f"{r.get('name')} {r.get('dose', '')} {r.get('frequency', '')} - Status: {r.get('status', 'unknown')}",
            "score": 1.0,
            "metadata": {
                "dose": r.get("dose"),
                "frequency": r.get("frequency"),
                "status": r.get("status"),
                "reason": r.get("reason")
            }
        }
        for r in results
    ]
