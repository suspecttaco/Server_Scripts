# =============================================================================
# apache/Dockerfile
# Imagen base: fedora:43
# PHP corre via php-fpm (FastCGI), no como modulo de Apache
# =============================================================================

FROM fedora:43

LABEL maintainer="infra"
LABEL description="Apache HTTP Server contenedor de produccion para infra_red"

ARG APACHE_USER=webuser
ARG APACHE_GROUP=webgroup

ENV APACHE_USER=${APACHE_USER}
ENV APACHE_GROUP=${APACHE_GROUP}

# -----------------------------------------------------------------------------
# Instalacion de paquetes
# php-fpm: PHP via FastCGI (forma nativa en Fedora)
# php-pgsql: extension para conectar a PostgreSQL
# -----------------------------------------------------------------------------
RUN dnf -y update && \
    dnf -y install \
        httpd \
        php-fpm \
        php-pgsql \
        iputils \
    && dnf clean all

# -----------------------------------------------------------------------------
# Usuario sin privilegios para Apache
# -----------------------------------------------------------------------------
RUN groupadd -r ${APACHE_GROUP} && \
    useradd -r -g ${APACHE_GROUP} -s /sbin/nologin -d /var/www/html ${APACHE_USER}

# -----------------------------------------------------------------------------
# Configuracion de Apache
# -----------------------------------------------------------------------------
COPY config/httpd.conf     /etc/httpd/conf/httpd.conf
COPY config/security.conf  /etc/httpd/conf.d/security.conf
COPY config/php-fpm.conf   /etc/httpd/conf.d/php-fpm.conf

# -----------------------------------------------------------------------------
# Configurar php-fpm para correr como el usuario sin privilegios
# y usar socket Unix en lugar de TCP
# -----------------------------------------------------------------------------
RUN sed -i "s/^user = apache/user = ${APACHE_USER}/"   /etc/php-fpm.d/www.conf && \
    sed -i "s/^group = apache/group = ${APACHE_GROUP}/" /etc/php-fpm.d/www.conf && \
    sed -i "s|^listen = .*|listen = /run/php-fpm/www.sock|" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.owner = .*/listen.owner = ${APACHE_USER}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.group = .*/listen.group = ${APACHE_GROUP}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.mode = .*/listen.mode = 0666/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;clear_env = no/clear_env = no/" /etc/php-fpm.d/www.conf

# Crear directorio para el socket de php-fpm
RUN mkdir -p /run/php-fpm && \
    chown ${APACHE_USER}:${APACHE_GROUP} /run/php-fpm

# -----------------------------------------------------------------------------
# Contenido web
# -----------------------------------------------------------------------------
COPY web/ /var/www/html/
RUN chown -R ${APACHE_USER}:${APACHE_GROUP} /var/www/html && \
    chmod -R 755 /var/www/html

# Logs a stdout/stderr
RUN ln -sf /dev/stdout /var/log/httpd/access_log && \
    ln -sf /dev/stderr /var/log/httpd/error_log

# Script de arranque
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 80

CMD ["/usr/local/bin/start.sh"]