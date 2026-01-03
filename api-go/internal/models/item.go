// Package models provides domain models and DTOs.
package models

import (
	"time"
)

// Item represents a demo item in the database.
type Item struct {
	ID          int64      `json:"id"`
	Name        string     `json:"name"`
	Description *string    `json:"description,omitempty"`
	Price       float64    `json:"price"`
	IsActive    bool       `json:"is_active"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

// ItemCreate represents the request body for creating an item.
type ItemCreate struct {
	Name        string  `json:"name" binding:"required,min=1,max=255"`
	Description *string `json:"description,omitempty" binding:"omitempty,max=1000"`
	Price       float64 `json:"price" binding:"required,gte=0"`
	IsActive    *bool   `json:"is_active,omitempty"`
}

// ItemUpdate represents the request body for updating an item.
type ItemUpdate struct {
	Name        *string  `json:"name,omitempty" binding:"omitempty,min=1,max=255"`
	Description *string  `json:"description,omitempty" binding:"omitempty,max=1000"`
	Price       *float64 `json:"price,omitempty" binding:"omitempty,gte=0"`
	IsActive    *bool    `json:"is_active,omitempty"`
}

// HealthResponse represents a health check response.
type HealthResponse struct {
	Status    string    `json:"status"`
	Version   string    `json:"version"`
	Timestamp time.Time `json:"timestamp"`
}

// ReadyResponse represents a readiness check response.
type ReadyResponse struct {
	Status    string    `json:"status"`
	Database  string    `json:"database"`
	Timestamp time.Time `json:"timestamp"`
}

// MetricsResponse represents database metrics.
type MetricsResponse struct {
	DatabaseSizeBytes       int64     `json:"database_size_bytes"`
	ActiveConnections       int       `json:"active_connections"`
	MaxConnections          int       `json:"max_connections"`
	ConnectionUsagePercent  float64   `json:"connection_usage_percent"`
	TransactionsCommitted   int64     `json:"transactions_committed"`
	TransactionsRolledBack  int64     `json:"transactions_rolled_back"`
	BlocksRead              int64     `json:"blocks_read"`
	BlocksHit               int64     `json:"blocks_hit"`
	CacheHitRatio           float64   `json:"cache_hit_ratio"`
	ReplicationLagBytes     *int64    `json:"replication_lag_bytes,omitempty"`
	IsInRecovery            bool      `json:"is_in_recovery"`
	Timestamp               time.Time `json:"timestamp"`
}

// BackupInfo represents information about a single backup.
type BackupInfo struct {
	Label             string     `json:"label"`
	Type              string     `json:"type"`
	StartTime         *time.Time `json:"start_time,omitempty"`
	StopTime          *time.Time `json:"stop_time,omitempty"`
	SizeBytes         *int64     `json:"size_bytes,omitempty"`
	DatabaseSizeBytes *int64     `json:"database_size_bytes,omitempty"`
}

// WALArchiveInfo represents WAL archive information.
type WALArchiveInfo struct {
	MinWAL *string `json:"min_wal,omitempty"`
	MaxWAL *string `json:"max_wal,omitempty"`
}

// BackupResponse represents the complete backup status.
type BackupResponse struct {
	Stanza         string          `json:"stanza"`
	Status         string          `json:"status"`
	StatusMessage  *string         `json:"status_message,omitempty"`
	Backups        []BackupInfo    `json:"backups"`
	WALArchive     *WALArchiveInfo `json:"wal_archive,omitempty"`
	LastFullBackup *time.Time      `json:"last_full_backup,omitempty"`
	LastDiffBackup *time.Time      `json:"last_diff_backup,omitempty"`
	Timestamp      time.Time       `json:"timestamp"`
}

// ErrorResponse represents an API error.
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}
