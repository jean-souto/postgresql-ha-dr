"""
Database connection management using asyncpg.
Provides connection pooling for PostgreSQL.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import asyncpg

from ..config import get_settings

# Global connection pool
_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    """Get or create the database connection pool."""
    global _pool

    if _pool is None:
        settings = get_settings()
        _pool = await asyncpg.create_pool(
            host=settings.db_host,
            port=settings.db_port,
            database=settings.db_name,
            user=settings.db_user,
            password=settings.db_password,
            min_size=settings.db_pool_min_size,
            max_size=settings.db_pool_max_size,
            command_timeout=60,
        )

    return _pool


async def close_pool() -> None:
    """Close the database connection pool."""
    global _pool

    if _pool is not None:
        await _pool.close()
        _pool = None


@asynccontextmanager
async def get_connection() -> AsyncGenerator[asyncpg.Connection, None]:
    """Get a connection from the pool as a context manager."""
    pool = await get_pool()
    async with pool.acquire() as connection:
        yield connection
