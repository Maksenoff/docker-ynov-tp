# syntax=docker/dockerfile:1

FROM php:8.3.12-apache-bookworm AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# pdo_mysql + opcache, msmtp pour mail(), supercronic pour le rapport quotidien
ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.33
# image de base epinglee, les paquets debian suivent les maj de securite de bookworm
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends msmtp \
 && rm -rf /var/lib/apt/lists/* \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql opcache \
 && case "$TARGETARCH" in \
      amd64) sha=71b0d58cc53f6bd72cf2f293e09e294b79c666d8 ;; \
      arm64) sha=e0f0c06ebc5627e43b25475711e694450489ab00 ;; \
      *) echo "archi non supportee : $TARGETARCH"; exit 1 ;; \
    esac \
 && curl -fsSLo /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
 && echo "${sha}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic

# apache sur 8080 (pas besoin de root pour ecouter), vhost geststock a la place du defaut
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf \
 && a2dissite 000-default \
 && a2disconf other-vhosts-access-log \
 && mkdir -p /var/www/uploads \
 && chown -R www-data:www-data /var/www/uploads /var/run/apache2 /var/lock/apache2 \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY docker/apache/geststock.conf /etc/apache2/sites-enabled/geststock.conf
COPY docker/php/geststock.ini "$PHP_INI_DIR/conf.d/zz-geststock.ini"
COPY docker/crontab /etc/geststock/crontab

ENV TZ=Europe/Paris \
    UPLOAD_DIR=/var/www/uploads \
    SMTP_HOST=localhost \
    SMTP_PORT=25 \
    SMTP_TLS=off \
    MAIL_FROM=geststock@shop.example

WORKDIR /var/www/geststock

# verification de syntaxe de tout le code avec le php de l'image
FROM base AS test
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY geststock/ ./
RUN find . -name '*.php' -print0 | xargs -0 -n1 php -l \
 && php -r 'require "lib/config.php"; exit(DB_HOST === "db" && LOG_FILE === "php://stderr" ? 0 : 1);'

FROM base AS runtime
ARG VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="geststock" \
      org.opencontainers.image.description="GestStock, inventaire (ex serveur legacy PHP 7.3)" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/Maksenoff/docker-ynov-tp"
# code en lecture seule pour www-data (appartient a root)
COPY geststock/ ./
# depuis le stage test pour obliger buildkit a le lancer
COPY --from=test /var/www/geststock/sql/schema.sql ./sql/schema.sql
USER www-data
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["php", "-r", "exit(@file_get_contents('http://127.0.0.1:8080/?health') === 'OK' ? 0 : 1);"]
# STOPSIGNAL SIGWINCH herite de l'image php apache : arret gracieux d'apache
CMD ["apache2-foreground"]
