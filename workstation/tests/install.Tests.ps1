# Pester 5 tests for workstation/install.ps1. Everything happens under
# $TestDrive: a fake Release payload (the "pack"), a fake Destination and a fake
# SSH config. Nothing touches the real profile or ~/.ssh, and nothing is
# downloaded. Run under both editions:
#   pwsh -NoProfile -c "Invoke-Pester workstation/tests"
#   powershell -NoProfile -c "Invoke-Pester workstation/tests"
BeforeAll {
    $script:Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:Commit = '0123456789abcdef0123456789abcdef01234567'

    function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

    # Write-Sums: (re)writes SHA256SUMS in sha256sum format, over every file but itself and install.ps1.
    function Write-Sums([string]$Pack) {
        $lines = Get-ChildItem -LiteralPath $Pack -File |
            Where-Object { $_.Name -notin 'SHA256SUMS', 'install.ps1' } |
            ForEach-Object { '{0}  {1}' -f (Get-Sha $_.FullName), $_.Name }
        Set-Content -Encoding ASCII -Path (Join-Path $Pack 'SHA256SUMS') -Value $lines
    }

    # New-Pack: a fake Release payload in its own folder; returns the folder.
    function New-Pack {
        param([string]$Name = 'pack', [string]$EnvCommit = $script:Commit)
        $pack = Join-Path $TestDrive $Name
        $stage = Join-Path $TestDrive "$Name-stage"
        New-Item -ItemType Directory -Force -Path $pack, (Join-Path $stage 'bin') | Out-Null
        # A fake portable VS Code: code.cmd logs its arguments next to Code.exe.
        Set-Content -Encoding ASCII -Path (Join-Path $stage 'bin\code.cmd') -Value '@echo %* >> "%~dp0..\calls.log"'
        Set-Content -Encoding ASCII -Path (Join-Path $stage 'Code.exe') -Value 'fake'
        $zip = "VSCode-win32-x64-$($script:Commit).zip"
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $pack $zip)
        Set-Content -Encoding ASCII -Path (Join-Path $pack 'ms-vscode-remote.remote-ssh-1.2.3.vsix') -Value 'vsix bytes'
        Copy-Item (Join-Path $script:Repo 'workstation\settings.json') $pack
        Copy-Item (Join-Path $script:Repo 'workstation\install.ps1') $pack -ErrorAction SilentlyContinue
        $zipSha = Get-Sha (Join-Path $pack $zip)
        Set-Content -Encoding ASCII -Path (Join-Path $pack 'vscode.env') -Value @(
            'VSCODE_VERSION=1.140.0', "VSCODE_COMMIT=$EnvCommit", "VSCODE_WIN_SHA256=$zipSha", 'VSCODE_REMOTE_SSH_VERSION=1.2.3')
        $rel = @{
            version = '2026.11.1'
            vscode = @{ version = '1.140.0'; commit = $script:Commit; zip = $zip }
            extensions = @(@{ id = 'ms-vscode-remote.remote-ssh'; version = '1.2.3'; file = 'ms-vscode-remote.remote-ssh-1.2.3.vsix' })
        }
        $rel | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII -Path (Join-Path $pack 'release.json')
        Write-Sums $pack
        $pack
    }

    function Invoke-Install {
        param([string]$Pack, [hashtable]$Arg = @{})
        $a = @{
            Destination = Join-Path $TestDrive 'dest'
            SshConfig   = Join-Path $TestDrive 'ssh\config'
            GatewayHost = 'gw.example.test'
            Port        = 2201
        }
        foreach ($k in $Arg.Keys) { $a[$k] = $Arg[$k] }
        & (Join-Path $Pack 'install.ps1') @a 6>$null
    }

    function Get-Target([string]$Rel = '2026.11.1') { Join-Path $TestDrive "dest\VSCode-1.140.0-$Rel" }
    function Get-Settings { Get-Content -Raw -LiteralPath (Join-Path (Get-Target) 'data\user-data\User\settings.json') | ConvertFrom-Json }
}

