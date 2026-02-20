# Unraid NVIDIA P2P Patch

A utility script (`patch-driver.sh`) that patches the Unraid Nvidia driver plugin with P2P-enabled `open-gpu-kernel-modules`. This re-enables peer-to-peer (P2P) memory access over PCIe on consumer GPUs like the RTX 3090, 4090 and 5090, which is necessary for certain machine learning and distributed computing workloads.

## Features

- **Auto-Detection:** Automatically detects your installed Unraid kernel and Nvidia driver versions.
- **Automated Downloads:** Fetches the appropriate P2P-patched kernel modules from `aikitoria/open-gpu-kernel-modules`.
- **Built-in Compilation:** Compiles the kernel modules directly on Unraid. If build tools (gcc, make) are not installed natively, it automatically builds and manages a Dockerized build environment (`ich777/unraid_kernel`).
- **Seamless Injection:** Extracts your locally installed Nvidia driver package (`.txz`), swaps in the compiled `.ko` modules, repackages it, and updates the `.md5` checksum.
- **Live Reload:** Optionally reloads the live kernel modules without requiring a system reboot.

## Prerequisites

- Unraid OS with the **Nvidia Driver** plugin installed.
- **Docker** installed and enabled on Unraid (required if you do not have native compilation tools installed on your host).

## Additional System Configuration

To successfully utilize P2P memory access, your system hardware and OS must be properly configured:

### 1. BIOS/UEFI Settings
You must enable the following settings in your motherboard's BIOS:
- **Above 4G Decoding**: Enabled
- **Resizable BAR (ReBAR)**: Enabled

### 2. Unraid Boot Flags
You need to enable DMA passthrough mode for IOMMU. As described in the [open-gpu-kernel-modules repository](https://github.com/aikitoria/open-gpu-kernel-modules#p2p-support), you should add the necessary boot flags to enable this.

To edit your boot flags in Unraid:
1. Navigate to the Unraid WebUI.
2. Go to **Main** -> click on **Boot Device: Flash** under the Flash section.
3. Scroll down to **Syslinux Configuration**.
4. In the `menu default` block (usually under **Unraid OS**), add the required flags to the `append` line (e.g., `amd_iommu=on iommu=pt` for AMD processors or `intel_iommu=on iommu=pt` for Intel processors).
5. Click **Apply** and reboot the server for the changes to take effect.

*(Note: If you run a standard Linux distribution with GRUB instead of Unraid, you would edit `/etc/default/grub`, add these flags to `GRUB_CMDLINE_LINUX_DEFAULT`, and run `sudo update-grub`.)*

## Usage

Run the script as `root` from your Unraid terminal:

```bash
./patch-driver.sh [OPTIONS]
```

### Options

| Option | Description |
|---|---|
| `--check` | List all driver versions with a P2P patch available. Shows if your currently installed driver is compatible. *Does not modify anything.* |
| `--dry-run` | Print what would be done, but make no actual changes. |
| `--reload` | After patching, immediately reload the live kernel modules (`rmmod` / `modprobe`). If omitted, you must reboot Unraid to activate the patched modules. |
| `--kernel-version <ver>`| Override the auto-detected kernel version (default: `uname -r`). |
| `--driver-version <ver>`| Override the auto-detected driver version (e.g. `590.48.01`). |
| `--src-dir <path>` | Path to an existing `open-gpu-kernel-modules` source directory. If not provided, the source is automatically downloaded. |
| `--plugin-dir <path>` | Override the default plugin packages directory (default: `/boot/config/plugins/nvidia-driver/packages`). |
| `--help` | Show the help message. |

## How it works

1. **Compatibility Check:** Queries the upstream GitHub repository to verify if your current Nvidia driver version has an associated P2P patch branch.
2. **Download:** Downloads the patched kernel module source code as a tarball.
3. **Build:** Checks for necessary build tools. If missing, it patches and builds the `ich777/unraid_kernel` Docker container, then uses it to compile the modules (`make modules`). Beware that building the container takes a while. The built container is cached by Docker for future use.
4. **Patching:** Extracts your currently installed Nvidia driver `.txz` file, replaces the default kernel modules with the newly compiled ones, and repackages the archive.
5. **Checksum:** Generates a new `.md5` file, ensuring the Unraid plugin manager recognizes the modified package as valid.

## Acknowledgments

- P2P-patched kernel modules provided by [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules).
- Docker build environment based on [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel).
