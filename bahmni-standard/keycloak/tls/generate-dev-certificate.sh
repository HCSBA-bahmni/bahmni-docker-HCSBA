#!/bin/sh
set -eu

work=/tmp/hcsba-dev-tls
rm -rf "$work"
mkdir -p "$work"

if [ -f /tls/local-dev-ca-key.pem ] && [ -f /tls/local-dev-ca-cert.pem ]; then
  cp /tls/local-dev-ca-key.pem /tls/local-dev-ca-cert.pem "$work/"
else
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 365 \
    -keyout "$work/local-dev-ca-key.pem" -out "$work/local-dev-ca-cert.pem" \
    -subj "/CN=HCSBA Local Development CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  cp "$work/local-dev-ca-key.pem" "$work/local-dev-ca-cert.pem" /tls/
fi

if [ ! -f /tls/sso-dev-key.pem ] || [ ! -f /tls/sso-dev-cert.pem ]; then
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
