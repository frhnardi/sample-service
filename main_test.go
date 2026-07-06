package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRouter(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		target     string
		wantStatus int
		wantBody   map[string]string // nil = do not assert on the body
	}{
		{
			name:       "healthz reports ok",
			method:     http.MethodGet,
			target:     "/healthz",
			wantStatus: http.StatusOK,
			wantBody:   map[string]string{"status": "ok"},
		},
		{
			name:       "hello without a name greets the world",
			method:     http.MethodGet,
			target:     "/hello",
			wantStatus: http.StatusOK,
			wantBody:   map[string]string{"message": "hello, world"},
		},
		{
			name:       "hello with a name greets that name",
			method:     http.MethodGet,
			target:     "/hello?name=dhoclo",
			wantStatus: http.StatusOK,
			wantBody:   map[string]string{"message": "hello, dhoclo"},
		},
		{
			name:       "an unknown path is 404",
			method:     http.MethodGet,
			target:     "/does-not-exist",
			wantStatus: http.StatusNotFound,
		},
		{
			name:       "the wrong method on a known path is 405",
			method:     http.MethodPost,
			target:     "/hello",
			wantStatus: http.StatusMethodNotAllowed,
		},
	}

	router := newRouter()

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, tt.target, nil)
			rec := httptest.NewRecorder()

			router.ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}

			if tt.wantBody == nil {
				return
			}

			var got map[string]string
			if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
				t.Fatalf("decoding response body: %v", err)
			}
			for key, want := range tt.wantBody {
				if got[key] != want {
					t.Errorf("body[%q] = %q, want %q", key, got[key], want)
				}
			}
		})
	}
}
