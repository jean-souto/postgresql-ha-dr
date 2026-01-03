// Package config provides application configuration management.
package config

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/spf13/viper"
)

// Config holds all application configuration.
type Config struct {
	App      AppConfig
	Database DatabaseConfig
	Backup   BackupConfig
}

// AppConfig holds application-level settings.
type AppConfig struct {
	Name    string `mapstructure:"name"`
	Version string `mapstructure:"version"`
	Port    int    `mapstructure:"port"`
	Debug   bool   `mapstructure:"debug"`
}

// DatabaseConfig holds database connection settings.
type DatabaseConfig struct {
	Host        string `mapstructure:"host"`
	Port        int    `mapstructure:"port"`
	Name        string `mapstructure:"name"`
	User        string `mapstructure:"user"`
	Password    string `mapstructure:"password"`
	PoolMinSize int    `mapstructure:"pool_min_size"`
	PoolMaxSize int    `mapstructure:"pool_max_size"`
}

// BackupConfig holds pgBackRest settings.
type BackupConfig struct {
	Stanza string `mapstructure:"stanza"`
}

// Load loads configuration from environment variables.
func Load() (*Config, error) {
	v := viper.New()

	// Set defaults
	v.SetDefault("app.name", "PostgreSQL HA/DR Demo API (Go)")
	v.SetDefault("app.version", "1.0.0")
	v.SetDefault("app.port", 8000)
	v.SetDefault("app.debug", false)

	v.SetDefault("database.host", "localhost")
	v.SetDefault("database.port", 5432)
	v.SetDefault("database.name", "postgres")
	v.SetDefault("database.user", "postgres")
	v.SetDefault("database.password", "")
	v.SetDefault("database.pool_min_size", 5)
	v.SetDefault("database.pool_max_size", 20)

	v.SetDefault("backup.stanza", "pgha-dev-postgres")

	// Environment variable bindings
	v.SetEnvPrefix("")
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()

	// Map flat environment variables to nested config
	v.BindEnv("app.name", "APP_NAME")
	v.BindEnv("app.version", "APP_VERSION")
	v.BindEnv("app.port", "PORT")
	v.BindEnv("app.debug", "DEBUG")

	v.BindEnv("database.host", "DB_HOST")
	v.BindEnv("database.port", "DB_PORT")
	v.BindEnv("database.name", "DB_NAME")
	v.BindEnv("database.user", "DB_USER")
	v.BindEnv("database.password", "DB_PASSWORD")
	v.BindEnv("database.pool_min_size", "DB_POOL_MIN_SIZE")
	v.BindEnv("database.pool_max_size", "DB_POOL_MAX_SIZE")

	v.BindEnv("backup.stanza", "PGBACKREST_STANZA")

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	return &cfg, nil
}

// DSN returns the PostgreSQL connection string.
func (c *DatabaseConfig) DSN() string {
	return fmt.Sprintf(
		"postgres://%s:%s@%s:%d/%s?sslmode=disable",
		url.QueryEscape(c.User),
		url.QueryEscape(c.Password),
		c.Host,
		c.Port,
		c.Name,
	)
}
