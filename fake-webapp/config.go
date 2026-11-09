package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
)

// Config holds runtime settings read from environment variables.
type Config struct {
	ListenAddr  string
	AppName     string
	Description string
	Keywords    string
	BaseURL     string
	RateLimit   float64
	// RandomSuffix makes the data endpoint /random-<suffix>.
	RandomSuffix string
}

var suffixRe = regexp.MustCompile(`^[0-9a-f]{8,12}$`)

// validate reports whether the config is usable.
func (c Config) validate() error {
	if !suffixRe.MatchString(c.RandomSuffix) {
		return fmt.Errorf("RANDOM_DATA_SUFFIX must match ^[0-9a-f]{8,12}$")
	}
	return nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() Config {
	rps := 10.0
	if v := os.Getenv("RATE_LIMIT_RPS"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			rps = f
		}
	}
	return Config{
		ListenAddr:   getenv("LISTEN_ADDR", ":8080"),
		AppName:      getenv("APP_NAME", "Cloud Portal"),
		Description:  getenv("APP_DESCRIPTION", "Secure sign-in to your cloud workspace: manage projects, files and team access in one place."),
		Keywords:     getenv("APP_KEYWORDS", "cloud portal, workspace, sign in, dashboard, team collaboration"),
		BaseURL:      getenv("BASE_URL", ""),
		RateLimit:    rps,
		RandomSuffix: os.Getenv("RANDOM_DATA_SUFFIX"),
	}
}
