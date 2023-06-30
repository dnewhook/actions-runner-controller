#!/bin/bash
source logger.sh
source graceful-stop.sh
trap graceful_stop TERM

log.notice "Starting Podman Socket (rootless)"

dumb-init bash <<'SCRIPT' &
source logger.sh
source wait.sh

log.debug 'Starting Podman daemon'
sudo podman system service --time=0 &

log.debug 'Waiting for processes to be running...'
processes=(podman)

for process in "${processes[@]}"; do
    if ! wait_for_process "$process"; then
        log.error "$process is not running after max time"
        exit 1
    else
        log.debug "$process is running"
    fi
done

sudo chmod g+rw /run/podman/podman.sock

startup.sh
SCRIPT

RUNNER_INIT_PID=$!
log.notice "Runner init started with pid $RUNNER_INIT_PID"
wait $RUNNER_INIT_PID
log.notice "Runner init exited. Exiting this process with code 0 so that the container and the pod is GC'ed Kubernetes soon."

trap - TERM
