// Package deploy executes a deploy script on behalf of a deploy user.
package deploy

import (
	"context"
	"fmt"
	"log/slog"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/prlima/agent-updater/internal/config"
)

const (
	// DeployTimeout caps total time for script execution.
	DeployTimeout = 15 * time.Minute
)

// Deployer serializes concurrent deploy requests per repository.
type Deployer struct {
	// locks maps repo full name → *sync.Mutex to prevent overlapping deploys.
	locks sync.Map
}

// New returns a ready Deployer.
func New() *Deployer {
	return &Deployer{}
}

// Deploy runs repo.DeployScript inside repo.DeployPath as repo.DeployUser via sudo.
// If a deploy for the same repo is already in progress, returns an error immediately.
func (d *Deployer) Deploy(ctx context.Context, repo *config.RepoConfig, logger *slog.Logger) error {
	mu := d.lockFor(repo.Name)

	if !mu.TryLock() {
		return fmt.Errorf("deploy already in progress for %s — skipping", repo.Name)
	}
	defer mu.Unlock()

	deployCtx, cancel := context.WithTimeout(ctx, DeployTimeout)
	defer cancel()

	log := logger.With(
		slog.String("repo", repo.Name),
		slog.String("deploy_path", repo.DeployPath),
		slog.String("deploy_user", repo.DeployUser),
		slog.String("deploy_script", repo.DeployScript),
	)

	log.Info("deploy started")

	start := time.Now()
	err := d.runScript(deployCtx, repo, log)
	duration := time.Since(start).Round(time.Millisecond)

	if err != nil {
		log.Error("deploy summary",
			slog.String("status", "failed"),
			slog.String("duration", duration.String()),
			slog.String("err", err.Error()),
		)
		return err
	}

	log.Info("deploy summary",
		slog.String("status", "success"),
		slog.String("duration", duration.String()),
	)
	return nil
}

// runScript executes: sudo -n -H -u <user> -D <deploy_path> <deploy_path>/<script>
// SECURITY: uses exec.Command with explicit arg list — no shell, no injection risk.
// -H sets HOME to the target user's home dir so the script sees e.g. /root/.docker/config.json
// (docker credentials). Without it, HOME stays the agent service user's home and docker
// pulls anonymously — private-registry pulls then fail with "pull access denied".
// -D (--chdir) makes sudo chdir into deploy_path AFTER switching to the deploy user.
// Do NOT use cmd.Dir here: Go performs that chdir in the forked child before exec,
// still as the unprivileged agent user, which cannot traverse /home/<deploy_user>
// and fails with "chdir ...: permission denied". Requires sudo >= 1.9.3 and
// CWD=* in the sudoers rule (written by install.sh) — per sudoers(5), only
// "*" authorizes the -D flag; CWD=<exact path> rejects -D and instead forces
// that cwd on its own.
func (d *Deployer) runScript(ctx context.Context, repo *config.RepoConfig, logger *slog.Logger) error {
	if err := validatePath(repo.DeployPath); err != nil {
		return fmt.Errorf("deploy_path validation: %w", err)
	}

	scriptPath := filepath.Join(repo.DeployPath, repo.DeployScript)

	cmd := exec.CommandContext(ctx, "sudo", "-n", "-H", "-u", repo.DeployUser, "-D", repo.DeployPath, scriptPath)

	logger.Info("running deploy script",
		slog.String("cmd", cmd.String()),
	)

	out, err := cmd.CombinedOutput()
	if len(out) > 0 {
		logger.Info("script output", slog.String("output", string(out)))
	}
	if err != nil {
		return fmt.Errorf("script exit: %w | output: %s", err, string(out))
	}

	return nil
}

func (d *Deployer) lockFor(repo string) *sync.Mutex {
	v, _ := d.locks.LoadOrStore(repo, &sync.Mutex{})
	return v.(*sync.Mutex)
}

func validatePath(path string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("not absolute: %q", path)
	}
	if filepath.Clean(path) != path {
		return fmt.Errorf("not clean: %q", path)
	}
	return nil
}
