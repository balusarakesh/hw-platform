package main

import (
	"context"
	"net/http"
	"os"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/contrib/propagators/aws/xray"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupTracing sends spans over OTLP/HTTP to the CloudWatch agent, which forwards them to X-Ray.
// Endpoint and sampling come from the standard OTEL_* env vars (set in the Helm chart):
//
//	OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  e.g. http://cloudwatch-agent.amazon-cloudwatch:4316/v1/traces
//	OTEL_TRACES_SAMPLER / _ARG          e.g. parentbased_traceidratio / 1.0
//
// With no endpoint configured (local runs, tests) tracing is a no-op.
func setupTracing(ctx context.Context) (shutdown func(context.Context) error, err error) {
	noop := func(context.Context) error { return nil }
	if os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		return noop, nil
	}

	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return noop, err
	}
	// resource.New builds the resource without pinning our own semconv schema URL. Merging
	// resource.Default() (the SDK's schema) with attributes from a different semconv package version
	// fails with "conflicting Schema URL" and crashed the app on startup.
	res, err := resource.New(ctx,
		resource.WithTelemetrySDK(),
		resource.WithFromEnv(), // OTEL_RESOURCE_ATTRIBUTES / OTEL_SERVICE_NAME
		resource.WithAttributes(
			attribute.String("service.name", env("OTEL_SERVICE_NAME", "hello-world")),
			attribute.String("deployment.environment", env("DEPLOYMENT_ENVIRONMENT", "demo")),
		),
	)
	if err != nil {
		return noop, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
		// X-Ray-compatible trace IDs (timestamp prefix), so traces work in X-Ray as well as Transaction Search.
		sdktrace.WithIDGenerator(xray.NewIDGenerator()),
	)
	otel.SetTracerProvider(tp)
	// Accept and forward both W3C traceparent and the ALB's X-Amzn-Trace-Id header.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}, xray.Propagator{},
	))
	return tp.Shutdown, nil
}

// traced wraps the app handler: one server span per request. Probes are skipped (they'd be most of
// the traces and carry no signal).
func traced(next http.Handler) http.Handler {
	return otelhttp.NewHandler(next, "http.request",
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
		}),
	)
}

// nameSpanByRoute renames the request span to the ServeMux route pattern once routing has happened
// (otelhttp starts the span before the route is known).
func nameSpanByRoute(r *http.Request) {
	span := trace.SpanFromContext(r.Context())
	if !span.IsRecording() {
		return
	}
	route := r.Pattern
	if route == "" {
		route = "unmatched"
	}
	span.SetName(route)
	span.SetAttributes(attribute.String("http.route", route))
}
