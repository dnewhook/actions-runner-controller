FROM registry.access.redhat.com/ubi9:latest

ARG TARGETPLATFORM
ARG RUNNER_VERSION
ARG RUNNER_CONTAINER_HOOKS_VERSION
# Docker and Docker Compose arguments
ENV CHANNEL=stable
ARG DOCKER_COMPOSE_VERSION=v2.16.0
ARG DUMB_INIT_VERSION=1.2.5
ARG RUNNER_USER_UID=1001

# Other arguments
ARG DEBUG=false

RUN test -n "$TARGETPLATFORM" || (echo "TARGETPLATFORM must be set" && false)

RUN dnf --disableplugin=subscription-manager --disablerepo=* --enablerepo=ubi-9-codeready-builder-rpms --enablerepo=ubi-9-appstream-rpms --enablerepo=ubi-9-baseos-rpms -y update; \
    rpm --restore --quiet shadow-utils; \
    dnf --disableplugin=subscription-manager --disablerepo=* --enablerepo=ubi-9-codeready-builder-rpms --enablerepo=ubi-9-appstream-rpms --enablerepo=ubi-9-baseos-rpms -y \
    install procps-ng crun podman podman-docker buildah netavark fuse-overlayfs /etc/containers/storage.conf \
    curl git jq sudo uidmap unzip zip--exclude container-selinux; \
    dnf --disableplugin=subscription-manager clean all; \
    rm -rf /var/cache /var/log/dnf* /var/log/yum.*; \
    ln -s /usr/bin/pip3 /usr/bin/pip

RUN set -eux; \
    addgroup --system docker

# Runner user
RUN useradd --uid $RUNNER_USER_UID -G docker runner; \
    echo -e "runner:1:1000\nrunner:1002:64535" > /etc/subuid; \
    echo -e "runner:1:1000\nrunner:1002:64535" > /etc/subgid;

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
    && ./bin/installdependencies.sh \
    && mv ./externals ./externalstmp \
    # libyaml-dev is required for ruby/setup-ruby action.
    # It is installed after installdependencies.sh and before removing /var/lib/apt/lists
    # to avoid rerunning apt-update on its own.
    && apt-get install -y libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
RUN mkdir /opt/hostedtoolcache \
    && chgrp runner /opt/hostedtoolcache \
    && chmod g+rwx /opt/hostedtoolcache

RUN cd "$RUNNER_ASSETS_DIR" \
    && curl -fLo runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip \
    && unzip ./runner-container-hooks.zip -d ./k8s \
    && rm -f runner-container-hooks.zip

ADD https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/containers.conf /etc/containers/containers.conf
ADD https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/podman-containers.conf /home/podman/.config/containers/containers.conf
ADD registries.conf /home/runner/.config/containers/registries.conf
ADD pind-tmpfiles.conf /usr/lib/tmpfiles.d/pind-tmpfiles.conf
ADD docker-config.json "$RUNNER_ASSETS_DIR"/.docker/config.json
RUN chown runner:runner -R /home/runner; \
    ln -s /run/user/1000/podman/podman.sock /var/run/docker.sock; \
    ln -s /runner/.docker/config.json /home/runner/.docker/config.json
VOLUME /home/runner/.local/share/containers

# chmod containers.conf and adjust storage.conf to enable Fuse storage.
RUN chmod 644 /etc/containers/containers.conf; sed -i -e 's|^#mount_program|mount_program|g' -e '/additionalimage.*/a "/var/lib/shared",' -e 's|^mountopt[[:space:]]*=.*$|mountopt = "nodev,fsync=0"|g' /etc/containers/storage.conf
RUN mkdir -p /var/lib/shared/overlay-images /var/lib/shared/overlay-layers /var/lib/shared/vfs-images /var/lib/shared/vfs-layers; touch /var/lib/shared/overlay-images/images.lock; touch /var/lib/shared/overlay-layers/layers.lock; touch /var/lib/shared/vfs-images/images.lock; touch /var/lib/shared/vfs-layers/layers.lock

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
ENV DOCKER_HOST=unix:///run/user/$RUNNER_USER_UID/docker.sock
ENV CONTAINER_HOST=unix:///var/run/docker.sock
ENV XDG_RUNTIME_DIR=/run/user/$RUNNER_USER_UID
ENV LANG=en_US.UTF-8
ENV _CONTAINERS_USERNS_CONFIGURED=""
ENV _BUILDAH_STARTED_IN_USERNS=""
ENV BUILDAH_ISOLATION=chroot

RUN echo "PATH=${PATH}" > /etc/environment \
    && echo "ImageOS=${ImageOS}" >> /etc/environment \
    && echo "DOCKER_HOST=${DOCKER_HOST}" >> /etc/environment \
    && echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}" >> /etc/environment \
    && echo "LANG=${LANG}" >> /etc/environment \
    && echo "_CONTAINERS_USERNS_CONFIGURED=${_CONTAINERS_USERNS_CONFIGURED}" >> /etc/environment \
    && echo "_BUILDAH_STARTED_IN_USERNS=${_BUILDAH_STARTED_IN_USERNS}" >> /etc/environment \
    && echo "BUILDAH_ISOLATION=${BUILDAH_ISOLATION}" >> /etc/environment \
    && echo "CONTAINER_HOST=unix:///var/run/docker.sock" >> /etc/environment

# We place the scripts in `/usr/bin` so that users who extend this image can
# override them with scripts of the same name placed in `/usr/local/bin`.
COPY entrypoint-pind-rootless.sh startup.sh logger.sh graceful-stop.sh update-status /usr/bin/

# Configure hooks folder structure.
COPY hooks-pind /etc/arc/hooks/

# No group definition, as that makes it harder to run docker.
USER runner


ENTRYPOINT ["/bin/bash", "-c"]
CMD ["entrypoint-pind-rootless.sh"]
