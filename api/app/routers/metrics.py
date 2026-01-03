"""
Database metrics endpoint.
Exposes PostgreSQL statistics and health metrics.
"""

from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException

from ..db import get_connection
from ..models import MetricsResponse

router = APIRouter(tags=["Metrics"])


@router.get("/metrics", response_model=MetricsResponse)
async def get_metrics() -> MetricsResponse:
    """
    Get database metrics and statistics.
    Returns information about database size, connections, transactions, and replication.
    """
    try:
        async with get_connection() as conn:
            # Get database size
            db_size = await conn.fetchval(
                "SELECT pg_database_size(current_database())"
            )

            # Get connection info
            conn_info = await conn.fetchrow("""
                SELECT
                    (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') as active_connections,
                    (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') as max_connections
            """)

            # Get transaction stats
            txn_stats = await conn.fetchrow("""
                SELECT
                    xact_commit as committed,
                    xact_rollback as rolled_back,
                    blks_read,
                    blks_hit
                FROM pg_stat_database
                WHERE datname = current_database()
            """)

            # Check if in recovery (replica)
            is_in_recovery = await conn.fetchval("SELECT pg_is_in_recovery()")

            # Get replication lag if replica
            replication_lag = None
            if is_in_recovery:
                lag_result = await conn.fetchval("""
                    SELECT CASE
                        WHEN pg_last_wal_receive_lsn() IS NOT NULL
                        THEN pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
                        ELSE NULL
                    END
                """)
                replication_lag = lag_result

            # Calculate cache hit ratio
            blocks_read = txn_stats['blks_read'] or 0
            blocks_hit = txn_stats['blks_hit'] or 0
            total_blocks = blocks_read + blocks_hit
            cache_hit_ratio = (blocks_hit / total_blocks * 100) if total_blocks > 0 else 100.0

            # Calculate connection usage
            active = conn_info['active_connections'] or 0
            max_conn = conn_info['max_connections'] or 100
            conn_usage = (active / max_conn * 100) if max_conn > 0 else 0

            return MetricsResponse(
                database_size_bytes=db_size or 0,
                active_connections=active,
                max_connections=max_conn,
                connection_usage_percent=round(conn_usage, 2),
                transactions_committed=txn_stats['committed'] or 0,
                transactions_rolled_back=txn_stats['rolled_back'] or 0,
                blocks_read=blocks_read,
                blocks_hit=blocks_hit,
                cache_hit_ratio=round(cache_hit_ratio, 2),
                replication_lag_bytes=replication_lag,
                is_in_recovery=is_in_recovery,
                timestamp=datetime.now(UTC),
            )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to retrieve metrics: {str(e)}"
        )
