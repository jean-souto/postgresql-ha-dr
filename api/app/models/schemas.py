"""
Pydantic models for request/response schemas.
"""

from datetime import datetime

from pydantic import BaseModel, Field

# =============================================================================
# Item CRUD Models
# =============================================================================

class ItemBase(BaseModel):
    """Base item model with common fields."""
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = Field(None, max_length=1000)
    price: float = Field(..., ge=0)
    is_active: bool = True


class ItemCreate(ItemBase):
    """Model for creating a new item."""
    pass


class ItemUpdate(BaseModel):
    """Model for updating an item (all fields optional)."""
    name: str | None = Field(None, min_length=1, max_length=255)
    description: str | None = Field(None, max_length=1000)
    price: float | None = Field(None, ge=0)
    is_active: bool | None = None


class Item(ItemBase):
    """Complete item model with database fields."""
    id: int
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


# =============================================================================
# Health Check Models
# =============================================================================

class HealthResponse(BaseModel):
    """Health check response."""
    status: str = "healthy"
    version: str
    timestamp: datetime


class ReadyResponse(BaseModel):
    """Readiness check response with component status."""
    status: str
    database: str
    timestamp: datetime


# =============================================================================
# Metrics Models
# =============================================================================

class MetricsResponse(BaseModel):
    """Database metrics response."""
    database_size_bytes: int
    active_connections: int
    max_connections: int
    connection_usage_percent: float
    transactions_committed: int
    transactions_rolled_back: int
    blocks_read: int
    blocks_hit: int
    cache_hit_ratio: float
    replication_lag_bytes: int | None = None
    is_in_recovery: bool
    timestamp: datetime


# =============================================================================
# Backup Models
# =============================================================================

class BackupInfo(BaseModel):
    """Individual backup information."""
    label: str
    type: str  # full, diff, incr
    start_time: datetime | None = None
    stop_time: datetime | None = None
    size_bytes: int | None = None
    database_size_bytes: int | None = None


class WALArchiveInfo(BaseModel):
    """WAL archive information."""
    min_wal: str | None = None
    max_wal: str | None = None


class BackupResponse(BaseModel):
    """Complete backup status response."""
    stanza: str
    status: str
    status_message: str | None = None
    backups: list[BackupInfo]
    wal_archive: WALArchiveInfo | None = None
    last_full_backup: datetime | None = None
    last_diff_backup: datetime | None = None
    timestamp: datetime
