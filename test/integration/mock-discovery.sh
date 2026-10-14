#!/usr/bin/env bash
# Copyright 2026 The AMD GPU DRA Driver Authors.
# SPDX-License-Identifier: Apache-2.0

# Test real discovery against a published mock, without a GPU or Kubernetes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runtime="${CONTAINER_RUNTIME:-docker}"
image="${AMD_GPU_MOCK_IMAGE:-docker.io/submod/amd-gpu-mock:v0.2.7@sha256:322d05fd0525583bc04a3b86a3645a35f597cd9808a8f82d4183b84ecece2907}"
command -v "$runtime" >/dev/null
command -v go >/dev/null
work="$(mktemp -d)"
name="amd-dra-mock-$$"
cleanup() {
    "$runtime" rm -f "$name" >/dev/null 2>&1 || true
    "$runtime" volume rm "$name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# Use the published MI300X defaults, with AMD occupying the second DRM card.
"$runtime" run --rm "$image" cat /etc/amd-gpu-mock/profiles/mi300x.yaml > "$work/profile-source.yaml"
awk '/^devices:/ {exit} {print}' "$work/profile-source.yaml" \
    | sed 's/amdgpu_version:.*/amdgpu_version: "6.19.4"/' > "$work/profile.yaml"
cat >> "$work/profile.yaml" <<'YAML'
devices:
  - index: 1
    uuid: "GPU-amd-mi300x-0000-0000-000000000001"
    pci_bdf: "0000:05:00.0"
    drm_render_minor: 129
    unique_id: "0x9c4f000000000001"
    xgmi_device_id: "0x0001"
YAML

# A Linux volume keeps mock character devices off the macOS host filesystem.
"$runtime" volume create "$name" >/dev/null
"$runtime" run -d --name "$name" --privileged \
    -v "$name:/fixture" -v "$work/profile.yaml:/profile.yaml:ro" \
    "$image" node-agent --config /profile.yaml --root /fixture >/dev/null
ready=false
for attempt in $(seq 1 30); do
    if "$runtime" exec "$name" test -f /fixture/sys/class/drm/card1/device/driver/module/version; then
        ready=true
        break
    fi
    sleep 1
done
if ! $ready; then
    "$runtime" logs "$name" >&2
    echo "Mock sysfs did not become ready" >&2
    exit 1
fi

# Model the foreign module's discovery surface, not a second AMD allocation.
"$runtime" exec "$name" sh -eu -c '
    mkdir -p /fixture/sys/module/nvidia /fixture/sys/bus/pci/drivers/nvidia /fixture/sys/class/drm/card0/device
    printf "580.159.04\n" > /fixture/sys/module/nvidia/version
    printf "0x10de\n" > /fixture/sys/class/drm/card0/device/vendor
    ln -s ../../../../module/nvidia /fixture/sys/bus/pci/drivers/nvidia/module
    ln -s ../../../../bus/pci/drivers/nvidia /fixture/sys/class/drm/card0/device/driver
'

# This package has no cgo dependency. Compile the checkout under test, not a
# released driver image; match the Linux container engine's native architecture.
arch="$("$runtime" info --format '{{.Host.Arch}}' 2>/dev/null || "$runtime" info --format '{{.Architecture}}')"
case "$arch" in
    aarch64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    arm64|amd64) ;;
    *) echo "Unsupported container architecture: $arch" >&2; exit 1 ;;
esac
cd "$ROOT"
CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go test -c -tags=integration \
    -o "$work/amdgpu.test" ./pkg/amdgpu
"$runtime" run --rm --privileged -e AMD_GPU_MOCK_INTEGRATION=1 \
    -v "$name:/fixture:ro" -v "$work:/test-work:ro" "$image" sh -eu -c '
        mount --bind /fixture/sys /sys
        exec /test-work/amdgpu.test -test.run=TestMockMixedVendorDiscovery -test.v -test.timeout=45s
    '
