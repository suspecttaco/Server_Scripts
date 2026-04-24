# =============================================================================
# nginx/Dockerfile
# Imagen base: fedora:43
# PHP corre via php-fpm (FastCGI), igual que en el contenedor Apache
# =============================================================================

FROM fedora:43

LABEL maintainer="infra"
LABEL description="Nginx contenedor de produccion para infra_red"

ARG NGINX_USER=webuser
ARG NGINX_GROUP=webgroup

ENV NGINX_USER=${NGINX_USER}
ENV NGINX_GROUP=${NGINX_GROUP}

# -----------------------------------------------------------------------------
# Instalacion de paquetes
# -----------------------------------------------------------------------------
RUN dnf -y update && \
    dnf -y install \
        nginx \
        php-fpm \
        php-pgsql \
        iputils \
    && dnf clean all

# -----------------------------------------------------------------------------
# Usuario sin privilegios para Nginx
# -----------------------------------------------------------------------------
RUN groupadd -r ${NGINX_GROUP} && \
    useradd -r -g ${NGINX_GROUP} -s /sbin/nologin -d /usr/share/nginx/html ${NGINX_USER}

# -----------------------------------------------------------------------------
# Configuracion de Nginx
# server_tokens off esta definido en nginx.conf
# -----------------------------------------------------------------------------
COPY config/nginx.conf /etc/nginx/nginx.conf

# -----------------------------------------------------------------------------
# Configurar php-fpm para correr como el usuario sin privilegios
# clear_env = no: permite que PHP reciba las variables de entorno de Docker
# -----------------------------------------------------------------------------
RUN sed -i "s/^user = apache/user = ${NGINX_USER}/"    /etc/php-fpm.d/www.conf && \
    sed -i "s/^group = apache/group = ${NGINX_GROUP}/"  /etc/php-fpm.d/www.conf && \
    sed -i "s|^listen = .*|listen = /run/php-fpm/www.sock|" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.owner = .*/listen.owner = ${NGINX_USER}/"  /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.group = .*/listen.group = ${NGINX_GROUP}/" /etc/php-fpm.d/www.conf && \
    sed -i "s/^;listen.mode = .*/listen.mode = 0666/"  /etc/php-fpm.d/www.conf && \
    sed -i "s/^;clear_env = no/clear_env = no/"         /etc/php-fpm.d/www.conf

# Directorio para el socket de php-fpm
RUN mkdir -p /run/php-fpm && \
    chown ${NGINX_USER}:${NGINX_GROUP} /run/php-fpm

# -----------------------------------------------------------------------------
# Contenido web
# -----------------------------------------------------------------------------
COPY web/ /usr/share/nginx/html/
RUN chown -R ${NGINX_USER}:${NGINX_GROUP} /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html

# Logs a stdout/stderr
RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Script de arranque
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 80

CMD ["/usr/local/bin/start.sh"]