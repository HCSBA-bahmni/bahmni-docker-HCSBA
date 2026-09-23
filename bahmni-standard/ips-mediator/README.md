# IPS/ICVP same-origin mediator

This gateway replaces the legacy browser-to-upstream contract. It publishes
only `/openmrs/ips-mediator/regional`, the two VHL operations and ICVP
generation. The `/openmrs` prefix is intentional: it lets the browser apply
the OpenMRS-scoped `JSESSIONID` without exposing or duplicating it.
Every request is validated against the current OpenMRS `JSESSIONID`; the
configured clinical privilege is required and upstream Basic credentials are
read from Docker secrets.

## Enable in development

1. Copy the IPS variables from `../.env.ips.example` to the untracked `.env`.
2. Create the two secret files under `ips-mediator/secrets/` (or another
   ignored absolute path) and restrict their filesystem permissions.
3. Set `IPS_MEDIATOR_ENABLED=true` and use `../../dev-environment.ps1 up`.
4. Use `../../dev-environment.ps1 verify`; it checks the mediator health when
   the switch is enabled.

The switch is off by default. Disabling it and recreating the development
stack removes the mediator and returns both dashboard controls to their
explicit protected/disabled state.

The local HC1 decoder is a preview only. It does not validate the COSE
signature; authoritative resolution remains an upstream operation.
