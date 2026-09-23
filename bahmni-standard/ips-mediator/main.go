package main

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"strings"
	"time"
)

const maxRequestBytes = 16 << 20

type config struct {
	listenAddress     string
	publicOrigin      string
	upstream          *url.URL
	username          string
	password          string
	sessionURL        string
	requiredPrivilege string
	tlsSkipVerify     bool
}

type gateway struct {
	config        config
	client        *http.Client
	upstreamProxy *httputil.ReverseProxy
}

type sessionResponse struct {
	Authenticated bool `json:"authenticated"`
	User          struct {
		Privileges []struct {
			Name string `json:"name"`
		} `json:"privileges"`
	} `json:"user"`
}

func required(name string) (string, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}

func secret(name string) (string, error) {
	path, err := required(name + "_FILE")
	if err != nil {
		return "", err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", name, err)
	}
	value := strings.TrimSpace(string(content))
	if value == "" {
		return "", fmt.Errorf("%s is empty", name)
	}
	return value, nil
}

func loadConfig() (config, error) {
	origin, err := required("PUBLIC_ORIGIN")
	if err != nil {
		return config{}, err
	}
	parsedOrigin, err := url.Parse(origin)
	if err != nil || parsedOrigin.Scheme != "https" || parsedOrigin.Host == "" || parsedOrigin.Path != "" {
		return config{}, errors.New("PUBLIC_ORIGIN must be an HTTPS origin without a path")
	}
	upstreamValue, err := required("IPS_UPSTREAM_BASE")
	if err != nil {
		return config{}, err
	}
	upstream, err := url.Parse(upstreamValue)
	if err != nil || upstream.Host == "" || (upstream.Scheme != "https" && upstream.Scheme != "http") {
		return config{}, errors.New("IPS_UPSTREAM_BASE must be an HTTP(S) origin")
	}
	if strings.Trim(upstream.Path, "/") != "" {
		return config{}, errors.New("IPS_UPSTREAM_BASE must not contain a path")
	}
	username, err := secret("IPS_UPSTREAM_USERNAME")
	if err != nil {
		return config{}, err
	}
	password, err := secret("IPS_UPSTREAM_PASSWORD")
	if err != nil {
		return config{}, err
	}
	sessionURL, err := required("OPENMRS_SESSION_URL")
	if err != nil {
		return config{}, err
	}
	if parsed, parseErr := url.Parse(sessionURL); parseErr != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return config{}, errors.New("OPENMRS_SESSION_URL must be an absolute HTTP(S) URL")
	}
	return config{
		listenAddress: strings.TrimSpace(os.Getenv("LISTEN_ADDRESS")), publicOrigin: strings.TrimSuffix(origin, "/"),
		upstream: upstream, username: username, password: password, sessionURL: sessionURL,
		requiredPrivilege: strings.TrimSpace(os.Getenv("OPENMRS_REQUIRED_PRIVILEGE")),
		tlsSkipVerify:     strings.EqualFold(strings.TrimSpace(os.Getenv("UPSTREAM_TLS_SKIP_VERIFY")), "true"),
	}, nil
}

func allowed(path, method string) bool {
	if strings.HasPrefix(path, "/openmrs/ips-mediator/regional/") || path == "/openmrs/ips-mediator/regional" {
		return method == http.MethodGet || method == http.MethodHead
	}
	if path == "/openmrs/ips-mediator/vhl/_generate" || path == "/openmrs/ips-mediator/vhl/_resolve" || path == "/openmrs/ips-mediator/icvpcert/_from-bundle" {
		return method == http.MethodPost
	}
	return false
}

func hasPrivilege(session sessionResponse, requiredPrivilege string) bool {
	if requiredPrivilege == "" {
		return true
	}
	for _, privilege := range session.User.Privileges {
		if privilege.Name == requiredPrivilege {
			return true
		}
	}
	return false
}

func (g *gateway) authorized(request *http.Request) (bool, error) {
	cookie, err := request.Cookie("JSESSIONID")
	if err != nil || strings.TrimSpace(cookie.Value) == "" {
		return false, nil
	}
	check, err := http.NewRequestWithContext(request.Context(), http.MethodGet, g.config.sessionURL, nil)
	if err != nil {
		return false, err
	}
	check.Header.Set("Accept", "application/json")
	check.AddCookie(&http.Cookie{Name: "JSESSIONID", Value: cookie.Value})
	response, err := g.client.Do(check)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false, nil
	}
	var session sessionResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&session); err != nil {
		return false, err
	}
	return session.Authenticated && hasPrivilege(session, g.config.requiredPrivilege), nil
}

func (g *gateway) serveHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	if request.URL.Path == "/health" {
		if request.Method != http.MethodGet {
			http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte(`{"status":"UP"}`))
		return
	}
	if !allowed(request.URL.Path, request.Method) {
		http.NotFound(writer, request)
		return
	}
	if path.Clean(request.URL.Path) != request.URL.Path || strings.Contains(strings.ToLower(request.URL.EscapedPath()), "%2e") {
		http.NotFound(writer, request)
		return
	}
	if request.Method == http.MethodPost {
		origin := strings.TrimSuffix(request.Header.Get("Origin"), "/")
		if origin != g.config.publicOrigin || strings.EqualFold(request.Header.Get("Sec-Fetch-Site"), "cross-site") {
			http.Error(writer, "forbidden origin", http.StatusForbidden)
			return
		}
	}
	ok, err := g.authorized(request)
	if err != nil {
		http.Error(writer, "identity service unavailable", http.StatusBadGateway)
		return
	}
	if !ok {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, maxRequestBytes)
	g.upstreamProxy.ServeHTTP(writer, request)
}

func newGateway(configuration config) *gateway {
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: configuration.tlsSkipVerify}}
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second}
	proxy := httputil.NewSingleHostReverseProxy(configuration.upstream)
	originalDirector := proxy.Director
	proxy.Director = func(request *http.Request) {
		originalDirector(request)
		request.URL.Path = strings.TrimPrefix(request.URL.Path, "/openmrs/ips-mediator")
		request.Host = configuration.upstream.Host
		request.Header.Del("Cookie")
		request.Header.Del("Authorization")
		request.Header.Del("Origin")
		request.Header.Del("Referer")
		request.Header.Del("X-Forwarded-For")
		request.SetBasicAuth(configuration.username, configuration.password)
	}
	proxy.ModifyResponse = func(response *http.Response) error {
		response.Header.Del("Set-Cookie")
		response.Header.Set("Cache-Control", "no-store")
		return nil
	}
	proxy.ErrorLog = log.New(io.Discard, "", 0)
	proxy.ErrorHandler = func(writer http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(writer, "IPS upstream unavailable", http.StatusBadGateway)
	}
	return &gateway{config: configuration, client: client, upstreamProxy: proxy}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		response, err := (&http.Client{Timeout: 2 * time.Second}).Get("http://127.0.0.1:8080/health")
		if err != nil || response.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		_ = response.Body.Close()
		return
	}
	configuration, err := loadConfig()
	if err != nil {
		log.Fatal("invalid IPS mediator configuration")
	}
	if configuration.listenAddress == "" {
		configuration.listenAddress = ":8080"
	}
	server := &http.Server{Addr: configuration.listenAddress, Handler: http.HandlerFunc(newGateway(configuration).serveHTTP), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 130 * time.Second, IdleTimeout: 60 * time.Second}
	log.Printf("IPS mediator listening on %s", configuration.listenAddress)
	log.Fatal(server.ListenAndServe())
}
