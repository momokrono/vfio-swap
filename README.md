# On‑Demand GPU Passthrough (Host ⇄ VM)

Why should I give up my GPU just to spin up a VM?

## Overview
A Bash script to switch a dedicated GPU between the Linux host and a virtual machine (e.g., QEMU/KVM) on demand:

```bash
vfio-swap to-vm      # Unbind GPU from host, bind to vfio-pci for VM
vfio-swap to-host    # Restore GPU to host drivers after VM shutdown
```

## Why
I wrote this because I thought it made no sense to tell the kernel to completely ignore a GPU during boot just to have it ready for the VMs. I need the dGPU to be available on the host at every boot, for games, machine learning, and general compute tasks, but sometimes I just want it available for a VM for all those programs I need to run through Windows because of missing native Linux apps.

The script aims to be easy to read, explicit in what it does, and minimal. The last thing I want is to lock your session or leave the GPU in an unusable state.

## Supported Hardware

| Vendor | Status | Notes |
|--------|--------|-------|
| NVIDIA | Tested | Full support including nvidia-persistenced restart |
| AMD | Untested | Detection and DRM node handling implemented |
| Intel | Untested | Detection and DRM node handling implemented |

I don't have AMD or Intel discrete GPUs to test with. If you do and want to help, please open an issue with your results!

## System prerequisites
### Hardware
- CPU and motherboard that support IOMMU and virtualization extensions (Intel VT‑d or AMD‑Vi)
- A dedicated GPU for the VM and a separate GPU or iGPU for the host desktop session

### Firmware/BIOS settings
- Enable virtualization and IOMMU:
  - Intel: VT‑d and IOMMU
  - AMD: SVM and IOMMU

### Kernel parameters (GRUB, systemd-boot or similar)
- Enable IOMMU. Examples:
  - Intel: `intel_iommu=on iommu=pt`
  - AMD: `iommu=pt` (AMD CPUs don't need `amd_iommu=on`)

### Operating system and packages
- Any Linux distribution with recent kernel and KVM/QEMU stack
- Required packages:
  - `pciutils` (for `lspci`)
  - `psmisc` (for `fuser`)
  - `kmod` (for `modprobe`)
- Optional: Looking Glass and `kvmfr` kernel module


## Quick Start

```bash
# Copy and edit config
cp vfio-passthrough.conf.example ~/.config/vfio-passthrough.conf
nano ~/.config/vfio-passthrough.conf

# Preview what would happen
sudo ./vfio-swap to-vm --dry-run --verbose

# Actually switch to VM mode
sudo ./vfio-swap to-vm

# Start your VM...

# After VM shutdown, restore GPU
sudo ./vfio-swap to-host
```


## Usage

```
vfio-swap v1.0.0 - On-demand GPU passthrough

Usage: vfio-swap <command> [options]

Commands:
  to-vm       Unbind GPU from host and prepare for VM passthrough
  to-host     Restore GPU to host after VM shutdown

Global Options:
  -n, --dry-run     Show what would be done without making changes
  -v, --verbose     Enable verbose output
  -l, --log         Enable syslog logging
  -h, --help        Show help message
  --version         Show version information
```

### to-vm options
```
  -g, --gpu ID      GPU PCI ID (default: 0000:01:00.0)
  -a, --audio ID    GPU Audio PCI ID (default: 0000:01:00.1)
  -f, --force       Force operation even if GPU appears already passed through
```

### to-host options
```
  -f, --force           Force operation (ignore state file validation errors)
  --no-nvidia-restart   Skip nvidia-persistenced restart
```

### Examples
```bash
# Switch GPU to VM with custom PCI IDs
sudo ./vfio-swap to-vm -g 0000:02:00.0 -a 0000:02:00.1

# Force switch even if state file exists (e.g., after crash)
sudo ./vfio-swap to-vm --force

# Restore with verbose output and logging
sudo ./vfio-swap to-host --verbose --log

# View logs
journalctl -t vfio-passthrough
```


## Configuration

### Config File (Recommended)
Create `~/.config/vfio-passthrough.conf`:

```bash
cp vfio-passthrough.conf.example ~/.config/vfio-passthrough.conf
```

The script checks these locations (first found wins):
1. `~/.config/vfio-passthrough.conf` — user config
2. `/etc/vfio-passthrough.conf` — system-wide fallback

Config options:
- `GPU_PCI_ID` — PCI ID of the GPU video function (e.g., `0000:01:00.0`)
- `GPU_AUDIO_PCI_ID` — PCI ID of the GPU audio function (e.g., `0000:01:00.1`)
- `VFIO_USER` / `VFIO_GROUP` — Owner for VFIO device nodes
- `NVIDIA_RESTART` — Whether to restart nvidia-persistenced (default: `true`)

### Finding your GPU PCI IDs
```bash
lspci -nn | grep -E "VGA|3D|Display|Audio"
# 01:00.0 VGA compatible controller: NVIDIA Corporation ...
# 01:00.1 Audio device: NVIDIA Corporation ...
```
Use `0000:01:00.0` and `0000:01:00.1` in your config.


## Prep work
- Always run as root (enforced by the script)
- Ensure your display server is **not** attached to the GPU you plan to passthrough
- The script detects and blocks if Xorg, Xwayland, KWin, GNOME Shell, Mutter, Weston, Sway, SDDM, or GDM are using the device
- Back up your system and have out‑of‑band access ready in case display output is lost


## Troubleshooting

> Don't panic.
> — Douglas Adams

| Problem | Solution |
|---------|----------|
| "Display server is attached" | Move your desktop to a different GPU (iGPU). Disconnect cables from passthrough GPU. |
| "GPU already in passthrough mode" | Run `vfio-swap to-host` first, or use `--force` if state is stale |
| GPU still in use after killing apps | Some services respawn. Stop them manually before running the script. |
| No video in VM | Check IOMMU group attachment and vbios settings for your GPU |
| GPU won't rebind after VM | Ensure VM fully released the device. Check for lingering QEMU processes. |
| Invalid PCI ID format | Use format `DDDD:BB:DD.F` (e.g., `0000:01:00.0`). Run `lspci -nn` to find IDs. |
| IOMMU not enabled | Check `cat /proc/cmdline` for `intel_iommu=on` or `iommu=pt`. Enable in BIOS. |


## FAQ

**Do I need a second GPU?**
Yes, but integrated GPUs work fine. That's my setup. Using the same GPU for host display and VM is unsafe and unsupported.

**Can I use this with AMD/Intel GPUs?**
The code for detecting and handling AMD/Intel GPUs is there, but I haven't tested it since I only have an NVIDIA card. It should work, but let me know if it doesn't.

**How do I debug?**
Use `--dry-run` to preview, `--verbose` for details, and `--log` for syslog output.


## Project Structure
```
vfio-swap/
├── vfio-swap                      # Main script
├── lib/
│   └── common.sh                  # Shared library
├── host_to_vm.sh                  # Wrapper (ease of use)
├── vm_to_host.sh                  # Wrapper (ease of use)
├── vfio-passthrough.conf.example
├── README.md
└── LICENSE
```


## Contributing
Found a bug or have improvements? Open an issue or PR!

If you need help, include your distro, kernel version, hardware, and what you tried. It helps a lot.


## License
MIT License — Copyright (c) 2025

See [LICENSE](LICENSE) for full text.
