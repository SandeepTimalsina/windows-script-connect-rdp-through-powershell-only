# Windows 11 KVM RDP Lab (Fedora Host)

A practical guide to enabling and testing Remote Desktop Protocol (RDP) from a Fedora host to a Windows 11 virtual machine running under KVM/libvirt.

> **Scope and safety:** This guide is intended for systems you own or are explicitly authorized to administer. Keep the VM on a private virtual network. Do not expose TCP port `3389` directly to the public internet.

## Overview

This setup uses:

- Fedora Linux as the KVM/libvirt host
- A Windows 11 guest VM
- libvirt's default NAT network (`192.168.122.0/24` in a typical default configuration)
- FreeRDP (`xfreerdp`) on Fedora to connect to the Windows guest

Your IP addresses, VM name, Windows account name, and network configuration may differ. Replace the example values below with the values from your own environment.

## 1. Check the Fedora/libvirt network

Check that the default libvirt network is active:

```bash
sudo virsh net-list --all
```

If the `default` network exists but is inactive, start it and configure it to start automatically:

```bash
sudo virsh net-start default
sudo virsh net-autostart default
```

Check the virtual network interface attached to your VM:

```bash
sudo virsh domiflist <VM_NAME>
```

Check the host-side virtual bridge:

```bash
ip address show virbr0
```

On a typical default libvirt NAT network, the bridge is `virbr0` and the subnet is `192.168.122.0/24`. Do not assume these values if you have customized libvirt networking.

## 2. Find the Windows guest IP address

In the Windows 11 VM, open PowerShell or Command Prompt and run:

```powershell
ipconfig
```

Find the IPv4 address for the virtual Ethernet adapter. In the commands below, replace `192.168.122.127` with the guest's actual address.

You can also inspect the guest's network configuration from Fedora:

```bash
sudo virsh domifaddr <VM_NAME>
```

This command may not report an address unless the guest agent or another supported address-discovery method is available.

## 3. Enable Remote Desktop in Windows

### Important edition note

Microsoft's built-in Remote Desktop **host** feature is generally available on Windows Pro, Enterprise, and Education editions, not Windows Home. Check **Settings → System → About → Windows specifications → Edition**. A successful TCP connection alone does not prove that a usable RDP session can be established.

### PowerShell setup script

Save the following as `Enable-RDP-Lab.ps1` inside the Windows guest. It requests administrator elevation, enables the RDP listener, starts the Remote Desktop service, and enables the built-in firewall rules only for the private libvirt subnet.

Review the `$AllowedRemoteAddress` value and change it if your virtual network uses a different subnet.

```powershell
# Enable-RDP-Lab.ps1
# Run inside your Windows VM. Administrator rights are required.

$AllowedRemoteAddress = "192.168.122.0/24"

# Relaunch this script with administrator privileges if needed.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        throw "Save this script as a .ps1 file before running it."
    }

    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "RemoteSigned",
        "-File", "`"$scriptPath`""
    )
    exit
}

try {
    # Enable Remote Desktop connections.
    Set-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    # Configure and start the Remote Desktop Services service.
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService

    # Enable built-in Remote Desktop firewall rules, restricted to the lab subnet.
    $rdpRules = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
    $rdpRules | Enable-NetFirewallRule

    $rdpRules | Get-NetFirewallAddressFilter |
        Set-NetFirewallAddressFilter -RemoteAddress $AllowedRemoteAddress

    Write-Host "Remote Desktop is enabled."
    Write-Host "Firewall access is restricted to: $AllowedRemoteAddress"
    Write-Host "Verify Windows edition and account permissions before connecting."
}
catch {
    Write-Error "RDP configuration failed: $_"
    exit 1
}
```

Run it from an elevated PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\Enable-RDP-Lab.ps1
```

Approve the User Account Control (UAC) prompt when it appears. The script also attempts to elevate itself if it is launched without administrator rights.

**Note:** Windows firewall display-group names can be localized on non-English Windows installations. If `Get-NetFirewallRule -DisplayGroup "Remote Desktop"` returns no rules, inspect the available rules in Windows Defender Firewall with Advanced Security and adapt the script for that installation.

## 4. Confirm the Windows RDP listener

Inside the Windows VM, run:

```powershell
Get-Service TermService
Get-NetTCPConnection -LocalPort 3389 -State Listen
```

You can also verify that Windows is configured to allow RDP:

```powershell
Get-ItemProperty `
  -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
  -Name fDenyTSConnections
