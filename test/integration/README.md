# Mock-backed discovery regression

Run `make test-mock` on a CPU-only Linux host with Go and Docker, or run
`CONTAINER_RUNTIME=podman make test-mock` with a Linux Podman machine.
The same target runs alongside the existing lint and unit-test CI jobs.

The test uses the digest-pinned [amd-gpu-mock](https://github.com/sub-mod/amd-gpu-mock)
v0.2.7 image to render one MI300X as AMD `card1`/`renderD129`. A small fixture
adds NVIDIA `card0` and its `580.159.04` module version. The production
`GetAMDGPUs()` discovery path must return only the AMD device, preserve its
192-GiB memory capacity and report the AMD module version `6.19.4`.

This covers [issue #56](https://github.com/ROCm/k8s-gpu-dra-driver/issues/56)
and the fix in [PR #117](https://github.com/ROCm/k8s-gpu-dra-driver/pull/117).
The older code globbed every DRM card's module version, selecting NVIDIA's
version when its card appeared first. The existing version-normalization unit
test does not exercise that filesystem discovery path.

The script compiles this checkout's `pkg/amdgpu` integration test and runs it
against an isolated, read-only mock `/sys` mount. It uses no released driver
binary and changes no production driver code. Both containers and their Linux
fixture volume are removed on exit. Privileged disposable containers are
required to render character devices and mount the fixture; the host's real
`/sys` is not changed. The image is multiarch; no GPU or Kubernetes cluster is
needed. `AMD_GPU_MOCK_IMAGE` can override the pinned image for development.

This test validates sysfs/KFD discovery, not AMD SMI, Kubernetes scheduling,
NodePrepare/NodeUnprepare, CDI injection, GPU computation, VFIO or partition
reconfiguration. Those require separate integration coverage.

## Historical regression proof

The same mock-backed test was run against unmodified production source from
the actual parent and merge commits of PR #117:

| Driver revision | Result |
| --- | --- |
| Before: `f93028fa0f1ccf36ea684781ed3b0f85a52031d2` | FAIL: AMD driver version incorrectly read as `580.159.04` |
| After: `ad96ab70d80a3cf93a00e71f11a6e59d526c6ddc` | PASS: AMD driver version `6.19.4` |
| Develop: `a03f37f62f843d927c569a47943c5f078cfb6c51` | PASS |

The existing `pkg/amdgpu` unit tests passed on the before revision. This
adds coverage of a real filesystem discovery regression they did not detect.
No deliberately broken production change was introduced.

Captured failure:

```text
AMD discovery used another vendor's module version: got "580.159.04", want 6.19.4
--- FAIL: TestMockMixedVendorDiscovery
```

Captured success:

```text
AMD card1/renderD129 at 0000:05:00.0: 192 GiB VRAM, driverVersion=6.19.4; NVIDIA card0 excluded
--- PASS: TestMockMixedVendorDiscovery
```
