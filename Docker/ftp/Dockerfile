# =============================================================================
# ftp/Dockerfile
# Imagen base: fedora:43
# Autenticacion via /etc/shadow con PAM password-auth
# =============================================================================

FROM fedora:43

LABEL maintainer="infra"
LABEL description="vsftpd contenedor de produccion para infra_red"

RUN dnf -y update && \
    dnf -y install \
        vsftpd \
        iputils \
    && dnf clean all

# -----------------------------------------------------------------------------
# Configuracion de vsftpd
# -----------------------------------------------------------------------------
RUN echo 'listen=YES' > /etc/vsftpd/vsftpd.conf && \
    echo 'listen_ipv6=NO' >> /etc/vsftpd/vsftpd.conf && \
    echo 'background=NO' >> /etc/vsftpd/vsftpd.conf && \
    echo 'anonymous_enable=NO' >> /etc/vsftpd/vsftpd.conf && \
    echo 'local_enable=YES' >> /etc/vsftpd/vsftpd.conf && \
    echo 'write_enable=YES' >> /etc/vsftpd/vsftpd.conf && \
    echo 'local_umask=022' >> /etc/vsftpd/vsftpd.conf && \
    echo 'chroot_local_user=YES' >> /etc/vsftpd/vsftpd.conf && \
    echo 'allow_writeable_chroot=YES' >> /etc/vsftpd/vsftpd.conf && \
    echo 'pam_service_name=vsftpd' >> /etc/vsftpd/vsftpd.conf && \
    echo 'pasv_enable=YES' >> /etc/vsftpd/vsftpd.conf && \
    echo 'pasv_min_port=30000' >> /etc/vsftpd/vsftpd.conf && \
    echo 'pasv_max_port=30010' >> /etc/vsftpd/vsftpd.conf && \
    echo 'ftpd_banner=FTP Server' >> /etc/vsftpd/vsftpd.conf && \
    echo 'idle_session_timeout=300' >> /etc/vsftpd/vsftpd.conf && \
    echo 'data_connection_timeout=120' >> /etc/vsftpd/vsftpd.conf && \
    echo 'xferlog_enable=YES' >> /etc/vsftpd/vsftpd.conf

RUN mkdir -p /var/ftp/uploads

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r//' /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 21
EXPOSE 30000-30010

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]