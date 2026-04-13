"""
Patient 360 Backend - Database Module

Provides PostgreSQL connection pool using pg8000 (pure Python).
Uses asyncio.to_thread for async compatibility with FastAPI.
"""

import logging
import asyncio
import re
from contextlib import asynccontextmanager
from typing import AsyncGenerator, Optional
from urllib.parse import urlparse, parse_qs, unquote

import pg8000.native
from azure.identity import DefaultAzureCredential

from app.settings import get_settings

logger = logging.getLogger(__name__)

# Entra ID token credential (reused across connections)
_credential: Optional[DefaultAzureCredential] = None

# Connection pool (simple list-based pool)
_pool: list[pg8000.native.Connection] = []
_pool_size: int = 5
_pool_lock = asyncio.Lock()


def _convert_params(query: str, args: tuple) -> tuple[str, dict]:
    """
    Convert $1, $2 style parameters to pg8000's :p1, :p2 style.
    Returns (converted_query, params_dict).
    """
    if not args:
        return query, {}
    
    # Convert $1, $2, ... to :p1, :p2, ...
    converted_query = re.sub(r'\$(\d+)', r':p\1', query)
    
    # Build kwargs dict: {'p1': args[0], 'p2': args[1], ...}
    params_dict = {f'p{i+1}': arg for i, arg in enumerate(args)}
    
    return converted_query, params_dict


def _get_entra_token() -> str:
    """Get an Entra ID access token for PostgreSQL."""
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    token = _credential.get_token("https://ossrdbms-aad.database.windows.net/.default")
    return token.token


def _parse_database_url(url: str) -> dict:
    """Parse database URL into connection parameters."""
    parsed = urlparse(url)
    
    username = unquote(parsed.username) if parsed.username else "postgres"
    
    params = {
        "host": parsed.hostname or "localhost",
        "port": parsed.port or 5432,
        "database": parsed.path.lstrip("/") if parsed.path else "postgres",
        "user": username,
        "password": _get_entra_token(),
    }
    
    logger.info(f"Connecting to {params['host']}:{params['port']}/{params['database']} as {params['user']} (Entra ID)")
    
    # Parse query parameters for SSL
    query_params = parse_qs(parsed.query)
    if "sslmode" in query_params:
        sslmode = query_params["sslmode"][0]
        if sslmode in ("require", "verify-ca", "verify-full"):
            params["ssl_context"] = True
    
    return params


def _create_connection() -> pg8000.native.Connection:
    """Create a new database connection."""
    settings = get_settings()
    conn_params = _parse_database_url(settings.database_url)
    return pg8000.native.Connection(**conn_params)


async def init_db_pool():
    """Initialize the database connection pool."""
    global _pool, _pool_size
    
    settings = get_settings()
    _pool_size = settings.db_pool_max_size
    
    logger.info("Initializing database connection pool...")
    
    # Create initial connections
    for i in range(settings.db_pool_min_size):
        try:
            conn = await asyncio.to_thread(_create_connection)
            _pool.append(conn)
        except Exception as e:
            logger.error(f"Failed to create initial connection: {e}")
            if i == 0:
                # If first connection fails, warn but continue (for development)
                logger.warning("Continuing without database connection - API will be degraded")
                return _pool
            raise
    
    # Test connection
    if _pool:
        result = await asyncio.to_thread(_pool[0].run, "SELECT 1")
        logger.info("Database connection successful")
    
    return _pool


async def close_db_pool():
    """Close all connections in the pool."""
    global _pool
    
    logger.info("Closing database connection pool...")
    
    for conn in _pool:
        try:
            await asyncio.to_thread(conn.close)
        except Exception:
            pass
    
    _pool = []


@asynccontextmanager
async def get_connection() -> AsyncGenerator[pg8000.native.Connection, None]:
    """Get a database connection from the pool."""
    global _pool
    
    conn = None
    async with _pool_lock:
        if _pool:
            conn = _pool.pop()
        elif len(_pool) < _pool_size:
            conn = await asyncio.to_thread(_create_connection)
    
    if conn is None:
        # Wait and retry
        await asyncio.sleep(0.1)
        async with _pool_lock:
            if _pool:
                conn = _pool.pop()
            else:
                conn = await asyncio.to_thread(_create_connection)
    
    try:
        yield conn
    finally:
        async with _pool_lock:
            if len(_pool) < _pool_size:
                _pool.append(conn)
            else:
                await asyncio.to_thread(conn.close)


async def execute_query(query: str, *args) -> list[dict]:
    """Execute a query and return results as list of dicts."""
    async with get_connection() as conn:
        # Convert $1, $2 to :p1, :p2 style for pg8000
        converted_query, params = _convert_params(query, args)
        rows = await asyncio.to_thread(conn.run, converted_query, **params)
        
        # Get column names from the cursor description
        if conn.columns:
            columns = [col["name"] for col in conn.columns]
            return [dict(zip(columns, row)) for row in rows]
        return []


async def execute_one(query: str, *args) -> Optional[dict]:
    """Execute a query and return single result."""
    results = await execute_query(query, *args)
    return results[0] if results else None


async def execute_scalar(query: str, *args):
    """Execute a query and return scalar value."""
    async with get_connection() as conn:
        converted_query, params = _convert_params(query, args)
        rows = await asyncio.to_thread(conn.run, converted_query, **params)
        if rows and rows[0]:
            return rows[0][0]
        return None


async def execute_command(query: str, *args) -> str:
    """Execute a command and return status."""
    async with get_connection() as conn:
        converted_query, params = _convert_params(query, args)
        await asyncio.to_thread(conn.run, converted_query, **params)
        return "OK"
