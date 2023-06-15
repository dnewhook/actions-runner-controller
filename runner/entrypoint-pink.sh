#!/bin/bash
source logger.sh
source graceful-stop.sh
trap graceful_stop TERM

log.notice "Starting Podman Socket (rootless)"

dumb-init bash <<'SCRIPT' &
# Note that we don't want podman socket to be terminated before the runner agent,
# because it defeats the goal of the runner agent graceful stop logic implemenbed above.
# We can't rely on e.g. `dumb-init --single-child` for that, because with `--single-child` we can't even trap SIGTERM
# for not only podman socket but also the runner agent.
sudo podman system service --time=0 &

startup-pink.sh
sudo chmod 660 /run/podman/podman.sock
SCRIPT

RUNNER_INIT_PID=$!
log.notice "Runner init started with pid $RUNNER_INIT_PID"
wait $RUNNER_INIT_PID
log.notice "Runner init exited. Exiting this process with code 0 so that the container and the pod is GC'ed Kubernetes soon."

if [ -f /runner/.runner ]; then
# If the runner failed with the following error:
#   √ Connected to GitHub
#   Failed to create a session. The runner registration has been deleted from the server, please re-configure.
#   Runner listener exit with terminated error, stop the service, no retry needed.
#   Exiting runner...
# It might have failed to delete the .runner file.
# We use the existence of the .runner file as the indicator that the runner agent has not stopped yet.
# Remove it by ourselves now, so that the dockerd sidecar prestop won't hang waiting for the .runner file to appear.
  echo "Removing the .runner file"
  rm -f /runner/.runner
fi

trap - TERM
