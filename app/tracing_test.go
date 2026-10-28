package main

import (
	"context"
	"testing"
)

// Regression test: with an endpoint configured, setupTracing must succeed. It used to fail with
// "conflicting Schema URL" (resource.Default() merged with a different semconv version), which
// only surfaced when tracing was switched on in the cluster.
func TestSetupTracingWithEndpoint(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:4318/v1/traces")
	t.Setenv("OTEL_SERVICE_NAME", "hello-world-test")
	shutdown, err := setupTracing(context.Background())
	if err != nil {
		t.Fatalf("setupTracing: %v", err)
	}
	_ = shutdown(context.Background())
}
