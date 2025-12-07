# On‑Demand GPU Passthrough (Host ⇄ VM)

Why should I give up my GPU just to spin up a VM?

## Overview
This repository provides two small Bash scripts to switch a dedicated GPU between the Linux host and a virtual machine (e.g., QEMU/KVM) on demand:
- `host_to_vm.sh` — Unbinds the specified GPU from the host driver and binds it to vfio‑pci for passthrough to a VM.
- `vm_to_host.sh` — Restores the GPU bindings back to the original host drivers using state captured during the handoff.

## Why
I wrote these scripts because I thought it made no sense to tell the kernel to completely ignore a GPU during boot just to have it ready for the VMs. I need the dGPU to be available on the host at every boot, for games, machine learning, and general compute tasks, but sometimes I just want it available for a VM for all those programs I need to run through Windows because of missing native Linux apps.

The scripts aim to be easy to read, explicit in what they do, and minimal. The last thing I want is to lock your session or leaving the GPU in an unusable state.

## System prerequisites
### Hardware
- CPU and motherboard that support IOMMU and virtualization extensions (Intel VT‑d or AMD‑Vi)
- A dedicated GPU for the VM and a separate GPU or iGPU for the host desktop session

### Firmware/BIOS settings
- Enable virtualization and IOMMU:
  - Intel: VT‑d and IOMMU
  - AMD: SVM and IOMMU

### Kernel parameters (GRUB, systemdboot or similar)
- Enable IOMMU and, for NVIDIA, consider disabling certain mitigations if needed for your environment. Examples:
  - Intel: `intel_iommu=on iommu=pt`
  - AMD: `iommu=pt`
    > Note: AMD CPUs don't need `amd_iommu=on`

### Operating system and packages
- Any Linux distribution with recent kernel and KVM/QEMU stack should do fine
- Packages/tools:
  - `pciutils` (for `lspci`)
  - `psmisc` (for `fuser`)
  - `kmod` (for `modprobe`)
  - `util‑linux` (for `lsmod`)
- Optional: Looking Glass components and `kvmfr` kernel module if you plan to use `/dev/kvmfr0`


## Prep work
- Always run these scripts as root. They enforce this requirement.
- Ensure your display server is not attached to the GPU you plan to passthrough. The script will refuse to proceed if it detects Xorg, Xwayland, KWin, GNOME Shell, SDDM, or GDM using the device.
- Back up your system configuration and be prepared with an out‑of‑band access method in case display output is lost.
- The state file is protected with restrictive permissions (600) and symlink validation.


## Configuration

### Config File (Recommended)
Create `~/.config/vfio-passthrough.conf` to set default values. See `vfio-passthrough.conf.example` for a template:

```bash
# Copy the example config to your user config directory
mkdir -p ~/.config
cp vfio-passthrough.conf.example ~/.config/vfio-passthrough.conf
nano ~/.config/vfio-passthrough.conf
```

The scripts check these locations in order (first found wins):
1. `~/.config/vfio-passthrough.conf` — user config
2. `/etc/vfio-passthrough.conf` — system-wide fallback

Config file options:
- `GPU_PCI_ID` — PCI ID of the GPU video function, e.g., `0000:01:00.0`
- `GPU_AUDIO_PCI_ID` — PCI ID of the GPU audio function, e.g., `0000:01:00.1`
- `NVIDIA_RESTART` — Whether to restart nvidia-persistenced after restoration (default: `true`)

### Command‑Line Arguments
Both scripts support command‑line arguments that override config file and defaults:

**host_to_vm.sh:**
```
Usage: host_to_vm.sh [OPTIONS]

Options:
  -g, --gpu ID          GPU PCI ID (default: 0000:01:00.0)
  -a, --audio ID        GPU Audio PCI ID (default: 0000:01:00.1)
  -n, --dry-run         Show what would be done without making changes
  -v, --verbose         Enable verbose output
  -l, --log             Enable syslog logging
  -h, --help            Show help message
```

**vm_to_host.sh:**
```
Usage: vm_to_host.sh [OPTIONS]

Options:
  -n, --dry-run             Show what would be done without making changes
  -v, --verbose             Enable verbose output
  -l, --log                 Enable syslog logging
  --no-nvidia-restart       Skip nvidia-persistenced restart
  -h, --help                Show help message
```

### Script Variables
If not using the config file, the scripts use these defaults (editable in the scripts):
- `VFIO_USER` — Username that should own VFIO device nodes during VM usage
- `VFIO_GROUP` — Group that should own VFIO device nodes during VM usage (e.g., `kvm`)
- `STATE_FILE` — Temporary path for saving original bindings (default: `/run/vfio_state`)


