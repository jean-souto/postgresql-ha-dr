// PostgreSQL HA/DR Demo API (Go)
//
// A Gin-based API demonstrating database connectivity, health checks,
// and backup status monitoring for a PostgreSQL HA cluster.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/config"
	"github.com/postgresql-ha-dr/api-go/internal/db"
	"github.com/postgresql-ha-dr/api-go/internal/handlers"
)

func main() {
	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Set Gin mode
	if !cfg.App.Debug {
		gin.SetMode(gin.ReleaseMode)
	}

	// Initialize database pool
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var pool *db.Pool
	pool, err = db.NewPool(ctx, &cfg.Database)
	if err != nil {
		log.Printf("Warning: Failed to initialize database pool: %v", err)
		log.Printf("API will start but database features will be unavailable")
	} else {
		defer pool.Close()
		log.Println("Database connection pool initialized")
	}

	// Create router
	router := gin.New()
	router.Use(gin.Logger())
	router.Use(gin.Recovery())
	router.Use(corsMiddleware())

	// Initialize handlers
	healthHandler := handlers.NewHealthHandler(cfg, pool)
	itemsHandler := handlers.NewItemsHandler(pool)
	metricsHandler := handlers.NewMetricsHandler(pool)
	backupsHandler := handlers.NewBackupsHandler(cfg)

	// Register routes
	router.GET("/", healthHandler.Root)
	router.GET("/health", healthHandler.Health)
	router.GET("/ready", healthHandler.Ready)
	router.GET("/metrics", metricsHandler.Metrics)
	router.GET("/backups", backupsHandler.Backups)

	// Items CRUD
	items := router.Group("/items")
	{
		items.POST("", itemsHandler.Create)
		items.GET("", itemsHandler.List)
		items.GET("/:id", itemsHandler.Get)
		items.PUT("/:id", itemsHandler.Update)
		items.DELETE("/:id", itemsHandler.Delete)
	}

	// Create HTTP server
	addr := fmt.Sprintf(":%d", cfg.App.Port)
	srv := &http.Server{
		Addr:    addr,
		Handler: router,
	}

	// Start server in goroutine
	go func() {
		log.Printf("Starting %s v%s on %s", cfg.App.Name, cfg.App.Version, addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start server: %v", err)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")

	// Graceful shutdown with timeout
	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}

// corsMiddleware adds CORS headers to responses.
func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}

		c.Next()
	}
}
