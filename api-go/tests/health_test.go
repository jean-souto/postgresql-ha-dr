package tests

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/postgresql-ha-dr/api-go/internal/config"
	"github.com/postgresql-ha-dr/api-go/internal/handlers"
	"github.com/postgresql-ha-dr/api-go/internal/models"
)

func setupRouter() *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()

	cfg := &config.Config{
		App: config.AppConfig{
			Name:    "Test API",
			Version: "1.0.0",
			Port:    8000,
			Debug:   true,
		},
	}

	healthHandler := handlers.NewHealthHandler(cfg, nil)

	router.GET("/", healthHandler.Root)
	router.GET("/health", healthHandler.Health)
	router.GET("/ready", healthHandler.Ready)

	return router
}

func TestHealthEndpoint(t *testing.T) {
	router := setupRouter()

	req, _ := http.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response models.HealthResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Errorf("Failed to parse response: %v", err)
	}

	if response.Status != "healthy" {
		t.Errorf("Expected status 'healthy', got '%s'", response.Status)
	}

	if response.Version != "1.0.0" {
		t.Errorf("Expected version '1.0.0', got '%s'", response.Version)
	}
}

func TestRootEndpoint(t *testing.T) {
	router := setupRouter()

	req, _ := http.NewRequest("GET", "/", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Errorf("Failed to parse response: %v", err)
	}

	if _, ok := response["message"]; !ok {
		t.Error("Expected 'message' field in response")
	}

	if _, ok := response["health"]; !ok {
		t.Error("Expected 'health' field in response")
	}
}

func TestReadyEndpointNoDB(t *testing.T) {
	router := setupRouter()

	req, _ := http.NewRequest("GET", "/ready", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	// Without DB pool, should return 503
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("Expected status 503, got %d", w.Code)
	}

	var response models.ReadyResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Errorf("Failed to parse response: %v", err)
	}

	if response.Status != "not_ready" {
		t.Errorf("Expected status 'not_ready', got '%s'", response.Status)
	}
}
