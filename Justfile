# fips-peer — build and publish the FIPS runtime image.
#
# The FIPS version is read from charts/fips-peer/Chart.yaml's `appVersion`
# (the chart also uses it as the image tag), so bump it there only.
#
#   just                  list recipes
#   just build            build ghcr.io/notmandatory/fips-peer:<version>
#   just publish          build and push
#   just test             run the built image and print the daemon version
#
# Environment overrides:
#   FIPS_PEER_REGISTRY    registry host            (default ghcr.io)
#   FIPS_PEER_REPOSITORY  image repository         (default <registry>/notmandatory/fips-peer)
#   FIPS_REPO             upstream FIPS repo       (default jmcorgan/fips)
#   FIPS_DEB_SHA256       pin the .deb download    (see `just checksums`)

set shell := ["bash", "-uc"]

registry := env("FIPS_PEER_REGISTRY", "ghcr.io")
repository := env("FIPS_PEER_REPOSITORY", registry + "/notmandatory/fips-peer")
fips_repo := env("FIPS_REPO", "jmcorgan/fips")
deb_sha256 := env("FIPS_DEB_SHA256", "")
fips_version := `awk -F: '/^appVersion:/ {gsub(/[ "]/, ""); print $2}' charts/fips-peer/Chart.yaml`
image := repository + ":" + fips_version

# List recipes (default).
default:
    @just --list

# Show the version, image reference, and checksum pin.
version:
    @echo "fips:   {{fips_version}}"
    @echo "image:  {{image}}"
    @echo "sha256: {{ if deb_sha256 == "" { "unpinned" } else { deb_sha256 } }}"

# Log in to the image registry.
login:
    podman login {{registry}}

# Build the runtime image at the chart's appVersion.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    args=(--build-arg "FIPS_VERSION={{fips_version}}")
    if [[ -n "{{deb_sha256}}" ]]; then
        args+=(--build-arg "FIPS_DEB_SHA256={{deb_sha256}}")
    fi
    podman build "${args[@]}" --tag "{{image}}" --file Dockerfile .

# Push the image built by `just build`.
push:
    podman push {{image}}

# Build and push.
publish: build push

# Run the built image and print the daemon version (smoke test).
test:
    podman run --rm --entrypoint /usr/bin/fips {{image}} --version

# Print the published .deb checksums for this version.
checksums:
    curl -fsSL "https://github.com/{{fips_repo}}/releases/download/v{{fips_version}}/checksums-linux.txt" | grep -- '\.deb'

# Print the published amd64 .deb checksum (for pinning FIPS_DEB_SHA256).
deb-sha256:
    @curl -fsSL "https://github.com/{{fips_repo}}/releases/download/v{{fips_version}}/checksums-linux.txt" | awk '/_amd64\.deb/ {print $1}'

# Lint the Helm chart.
lint:
    helm lint ./charts/fips-peer

# Render the chart with the default values.
render:
    helm template fips-peer ./charts/fips-peer --namespace fips-peer
