"""
Application configuration using pydantic-settings.
Environment variables are loaded automatically.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Application
    app_name: str = "PostgreSQL HA/DR Demo API"
    app_version: str = "1.0.0"
    debug: bool = False

    # Database
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "postgres"
    db_user: str = "postgres"
    db_password: str = ""
    db_pool_min_size: int = 5
    db_pool_max_size: int = 20

    # pgBackRest (for backup status endpoint)
    pgbackrest_stanza: str = "pgha-dev-postgres"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
