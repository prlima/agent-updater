package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prlima/personal-agent-updater/internal/config"
	"github.com/prlima/personal-agent-updater/internal/deploy"
	"github.com/prlima/personal-agent-updater/internal/webhook"
)

const shutdownTimeout = 30 * time.Second

var (
	version   = "dev"
	buildTime = "unknown"
)

func main() {
	cfgPath := flag.String("config", "config.yaml", "path to config file")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("github-agent %s (built %s)\n", version, buildTime)
		return
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	if err := run(*cfgPath, logger); err != nil {
		logger.Error("fatal", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

func run(cfgPath string, logger *slog.Logger) error {
	// --- Load config ---
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// Secret must be non-empty after env expansion.
	if cfg.Webhook.Secret == "" {
		return fmt.Errorf(
			"webhook.secret is empty — export GITHUB_WEBHOOK_SECRET (or equivalent) before starting",
		)
	}

	// Log repos (no secrets).
	for _, r := range cfg.Repos {
		logger.Info("repo registered",
			slog.String("repo", r.Name),
			slog.String("branch", r.Branch),
			slog.String("workflow", r.Workflow),
			slog.String("deploy_path", r.DeployPath),
			slog.String("deploy_user", r.DeployUser),
		)
	}

	// --- Build HTTP mux ---
	deployer := deploy.New()
	handler := webhook.New(cfg, deployer, logger)

	mux := http.NewServeMux()
	mux.Handle(cfg.Webhook.Path, handler)
	mux.HandleFunc("/healthz", healthz)

	srv := &http.Server{
		Addr:    cfg.Server.Addr,
		Handler: mux,
		// Timeouts prevent Slowloris and related attacks.
		ReadTimeout:       time.Duration(cfg.Server.ReadTimeout) * time.Second,
		WriteTimeout:      time.Duration(cfg.Server.WriteTimeout) * time.Second,
		IdleTimeout:       60 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// --- Start server ---
	serverErr := make(chan error, 1)
	go func() {
		logger.Info("server listening",
			slog.String("addr", cfg.Server.Addr),
			slog.String("webhook_path", cfg.Webhook.Path),
		)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
	}()

	// --- Graceful shutdown ---
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-serverErr:
		return fmt.Errorf("server error: %w", err)
	case sig := <-quit:
		logger.Info("shutdown signal received", slog.String("signal", sig.String()))
	}

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		return fmt.Errorf("graceful shutdown failed: %w", err)
	}

	logger.Info("server stopped gracefully")
	return nil
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}