Describe 'install.ps1' {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:Pack = New-Pack
    }

    Context 'a good Release' {
        It 'unzips a portable VS Code into a per-Release folder' {
            Invoke-Install $Pack
            Test-Path (Join-Path (Get-Target) 'Code.exe') | Should -BeTrue
            Test-Path (Join-Path (Get-Target) 'data\tmp') -PathType Container | Should -BeTrue
        }
        It 'installs only the Remote-SSH extension' {
            Invoke-Install $Pack
            $calls = @(Get-Content (Join-Path (Get-Target) 'calls.log'))
            $calls.Count | Should -Be 1
            $calls[0] | Should -Match 'install-extension .*ms-vscode-remote\.remote-ssh-1\.2\.3\.vsix'
            ($calls -join ' ') | Should -Not -Match 'containers|kubernetes|vsphere'
        }
        It 'writes the offline settings and Remote-SSH platform for the host alias, with nothing for Dev Containers' {
            Invoke-Install $Pack
            $s = Get-Settings
            $s.'update.mode' | Should -Be 'none'
            $s.'telemetry.telemetryLevel' | Should -Be 'off'
            $s.'remote.SSH.localServerDownload' | Should -Be 'off'
            $s.'remote.SSH.remotePlatform'.devcontainer | Should -Be 'linux'
            $s.PSObject.Properties.Name | Where-Object { $_ -like 'dev.containers.*' -or $_ -eq 'remote.serverDownloadFolder' } | Should -BeNullOrEmpty
        }
        It 'carries data\user-data forward with -From, offline settings winning' {
            Invoke-Install $Pack
            $old = Get-Target
            Set-Content (Join-Path $old 'data\user-data\User\keybindings.json') '[]'
            $sf = Join-Path $old 'data\user-data\User\settings.json'
            $s = Get-Content -Raw $sf | ConvertFrom-Json
            $s | Add-Member -Force -NotePropertyName 'editor.fontSize' -NotePropertyValue 15
            $s | Add-Member -Force -NotePropertyName 'update.mode' -NotePropertyValue 'default'
            $s | ConvertTo-Json -Depth 10 | Set-Content $sf
            $pack2 = New-Pack 'pack2'
            $rel = Get-Content -Raw (Join-Path $pack2 'release.json') | ConvertFrom-Json
            $rel.version = '2026.12.1'
            $rel | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII (Join-Path $pack2 'release.json')
            Write-Sums $pack2
            Invoke-Install $pack2 @{ From = $old }
            $new = Join-Path (Get-Target '2026.12.1') 'data\user-data\User'
            Test-Path (Join-Path $new 'keybindings.json') | Should -BeTrue
            $n = Get-Content -Raw (Join-Path $new 'settings.json') | ConvertFrom-Json
            $n.'editor.fontSize' | Should -Be 15
            $n.'update.mode' | Should -Be 'none'
        }
        It 'rerunning for the same Release keeps VS Code and does not reinstall' {
            Invoke-Install $Pack
            { Invoke-Install $Pack } | Should -Not -Throw
            @(Get-Content (Join-Path (Get-Target) 'calls.log')).Count | Should -Be 1
        }
    }

    Context 'verification before anything is written' {
        It 'refuses a tampered file and writes nothing' {
            Add-Content (Join-Path $Pack 'ms-vscode-remote.remote-ssh-1.2.3.vsix') 'tampered'
            { Invoke-Install $Pack } | Should -Throw '*mismatch*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
            Test-Path (Join-Path $TestDrive 'ssh') | Should -BeFalse
        }
        It 'refuses a missing file' {
            Remove-Item (Join-Path $Pack 'settings.json')
            { Invoke-Install $Pack } | Should -Throw '*missing*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'refuses a file the release names but SHA256SUMS does not cover' {
            $f = Join-Path $Pack 'SHA256SUMS'
            Set-Content -Encoding ASCII $f (Get-Content $f | Where-Object { $_ -notmatch '\.vsix' })
            { Invoke-Install $Pack } | Should -Throw '*not covered*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'refuses a SHA256SUMS path that climbs out of the pack' {
            Add-Content (Join-Path $Pack 'SHA256SUMS') ('{0}  ..\outside.txt' -f ('0' * 64))
            { Invoke-Install $Pack } | Should -Throw
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'refuses a portable VS Code whose commit differs from the pin baked into the image' {
            $p = New-Pack 'other' -EnvCommit ('f' * 40)
            { Invoke-Install $p } | Should -Throw '*commit*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'refuses a VS Code zip that is not the pinned one' {
            $e = Join-Path $Pack 'vscode.env'
            (Get-Content $e) -replace 'VSCODE_WIN_SHA256=.*', ('VSCODE_WIN_SHA256=' + ('a' * 64)) | Set-Content -Encoding ASCII $e
            Write-Sums $Pack
            { Invoke-Install $Pack } | Should -Throw '*pinned*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'refuses a Release that names an extension other than Remote-SSH' {
            $rel = Get-Content -Raw (Join-Path $Pack 'release.json') | ConvertFrom-Json
            $rel.extensions[0].id = 'ms-vscode-remote.remote-containers'
            $rel | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII (Join-Path $Pack 'release.json')
            Write-Sums $Pack
            { Invoke-Install $Pack } | Should -Throw '*Remote-SSH*'
        }
        It 'refuses a Remote-SSH version that is not the one pinned in vscode.env, naming both' {
            $e = Join-Path $Pack 'vscode.env'
            (Get-Content $e) -replace 'VSCODE_REMOTE_SSH_VERSION=.*', 'VSCODE_REMOTE_SSH_VERSION=1.2.4' | Set-Content -Encoding ASCII $e
            Write-Sums $Pack
            { Invoke-Install $Pack } | Should -Throw '*1.2.3*1.2.4*'
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
            Test-Path (Join-Path $TestDrive 'ssh') | Should -BeFalse
        }
        It 'rejects a bad port' {
            { Invoke-Install $Pack @{ Port = 70000 } } | Should -Throw
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'removes the half-installed folder if the extension install fails' {
            $zipPath = Join-Path $Pack (Get-ChildItem $Pack -Filter *.zip).Name
            Remove-Item $zipPath
            $stage = Join-Path $TestDrive 'badstage'
            New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin') | Out-Null
            Set-Content -Encoding ASCII (Join-Path $stage 'bin\code.cmd') '@exit /b 3'
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath
            $e = Join-Path $Pack 'vscode.env'
            (Get-Content $e) -replace 'VSCODE_WIN_SHA256=.*', ('VSCODE_WIN_SHA256=' + (Get-Sha $zipPath)) | Set-Content -Encoding ASCII $e
            Write-Sums $Pack
            { Invoke-Install $Pack } | Should -Throw
            Test-Path (Get-Target) | Should -BeFalse
            Test-Path (Join-Path $TestDrive 'ssh\config') | Should -BeFalse
        }
    }

    Context 'the SSH config' {
        BeforeEach { $script:Cfg = Join-Path $TestDrive 'ssh\config' }

        It 'creates it with the Gateway host, the admin port and the image user' {
            Invoke-Install $Pack
            $t = Get-Content -Raw $Cfg
            $t | Should -Match '(?m)^Host devcontainer\r?$'
            $t | Should -Match '(?m)^\s+HostName gw\.example\.test\r?$'
            $t | Should -Match '(?m)^\s+Port 2201\r?$'
            $t | Should -Match '(?m)^\s+User dev\r?$'
            $t | Should -Match '(?m)^\s+ForwardAgent yes\r?$'
        }
        It 'writes no byte order mark' {
            Invoke-Install $Pack
            $b = [IO.File]::ReadAllBytes($Cfg)
            ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) | Should -BeFalse
        }
        It 'keeps everything already in the file' {
            New-Item -ItemType Directory -Force -Path (Split-Path $Cfg) | Out-Null
            $orig = "# mine`nHost github.com`n  User git`n"
            [IO.File]::WriteAllText($Cfg, $orig)
            Invoke-Install $Pack
            (Get-Content -Raw $Cfg).StartsWith($orig) | Should -BeTrue
        }
        It 'is idempotent: a second run leaves the file byte-identical' {
            Invoke-Install $Pack
            $first = [IO.File]::ReadAllBytes($Cfg)
            Invoke-Install $Pack
            [IO.File]::ReadAllBytes($Cfg) | Should -Be $first
        }
        It 'updates only its own block when the port changes' {
            New-Item -ItemType Directory -Force -Path (Split-Path $Cfg) | Out-Null
            [IO.File]::WriteAllText($Cfg, "Host other`n  Port 22`n")
            Invoke-Install $Pack
            Invoke-Install $Pack @{ Port = 2305 }
            $t = Get-Content -Raw $Cfg
            ([regex]::Matches($t, '(?m)^Host devcontainer\r?$')).Count | Should -Be 1
            $t | Should -Match 'Port 2305'
            $t | Should -Not -Match 'Port 2201'
            $t | Should -Match '(?m)^Host other\r?\n  Port 22'
        }
        It 'refuses to touch a hand-written Host of the same name, and writes nothing' {
            New-Item -ItemType Directory -Force -Path (Split-Path $Cfg) | Out-Null
            $orig = "Host devcontainer`n  HostName mine`n"
            [IO.File]::WriteAllText($Cfg, $orig)
            { Invoke-Install $Pack } | Should -Throw '*HostAlias*'
            Get-Content -Raw $Cfg | Should -Be $orig
            Test-Path (Join-Path $TestDrive 'dest') | Should -BeFalse
        }
        It 'honours -HostAlias and -User' {
            Invoke-Install $Pack @{ HostAlias = 'dc-john'; User = 'admin' }
            $t = Get-Content -Raw $Cfg
            $t | Should -Match '(?m)^Host dc-john\r?$'
            $t | Should -Match '(?m)^\s+User admin\r?$'
            (Get-Settings).'remote.SSH.remotePlatform'.'dc-john' | Should -Be 'linux'
        }
    }
}

Describe 'the Workstation sources' {
    It 'the settings snippet has no Dev Containers or serverDownloadFolder entries and keeps the offline ones' {
        $s = Get-Content -Raw (Join-Path $Repo 'workstation\settings.json') | ConvertFrom-Json
        $names = $s.PSObject.Properties.Name
        $names | Where-Object { $_ -like 'dev.containers.*' -or $_ -eq 'remote.serverDownloadFolder' } | Should -BeNullOrEmpty
        foreach ($k in 'remote.SSH.path', 'remote.SSH.localServerDownload', 'update.mode', 'extensions.autoUpdate',
            'telemetry.telemetryLevel', 'extensions.ignoreRecommendations', 'json.schemaDownload.enable') {
            $names | Should -Contain $k
        }
    }
    It 'the installer makes no network calls' {
        $src = Get-Content -Raw (Join-Path $Repo 'workstation\install.ps1')
        $src | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|WebClient|\bcurl\b|\bkubectl\b'
    }
}
