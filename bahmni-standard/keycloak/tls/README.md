# TLS de Keycloak

Esta carpeta recibe `sso-dev-cert.pem` y `sso-dev-key.pem`, emitidos por la CA
interna para `sso-dev.hcsba.local`. Los archivos PEM, claves y CSR están
ignorados por Git. `sso.ps1 csr` genera la clave privada y el CSR sin
sobrescribir material existente.
