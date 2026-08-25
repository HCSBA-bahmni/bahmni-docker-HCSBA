#!/bin/sh
set -eu

work=/tmp/hcsba-dev-tls
rm -rf "$work"
mkdir -p "$work"

ca_needs_renewal=1
if [ -f /tls/local-dev-ca-key.pem ] && [ -f /tls/local-dev-ca-cert.pem ]; then
  cert_modulus="$(openssl x509 -in /tls/local-dev-ca-cert.pem -noout -modulus | openssl sha256)"
  key_modulus="$(openssl rsa -in /tls/local-dev-ca-key.pem -noout -modulus 2>/dev/null | openssl sha256)"
  if openssl x509 -checkend 604800 -noout -in /tls/local-dev-ca-cert.pem >/dev/null && \
     [ "$cert_modulus" = "$key_modulus" ]; then
    ca_needs_renewal=0
    cp /tls/local-dev-ca-key.pem /tls/local-dev-ca-cert.pem "$work/"
  fi
elif [ -f /tls/local-dev-ca-key.pem ] || [ -f /tls/local-dev-ca-cert.pem ]; then
  echo "El par de la CA local esta incompleto." >&2
  exit 1
fi

if [ "$ca_needs_renewal" -eq 1 ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 365 \
    -keyout "$work/local-dev-ca-key.pem" -out "$work/local-dev-ca-cert.pem" \
    -subj "/CN=HCSBA Local Development CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  cp "$work/local-dev-ca-key.pem" "$work/local-dev-ca-cert.pem" /tls/
fi

server_needs_renewal=1
if [ -f /tls/sso-dev-key.pem ] && [ -f /tls/sso-dev-cert.pem ]; then
  cert_modulus="$(openssl x509 -in /tls/sso-dev-cert.pem -noout -modulus | openssl sha256)"
  key_modulus="$(openssl rsa -in /tls/sso-dev-key.pem -noout -modulus 2>/dev/null | openssl sha256)"
  if openssl x509 -checkend 604800 -noout -in /tls/sso-dev-cert.pem >/dev/null && \
     openssl x509 -checkhost localhost -noout -in /tls/sso-dev-cert.pem >/dev/null && \
     openssl verify -CAfile "$work/local-dev-ca-cert.pem" /tls/sso-dev-cert.pem >/dev/null && \
     [ "$cert_modulus" = "$key_modulus" ]; then
    server_needs_renewal=0
  fi
elif [ -f /tls/sso-dev-key.pem ] || [ -f /tls/sso-dev-cert.pem ]; then
  echo "El par servidor TLS esta incompleto." >&2
  exit 1
fi

if [ "$server_needs_renewal" -eq 1 ]; then
  openssl req -new -newkey rsa:3072 -nodes -sha256 \
    -keyout "$work/sso-dev-key.pem" -out "$work/sso-dev.csr" \
    -subj "/CN=sso-dev.hcsba.local"
  openssl x509 -req -sha256 -days 30 \
    -in "$work/sso-dev.csr" \
    -CA "$work/local-dev-ca-cert.pem" -CAkey "$work/local-dev-ca-key.pem" \
    -CAcreateserial -CAserial "$work/local-dev-ca.srl" \
    -out "$work/sso-dev-cert.pem" -extfile /tls/dev-server-ext.cnf
  cp "$work/sso-dev-key.pem" "$work/sso-dev.csr" "$work/sso-dev-cert.pem" /tls/
fi
