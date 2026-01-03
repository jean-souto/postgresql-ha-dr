"""
Backup status endpoint.
Queries pgBackRest for backup information.
"""

import json
import subprocess
from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException

from ..config import get_settings
from ..models import BackupInfo, BackupResponse, WALArchiveInfo

router = APIRouter(tags=["Backups"])


def parse_pgbackrest_timestamp(ts: int | None) -> datetime | None:
    """Convert pgBackRest Unix timestamp to datetime."""
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=UTC)


@router.get("/backups", response_model=BackupResponse)
async def get_backup_status() -> BackupResponse:
    """
    Get pgBackRest backup status.
    Returns information about all backups and WAL archiving status.

    Note: This endpoint requires pgBackRest to be installed and configured
    on the system where the API is running.
    """
    settings = get_settings()
    stanza = settings.pgbackrest_stanza

    try:
        # Run pgbackrest info command
        result = subprocess.run(
            ["pgbackrest", "--stanza", stanza, "info", "--output=json"],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            # pgBackRest not available or stanza not configured
            return BackupResponse(
                stanza=stanza,
                status="unavailable",
                status_message=f"pgBackRest error: {result.stderr.strip() or 'Unknown error'}",
                backups=[],
                timestamp=datetime.now(UTC),
            )

        # Parse JSON output
        info = json.loads(result.stdout)

        if not info:
            return BackupResponse(
                stanza=stanza,
                status="no_stanza",
                status_message="No stanza information available",
                backups=[],
                timestamp=datetime.now(UTC),
            )

        stanza_info = info[0]
        status_code = stanza_info.get("status", {}).get("code", 99)
        status_message = stanza_info.get("status", {}).get("message", "Unknown")

        # Map status code to string
        if status_code == 0:
            status = "ok"
        elif status_code == 1:
            status = "missing_stanza"
        elif status_code == 2:
            status = "no_backup"
        else:
            status = "error"

        # Parse backups
        backups: list[BackupInfo] = []
        last_full: datetime | None = None
        last_diff: datetime | None = None

        for backup in stanza_info.get("backup", []):
            backup_info = BackupInfo(
                label=backup.get("label", "unknown"),
                type=backup.get("type", "unknown"),
                start_time=parse_pgbackrest_timestamp(backup.get("timestamp", {}).get("start")),
                stop_time=parse_pgbackrest_timestamp(backup.get("timestamp", {}).get("stop")),
                size_bytes=backup.get("info", {}).get("size"),
                database_size_bytes=backup.get("info", {}).get("repository", {}).get("size"),
            )
            backups.append(backup_info)

            # Track latest backups by type
            if backup_info.type == "full" and backup_info.stop_time:
                if last_full is None or backup_info.stop_time > last_full:
                    last_full = backup_info.stop_time
            elif backup_info.type == "diff" and backup_info.stop_time:
                if last_diff is None or backup_info.stop_time > last_diff:
                    last_diff = backup_info.stop_time

        # Parse WAL archive info
        wal_archive = None
        archive_info = stanza_info.get("archive", [])
        if archive_info:
            wal_archive = WALArchiveInfo(
                min_wal=archive_info[0].get("min"),
                max_wal=archive_info[0].get("max"),
            )

        return BackupResponse(
            stanza=stanza,
            status=status,
            status_message=status_message if status != "ok" else None,
            backups=backups,
            wal_archive=wal_archive,
            last_full_backup=last_full,
            last_diff_backup=last_diff,
            timestamp=datetime.now(UTC),
        )

    except subprocess.TimeoutExpired:
        return BackupResponse(
            stanza=stanza,
            status="timeout",
            status_message="pgBackRest command timed out",
            backups=[],
            timestamp=datetime.now(UTC),
        )
    except FileNotFoundError:
        return BackupResponse(
            stanza=stanza,
            status="not_installed",
            status_message="pgBackRest is not installed on this system",
            backups=[],
            timestamp=datetime.now(UTC),
        )
    except json.JSONDecodeError as e:
        return BackupResponse(
            stanza=stanza,
            status="parse_error",
            status_message=f"Failed to parse pgBackRest output: {str(e)}",
            backups=[],
            timestamp=datetime.now(UTC),
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get backup status: {str(e)}"
        )
