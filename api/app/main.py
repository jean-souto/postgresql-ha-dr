"""
PostgreSQL HA/DR Demo API

A FastAPI application demonstrating database connectivity, health checks,
and backup status monitoring for a PostgreSQL HA cluster.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .db import close_pool, get_pool
from .routers import backups_router, health_router, items_router, metrics_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Lifespan context manager for startup/shutdown events.
    Initializes database pool on startup and closes on shutdown.
    """
    # Startup: Initialize database connection pool
    try:
        await get_pool()
        print("Database connection pool initialized")
    except Exception as e:
        print(f"Warning: Failed to initialize database pool: {e}")

    yield

    # Shutdown: Close database connection pool
    await close_pool()
    print("Database connection pool closed")


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    settings = get_settings()

    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        description="""
## PostgreSQL HA/DR Demo API

This API demonstrates connectivity and monitoring for a PostgreSQL High Availability
cluster with Disaster Recovery capabilities.

### Features
- **Health Checks**: Liveness and readiness endpoints
- **CRUD Operations**: Sample items resource for testing
- **Database Metrics**: PostgreSQL statistics and health metrics
- **Backup Status**: pgBackRest backup and WAL archive status

### Architecture
- **Database**: PostgreSQL 17 with Patroni for HA
- **Backup**: pgBackRest with S3 storage
- **Deployment**: AWS App Runner
        """,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )

    # CORS middleware
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],  # Configure appropriately for production
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Include routers
    app.include_router(health_router)
    app.include_router(items_router)
    app.include_router(metrics_router)
    app.include_router(backups_router)

    return app


# Create app instance
app = create_app()


@app.get("/", include_in_schema=False)
async def root():
    """Root endpoint redirects to docs."""
    return {
        "message": "PostgreSQL HA/DR Demo API",
        "docs": "/docs",
        "health": "/health",
        "ready": "/ready",
    }
