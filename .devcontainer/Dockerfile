# Base image: Microsoft's official Dev Containers Ubuntu image.
# Tools (terraform, kubectl, helm, ansible) are layered on by Dev Container Features
# declared in devcontainer.json — see that file rather than reinventing the install
# logic here.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# A few small things easier to do in a Dockerfile than via features:
#   - A writable in-container SSH config dir so the bind-mounted host ~/.ssh
#     can stay read-only.
#   - Standard CLI tools the scripts assume.

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl \
        wget \
        ca-certificates \
        jq \
        python3-pip \
        python3-kubernetes \
        openssh-client \
        rsync \
        unzip \
        less \
    && rm -rf /var/lib/apt/lists/*

# Create a writable SSH config dir for the mark user. The host's ~/.ssh is
# bind-mounted read-only at /home/mark/.ssh per devcontainer.json; we point
# SSH at a writable copy of the config for known_hosts and the like.
# The post-create script handles the actual user-level setup, since it
# runs after the common-utils feature has created the user.
