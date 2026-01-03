"""
Tests for backup status endpoint.
"""

import json
from unittest.mock import MagicMock, patch

import pytest


@pytest.mark.anyio
async def test_backups_endpoint_success(client):
    """Test backup status endpoint with successful pgBackRest output."""
    mock_output = json.dumps([
        {
            "status": {"code": 0, "message": "ok"},
            "backup": [
                {
                    "label": "20250115-120000F",
                    "type": "full",
                    "timestamp": {"start": 1705320000, "stop": 1705320600},
                    "info": {"size": 1073741824, "repository": {"size": 536870912}}
                }
            ],
            "archive": [
                {"min": "000000010000000000000001", "max": "000000010000000000000010"}
            ]
        }
    ])

    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = mock_output
    mock_result.stderr = ""

    with patch("subprocess.run", return_value=mock_result):
        response = await client.get("/backups")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "ok"
        assert len(data["backups"]) == 1
        assert data["backups"][0]["type"] == "full"
        assert data["wal_archive"] is not None


@pytest.mark.anyio
async def test_backups_endpoint_not_installed(client):
    """Test backup status when pgBackRest is not installed."""
    with patch("subprocess.run", side_effect=FileNotFoundError):
        response = await client.get("/backups")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "not_installed"


@pytest.mark.anyio
async def test_backups_endpoint_error(client):
    """Test backup status when pgBackRest returns error."""
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stdout = ""
    mock_result.stderr = "stanza not found"

    with patch("subprocess.run", return_value=mock_result):
        response = await client.get("/backups")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "unavailable"


@pytest.mark.anyio
async def test_backups_endpoint_no_backups(client):
    """Test backup status when no backups exist."""
    mock_output = json.dumps([
        {
            "status": {"code": 2, "message": "no backup exists"},
            "backup": [],
            "archive": []
        }
    ])

    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = mock_output
    mock_result.stderr = ""

    with patch("subprocess.run", return_value=mock_result):
        response = await client.get("/backups")
        assert response.status_code == 200

        data = response.json()
        assert data["status"] == "no_backup"
        assert len(data["backups"]) == 0