```

A value of `0` means incoming Remote Desktop connections are enabled in this registry setting.

## 5. Install FreeRDP on Fedora

Install the FreeRDP client package available for your Fedora release:

```bash
sudo dnf search freerdp
```

Then install the package that provides `xfreerdp` (package naming may vary by Fedora release, for example `freerdp` or `freerdp3`):

```bash
sudo dnf provides '*/xfreerdp'
```

Use the package name reported by that command with `dnf install`. Confirm the client is available:

```bash
xfreerdp /version
```

## 6. Test connectivity from Fedora

Check whether the Windows guest's RDP port is reachable. Replace the example IP with your guest's actual address:

```bash
nc -zv -w 3 192.168.122.127 3389
```

A successful TCP connection indicates that something is accepting connections on that port. It does not by itself confirm that authentication or an RDP desktop session will work.

If `nc` is not installed:

```bash
sudo dnf install nmap-ncat
```

### Connect with FreeRDP

```bash
xfreerdp /v:192.168.122.127:3389 /u:<WINDOWS_USERNAME> /dynamic-resolution
```

Replace the IP and username placeholders with your own values. FreeRDP will prompt for the password if one is not supplied.

For a local Windows account, the account may need to be specified as:

```bash
xfreerdp /v:192.168.122.127 /u:'<COMPUTER_NAME>\<WINDOWS_USERNAME>' /dynamic-resolution
```

If the VM presents a certificate that your client does not trust, inspect and verify the certificate where practical. In a disposable, isolated lab only, you can bypass certificate validation for a test connection:

```bash
xfreerdp /v:192.168.122.127 /u:<WINDOWS_USERNAME> /dynamic-resolution /cert:ignore
```

Do not use `/cert:ignore` as a general setting for connections across untrusted networks.

## 7. Troubleshooting

### TCP port 3389 is unreachable

- Confirm that the VM is running.
- Confirm the guest IP with `ipconfig`.
- Confirm that the VM NIC is attached to the expected libvirt network:

  ```bash
  sudo virsh domiflist <VM_NAME>
  ```

- Confirm that the libvirt default network is active.
- In Windows, check `TermService`, the RDP listener, and the Remote Desktop firewall rules.
- Check that the firewall's allowed remote subnet matches the actual libvirt subnet.

### Ping fails, but TCP 3389 works

Windows may block inbound ICMP echo requests by firewall policy. A failed ping does not necessarily indicate that RDP is unavailable. The TCP port test is more directly relevant to RDP connectivity.

### Authentication fails

- Confirm the Windows account name and password.
- Confirm the account is permitted to connect through Remote Desktop (for example, it is an administrator or a member of the Remote Desktop Users group).
- For local accounts, try the computer-qualified username format shown above.
- Check Windows edition support for hosting RDP sessions.

### The script reports registry access denied

Run the script again and approve the UAC elevation prompt. The registry and service changes require administrator privileges.

### FreeRDP command is not found

Use `dnf provides '*/xfreerdp'` to identify the package containing the executable for your Fedora version, then install that package.

## 8. Accessing the lab remotely

The guest address on libvirt's default NAT network (often `192.168.122.x`) is a private address. It is normally reachable from the Fedora host and other appropriately routed systems, but it is not directly reachable from the public internet.

For remote access while away from the host, use a private VPN or authenticated overlay network such as WireGuard or Tailscale. Keep RDP reachable only through that private network, and restrict firewall access to the VPN subnet or trusted devices.

**Do not forward TCP port `3389` from your home router or cloud firewall directly to the Windows VM.** Directly exposing RDP to the internet creates substantial risk from password attacks, vulnerability exploitation, and misconfiguration.

## 9. Lab hygiene

- Take a VM snapshot before security testing or major configuration changes.
- Use unique, strong passwords and avoid reusing personal credentials.
- Keep the lab network isolated from sensitive home or workplace systems.
- Use only test accounts and data in the VM.
- Keep Windows and Fedora updated.
- Revert the VM to a known-good snapshot after experiments when appropriate.
- Only test systems for which you have explicit authorization.

## Quick reference

| Task | Command |
|---|---|
| List libvirt networks | `sudo virsh net-list --all` |
| Start default network | `sudo virsh net-start default` |
| Show VM interfaces | `sudo virsh domiflist <VM_NAME>` |
| Show host bridge | `ip address show virbr0` |
| Check RDP TCP port | `nc -zv -w 3 <WINDOWS_VM_IP> 3389` |
| Connect to Windows | `xfreerdp /v:<WINDOWS_VM_IP> /u:<WINDOWS_USERNAME> /dynamic-resolution` |

---

## Contributing

If you adapt this guide for another Fedora, libvirt, or Windows release, please document the versions tested and avoid committing private IP details, usernames, passwords, certificates, or other environment-specific information.
