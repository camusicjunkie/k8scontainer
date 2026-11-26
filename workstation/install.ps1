<#
.SYNOPSIS
Installs this Release's portable VS Code on a Workstation, offline, and points
Remote-SSH at your Devcontainer Pod.

.DESCRIPTION
Checks every file against SHA256SUMS before writing anything, checks the
portable VS Code is the commit pinned in the image (vscode.env) and the
Remote-SSH VSIX the version pinned there, then unzips it
into its own per-Release folder under -Destination, makes it portable (data\ and
data\tmp), installs the Remote-SSH extension from its VSIX file, writes the
offline settings, and adds a Host block (the Gateway host and your port) to your
SSH config. Nothing is downloaded. Runs on Windows PowerShell 5.1 or PowerShell 7.

The SSH config is only ever changed inside the block this script owns (between
the "# BEGIN devcontainer-installer" and "# END devcontainer-installer" lines),
so a rerun, even with a new -Port, replaces that block and leaves the rest of
the file alone. A hand-written Host of the same name is never touched: the
script stops before writing anything and asks you to pick another -HostAlias.

.EXAMPLE
.\install.ps1 -GatewayHost gateway.example.internal -Port 2201
#>
[CmdletBinding()]
param(
    # The Gateway's DNS name or IP address (the one shared by every admin). Prefer the DNS name.
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [string] $GatewayHost,

    # Your own port on the Gateway, from the Roster.
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int] $Port,

    # The Host name to write in the SSH config and to pick in Remote-SSH.
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $HostAlias = 'devcontainer',

    # The Pod's login user (the Standard Image's user).
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $User = 'dev',

    # Where per-Release folders go.
    [string] $Destination = (Join-Path $env:LOCALAPPDATA 'Programs\devcontainer-vscode'),

    # The SSH config file to update.
    [string] $SshConfig = (Join-Path $HOME '.ssh\config'),

    # A previous Release's install folder whose data\user-data (settings,
    # keybindings, state) is carried forward. Extensions are not: they come
    # from this Release's VSIX file.
    [string] $From
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM: OpenSSH and VS Code dislike one

function Get-Sha {
    param(
        # The file to hash.
        [string] $Path
    )
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# 1. Every file, before anything is written. $covered remembers what SHA256SUMS
#    vouches for; a hashtable's keys are case-insensitive, as Windows paths are.
Write-Host 'Checking SHA256SUMS'
$covered = @{}
$sumsFile = Join-Path $here 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $sumsFile)) { throw "missing file: $sumsFile" }
foreach ($line in Get-Content -LiteralPath $sumsFile) {
    if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') { throw "SHA256SUMS: can't read line: $line" }
    $want = $Matches[1].ToLower()
    $name = $Matches[2] -replace '/', '\'
    if ([IO.Path]::IsPathRooted($name) -or ($name -split '\\') -contains '..') { throw "SHA256SUMS: path leaves the Release folder: $name" }
    $file = Join-Path $here $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "missing file: $file" }
    $have = Get-Sha $file
    if ($have -ne $want) { throw "SHA-256 mismatch for ${file}: expected $want, got $have. The copy is damaged; don't install it." }
    $covered[$name] = $true
}
function Assert-Covered {
    param(
        # A file name from the Release folder, as release.json names it.
        [string] $Name
    )
    if (-not $covered.ContainsKey($Name)) {
        throw "$Name is not covered by SHA256SUMS; refusing to use it"
    }
}

# 2. What the Release says, and that it is the VS Code the image bakes in.
foreach ($n in 'release.json', 'vscode.env', 'settings.json') { Assert-Covered $n }
$release = Get-Content -Raw -LiteralPath (Join-Path $here 'release.json') | ConvertFrom-Json
$pin = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $here 'vscode.env')) {
    if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $pin[$Matches[1]] = $Matches[2].Trim() }
}
if ($release.vscode.commit -ne $pin['VSCODE_COMMIT']) {
    throw "VS Code commit $($release.vscode.commit) is not the commit $($pin['VSCODE_COMMIT']) baked into the image; Remote-SSH would refuse the mismatch."
}
if ($release.vscode.version -ne $pin['VSCODE_VERSION']) {
    throw "VS Code version $($release.vscode.version) is not the pinned $($pin['VSCODE_VERSION'])."
}
Assert-Covered $release.vscode.zip
if ((Get-Sha (Join-Path $here $release.vscode.zip)) -ne $pin['VSCODE_WIN_SHA256']) {
    throw "$($release.vscode.zip) is not the pinned portable VS Code (VSCODE_WIN_SHA256 in vscode.env)."
}
$extensions = @($release.extensions)
if ($extensions.Count -ne 1 -or $extensions[0].id -ne 'ms-vscode-remote.remote-ssh') {
    throw 'This Release must carry exactly one extension, Remote-SSH (ms-vscode-remote.remote-ssh).'
}
if ($extensions[0].version -ne $pin['VSCODE_REMOTE_SSH_VERSION']) {
    throw "Remote-SSH $($extensions[0].version) is not the pinned $($pin['VSCODE_REMOTE_SSH_VERSION']) (VSCODE_REMOTE_SSH_VERSION in vscode.env)."
}
Assert-Covered $extensions[0].file

