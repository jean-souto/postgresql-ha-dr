# PostgreSQL HA/DR Demo API (Go) - Makefile

.PHONY: build run test clean docker-build docker-run lint fmt

# Build configuration
BINARY_NAME=api
MAIN_PATH=./cmd/api

# Go commands
GOCMD=go
GOBUILD=$(GOCMD) build
GORUN=$(GOCMD) run
GOTEST=$(GOCMD) test
GOMOD=$(GOCMD) mod
GOFMT=gofmt

# Build the application
build:
	$(GOBUILD) -o $(BINARY_NAME) $(MAIN_PATH)

# Run the application
run:
	$(GORUN) $(MAIN_PATH)

# Run tests
test:
	$(GOTEST) -v ./...

# Run tests with coverage
test-coverage:
	$(GOTEST) -v -coverprofile=coverage.out ./...
	$(GOCMD) tool cover -html=coverage.out -o coverage.html

# Clean build artifacts
clean:
	rm -f $(BINARY_NAME)
	rm -f coverage.out coverage.html

# Download dependencies
deps:
	$(GOMOD) download
	$(GOMOD) tidy

# Format code
fmt:
	$(GOFMT) -s -w .

# Lint code (requires golangci-lint)
lint:
	golangci-lint run

# Build Docker image
docker-build:
	docker build -t postgresql-ha-dr-api-go:latest .

# Run Docker container
docker-run:
	docker run --rm -p 8000:8000 \
		-e DB_HOST=host.docker.internal \
		-e DB_PASSWORD=password \
		postgresql-ha-dr-api-go:latest

# Development mode with hot reload (requires air)
dev:
	air

# Generate go.sum if needed
init:
	$(GOMOD) init github.com/postgresql-ha-dr/api-go || true
	$(GOMOD) tidy
