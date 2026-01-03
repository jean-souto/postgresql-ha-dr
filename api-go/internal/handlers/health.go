// Package handlers provides HTTP request handlers.
package handlers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/config"
	"github.com/postgresql-ha-dr/api-go/internal/db"
	"github.com/postgresql-ha-dr/api-go/internal/models"
)

// HealthHandler handles health check endpoints.
type HealthHandler struct {
	cfg  *config.Config
	pool *db.Pool
}

// NewHealthHandler creates a new health handler.
func NewHealthHandler(cfg *config.Config, pool *db.Pool) *HealthHandler {
	return &HealthHandler{
		cfg:  cfg,
		pool: pool,
	}
}

// Health handles GET /health - basic liveness check.
func (h *HealthHandler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, models.HealthResponse{
		Status:    "healthy",
		Version:   h.cfg.App.Version,
		Timestamp: time.Now().UTC(),
	})
}

// Ready handles GET /ready - readiness check with database connectivity.
func (h *HealthHandler) Ready(c *gin.Context) {
	dbStatus := "unknown"

	if h.pool != nil {
		if err := h.pool.HealthCheck(c.Request.Context()); err != nil {
			dbStatus = "error: " + err.Error()
		} else {
			dbStatus = "connected"
		}
	} else {
		dbStatus = "not_initialized"
	}

	status := "ready"
	if dbStatus != "connected" {
		status = "not_ready"
	}

	response := models.ReadyResponse{
		Status:    status,
		Database:  dbStatus,
		Timestamp: time.Now().UTC(),
	}

	if status == "not_ready" {
		c.JSON(http.StatusServiceUnavailable, response)
		return
	}

	c.JSON(http.StatusOK, response)
}

// Root handles GET / - API info.
func (h *HealthHandler) Root(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"message": "PostgreSQL HA/DR Demo API (Go)",
		"docs":    "/docs",
		"health":  "/health",
		"ready":   "/ready",
	})
}
