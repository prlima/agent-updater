// Package webhook handles incoming GitHub webhook requests.
package webhook

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"golang.org/x/time/rate"

	"github.com/prlima/personal-agent-updater/internal/config"
	"github.com/prlima/personal-agent-updater/internal/deploy"
	"github.com/prlima/personal-agent-updater/internal/security"
)

// GitHub workflow_run event payload (only fields we use).
type workflowRunPayload struct {
	Action      string      `json:"action"`
	WorkflowRun workflowRun `json:"workflow_run"`
	Repository  repository  `json:"repository"`
}

type workflowRun struct {
	Name       string `json:"name"`       // workflow file/display name
	HeadBranch string `json:"head_branch"`
	Conclusion string `json:"conclusion"` // "success", "failure", etc.
	Status     string `json:"status"`
}

type repository struct {
	FullName string `json:"full_name"` // "owner/repo"
}

// Handler validates and dispatches GitHub webhook events.
type Handler struct {
	cfg      *config.Config
	deployer *deploy.Deployer
	logger   *slog.Logger
	secret   []byte
	// limiter is shared across all IPs — for per-IP limiting, use a map+mutex.
	limiter *rate.Limiter
}

// New creates a Handler.
func New(cfg *config.Config, deployer *deploy.Deployer, logger *slog.Logger) *Handler {
	return &Handler{
		cfg:      cfg,
		deployer: deployer,
		logger:   logger,
		secret:   []byte(cfg.Webhook.Secret),
		// Allow burst of 5, recover 1 token/second.
		// Webhook rate from GitHub is low; this guards against replay storms.
		limiter: rate.NewLimiter(rate.Every(time.Second), 5),
	}
}

// ServeHTTP implements http.Handler.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	log := h.logger.With(slog.String("remote_addr", r.RemoteAddr))

	// --- Rate limiting ---
	if !h.limiter.Allow() {
		log.Warn("rate limit exceeded")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}

	// --- Method check ---
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// --- Read body (bounded) ---
	body, err := io.ReadAll(io.LimitReader(r.Body, h.cfg.Server.MaxBodyBytes))
	if err != nil {
		log.Error("failed to read request body", slog.String("err", err.Error()))
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// --- HMAC verification — must happen before any payload processing ---
	sig := r.Header.Get("X-Hub-Signature-256")
	if err := security.VerifyGitHubSignature(h.secret, body, sig); err != nil {
		log.Warn("webhook signature verification failed",
			slog.String("err", err.Error()),
			slog.String("signature_header", sig),
		)
		// Return 403, not 401 — don't reveal whether the secret exists.
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	// --- Event type filter ---
	event := r.Header.Get("X-GitHub-Event")
	deliveryID := r.Header.Get("X-GitHub-Delivery")

	log = log.With(
		slog.String("event", event),
		slog.String("delivery_id", deliveryID),
	)

	if event == "ping" {
		log.Info("ping received", slog.String("hook_id", r.Header.Get("X-Github-Hook-Id")))
		w.WriteHeader(http.StatusOK)
		return
	}

	if event != "workflow_run" {
		log.Debug("ignoring non-workflow_run event")
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// --- Parse payload ---
	var payload workflowRunPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		log.Error("failed to parse webhook payload", slog.String("err", err.Error()))
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	log = log.With(
		slog.String("repo", payload.Repository.FullName),
		slog.String("branch", payload.WorkflowRun.HeadBranch),
		slog.String("workflow", payload.WorkflowRun.Name),
		slog.String("action", payload.Action),
		slog.String("conclusion", payload.WorkflowRun.Conclusion),
	)

	// Only deploy on completed + successful runs.
	if payload.Action != "completed" || payload.WorkflowRun.Conclusion != "success" {
		log.Info("workflow_run not eligible for deploy")
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// --- Match repo config ---
	repo := h.cfg.RepoByEvent(
		payload.Repository.FullName,
		payload.WorkflowRun.HeadBranch,
		payload.WorkflowRun.Name,
	)
	if repo == nil {
		log.Info("no deploy config found for this repo/branch/workflow")
		w.WriteHeader(http.StatusNoContent)
		return
	}

	log.Info("deploy triggered")

	// Respond 202 immediately — deploy is async, GitHub doesn't wait.
	w.WriteHeader(http.StatusAccepted)

	// Capture values needed in goroutine before request is gone.
	repoSnapshot := *repo
	deployLogger := log

	go func() {
		// Use a fresh context — request context will be cancelled after ServeHTTP returns.
		ctx, cancel := context.WithTimeout(context.Background(), deploy.DeployTimeout+30*time.Second)
		defer cancel()

		if err := h.deployer.Deploy(ctx, &repoSnapshot, deployLogger); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				deployLogger.Error("deploy timed out", slog.String("err", err.Error()))
			} else {
				deployLogger.Error("deploy failed", slog.String("err", err.Error()))
			}
		}
	}()
}
