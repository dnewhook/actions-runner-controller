FROM registry.fedoraproject.org/fedora:latest

ARG TARGETPLATFORM
ARG RUNNER_VERSION
ARG RUNNER_CONTAINER_HOOKS_VERSION
# Docker and Docker Compose arguments
ENV CHANNEL=stable
ARG DOCKER_COMPOSE_VERSION=v2.16.0
ARG DUMB_INIT_VERSION=1.2.5
# Use 1001 and 121 for compatibility with GitHub-hosted runners
ARG RUNNER_UID=1000
ARG DOCKER_GID=1001

# Other arguments
ARG DEBUG=false

RUN test -n "$TARGETPLATFORM" || (echo "TARGETPLATFORM must be set" && false)

# Don't include container-selinux and remove
# directories used by yum that are just taking
# up space.
RUN dnf -y update; yum -y reinstall shadow-utils; \
    dnf -y install procps-ng crun podman podman-docker buildah netavark iptables-nft fuse-overlayfs /etc/containers/storage.conf \
    git jq libicu sudo unzip zip --exclude container-selinux; \
    dnf clean all; \
    rm -rf /var/cache /var/log/dnf* /var/log/yum.*; \
    ln -s /usr/bin/pip3 /usr/bin/pip

# Runner user
RUN groupadd docker --gid $DOCKER_GID; \
    groupadd runner --gid $RUNNER_UID
RUN useradd --uid $RUNNER_UID -g runner -G docker runner
RUN echo -e "runner:1:999\nrunner:1001:64535" > /etc/subuid; \
    echo -e "runner:1:999\nrunner:1001:64535" > /etc/subgid

ENV HOME=/home/runner

RUN export ARCH=$(echo ${TARGETPLATFORM} | cut -d / -f2) \
    && if [ "$ARCH" = "arm64" ]; then export ARCH=aarch64 ; fi \
    && if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "i386" ]; then export ARCH=x86_64 ; fi \
    && curl -fLo /usr/bin/dumb-init https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_${ARCH} \
    && chmod +x /usr/bin/dumb-init

ENV RUNNER_ASSETS_DIR=/runnertmp
RUN export ARCH=$(echo ${TARGETPLATFORM} | cut -d / -f2) \
    && if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "i386" ]; then export ARCH=x64 ; fi \
    && mkdir -p "$RUNNER_ASSETS_DIR" \
    && cd "$RUNNER_ASSETS_DIR" \
    && curl -fLo runner.tar.gz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./runner.tar.gz \
    && rm runner.tar.gz \
    && mv ./externals ./externalstmp

ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
RUN mkdir /opt/hostedtoolcache \
    && chgrp runner /opt/hostedtoolcache \
    && chmod g+rwx /opt/hostedtoolcache

RUN cd "$RUNNER_ASSETS_DIR" \
    && curl -fLo runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip \
    && unzip ./runner-container-hooks.zip -d ./k8s \
    && rm -f runner-container-hooks.zip

# Make the runner directory executable
RUN mkdir -p /run/podman
RUN chmod 755 /run/podman \
    && chown runner:runner /run/podman \
    && chmod g+s /run/podman \
    && chmod a+x /run/podman

VOLUME /var/lib/containers
RUN mkdir -p /home/runner/.local/share/containers; \
    mkdir -p /root/.config/containers; \
    mkdir -p /home/runner/.docker; \
    mkdir /github; \
    touch /etc/containers/nodocker; \
    ln -s /home/runner /github/home

#https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/containers.conf
ADD containers-rootful.conf /etc/containers/containers.conf
#https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/containers.conf
#ADD podman-containers.conf /root/.config/containers/containers.conf
#ADD registries.conf /root/.config/containers/registries.conf
ADD sudoers_pink /etc/sudoers.d/runner
ADD docker-config.json "$RUNNER_ASSETS_DIR"/.docker/config.json
RUN chown -R runner:runner /home/runner; \
    ln -s /run/podman/podman.sock /var/run/docker.sock; \
    ln -s /runner/.docker/config.json /home/runner/.docker/config.json
VOLUME /home/runner/.local/share/containers

RUN cp /usr/share/containers/storage.conf /etc/containers/storage.conf
#RUN cp /usr/share/containers/containers.conf /etc/containers/containers.conf
# chmod containers.conf and adjust storage.conf to enable Fuse storage.
RUN chmod 644 /etc/containers/containers.conf; sed -i -e 's|^#mount_program|mount_program|g' -e '/additionalimage.*/a "/var/lib/shared",' -e 's|^mountopt[[:space:]]*=.*$|mountopt = "nodev,fsync=0"|g' /etc/containers/storage.conf
#RUN chmod 644 /etc/containers/containers.conf; sed -i -e 's|^mount_program|#mount_program|g' -e '/additionalimage.*/a "/var/lib/shared",' -e 's|^mountopt|#mountopt|g' /etc/containers/storage.conf

RUN mkdir -p /var/lib/shared/overlay-images \
             /var/lib/shared/overlay-layers \
             /var/lib/shared/vfs-images \
             /var/lib/shared/vfs-layers && \
    touch /var/lib/shared/overlay-images/images.lock && \
    touch /var/lib/shared/overlay-layers/layers.lock && \
    touch /var/lib/shared/vfs-images/images.lock && \
    touch /var/lib/shared/vfs-layers/layers.lock

# Add the Python "User Script Directory" to the PATH
ENV PATH="${PATH}:${HOME}/.local/bin:/home/runner/bin"
ENV ImageOS=ubi9
ENV LANG=en_US.UTF-8
ENV CONTAINER_HOST=unix:///run/podman/podman.sock
ENV _CONTAINERS_USERNS_CONFIGURED=""
ENV _BUILDAH_STARTED_IN_USERNS=""
ENV BUILDAH_ISOLATION=chroot

RUN echo "PATH=${PATH}" > /etc/environment \
    && echo "ImageOS=${ImageOS}" >> /etc/environment \
    && echo "LANG=${LANG}" >> /etc/environment \
    && echo "_CONTAINERS_USERNS_CONFIGURED=${_CONTAINERS_USERNS_CONFIGURED}" >> /etc/environment \
    && echo "_BUILDAH_STARTED_IN_USERNS=${_BUILDAH_STARTED_IN_USERNS}" >> /etc/environment \
    && echo "BUILDAH_ISOLATION=${BUILDAH_ISOLATION}" >> /etc/environment

# We place the scripts in `/usr/bin` so that users who extend this image can
# override them with scripts of the same name placed in `/usr/local/bin`.
COPY entrypoint-pink-rootful.sh startup.sh logger.sh wait.sh graceful-stop.sh update-status /usr/bin/

# Configure hooks folder structure.
COPY hooks /etc/arc/hooks/

# No group definition, as that makes it harder to run docker.
USER runner


ENTRYPOINT ["/bin/bash", "-c"]
CMD ["entrypoint-pink-rootful.sh"]
