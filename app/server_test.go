package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

type fakeStore struct {
	items []item
	err   error
}

func (f fakeStore) ListItems(context.Context) ([]item, error) { return f.items, f.err }

func newTestApp(s itemStore) *app {
	a := &app{store: s, dbTimeout: time.Second}
	a.ready.Store(true)
	return a
}

func do(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestItemsOK(t *testing.T) {
	h := newTestApp(fakeStore{items: []item{{ID: 1, Name: "a"}}}).routes()
	rec := do(t, h, "/api/items")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"name":"a"`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}

func TestItemsDBErrorIs503(t *testing.T) {
	h := newTestApp(fakeStore{err: errors.New("boom")}).routes()
	if rec := do(t, h, "/api/items"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestReadyzFlipsOnShutdown(t *testing.T) {
	a := newTestApp(fakeStore{})
	h := a.routes()
	if rec := do(t, h, "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("ready: got %d", rec.Code)
	}
	a.ready.Store(false)
	if rec := do(t, h, "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("shutting down: got %d", rec.Code)
	}
}

func TestMetricsUseRoutePatternNotRawPath(t *testing.T) {
	h := newTestApp(fakeStore{}).routes()
	do(t, h, "/healthz")
	do(t, h, "/no/such/path/12345")
	if got := testutil.ToFloat64(httpRequests.WithLabelValues("GET", "GET /healthz", "200")); got < 1 {
		t.Fatalf("healthz counter = %v", got)
	}
	if got := testutil.ToFloat64(httpRequests.WithLabelValues("GET", "unmatched", "404")); got < 1 {
		t.Fatalf("unmatched counter = %v", got)
	}
}

func TestQuoteLiteral(t *testing.T) {
	if got := quoteLiteral("o'brien"); got != "'o''brien'" {
		t.Fatalf("got %s", got)
	}
}
