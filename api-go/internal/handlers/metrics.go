package handlers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/db"
	"github.com/postgresql-ha-dr/api-go/internal/models"
)

// MetricsHandler handles database metrics endpoints.
type MetricsHandler struct {
	pool *db.Pool
}

// NewMetricsHandler creates a new metrics handler.
func NewMetricsHandler(pool *db.Pool) *MetricsHandler {
	return &MetricsHandler{pool: pool}
}

// Metrics handles GET /metrics - get database metrics.
func (h *MetricsHandler) Metrics(c *gin.Context) {
	ctx := c.Request.Context()

	// Get database size
	var dbSize int64
	err := h.pool.QueryRow(ctx, "SELECT pg_database_size(current_database())").Scan(&dbSize)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to get database size",
		})
		return
	}

	// Get connection info
	var activeConns, maxConns int
	err = h.pool.QueryRow(ctx, `
		SELECT
			(SELECT count(*) FROM pg_stat_activity WHERE state = 'active'),
			(SELECT setting::int FROM pg_settings WHERE name = 'max_connections')
	`).Scan(&activeConns, &maxConns)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to get connection info",
		})
		return
	}

	// Get transaction stats
	var committed, rolledBack, blocksRead, blocksHit int64
	err = h.pool.QueryRow(ctx, `
		SELECT
			COALESCE(xact_commit, 0),
			COALESCE(xact_rollback, 0),
			COALESCE(blks_read, 0),
			COALESCE(blks_hit, 0)
		FROM pg_stat_database
		WHERE datname = current_database()
	`).Scan(&committed, &rolledBack, &blocksRead, &blocksHit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to get transaction stats",
		})
		return
	}

	// Check if in recovery
	var isInRecovery bool
	err = h.pool.QueryRow(ctx, "SELECT pg_is_in_recovery()").Scan(&isInRecovery)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to check recovery status",
		})
		return
	}

	// Get replication lag if replica
	var replicationLag *int64
	if isInRecovery {
		var lag int64
		err = h.pool.QueryRow(ctx, `
			SELECT CASE
				WHEN pg_last_wal_receive_lsn() IS NOT NULL
				THEN pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
				ELSE NULL
			END
		`).Scan(&lag)
		if err == nil {
			replicationLag = &lag
		}
	}

	// Calculate cache hit ratio
	totalBlocks := blocksRead + blocksHit
	var cacheHitRatio float64 = 100.0
	if totalBlocks > 0 {
		cacheHitRatio = float64(blocksHit) / float64(totalBlocks) * 100
	}

	// Calculate connection usage
	var connUsage float64 = 0
	if maxConns > 0 {
		connUsage = float64(activeConns) / float64(maxConns) * 100
	}

	c.JSON(http.StatusOK, models.MetricsResponse{
		DatabaseSizeBytes:      dbSize,
		ActiveConnections:      activeConns,
		MaxConnections:         maxConns,
		ConnectionUsagePercent: connUsage,
		TransactionsCommitted:  committed,
		TransactionsRolledBack: rolledBack,
		BlocksRead:             blocksRead,
		BlocksHit:              blocksHit,
		CacheHitRatio:          cacheHitRatio,
		ReplicationLagBytes:    replicationLag,
		IsInRecovery:           isInRecovery,
		Timestamp:              time.Now().UTC(),
	})
}
