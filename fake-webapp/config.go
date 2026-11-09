package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"time"
)

// Config holds runtime settings read from environment variables.
type Config struct {
	ListenAddr  string
	AppName     string
	Description string
	Keywords    string
	BaseURL     string
	// RateLimit/RateBurst: per-client-IP token bucket; GlobalRate: ceiling for all clients.
	RateLimit  float64
	RateBurst  float64
	GlobalRate float64
	// LoginDelayMin/Max bound the random delay of POST /login.
	LoginDelayMin time.Duration
	LoginDelayMax time.Duration
	// FaviconFile is an optional replacement for the built-in blank favicon.
	FaviconFile string
	// envErr is the first parse error of the numeric variables.
	envErr error
	// RandomSuffix makes the data endpoint /random-<suffix>.
	RandomSuffix string
	// PageSeed selects the generated page variant; PageFile is where the
	// (editable) page template is stored. Empty PageFile means memory only.
	PageSeed string
	PageFile string
}

var (
	suffixRe = regexp.MustCompile(`^[0-9a-f]{8,12}$`)
	seedRe   = regexp.MustCompile(`^[0-9a-f]{16,64}$`)
)

// validate reports whether the config is usable.
func (c Config) validate() error {
	if !suffixRe.MatchString(c.RandomSuffix) {
		return fmt.Errorf("RANDOM_DATA_SUFFIX must match ^[0-9a-f]{8,12}$")
	}
	if !seedRe.MatchString(c.PageSeed) {
		return fmt.Errorf("PAGE_SEED must match ^[0-9a-f]{16,64}$")
	}
	if c.envErr != nil {
		return c.envErr
	}
	if c.RateLimit < 1 || c.RateLimit > 1000 {
		return fmt.Errorf("RATE_LIMIT_RPS must be in 1..1000")
	}
	if c.RateBurst < 1 || c.RateBurst > 1000 {
		return fmt.Errorf("RATE_LIMIT_BURST must be in 1..1000")
	}
	if c.GlobalRate < 1 || c.GlobalRate > 100000 {
		return fmt.Errorf("RATE_LIMIT_GLOBAL_RPS must be in 1..100000")
	}
	if c.LoginDelayMin < 0 || c.LoginDelayMax > 10*time.Second || c.LoginDelayMin > c.LoginDelayMax {
		return fmt.Errorf("LOGIN_DELAY_MIN_MS/LOGIN_DELAY_MAX_MS must satisfy 0 <= min <= max <= 10000")
	}
	return nil
}

// envInt reads a required integer variable; problems are recorded in *errp.
func envInt(key string, errp *error) int {
	v := os.Getenv(key)
	n, err := strconv.Atoi(v)
	if err != nil {
		if *errp == nil {
			*errp = fmt.Errorf("%s must be an integer (got %q)", key, v)
		}
		return 0
	}
	return n
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() Config {
	var envErr error
	rps := envInt("RATE_LIMIT_RPS", &envErr)
	burst := envInt("RATE_LIMIT_BURST", &envErr)
	global := envInt("RATE_LIMIT_GLOBAL_RPS", &envErr)
	dmin := envInt("LOGIN_DELAY_MIN_MS", &envErr)
	dmax := envInt("LOGIN_DELAY_MAX_MS", &envErr)
	return Config{
		ListenAddr:    getenv("LISTEN_ADDR", ":8080"),
		AppName:       getenv("APP_NAME", "Cloud Portal"),
		Description:   getenv("APP_DESCRIPTION", "Secure sign-in to your cloud workspace: manage projects, files and team access in one place."),
		Keywords:      getenv("APP_KEYWORDS", "cloud portal, workspace, sign in, dashboard, team collaboration"),
		BaseURL:       getenv("BASE_URL", ""),
		RateLimit:     float64(rps),
		RateBurst:     float64(burst),
		GlobalRate:    float64(global),
		LoginDelayMin: time.Duration(dmin) * time.Millisecond,
		LoginDelayMax: time.Duration(dmax) * time.Millisecond,
		FaviconFile:   getenv("FAVICON_FILE", "/data/favicon.ico"),
		envErr:        envErr,
		RandomSuffix:  os.Getenv("RANDOM_DATA_SUFFIX"),
		PageSeed:      os.Getenv("PAGE_SEED"),
		PageFile:      getenv("PAGE_FILE", "/data/page.html"),
	}
}
