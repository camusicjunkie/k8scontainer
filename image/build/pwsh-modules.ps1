# pwsh-modules.ps1 LIST: installs each "Name ~> MAJOR" in LIST for all users, at
# the newest version inside that major, then prints "Name Version" for every
# installed module (dependencies included) for MANIFEST. The gallery's
# server-side version ranges miss four-part versions like PowerCLI's, so the
# major is filtered here and the exact version installed.
param([Parameter(Mandatory)][string]$List)
$ErrorActionPreference = 'Stop'

foreach ($line in Get-Content $List) {
    if ($line -match '^\s*(#|$)') { continue }
    $name, $op, $major = -split $line
    if ($op -ne '~>') { throw "expected 'Name ~> MAJOR', got: $line" }
    $version = Find-PSResource -Name $name -Version '*' |
        Where-Object { $_.Version.Major -eq [int]$major } |
        Sort-Object Version -Descending |
        Select-Object -First 1 -ExpandProperty Version
    if (-not $version) { throw "the gallery has no $name $major.x" }
    Install-PSResource -Name $name -Version "$version" -Scope AllUsers -TrustRepository -AcceptLicense -Quiet
}

Get-InstalledPSResource -Scope AllUsers |
    Sort-Object Name |
    ForEach-Object { '{0} {1}' -f $_.Name, $_.Version }
