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