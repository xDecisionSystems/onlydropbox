FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DROPBOX_HOME=/home/dropbox
ENV PATH=/home/dropbox/.local/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        tar \
        python3 \
        python3-gpg \
        procps \
        libatomic1 \
        libglib2.0-0 \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# Create runtime user (Dropbox should not run as root)
RUN useradd -m -d "${DROPBOX_HOME}" -s /bin/bash dropbox \
    && mkdir -p "${DROPBOX_HOME}/.local/bin" "${DROPBOX_HOME}/Dropbox" "${DROPBOX_HOME}/.config/codedrop" \
    && chown -R dropbox:dropbox "${DROPBOX_HOME}"

# Install Dropbox daemon into user home
RUN curl -fsSL "https://www.dropbox.com/download?plat=lnx.x86_64" -o /tmp/dropbox.tgz \
    && tar -xzf /tmp/dropbox.tgz -C "${DROPBOX_HOME}" \
    && rm /tmp/dropbox.tgz \
    && chown -R dropbox:dropbox "${DROPBOX_HOME}/.dropbox-dist"

# Install Dropbox CLI helper into user-local bin
RUN curl -fsSL "https://www.dropbox.com/download?dl=packages/dropbox.py" -o "${DROPBOX_HOME}/.local/bin/dropbox" \
    && chmod +x "${DROPBOX_HOME}/.local/bin/dropbox" \
    && chown dropbox:dropbox "${DROPBOX_HOME}/.local/bin/dropbox"

# Install code-server system-wide (like LXC root flow)
RUN sh -c 'curl -fsSL https://code-server.dev/install.sh | sh'

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/home/dropbox/.dropbox", "/home/dropbox/Dropbox", "/home/dropbox/.config/codedrop"]

ENV SYNC_FOLDERS=""
ENV ACCOUNT_ROOT=""
ENV ACCOUNT_NAME=""

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
