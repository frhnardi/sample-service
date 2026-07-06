// Package main is a minimal HTTP service wired to the golden path.
//
// It exposes two endpoints:
//
//	GET /healthz  liveness/readiness probe (used by Kubernetes)
//	GET /hello    demo endpoint; optional ?name= query parameter
//
// Keep this file small: the point of the template is the paved road around it
// (CI, scanning, signing, GitOps), not the business logic.
package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"
)

// newRouter builds the HTTP handler. It is split out from main so tests can
// exercise the routes with httptest without binding a real socket.
//
// Routes use Go 1.22 method-aware patterns, so the mux returns 405 for a known
// path hit with the wrong method and 404 for an unknown path — no manual checks.
func newRouter() http.Handler {
	mux := http.NewServeMux()

	// Liveness probe. Deliberately dependency-free so it still answers when
	// downstreams are unhealthy — Kubernetes uses it only to decide restarts.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	// Demo endpoint. Greets the caller; the name defaults to "world".
	mux.HandleFunc("GET /hello", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		if name == "" {
			name = "world"
		}
		writeJSON(w, http.StatusOK, map[string]string{"message": "hello, " + name})
	})

	return mux
}

// writeJSON encodes body as JSON with the given status. The encode error is
// intentionally ignored: the header/status are already committed to the wire,
// so there is nothing actionable to do if the client has gone away.
func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func main() {
	addr := ":8080"
	if port := os.Getenv("PORT"); port != "" {
		addr = ":" + port
	}

	srv := &http.Server{
		Addr:    addr,
		Handler: newRouter(),
		// Bound the header read so a slow client cannot hold a connection open
		// indefinitely (mitigates Slowloris; satisfies gosec G112).
		ReadHeaderTimeout: 5 * time.Second,
	}

	slog.Info("starting service", "addr", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
