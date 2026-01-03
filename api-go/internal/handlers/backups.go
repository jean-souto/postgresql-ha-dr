package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/config"
	"github.com/postgresql-ha-dr/api-go/internal/models"
)

// BackupsHandler handles backup status endpoints.
type BackupsHandler struct {
	cfg *config.Config
}

// NewBackupsHandler creates a new backups handler.
func NewBackupsHandler(cfg *config.Config) *BackupsHandler {
	return &BackupsHandler{cfg: cfg}
}

// pgBackRestInfo represents the JSON output from pgbackrest info.
type pgBackRestInfo struct {
	Status struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"status"`
	Backup []struct {
		Label     string `json:"label"`
		Type      string `json:"type"`
		Timestamp struct {
			Start int64 `json:"start"`
			Stop  int64 `json:"stop"`
		} `json:"timestamp"`
		Info struct {
			Size       int64 `json:"size"`
			Repository struct {
				Size int64 `json:"size"`
			} `json:"repository"`
		} `json:"info"`
	} `json:"backup"`
	Archive []struct {
		Min string `json:"min"`
		Max string `json:"max"`
	} `json:"archive"`
}

// Backups handles GET /backups - get backup status.
func (h *BackupsHandler) Backups(c *gin.Context) {
	stanza := h.cfg.Backup.Stanza

	// Create context with timeout
	ctx, cancel := context.WithTimeout(c.Request.Context(), 30*time.Second)
	defer cancel()

	// Run pgbackrest info command
	cmd := exec.CommandContext(ctx, "pgbackrest", "--stanza", stanza, "info", "--output=json")
	output, err := cmd.Output()

	if err != nil {
		if _, ok := err.(*exec.Error); ok {
			// pgBackRest not installed
			c.JSON(http.StatusOK, models.BackupResponse{
				Stanza:        stanza,
				Status:        "not_installed",
				StatusMessage: strPtr("pgBackRest is not installed on this system"),
				Backups:       []models.BackupInfo{},
				Timestamp:     time.Now().UTC(),
			})
			return
		}

		// Other error
		c.JSON(http.StatusOK, models.BackupResponse{
			Stanza:        stanza,
			Status:        "unavailable",
			StatusMessage: strPtr("pgBackRest error: " + err.Error()),
			Backups:       []models.BackupInfo{},
			Timestamp:     time.Now().UTC(),
		})
		return
	}

	// Parse JSON output
	var infos []pgBackRestInfo
	if err := json.Unmarshal(output, &infos); err != nil {
		c.JSON(http.StatusOK, models.BackupResponse{
			Stanza:        stanza,
			Status:        "parse_error",
			StatusMessage: strPtr("Failed to parse pgBackRest output: " + err.Error()),
			Backups:       []models.BackupInfo{},
			Timestamp:     time.Now().UTC(),
		})
		return
	}

	if len(infos) == 0 {
		c.JSON(http.StatusOK, models.BackupResponse{
			Stanza:        stanza,
			Status:        "no_stanza",
			StatusMessage: strPtr("No stanza information available"),
			Backups:       []models.BackupInfo{},
			Timestamp:     time.Now().UTC(),
		})
		return
	}

	info := infos[0]

	// Map status code to string
	var status string
	switch info.Status.Code {
	case 0:
		status = "ok"
	case 1:
		status = "missing_stanza"
	case 2:
		status = "no_backup"
	default:
		status = "error"
	}

	// Parse backups
	backups := make([]models.BackupInfo, 0, len(info.Backup))
	var lastFull, lastDiff *time.Time

	for _, b := range info.Backup {
		backup := models.BackupInfo{
			Label: b.Label,
			Type:  b.Type,
		}

		if b.Timestamp.Start > 0 {
			t := time.Unix(b.Timestamp.Start, 0).UTC()
			backup.StartTime = &t
		}
		if b.Timestamp.Stop > 0 {
			t := time.Unix(b.Timestamp.Stop, 0).UTC()
			backup.StopTime = &t

			// Track latest by type
			if b.Type == "full" {
				if lastFull == nil || t.After(*lastFull) {
					lastFull = &t
				}
			} else if b.Type == "diff" {
				if lastDiff == nil || t.After(*lastDiff) {
					lastDiff = &t
				}
			}
		}
		if b.Info.Size > 0 {
			backup.SizeBytes = &b.Info.Size
		}
		if b.Info.Repository.Size > 0 {
			backup.DatabaseSizeBytes = &b.Info.Repository.Size
		}

		backups = append(backups, backup)
	}

	// Parse WAL archive info
	var walArchive *models.WALArchiveInfo
	if len(info.Archive) > 0 {
		walArchive = &models.WALArchiveInfo{}
		if info.Archive[0].Min != "" {
			walArchive.MinWAL = &info.Archive[0].Min
		}
		if info.Archive[0].Max != "" {
			walArchive.MaxWAL = &info.Archive[0].Max
		}
	}

	var statusMessage *string
	if status != "ok" {
		statusMessage = &info.Status.Message
	}

	c.JSON(http.StatusOK, models.BackupResponse{
		Stanza:         stanza,
		Status:         status,
		StatusMessage:  statusMessage,
		Backups:        backups,
		WALArchive:     walArchive,
		LastFullBackup: lastFull,
		LastDiffBackup: lastDiff,
		Timestamp:      time.Now().UTC(),
	})
}

func strPtr(s string) *string {
	return &s
}
