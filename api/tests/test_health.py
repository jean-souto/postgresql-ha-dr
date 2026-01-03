"""
Tests for health check endpoints.
"""

from unittest.mock import AsyncMock, patch

import pytest


@pytest.mark.anyio
async def test_health_endpoint(client):
    """Test basic health endpoint returns 200."""
    response = await client.get("/health")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "healthy"
    assert "version" in data
    assert "timestamp" in data


@pytest.mark.anyio
async def test_root_endpoint(client):
    """Test root endpoint returns API info."""
    response = await client.get("/")
    assert response.status_code == 200

    data = response.json()
    assert "message" in data
    assert "docs" in data
    assert "health" in data


@pytest.mark.anyio
async def test_ready_endpoint_db_connected(client):
    """Test readiness endpoint when database is connected."""
    mock_pool = AsyncMock()
    mock_conn = AsyncMock()
    mock_conn.fetchval = AsyncMock(return_value=1)
    mock_pool.acquire.return_value.__aenter__.return_value = mock_conn

    with patch("app.routers.health.get_pool", return_value=mock_pool):
        response = await client.get("/ready")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "ready"
        assert data["database"] == "connected"


@pytest.mark.anyio
async def test_ready_endpoint_db_error(client):
    """Test readiness endpoint when database connection fails."""
    with patch("app.routers.health.get_pool", side_effect=Exception("Connection failed")):
        response = await client.get("/ready")
        assert response.status_code == 503
