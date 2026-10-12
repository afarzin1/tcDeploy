<#
    diagnose-box.ps1 -- run this ON the build box (RDP, elevated PowerShell).

    Answers, in one pass, why a local account cannot authenticate over WinRM.
    There are exactly three plausible causes and they are indistinguishable from
    the network, because NTLM deliberately does not leak account existence.

    Paste the output back. Reads only -- changes nothing.
#>
param([string] $UserName = 'tcbuild')   # the build account to check (local part only)
$ErrorActionPreference = 'Continue'
function H($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

H 'identity of this box'
$cs = Get-CimInstance Win32_ComputerSystem
"computer      : $($cs.Name)"
"domain-joined : $($cs.PartOfDomain)  ($($cs.Domain))"
"os            : $((Get-CimInstance Win32_OperatingSystem).Caption)"

H 'CAUSE 1 -- does the account exist, and is it usable?'
$u = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $u) {
    Write-Host "$UserName DOES NOT EXIST as a local user." -ForegroundColor Red
    "existing local users:"; Get-LocalUser | Select-Object Name, Enabled | Format-Table -AutoSize | Out-String
} else {
    $u | Select-Object Name, Enabled, PasswordExpires, PasswordRequired, LastLogon |
        Format-List | Out-String
    $inAdmin = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*\$UserName" }
    "in local Administrators : $([bool]$inAdmin)"
    $inWinRM = Get-LocalGroupMember -Group 'Remote Management Users' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*\$UserName" }
    "in Remote Management Users : $([bool]$inWinRM)"
    if (-not $u.Enabled) { Write-Host "ACCOUNT IS DISABLED" -ForegroundColor Red }
}
"lockout policy:"; (net accounts) -join "`n"

H 'CAUSE 2 -- is incoming NTLM blocked by policy?'
# 'Restrict NTLM: Incoming NTLM traffic' = Deny all accounts rejects the type-3
# message for local accounts exactly the way a wrong password does.
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
$r = Get-ItemProperty $lsa -ErrorAction SilentlyContinue
"RestrictReceivingNTLMTraffic : $($r.RestrictReceivingNTLMTraffic)   # 2 = DENY ALL -> this is your cause"
"RestrictSendingNTLMTraffic   : $($r.RestrictSendingNTLMTraffic)"
$lsa2 = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
"LmCompatibilityLevel         : $($lsa2.LmCompatibilityLevel)"
"NoLmHash                     : $($lsa2.NoLmHash)"

H 'CAUSE 3 -- remote UAC token filtering'
# Blocks non-built-in local admins AFTER successful auth. Less likely given the
# symptom, but free to check while we are here.
$sys = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
"LocalAccountTokenFilterPolicy : $($sys.LocalAccountTokenFilterPolicy)   # needs 1 for local admins over WinRM"
"FilterAdministratorToken      : $($sys.FilterAdministratorToken)"

H 'WinRM service state'
try {
    "listeners:"; winrm enumerate winrm/config/listener 2>&1 | Select-String 'Address|Transport|Port'
    "auth:";      winrm get winrm/config/service/auth 2>&1 | Select-String 'Basic|Negotiate|Kerberos|CredSSP'
    "service:";   winrm get winrm/config/service 2>&1 | Select-String 'AllowUnencrypted|MaxConcurrent'
} catch { "winrm query failed: $_" }

H 'what the workflow needs next'
"OpenSSH Server : $((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').State)"
"sshd service   : $((Get-Service sshd -ErrorAction SilentlyContinue).Status)"
$tc = @('C:\TwinCAT\3.1','C:\Program Files (x86)\Beckhoff\TwinCAT\3.1','C:\Program Files\Beckhoff\TwinCAT\3.1') |
      Where-Object { Test-Path $_ } | Select-Object -First 1
"TwinCAT 3.1    : $(if ($tc) { $tc } else { 'NOT FOUND' })"
"XAE DTE ProgId : $(@('TcXaeShell.DTE.17.0','TcXaeShell.DTE.15.0','VisualStudio.DTE.17.0') |
                    Where-Object { Test-Path "Registry::HKEY_CLASSES_ROOT\$_" } | Select-Object -First 1)"
"tar.exe        : $(if (Get-Command tar.exe -ErrorAction SilentlyContinue) { 'present' } else { 'MISSING' })"
"git            : $(if (Get-Command git -ErrorAction SilentlyContinue) { (git --version) } else { 'MISSING' })"
Write-Host "`ndone -- paste this output back." -ForegroundColor Green
