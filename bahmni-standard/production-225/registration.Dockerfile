# Restore the verified HCSBA EIS UI config, preserving every other file in the deployed image.
# Build context: standard-config-HCSBA (sibling repository).
FROM hcsba/standard-config:2026.10.16-config.1
COPY openmrs/apps/registration/app.json /etc/bahmni_config/openmrs/apps/registration/app.json
COPY openmrs/i18n/registration/locale_es.json /etc/bahmni_config/openmrs/i18n/registration/locale_es.json