### Identify your GPU PCI IDs
Use `lspci` to find the relevant functions. Typical dGPU exposes two functions: video and audio.
Example:
```
lspci -nn | grep -E "VGA|3D|Audio"
# 01:00.0 VGA compatible controller: NVIDIA Corporation ...
# 01:00.1 Audio device: NVIDIA Corporation ...
```
Then use `0000:01:00.0` and `0000:01:00.1` in your config or arguments.


## Step-by-step checklist
1. Enable IOMMU and verify groups (see above)

2. Install required tools

3. Ensure appropriate drivers and modules are working correctly:
   - Host GPU drivers (e.g., nvidia, nvidia_drm, amdgpu) should be installed and working.
   - vfio‑pci should be available. The script loads it as needed.
   - If using Looking Glass, ensure the `kvmfr` module is available (the script loads it if present).

4. User and group permissions
   - VFIO_USER should be your user that runs the VM.
   - VFIO_GROUP typically is kvm. Ensure your user belongs to this group

5. Verify no critical processes use the passthrough GPU
   - The script will check /dev/nvidia* and block if the display server is attached.


## Usage

### Preview with Dry Run
Before making changes, preview what the scripts will do:
```bash
sudo ./host_to_vm.sh --dry-run --verbose
sudo ./vm_to_host.sh --dry-run --verbose
```

### Switch Host → VM
1. Configure your GPU IDs (config file or arguments).
2. Run as root:
    ```bash
    sudo ./host_to_vm.sh
    # Or with custom GPU:
    sudo ./host_to_vm.sh -g 0000:02:00.0 -a 0000:02:00.1
    ```
3. When prompted, confirm termination of processes that hold the GPU (if any).
4. Start your VM with the vfio‑pci devices corresponding to your GPU and audio function. Ensure the VM XML or QEMU command attaches the IOMMU group correctly.

### Switch VM → Host
1. Shut down the VM that uses the GPU.
2. Run as root:
    ```bash
    sudo ./vm_to_host.sh
    ```
3. Verify on host. For NVIDIA GPUs, run `nvidia-smi` and ensure the GPU is listed correctly.

### Enable Logging
For debugging or audit trails, enable syslog logging:
```bash
sudo ./host_to_vm.sh --log --verbose
# View logs with:
journalctl -t vfio-passthrough
```

## Troubleshooting
> Don't panic.
>
> -- <cite>Douglas Adams</cite>

- The script says the display server is attached
  - Ensure your desktop is using a different GPU (iGPU or secondary dGPU). Move display outputs if necessary and configure your compositor accordingly. Ensure HDMI and DP cables are **not** attached to the GPU ports.

- GPU is still in use after killing apps
  - Some services may respawn. Disable or stop the offending services before running the script.

- No video output in VM
  - Confirm the correct IOMMU group is attached to the VM and that vbios/firmware settings are correct for your GPU model.

- VM shuts down but GPU will not rebind
  - Ensure the VM has released the device. Verify that no vfio‑userspace or QEMU processes are still running. Then run `vm_to_host.sh` again.

- Permissions on `/dev/vfio/<group>`
  - Re‑run `host_to_vm.sh` to reset ownership. Confirm VFIO_USER and VFIO_GROUP are correct.

- Script interrupted mid‑execution
  - The scripts have trap handlers that preserve state on interruption. Re‑run `vm_to_host.sh` to restore the GPU if needed.

- IOMMU not enabled errors
  - Verify kernel parameters with `cat /proc/cmdline`. Ensure `intel_iommu=on` is present for Intel CPUs. Reboot after adding parameters and enabling IOMMU from the BIOS.


## Frequently asked questions
### Do I need a second GPU?
Yes. But integrated GPUs are more than enough. This is exactly my setup. Using the same GPU for both host display and VM is unsafe and not supported by these scripts.

### Can I use this with AMD GPUs?
Yes. The scripts __should__ work with any GPU but I haven't been able to test them with AMD hardware since my only dGPU is from team green. The nvidia-specific features (device node checking, persistenced restart) are optional and skipped for AMD GPUs.

### How do I debug issues?
Use `--dry-run` to preview actions, `--verbose` for detailed output, and `--log` to send output to syslog for later review.


## Contributing
Found a bug? Having issues/improvements? Feel free to open an issue or a PR!
If you need assistance, please include distro, kernel version, hardware and the steps you made, it helps a lot.

## License
MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
