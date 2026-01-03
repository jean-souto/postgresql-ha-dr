package handlers

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/db"
	"github.com/postgresql-ha-dr/api-go/internal/models"
)

// ItemsHandler handles item CRUD operations.
type ItemsHandler struct {
	pool *db.Pool
}

// NewItemsHandler creates a new items handler.
func NewItemsHandler(pool *db.Pool) *ItemsHandler {
	return &ItemsHandler{pool: pool}
}

// ensureTableExists creates the items table if it doesn't exist.
func (h *ItemsHandler) ensureTableExists(ctx context.Context) error {
	_, err := h.pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS items (
			id SERIAL PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			description TEXT,
			price DECIMAL(10, 2) NOT NULL,
			is_active BOOLEAN DEFAULT TRUE,
			created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
			updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
		)
	`)
	if err != nil {
		return err
	}

	_, err = h.pool.Exec(ctx, `
		CREATE INDEX IF NOT EXISTS idx_items_is_active ON items(is_active)
	`)
	return err
}

// Create handles POST /items - create a new item.
func (h *ItemsHandler) Create(c *gin.Context) {
	var req models.ItemCreate
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "validation_error",
			Message: err.Error(),
		})
		return
	}

	ctx := c.Request.Context()
	if err := h.ensureTableExists(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to ensure table exists",
		})
		return
	}

	isActive := true
	if req.IsActive != nil {
		isActive = *req.IsActive
	}

	now := time.Now().UTC()
	var item models.Item

	err := h.pool.QueryRow(ctx, `
		INSERT INTO items (name, description, price, is_active, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $5)
		RETURNING id, name, description, price, is_active, created_at, updated_at
	`, req.Name, req.Description, req.Price, isActive, now).Scan(
		&item.ID, &item.Name, &item.Description, &item.Price,
		&item.IsActive, &item.CreatedAt, &item.UpdatedAt,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create item",
		})
		return
	}

	c.JSON(http.StatusCreated, item)
}

// List handles GET /items - list all items.
func (h *ItemsHandler) List(c *gin.Context) {
	ctx := c.Request.Context()
	if err := h.ensureTableExists(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to ensure table exists",
		})
		return
	}

	skip, _ := strconv.Atoi(c.DefaultQuery("skip", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	activeOnly := c.DefaultQuery("active_only", "false") == "true"

	if limit > 1000 {
		limit = 1000
	}

	var rows interface{}
	var err error

	if activeOnly {
		rows, err = h.pool.Query(ctx, `
			SELECT id, name, description, price, is_active, created_at, updated_at
			FROM items
			WHERE is_active = TRUE
			ORDER BY id
			OFFSET $1 LIMIT $2
		`, skip, limit)
	} else {
		rows, err = h.pool.Query(ctx, `
			SELECT id, name, description, price, is_active, created_at, updated_at
			FROM items
			ORDER BY id
			OFFSET $1 LIMIT $2
		`, skip, limit)
	}

	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list items",
		})
		return
	}

	pgRows := rows.(interface{ Close(); Next() bool; Scan(dest ...any) error })
	defer pgRows.Close()

	var items []models.Item
	for pgRows.Next() {
		var item models.Item
		if err := pgRows.Scan(
			&item.ID, &item.Name, &item.Description, &item.Price,
			&item.IsActive, &item.CreatedAt, &item.UpdatedAt,
		); err != nil {
			continue
		}
		items = append(items, item)
	}

	if items == nil {
		items = []models.Item{}
	}

	c.JSON(http.StatusOK, items)
}

// Get handles GET /items/:id - get a specific item.
func (h *ItemsHandler) Get(c *gin.Context) {
	ctx := c.Request.Context()
	if err := h.ensureTableExists(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to ensure table exists",
		})
		return
	}

	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_id",
			Message: "Item ID must be a number",
		})
		return
	}

	var item models.Item
	err = h.pool.QueryRow(ctx, `
		SELECT id, name, description, price, is_active, created_at, updated_at
		FROM items
		WHERE id = $1
	`, id).Scan(
		&item.ID, &item.Name, &item.Description, &item.Price,
		&item.IsActive, &item.CreatedAt, &item.UpdatedAt,
	)

	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Item not found",
		})
		return
	}

	c.JSON(http.StatusOK, item)
}

// Update handles PUT /items/:id - update an item.
func (h *ItemsHandler) Update(c *gin.Context) {
	ctx := c.Request.Context()
	if err := h.ensureTableExists(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to ensure table exists",
		})
		return
	}

	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_id",
			Message: "Item ID must be a number",
		})
		return
	}

	var req models.ItemUpdate
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "validation_error",
			Message: err.Error(),
		})
		return
	}

	// Get current item
	var current models.Item
	err = h.pool.QueryRow(ctx, `
		SELECT id, name, description, price, is_active, created_at, updated_at
		FROM items WHERE id = $1
	`, id).Scan(
		&current.ID, &current.Name, &current.Description, &current.Price,
		&current.IsActive, &current.CreatedAt, &current.UpdatedAt,
	)

	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Item not found",
		})
		return
	}

	// Apply updates
	if req.Name != nil {
		current.Name = *req.Name
	}
	if req.Description != nil {
		current.Description = req.Description
	}
	if req.Price != nil {
		current.Price = *req.Price
	}
	if req.IsActive != nil {
		current.IsActive = *req.IsActive
	}
	current.UpdatedAt = time.Now().UTC()

	// Save
	_, err = h.pool.Exec(ctx, `
		UPDATE items
		SET name = $1, description = $2, price = $3, is_active = $4, updated_at = $5
		WHERE id = $6
	`, current.Name, current.Description, current.Price, current.IsActive, current.UpdatedAt, id)

	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to update item",
		})
		return
	}

	c.JSON(http.StatusOK, current)
}

// Delete handles DELETE /items/:id - delete an item.
func (h *ItemsHandler) Delete(c *gin.Context) {
	ctx := c.Request.Context()
	if err := h.ensureTableExists(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to ensure table exists",
		})
		return
	}

	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_id",
			Message: "Item ID must be a number",
		})
		return
	}

	result, err := h.pool.Exec(ctx, "DELETE FROM items WHERE id = $1", id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to delete item",
		})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Item not found",
		})
		return
	}

	c.Status(http.StatusNoContent)
}
