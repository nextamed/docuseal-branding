# OKorn-branded DocuSeal overlay.
# Builds on upstream DocuSeal OSS and retains AGPLv3 attribution.
# Renovate keeps this base image tag fresh: see renovate.json.

ARG DOCUSEAL_VERSION=3.3.1
FROM docuseal/docuseal:${DOCUSEAL_VERSION}

# Versionsangaben fuer das Beweisprotokoll (jeder Eintrag nennt Overlay-Commit
# und Upstream-Version). CI setzt OKORN_OVERLAY_REVISION auf den Git-Commit.
ARG DOCUSEAL_VERSION
ARG OKORN_OVERLAY_REVISION=unknown
ENV OKORN_DOCUSEAL_VERSION=${DOCUSEAL_VERSION} \
    OKORN_OVERLAY_REVISION=${OKORN_OVERLAY_REVISION}

# Static assets (favicons + custom logo)
COPY overrides/public/ /app/public/

# Views (logo/headline overrides, Buttonloesung) and the evidence endpoint
COPY overrides/app/ /app/app/

# i18n override (`zz_` prefix loads after upstream i18n.yml), evidence
# initializer and modules (config/initializers, config/okorn)
COPY overrides/config/ /app/config/

LABEL org.opencontainers.image.source="https://github.com/nextamed/docuseal-branding"
LABEL org.opencontainers.image.description="OKorn-Immobilien-branded DocuSeal overlay (retains DocuSeal AGPLv3 attribution)"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.revision="${OKORN_OVERLAY_REVISION}"
