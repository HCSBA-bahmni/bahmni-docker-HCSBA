package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func testGateway(t *testing.T, privilege bool) (*gateway, *httptest.Server) {
	t.Helper()
	identity := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if !strings.Contains(request.Header.Get("Cookie"), "JSESSIONID=synthetic") {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		privileges := []map[string]string{}
		if privilege {
			privileges = append(privileges, map[string]string{"name": "app:clinical"})
		}
		_ = json.NewEncoder(writer).Encode(map[string]any{"authenticated": true, "user": map[string]any{"privileges": privileges}})
	}))
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		username, password, ok := request.BasicAuth()
		if !ok || username != "technical" || password != "secret" {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		if request.Header.Get("Cookie") != "" {
			t.Error("clinical cookie was forwarded upstream")
		}
		_ = json.NewEncoder(writer).Encode(map[string]string{"path": request.URL.Path})
	}))
	parsed, _ := url.Parse(upstream.URL)
	gateway := newGateway(config{publicOrigin: "https://localhost", upstream: parsed, username: "technical", password: "secret", sessionURL: identity.URL, requiredPrivilege: "app:clinical"})
	t.Cleanup(identity.Close)
	return gateway, upstream
}

func TestGatewayAllowsOnlyAuthenticatedClinicalContract(t *testing.T) {
	gateway, upstream := testGateway(t, true)
	defer upstream.Close()
	request := httptest.NewRequest(http.MethodGet, "/openmrs/ips-mediator/regional/DocumentReference?patient.identifier=SYN", nil)
	request.Header.Set("Cookie", "JSESSIONID=synthetic")
	response := httptest.NewRecorder()
	gateway.serveHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.Code)
	}
	if !strings.Contains(response.Body.String(), `"path":"/regional/DocumentReference"`) {
		t.Fatalf("unexpected body: %s", response.Body.String())
	}
}

func TestGatewayRejectsMissingPrivilegeAndUnknownRoutes(t *testing.T) {
	gateway, upstream := testGateway(t, false)
	defer upstream.Close()
	request := httptest.NewRequest(http.MethodGet, "/openmrs/ips-mediator/regional/DocumentReference", nil)
	request.Header.Set("Cookie", "JSESSIONID=synthetic")
	response := httptest.NewRecorder()
	gateway.serveHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.Code)
	}
	unknown := httptest.NewRequest(http.MethodGet, "/openmrs/ips-mediator/admin", nil)
	unknownResponse := httptest.NewRecorder()
	gateway.serveHTTP(unknownResponse, unknown)
	if unknownResponse.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", unknownResponse.Code)
	}
}

func TestGatewayRequiresSameOriginForClinicalWrites(t *testing.T) {
	gateway, upstream := testGateway(t, true)
	defer upstream.Close()
	request := httptest.NewRequest(http.MethodPost, "/openmrs/ips-mediator/vhl/_generate", strings.NewReader(`{}`))
	request.Header.Set("Cookie", "JSESSIONID=synthetic")
	request.Header.Set("Origin", "https://example.invalid")
	response := httptest.NewRecorder()
	gateway.serveHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", response.Code)
	}
}
