<#
    bootstrap.ps1 -- one-time build box setup (design §4.1).

    Assumes TwinCAT XAE is ALREADY installed. Everything else is created here.
    Idempotent: safe to re-run.

    Run elevated:
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 `
        -PublicKey "ssh-ed25519 AAAA... you@devbox" -TcBuildPassword (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PublicKey,
    [Parameter(Mandatory)][securestring] $TcBuildPassword,
    [string] $UserName        = 'tcbuild',
    [string] $Root            = 'C:\_tcDeploy',
    [string] $ExpectedTcVersion = '4026.27',
    [switch] $EnableAutologon,
    [switch] $SkipSsh
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say  { param($m) Write-Host "[bootstrap] $m" }
function Warn { param($m) Write-Host "[bootstrap] WARNING: $m" -ForegroundColor Yellow }
function Ok   { param($m) Write-Host "[bootstrap] OK: $m" -ForegroundColor Green }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "bootstrap.ps1 must run elevated."
}

# ---------------------------------------------------------------- TwinCAT ---
Say "checking TwinCAT ..."
$tcRoot = @('C:\TwinCAT\3.1', 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1',
            'C:\Program Files\Beckhoff\TwinCAT\3.1') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $tcRoot) { Warn "no TwinCAT 3.1 directory found -- XAE must be installed before this box can build." }
else {
    Ok "TwinCAT at $tcRoot"
    $tcpkg = Get-Command tcpkg -ErrorAction SilentlyContinue
    if ($tcpkg) {
        $ver = (& tcpkg list -i 2>$null | Select-String -Pattern 'TwinCAT\.XAE|TF1000|TC31' | Select-Object -First 5)
        if ($ver) { Say "tcpkg reports:"; $ver | ForEach-Object { Say "  $_" } }
        Say "design pins $ExpectedTcVersion -- confirm the above matches the engineering workstations."
    } else { Warn "tcpkg not on PATH; cannot verify the version pin ($ExpectedTcVersion)." }
}

# ------------------------------------------------------------------- user ---
# The build box may be domain-joined, in which case the build identity may be an
# existing DOMAIN account, and we must NOT try to create it locally. Accept a
# local name ('tcbuild'), 'DOMAIN\account' or 'account@domain.example'.
$cs         = Get-CimInstance Win32_ComputerSystem
$isDomain   = [bool]$cs.PartOfDomain
$machineDom = $env:COMPUTERNAME
if ($isDomain) { Say "box is domain-joined to $($cs.Domain)" } else { Say "box is in workgroup $($cs.Workgroup)" }

if ($UserName -match '^(?<dom>[^\\]+)\\(?<acct>.+)$') {
    $accountDomain = $Matches.dom
    $accountName   = $Matches.acct
} elseif ($UserName -match '^(?<acct>[^@]+)@(?<dom>.+)$') {
    $accountDomain = $Matches.dom.Split('.')[0]
    $accountName   = $Matches.acct
} else {
    $accountDomain = $machineDom
    $accountName   = $UserName
}
if ($accountDomain -eq '.') { $accountDomain = $machineDom }   # '.\user' means local
$isLocalAccount = ($accountDomain -eq $machineDom)
$qualified      = "$accountDomain\$accountName"
Say "build identity: $qualified ($(if ($isLocalAccount) { 'local' } else { 'domain' }) account)"

if ($isLocalAccount) {
    $user = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
    if (-not $user) {
        $null = New-LocalUser -Name $accountName -Password $TcBuildPassword `
                  -FullName 'TwinCAT build agent' -Description 'Runs the TwinCAT workflow worker' `
                  -PasswordNeverExpires -AccountNeverExpires
        Ok "created local user $accountName"
    } else {
        Set-LocalUser -Name $accountName -Password $TcBuildPassword -PasswordNeverExpires $true
        Ok "local user $accountName exists; password reset"
    }
} else {
    # Domain account: verify it resolves, but never touch it. Its password,
    # expiry and lockout policy belong to the domain, not to this script.
    try {
        $sid = (New-Object Security.Principal.NTAccount($accountDomain, $accountName)).
               Translate([Security.Principal.SecurityIdentifier]).Value
        Ok "domain account $qualified resolves (SID $sid)"
    } catch {
        throw "domain account '$qualified' could not be resolved on this box: $($_.Exception.Message)"
    }
    Warn "This is a DOMAIN account. Three consequences for an unattended build agent:"
    Warn "  - Domain password rotation will silently break autologon and SSH."
    Warn "    Get it exempted from rotation, or accept re-running bootstrap on each change."
    Warn "  - Domain lockout policy applies: repeated bad auth locks the BUILD AGENT out."
    Warn "  - Group Policy can override the autologon and lock-screen settings below."
    Warn "    Verify with 'gpresult /r' after a reboot that they actually stuck."
}

# ActivateConfiguration and StartRestartTwinCAT control the TwinCAT system
# service, which needs admin. This is also the privilege point design §2.2
# flags as a likelier cause of Automation Interface failures than session type.
if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $qualified -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member $qualified
    Ok "$qualified added to local Administrators"
}
# Needed for autologon and for RDP bootstrap access.
foreach ($g in @('Remote Desktop Users')) {
    if (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue) {
        if (-not (Get-LocalGroupMember -Group $g -Member $qualified -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $g -Member $qualified; Ok "$qualified added to $g"
        }
    }
}

# ------------------------------------------------------------------- tree ---
Say "creating $Root ..."
foreach ($d in @($Root, "$Root\queue", "$Root\out", "$Root\state", "$Root\scripts", "$Root\tmp", "$Root\projects")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$acl = Get-Acl $Root
$acl.SetAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $qualified, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -Path $Root -AclObject $acl
Ok "$Root ready, $qualified has full control"

# -------------------------------------------------------------------- ssh ---
if (-not $SkipSsh) {
    Say "installing OpenSSH Server ..."
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Ok "OpenSSH.Server installed"
    } else { Ok "OpenSSH.Server already present" }

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Ok "sshd running and set to Automatic"

    if (-not (Get-NetFirewallRule -Name 'TcWorkflow-SSH' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'TcWorkflow-SSH' -DisplayName 'OpenSSH Server (TwinCAT workflow)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Ok "firewall rule added for tcp/22"
    }

    # THE GOTCHA: Windows sshd ignores ~/.ssh/authorized_keys for any user in
    # the Administrators group. Admin keys must live in this one shared file,
    # and sshd silently refuses it unless the ACL is exactly Administrators +
    # SYSTEM with inheritance disabled.
    $adminKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
    Say "installing public key into $adminKeys (admin user -- per-user authorized_keys is ignored)"
    $existing = if (Test-Path $adminKeys) { Get-Content $adminKeys -Raw } else { '' }
    if ($existing -notmatch [regex]::Escape($PublicKey.Trim())) {
        Add-Content -Path $adminKeys -Value $PublicKey.Trim() -Encoding ASCII
        Ok "public key appended"
    } else { Ok "public key already present" }

    $kacl = Get-Acl $adminKeys
    $kacl.SetAccessRuleProtection($true, $false)         # break inheritance
    $kacl.Access | ForEach-Object { $null = $kacl.RemoveAccessRule($_) }
    foreach ($p in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $kacl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($p, 'FullControl', 'Allow')))
    }
    Set-Acl -Path $adminKeys -AclObject $kacl
    Ok "ACL locked to SYSTEM + Administrators (sshd refuses the file otherwise)"

    # Keep cmd.exe as the default shell: setting it to PowerShell is a known
    # way to break scp/sftp, and the wrappers invoke powershell explicitly.
    Say "leaving DefaultShell as cmd.exe (deliberate -- PowerShell default breaks scp)"
    Restart-Service sshd
}

# ------------------------------------------------------------- scripts -----
Say "note: copy windows\\*.ps1 and windows\\lib\\ into $Root\\scripts (the tcscripts wrapper does this)."

# --------------------------------------------------------------- autologon --
if ($EnableAutologon) {
    Say "configuring autologon for $UserName ..."
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($TcBuildPassword))
    $win = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $win -Name 'AutoAdminLogon'    -Value '1'       -Type String
    Set-ItemProperty $win -Name 'DefaultUserName'   -Value $accountName   -Type String
    Set-ItemProperty $win -Name 'DefaultDomainName' -Value $accountDomain -Type String
    Set-ItemProperty $win -Name 'DefaultPassword'   -Value $plain    -Type String
    Warn "DefaultPassword is stored in the registry in CLEARTEXT. Any local admin can read it."
    Warn "Prefer Sysinternals Autologon.exe, which puts it in an LSA secret instead."
    Warn "Design §4.1 already says: do not let this box be a casual RDP target."

    # An interactive session that is LOCKED still breaks GUI automation.
    Set-ItemProperty $win -Name 'DisableLockWorkstation' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    $desk = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty $desk -Name 'ScreenSaveActive' -Value '0' -Type String -ErrorAction SilentlyContinue
    Set-ItemProperty $desk -Name 'ScreenSaverIsSecure' -Value '0' -Type String -ErrorAction SilentlyContinue
    powercfg /change standby-timeout-ac 0 2>$null
    powercfg /change monitor-timeout-ac 0 2>$null
    Ok "autologon configured; lock screen and sleep disabled"
} else {
    Say "autologon NOT configured (pass -EnableAutologon). Worker mode needs it (design §4.2)."
}

# ------------------------------------------------------------ worker task ---
Say "registering TcWorkflowWorker scheduled task ..."
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$Root\scripts\worker.ps1`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $qualified
# InteractiveToken is load-bearing: it runs the worker IN the desktop session.
# S4U or a password-based principal would put it back in a non-interactive
# station and reintroduce exactly the problem design §2.2 describes.
$principal = New-ScheduledTaskPrincipal -UserId $qualified -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'TcWorkflowWorker' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Ok "TcWorkflowWorker registered (at logon of $qualified, interactive, highest)"

Write-Host ""
Ok "bootstrap complete."
Write-Host @"
Remaining MANUAL steps (design §4.1 -- these genuinely need a human at the GUI):
  1. For each project: put its full tree at $Root\projects\<PROJECT>, log in as
     $qualified over RDP (or let autologon do it) and open its .sln in the
     XAE Shell ONCE. Accept every first-run, layout and activation prompt.
     SuppressUI does not cover all of them.
  2. Nothing git-related. This box never runs git: tcdeploy checks the tree
     and tags on Linux; the box builds what tcsync sends and
     verifies it against tcsync's SHA-256 manifest first.
  3. Add an ADS route to each target controller (its TARGET_NETID) in the
     TwinCAT router (Static route, so it survives reboots).
  4. From Linux: run tools/smoketest.sh to decide TC_MODE.
"@
