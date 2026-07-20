package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config holds all application configuration.
// Secrets must be injected via environment variables using ${VAR} syntax.
type Config struct {
	Server  ServerConfig  `yaml:"server"`
	Webhook WebhookConfig `yaml:"webhook"`
	Repos   []RepoConfig  `yaml:"repos"`
}

type ServerConfig struct {
	// Addr should always be "127.0.0.1:<port>" — never 0.0.0.0 in production.
	Addr         string `yaml:"addr"`
	ReadTimeout  int    `yaml:"read_timeout_seconds"`
	WriteTimeout int    `yaml:"write_timeout_seconds"`
	// MaxBodyBytes limits incoming webhook payload size.
	MaxBodyBytes int64 `yaml:"max_body_bytes"`
}

type WebhookConfig struct {
	// Path is the HTTP endpoint that receives GitHub webhooks.
	Path string `yaml:"path"`
	// Secret is the HMAC-SHA256 key shared with GitHub.
	// Use ${GITHUB_WEBHOOK_SECRET} and export the env var — never hardcode.
	Secret string `yaml:"secret"`
}

type RepoConfig struct {
	// Name is "owner/repo" as reported by GitHub.
	Name string `yaml:"name"`
	// Branch that triggers deploy (e.g. "main").
	Branch string `yaml:"branch"`
	// Workflow is the workflow file name or display name (e.g. "ci.yml").
	// Empty string matches any workflow on the configured branch.
	Workflow string `yaml:"workflow"`
	// DeployPath is the absolute path to the project directory on this server.
	// Must be owned by DeployUser.
	DeployPath string `yaml:"deploy_path"`
	// DeployUser is the OS user that runs the deploy script.
	DeployUser string `yaml:"deploy_user"`
	// DeployScript is the script filename to execute inside DeployPath (e.g. "update.sh").
	// Executed as: sudo -n -H -u DeployUser DeployPath/DeployScript
	DeployScript string `yaml:"deploy_script"`
}

// Load reads, validates, and returns Config from path.
// Expands ${ENV_VAR} in the file before parsing.
// Fails if the config file is group- or world-readable (mode must be 0600 or tighter).
func Load(path string) (*Config, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat config %q: %w", path, err)
	}
	if info.Mode().Perm()&0o044 != 0 {
		return nil, fmt.Errorf(
			"config file %q permissions are too open (mode %04o): set to 0600 — "+
				"this file may contain secrets via env expansion",
			path, info.Mode().Perm(),
		)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	expanded := os.ExpandEnv(string(raw))

	var cfg Config
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

func (c *Config) validate() error {
	// Server defaults
	if c.Server.Addr == "" {
		c.Server.Addr = "127.0.0.1:9000"
	}
	if c.Server.ReadTimeout == 0 {
		c.Server.ReadTimeout = 10
	}
	if c.Server.WriteTimeout == 0 {
		c.Server.WriteTimeout = 10
	}
	if c.Server.MaxBodyBytes == 0 {
		c.Server.MaxBodyBytes = 10 * 1024 * 1024 // 10 MiB
	}

	// Webhook defaults
	if c.Webhook.Path == "" {
		c.Webhook.Path = "/webhook"
	}
	// Secret validated separately in main (so error message is clear)

	if len(c.Repos) == 0 {
		return fmt.Errorf("no repos configured")
	}

	seen := make(map[string]bool)
	for i := range c.Repos {
		r := &c.Repos[i]

		if r.Name == "" {
			return fmt.Errorf("repos[%d]: name required", i)
		}
		if !strings.Contains(r.Name, "/") {
			return fmt.Errorf("repos[%d]: name must be 'owner/repo', got %q", i, r.Name)
		}
		if r.DeployPath == "" {
			return fmt.Errorf("repos[%d] (%s): deploy_path required", i, r.Name)
		}
		if r.DeployUser == "" {
			return fmt.Errorf("repos[%d] (%s): deploy_user required", i, r.Name)
		}
		if r.DeployScript == "" {
			return fmt.Errorf("repos[%d] (%s): deploy_script required", i, r.Name)
		}
		if filepath.IsAbs(r.DeployScript) || strings.Contains(r.DeployScript, "..") {
			return fmt.Errorf("repos[%d] (%s): deploy_script must be a filename, not a path — got %q", i, r.Name, r.DeployScript)
		}

		// Sanitize deploy_path — must be absolute and clean.
		clean := filepath.Clean(r.DeployPath)
		if !filepath.IsAbs(clean) {
			return fmt.Errorf("repos[%d] (%s): deploy_path must be absolute, got %q", i, r.Name, r.DeployPath)
		}
		if clean != r.DeployPath {
			return fmt.Errorf("repos[%d] (%s): deploy_path is not clean — use %q instead of %q",
				i, r.Name, clean, r.DeployPath)
		}

		if r.Branch == "" {
			r.Branch = "main"
		}

		key := r.Name + "|" + r.Branch + "|" + r.Workflow
		if seen[key] {
			return fmt.Errorf("repos[%d]: duplicate entry for repo=%s branch=%s workflow=%q", i, r.Name, r.Branch, r.Workflow)
		}
		seen[key] = true
	}

	return nil
}

// RepoByEvent finds a matching RepoConfig for an incoming workflow_run event.
// Returns nil if no config matches.
func (c *Config) RepoByEvent(repoFullName, branch, workflowName string) *RepoConfig {
	for i := range c.Repos {
		r := &c.Repos[i]
		if r.Name != repoFullName || r.Branch != branch {
			continue
		}
		// Empty workflow matches any workflow on that branch.
		if r.Workflow == "" || r.Workflow == workflowName {
			return r
		}
	}
	return nil
}
