// hello-world: a tiny web app that reads rows from Aurora PostgreSQL using IAM database auth.
//
// Subcommands:
//
//	serve    run the HTTP server (Deployment)
//	migrate  create the IAM-auth DB user, schema and seed data (PreSync Job)
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch cmd {
	case "serve":
		err = serve(ctx)
	case "migrate":
		err = migrate(ctx)
	default:
		err = fmt.Errorf("unknown command %q (want serve|migrate)", cmd)
	}
	if err != nil {
		slog.Error("exiting", "command", cmd, "error", err)
		os.Exit(1)
	}
}

// env returns an environment variable or a default.
func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

// mustEnv returns an environment variable or an error naming it.
func mustEnv(key string) (string, error) {
	v := os.Getenv(key)
	if v == "" {
		return "", fmt.Errorf("missing required env var %s", key)
	}
	return v, nil
}
