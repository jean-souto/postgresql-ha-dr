"""
Health check endpoints.
- /health - Basic liveness check
- /ready - Readiness check with database connectivity
"""

from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException

from ..config import get_settings
from ..db import get_pool
from ..models import HealthResponse, ReadyResponse

router = APIRouter(tags=["Health"])


@router.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """
    Basic health check endpoint.
    Returns 200 if the service is running.
    """
    settings = get_settings()
    return HealthResponse(
        status="healthy",
        version=settings.app_version,
        timestamp=datetime.now(UTC),
    )


@router.get("/ready", response_model=ReadyResponse)
async def readiness_check() -> ReadyResponse:
    """
    Readiness check endpoint.
    Verifies database connectivity before returning healthy.
    """
    db_status = "unknown"

    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            result = await conn.fetchval("SELECT 1")
            if result == 1:
                db_status = "connected"
            else:
                db_status = "error"
    except Exception as e:
        db_status = f"error: {str(e)}"

    overall_status = "ready" if db_status == "connected" else "not_ready"

    if overall_status == "not_ready":
        raise HTTPException(
            status_code=503,
            detail=ReadyResponse(
                status=overall_status,
                database=db_status,
                timestamp=datetime.now(UTC),
            ).model_dump(),
        )

    return ReadyResponse(
        status=overall_status,
        database=db_status,
        timestamp=datetime.now(UTC),
    )
