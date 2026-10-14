//go:build integration

/*
Copyright (c) Advanced Micro Devices, Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the \"License\");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an \"AS IS\" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package amdgpu

import (
	"os"
	"testing"
)

// Run through test/integration/mock-discovery.sh, which mounts an isolated mock
// sysfs tree. NVIDIA card0 precedes AMD card1, as on a mixed-vendor worker.
func TestMockMixedVendorDiscovery(t *testing.T) {
	if os.Getenv("AMD_GPU_MOCK_INTEGRATION") != "1" {
		t.Skip("requires the isolated amd-gpu-mock sysfs fixture")
	}
	foreign, err := os.ReadFile("/sys/class/drm/card0/device/driver/module/version")
	if err != nil || string(foreign) != "580.159.04\n" {
		t.Fatalf("mixed-vendor fixture is missing: version=%q, error=%v", foreign, err)
	}
	gpus := GetAMDGPUs()
	if len(gpus) != 1 {
		t.Fatalf("want one AMD GPU, got %d: %#v", len(gpus), gpus)
	}
	for pci, gpu := range gpus {
		if gpu["card"] != 1 || gpu["renderD"] != 129 || gpu["deviceID"] != "0x74a1" {
			t.Fatalf("unexpected AMD identity at %s: %#v", pci, gpu)
		}
		if gpu["vramBytes"] != uint64(192*1024*1024*1024) {
			t.Fatalf("unexpected mock VRAM at %s: %v", pci, gpu["vramBytes"])
		}
		if gpu["driverVersion"] != "6.19.4" {
			t.Fatalf("AMD discovery used another vendor's module version: got %q, want 6.19.4", gpu["driverVersion"])
		}
		t.Logf("AMD card1/renderD129 at %s: 192 GiB VRAM, driverVersion=%s; NVIDIA card0 excluded", pci, gpu["driverVersion"])
	}
}
