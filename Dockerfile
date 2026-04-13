FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Install Dropbox daemon
RUN curl -fsSL "https://www.dropbox.com/download?plat=lnx.x86_64" -o /tmp/dropbox.tgz \
    && tar -xzf /tmp/dropbox.tgz -C /root \
    && rm /tmp/dropbox.tgz

# Install Dropbox CLI helper
RUN curl -fsSL "https://www.dropbox.com/download?dl=packages/dropbox.py" -o /usr/local/bin/dropbox \
    && chmod +x /usr/local/bin/dropbox

RUN mkdir -p /root/.dropbox /root/Dropbox

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/root/.dropbox", "/root/Dropbox"]

ENV SYNC_FOLDERS=""
ENV PREFIX_PATH="/"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
