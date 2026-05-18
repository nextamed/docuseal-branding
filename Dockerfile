# OKorn-branded DocuSeal overlay.
# Builds on upstream DocuSeal OSS and retains AGPLv3 attribution.
# Renovate keeps this base image tag fresh: see renovate.json.

ARG DOCUSEAL_VERSION=latest
FROM docuseal/docuseal:${DOCUSEAL_VERSION}

# Static assets (favicons + custom logo)
COPY overrides/public/ /app/public/

# View partials: logo + headline overrides
COPY overrides/app/views/ /app/app/views/

# i18n override: `zz_` prefix guarantees alphabetical load after upstream i18n.yml
COPY overrides/config/locales/ /app/config/locales/

LABEL org.opencontainers.image.source="https://github.com/nextamed/docuseal-branding"
LABEL org.opencontainers.image.description="OKorn-Immobilien-branded DocuSeal overlay (retains DocuSeal AGPLv3 attribution)"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
