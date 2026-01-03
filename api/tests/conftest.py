"""
Pytest configuration and fixtures.
"""

from unittest.mock import AsyncMock, patch

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.fixture
def anyio_backend():
    """Use asyncio as the async backend."""
    return "asyncio"


@pytest.fixture
async def client():
    """Create an async test client."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
def mock_db_pool():
    """Mock database pool for tests that don't need real DB."""
    with patch("app.db.connection._pool") as mock_pool:
        mock_conn = AsyncMock()
        mock_pool.acquire.return_value.__aenter__.return_value = mock_conn
        yield mock_pool, mock_conn


@pytest.fixture
def mock_pgbackrest():
    """Mock pgBackRest subprocess calls."""
    with patch("subprocess.run") as mock_run:
        yield mock_run