# 3. The SSH config: decide the new text now, so a conflict stops us before any write.
$begin = "# BEGIN devcontainer-installer $HostAlias"
$end = "# END devcontainer-installer $HostAlias"
$block = (@($begin, "Host $HostAlias", "  HostName $GatewayHost", "  Port $Port", "  User $User", '  ForwardAgent yes', $end) -join "`n") + "`n"
$sshText = ''
if (Test-Path -LiteralPath $SshConfig) { $sshText = [IO.File]::ReadAllText($SshConfig) }
$ownBlock = '(?ms)^' + [regex]::Escape($begin) + '[ \t]*\r?\n.*?^' + [regex]::Escape($end) + '[ \t]*(\r?\n|\z)'
$others = [regex]::Replace($sshText, $ownBlock, '')
if ($others -match ('(?im)^\s*Host\s+(.*\s)?' + [regex]::Escape($HostAlias) + '(\s|$)')) {
    throw "$SshConfig already has its own 'Host $HostAlias'. It was left alone; pick another name with -HostAlias."
}
$own = [regex]::Match($sshText, $ownBlock)
if ($own.Success) {
    $newSsh = $sshText.Substring(0, $own.Index) + $block + $sshText.Substring($own.Index + $own.Length)
} else {
    $sep = ''
    if ($sshText.Length -gt 0) { $sep = if ($sshText -match '\n$') { "`n" } else { "`n`n" } }
    $newSsh = $sshText + $sep + $block
}

# 4. -From is checked here too, so a bad path fails before anything is written.
$previous = $null
if ($From) {
    $previous = Join-Path $From 'data\user-data'
    if (-not (Test-Path -LiteralPath $previous)) { throw "no data\user-data under $From" }
}

# 5. A fresh per-Release folder. From here a failure removes it again, so the
#    rerun isn't blocked. An existing folder is a finished install: keep it.
$target = Join-Path $Destination ("VSCode-{0}-{1}" -f $release.vscode.version, $release.version)
$userData = Join-Path $target 'data\user-data'
$fresh = -not (Test-Path -LiteralPath $target)
try {
    if ($fresh) {
        Write-Host "Unzipping VS Code $($release.vscode.version) into $target"
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Expand-Archive -LiteralPath (Join-Path $here $release.vscode.zip) -DestinationPath $target
        New-Item -ItemType Directory -Path (Join-Path $target 'data\tmp') | Out-Null
        if ($From) {
            Write-Host "Carrying data\user-data forward from $From"
            Copy-Item -Recurse -LiteralPath $previous -Destination $userData
        }
        $code = Join-Path $target 'bin\code.cmd'
        foreach ($ext in $extensions) {
            Write-Host "Installing $($ext.id) $($ext.version)"
            & $code --install-extension (Join-Path $here $ext.file) --force
            if ($LASTEXITCODE -ne 0) { throw "installing $($ext.file) failed" }
        }
    } else {
        Write-Host "VS Code $($release.vscode.version) for Release $($release.version) is already installed in $target"
    }

    # 6. The offline settings win over whatever was carried forward.
    $snippet = Get-Content -Raw -LiteralPath (Join-Path $here 'settings.json') | ConvertFrom-Json
    $platforms = New-Object PSObject
    $platforms | Add-Member -NotePropertyName $HostAlias -NotePropertyValue 'linux'
    $userDir = Join-Path $userData 'User'
    $settingsFile = Join-Path $userDir 'settings.json'
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null
    $settings = New-Object PSObject
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json
            if ($null -eq $settings) { $settings = New-Object PSObject }
        } catch {
            $aside = Join-Path $userDir 'settings.offline.json'
            $snippet | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $aside
            Write-Warning "Your settings.json has comments or isn't plain JSON, so it was left alone. Merge $aside into it by hand."
            $settings = $null
        }
    }
    if ($null -ne $settings) {
        # Hosts already in remotePlatform stay; this run's alias is added and wins.
        $merged = New-Object PSObject
        $existing = $settings.PSObject.Properties['remote.SSH.remotePlatform']
        if ($existing -and $existing.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $existing.Value.PSObject.Properties) { $merged | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        }
        $merged | Add-Member -Force -NotePropertyName $HostAlias -NotePropertyValue 'linux'
        $snippet | Add-Member -Force -NotePropertyName 'remote.SSH.remotePlatform' -NotePropertyValue $merged
        foreach ($p in $snippet.PSObject.Properties) {
            $settings | Add-Member -Force -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
        [IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 10), $utf8)
    }
} catch {
    if ($fresh -and (Test-Path -LiteralPath $target)) { Remove-Item -Recurse -Force -LiteralPath $target }
    throw
}

# 7. Last, the SSH config, once everything else has worked.
if ($newSsh -ne $sshText) {
    $sshDir = Split-Path -Parent $SshConfig
    if ($sshDir) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
    [IO.File]::WriteAllText($SshConfig, $newSsh, $utf8)
    Write-Host "Updated $SshConfig (Host $HostAlias -> ${GatewayHost}:$Port)"
} else {
    Write-Host "$SshConfig already has Host $HostAlias -> ${GatewayHost}:$Port"
}

Write-Host ''
Write-Host "Installed. Start VS Code with: $(Join-Path $target 'Code.exe')"
Write-Host "Then use Remote-SSH: Connect to Host... and pick $HostAlias."
