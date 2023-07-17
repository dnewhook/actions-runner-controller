#!/bin/bash
source logger.sh
source graceful-stop.sh
trap graceful_stop TERM

log.notice "Starting Podman Socket (rootless)"

dumb-init bash <<'SCRIPT' &
source logger.sh
source wait.sh

mkdir -p /home/runner/.local/share/containers/storage/overlay-images \
             /home/runner/.local/share/containers/storage/overlay-layers
touch /home/runner/.local/share/containers/storage/overlay-images/images.lock
touch /home/runner/.local/share/containers/storage/overlay-layers/layers.lock

log.debug 'Starting Podman daemon'
sudo podman system service --time=0 unix:///run/podman/podman.sock &

log.debug 'Waiting for processes to be running...'
socketspec=/run/podman/podman.sock

if ! wait_for_socket "$socketspec"; then
    log.error "$socketspec is not available after max time"
    exit 1
else
    log.debug "$socketspec is available"
fi

sudo chmod g+rw $socketspec

startup.sh
SCRIPT

RUNNER_INIT_PID=$!
log.notice "Runner init started with pid $RUNNER_INIT_PID"
wait $RUNNER_INIT_PID
log.notice "Runner init exited. Exiting this process with code 0 so that the container and the pod is GC'ed Kubernetes soon."

trap - TERM
