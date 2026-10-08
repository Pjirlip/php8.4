FROM php:8.4-apache
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

# System- und Umgebungsvariablen
ENV PROVISION_CONTEXT="production" \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Berlin \
    APACHE_LOCK_DIR=/var/lock/apache2 \
    APACHE_LOG_DIR=/var/log/apache2 \
    APACHE_PID_FILE=/var/run/apache2/apache2.pid \
    APACHE_SERVER_NAME=localhost \
    APACHE_RUN_USER=propeller \
    APACHE_RUN_GROUP=propeller \
    APACHE_RUN_DIR=/var/run/apache2 \
    DOCUMENT_ROOT=/var/www/html \
    LETSENCRYPT_EMAIL=certbot@propeller.de \
    PORT=80 \
    SMTP_SERVER=example.com \
    SMTP_PORT=25 \
    SMTP_FROM=mail@example.com \
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXEC_TIME=240 \
    PHP_POST_AND_UPLOAD_MAX_SIZE=50M \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en

# Apache-Laufzeit-Tuning (K1, K2, H4). Ein leeres APACHE_MAX_REQUEST_WORKERS lässt entrypoint.sh den Wert
# aus dem Memory-Limit des Containers ableiten: floor((limit_MiB - BASELINE_MB) / CHILD_MB)
ENV APACHE_MAX_REQUEST_WORKERS="" \
    APACHE_CHILD_MEMORY_MB=100 \
    APACHE_BASELINE_MEMORY_MB=256 \
    APACHE_MIN_SPARE_SERVERS=2 \
    APACHE_MAX_SPARE_SERVERS=4 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=1000 \
    APACHE_TIMEOUT=120 \
    APACHE_ALLOW_OVERRIDE=All

# PHP-Laufzeit-Tuning (K2, H4)
ENV PHP_OPCACHE_MEMORY=192 \
    PHP_OPCACHE_MAX_FILES=50000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=60 \
    PHP_MYSQLND_NET_READ_TIMEOUT=300

# Benutzer erstellen
RUN addgroup --gid 1000 propeller && \
    useradd --system -u 1000 -g propeller propeller

#Composer Installation
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Konfigurationsdateien kopieren
COPY ./config/php.ini /usr/local/etc/php/conf.d/zz-propeller.ini
COPY ./config/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY ./config/apache2.conf /etc/apache2/apache2.conf
COPY ./config/mpm_prefork.conf /etc/apache2/mods-available/mpm_prefork.conf
COPY ./config/locale.gen /etc/locale.gen
COPY ./scripts/*.sh /usr/local/bin/

# Hauptinstallation und Konfiguration
RUN chmod +x /usr/local/bin/*.sh && \
    mkdir -p /home/propeller/.composer/cache && \
    chown -R propeller:propeller /home/propeller/ && \
    chmod -R 0750 /home/propeller/ && \
    apt-get update && \
    apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    locales \
    libxml2-dev \
    libfreetype6-dev \
    libcurl3-openssl-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    zlib1g-dev \
    libicu-dev \
    libzip-dev \
    libxslt-dev \
    libonig-dev \
    libldap2-dev \
    wget \
    git \
    msmtp \
    sudo \
    ssh-client \
    vim \
    gpg \
    gcc \
    g++ \
    apt-transport-https \
    libgraphicsmagick1-dev \
    graphicsmagick \
    ghostscript \
    lsb-release \
    mailutils && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-install -j$(nproc) pdo_mysql sysvmsg sysvsem mysqli exif soap gd zip opcache intl curl bcmath sockets xsl ldap && \
    a2enmod rewrite deflate headers mime expires filter setenvif env authz_core auth_basic alias remoteip && \
    pecl install redis && \
    docker-php-ext-enable redis && \
    locale-gen && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    # Logs gehen direkt auf die Container-Streams (siehe apache2.conf); der Debian-Default würde jeden
    # Request ein zweites Mal nach other_vhosts_access.log schreiben (H5)
    rm -f /etc/apache2/conf-enabled/other-vhosts-access-log.conf && \
    # Statischer Health-Endpoint für Kubernetes-Probes (H3) und Drop-in-Verzeichnis für Site-Regeln (K2)
    mkdir -p /opt/propeller/healthz /etc/apache2/site.d && \
    echo ok > /opt/propeller/healthz/index.html && \
    mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    (ssh-keyscan -T 5 -H gitlab.propeller.de atum.propeller.de >> /etc/ssh/ssh_known_hosts || true) && \
    apt-get clean && \
    apt-get -y purge \
    libxml2-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    zlib1g-dev && \
    rm -rf /var/lib/apt/lists/* /usr/src/* /tmp/pear

# Komplette Konfiguration zur Build-Zeit prüfen, ohne einen Daemon zu starten (H6)
RUN APACHE_MAX_REQUEST_WORKERS=8 apache2ctl -t

EXPOSE $PORT

ENTRYPOINT ["entrypoint.sh"]
