package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

//go:embed web/index.html
var indexHTML []byte

type item struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

// itemStore is what the handlers need from the database (an interface so tests can fake it).
type itemStore interface {
	ListItems(ctx context.Context) ([]item, error)
}

type pgStore struct{ pool *pgxpool.Pool }

func (s pgStore) ListItems(ctx context.Context) ([]item, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, created_at FROM items ORDER BY id LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Name, &it.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

type app struct {
	store     itemStore
	ready     atomic.Bool
	dbTimeout time.Duration
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.handleIndex)
	mux.HandleFunc("GET /api/items", a.handleItems)
	mux.HandleFunc("GET /healthz", a.handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	return securityHeaders(instrument(mux))
}

func (a *app) handleIndex(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(indexHTML)
}

func (a *app) handleItems(w http.ResponseWriter, r *http.Request) {
	// Generous timeout: the first query after Aurora auto-pauses waits for it to resume (~15s).
	ctx, cancel := context.WithTimeout(r.Context(), a.dbTimeout)
	defer cancel()

	start := time.Now()
	items, err := a.store.ListItems(ctx)
	elapsed := time.Since(start)
	if err != nil {
		slog.Error("list items", "error", err, "db_ms", elapsed.Milliseconds())
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "database unavailable, try again"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "db_ms": elapsed.Milliseconds()})
}

// Liveness: the process is up. No dependency checks, so a DB issue never restarts pods.
func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Readiness: deliberately does NOT ping the database. Aurora scales to zero when idle; if
// readiness depended on it, every pod would drop out of the ALB during a pause and users
// would get 502s instead of a slow first response. It only flips to false during shutdown
// so the ALB stops sending traffic before the process exits.
func (a *app) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !a.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting down"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

func serve(ctx context.Context) error {
	dbc, err := dbConfigFromEnv()
	if err != nil {
		return err
	}
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(dbc.Region))
	if err != nil {
		return err
	}
	pool, err := newIAMPool(ctx, dbc, awsCfg.Credentials)
	if err != nil {
		return err
	}
	defer pool.Close()

	a := &app{store: pgStore{pool: pool}, dbTimeout: 25 * time.Second}
	a.ready.Store(true)

	appSrv := &http.Server{
		Addr:              env("LISTEN_ADDR", ":8080"),
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	// Metrics live on a separate port that the Service/Ingress don't expose,
	// so /metrics is never reachable from the internet.
	metricsMux := http.NewServeMux()
	metricsMux.Handle("GET /metrics", promhttp.Handler())
	metricsSrv := &http.Server{
		Addr:              env("METRICS_ADDR", ":9090"),
		Handler:           metricsMux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 2)
	for _, s := range []*http.Server{appSrv, metricsSrv} {
		go func() {
			slog.Info("listening", "addr", s.Addr)
			if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errCh <- err
			}
		}()
	}

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	// Graceful shutdown: fail readiness, give the ALB time to deregister, then drain.
	slog.Info("shutting down")
	a.ready.Store(false)
	time.Sleep(env2dur("SHUTDOWN_DELAY", 10*time.Second))
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return errors.Join(appSrv.Shutdown(shutdownCtx), metricsSrv.Shutdown(shutdownCtx))
}

func env2dur(key string, def time.Duration) time.Duration {
	d, err := time.ParseDuration(env(key, ""))
	if err != nil {
		return def
	}
	return d
}
