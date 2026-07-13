#requires -Version 7.0
<#
.SYNOPSIS
    Codenzia fleet dependency-policy enforcement checker (fleet-dependency-plan.md §7).

.DESCRIPTION
    Recursively inspects committed composer.json files under -Root and rejects the
    unsafe in-house dependency patterns catalogued in the approved fleet dependency
    plan (§3.1 / §7):

      * unsafe codenzia/* constraints (@dev / *@dev / dev-main / dev-master /
        0.x-dev branch aliases, bare '*', unbounded ranges, dev/branch fallbacks
        after '||', and commit-hash references);
      * application manifests (type "project" or requiring laravel/framework) whose
        minimum-stability is not "stable";
      * a git-tracked composer.local.json (local overlays must stay gitignored);
      * a committed path-repository overlay inside a tracked composer.json;
      * a git-tracked auth.json (Satis credentials must never be committed).

    Two run modes:
      -Mode Audit    report every violation, always exit 0 (fleet survey).
      -Mode Enforce  exit 1 when any non-baselined violation is present (CI gate).

    An optional -Baseline file lists tolerated (pre-existing) violations so CI can
    block *new* violations while the fleet is migrated wave-by-wave.

.PARAMETER Root
    Directory to scan. In Enforce mode this is normally the calling repo ('.'); in
    fleet Audit mode it is the parent folder that holds every repo.

.PARAMETER Mode
    Audit (default) or Enforce.

.PARAMETER Baseline
    Path to a JSON file containing an array of tolerated-violation objects. Any of
    the fields file / dependency / constraint / rule may be present; the fields that
    are present must all match for a violation to be tolerated (absent fields act as
    wildcards). File paths are matched relative to -Root, forward-slashed.

.PARAMETER JsonReport
    Optional path. When set, the machine-readable JSON report is also written there.

.EXAMPLE
    ./scripts/check-inhouse-dependencies.ps1 -Root . -Mode Enforce

.EXAMPLE
    ./scripts/check-inhouse-dependencies.ps1 -Root C:\mh2\Projects\Codenzia\GitHub -Mode Audit
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Root = '.',

    [Parameter()]
    [ValidateSet('Audit', 'Enforce')]
    [string]$Mode = 'Audit',

    [Parameter()]
    [string]$Baseline,

    [Parameter()]
    [string]$JsonReport
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Directories that are never part of a committed dependency graph. ---------
$IgnoreDirNames = @(
    'vendor', 'node_modules', '_archive', 'old-ignored', 'zipped files',
    'dist', '.build', '.git'
)

function Resolve-RootPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Root path does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

# --- Filesystem walk that prunes ignored directories before descending. -------
function Get-CandidateFiles {
    param([string]$RootPath)

    $wanted = @('composer.json', 'composer.local.json', 'auth.json')
    $results = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($RootPath)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $leaf = Split-Path -Leaf $dir

        if ($IgnoreDirNames -contains $leaf) { continue }
        if ($leaf -like '_pre-fold-backup-*') { continue }
        $norm = ($dir -replace '\\', '/')
        if ($norm -match '/studio/demo-fleet(/|$)') { continue }

        try {
            $entries = [System.IO.Directory]::GetFileSystemEntries($dir)
        } catch {
            continue
        }

        foreach ($entry in $entries) {
            try {
                if ([System.IO.Directory]::Exists($entry)) {
                    $stack.Push($entry)
                } else {
                    $name = Split-Path -Leaf $entry
                    if ($wanted -contains $name) { $results.Add($entry) }
                }
            } catch {
                continue
            }
        }
    }

    return $results
}

# --- git tracked-ness (works across nested repos via -C). --------------------
function Test-GitTracked {
    param([string]$FilePath)
    $dir = Split-Path -Parent $FilePath
    $name = Split-Path -Leaf $FilePath
    if (-not $dir) { return $false }
    & git -C $dir ls-files --error-unmatch -- $name *> $null
    return ($LASTEXITCODE -eq 0)
}

# --- Classify a single codenzia/* version constraint. ------------------------
# Returns a human-readable rule reason, or $null when the constraint is safe.
function Get-ConstraintViolation {
    param([string]$Constraint)

    $c = "$Constraint".Trim()
    if ($c -eq '') { return 'empty constraint' }
    if ($c -eq '*') { return 'bare wildcard (*)' }
    if ($c -match '@dev\b') { return 'dev stability flag (@dev)' }
    if ($c -match '#[0-9a-fA-F]{7,40}\b') { return 'commit-hash reference' }
    if ($c -match '^[0-9a-fA-F]{40}$') { return 'raw commit hash' }

    foreach ($rawAlt in ($c -split '\|\|')) {
        $t = $rawAlt.Trim()
        if ($t -eq '') { continue }
        if ($t -eq '*') { return 'bare wildcard alternative (*)' }
        if ($t -match '(^|\s)dev-') { return "branch reference ($t)" }
        if ($t -match '-dev$') { return "branch alias ($t)" }
        # Lower-bound operator with no upper bound = unbounded range.
        if (($t -match '>=?') -and ($t -notmatch '<')) { return "unbounded range ($t)" }
    }

    return $null
}

# --- Enumerate name/value pairs from a require / require-dev object. ----------
function Get-RequirePairs {
    param($RequireObject)
    $pairs = @()
    if ($null -eq $RequireObject) { return $pairs }
    foreach ($prop in $RequireObject.PSObject.Properties) {
        $pairs += [pscustomobject]@{ Name = $prop.Name; Value = "$($prop.Value)" }
    }
    return $pairs
}

function Test-IsApplicationManifest {
    param($Json)
    if ($Json.PSObject.Properties.Name -contains 'type' -and $Json.type -eq 'project') {
        return $true
    }
    foreach ($section in @('require', 'require-dev')) {
        if ($Json.PSObject.Properties.Name -contains $section -and $null -ne $Json.$section) {
            if ($Json.$section.PSObject.Properties.Name -contains 'laravel/framework') {
                return $true
            }
        }
    }
    return $false
}

# -----------------------------------------------------------------------------
$RootPath = Resolve-RootPath -Path $Root
$violations = [System.Collections.Generic.List[object]]::new()

function Add-Violation {
    param(
        [string]$AbsFile,
        [string]$Dependency,
        [string]$Constraint,
        [string]$Rule
    )
    $rel = $AbsFile
    if ($AbsFile.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $AbsFile.Substring($RootPath.Length).TrimStart('\', '/')
    }
    $rel = $rel -replace '\\', '/'
    $script:violations.Add([pscustomobject]@{
        file       = $rel
        dependency = $Dependency
        constraint = $Constraint
        rule       = $Rule
    })
}

$candidateFiles = Get-CandidateFiles -RootPath $RootPath
$composerCount = 0

foreach ($file in $candidateFiles) {
    $name = Split-Path -Leaf $file

    if ($name -eq 'composer.local.json') {
        if (Test-GitTracked -FilePath $file) {
            Add-Violation -AbsFile $file -Dependency '(composer.local.json)' `
                -Constraint '(tracked)' -Rule 'tracked-composer-local'
        }
        continue
    }

    if ($name -eq 'auth.json') {
        if (Test-GitTracked -FilePath $file) {
            Add-Violation -AbsFile $file -Dependency '(auth.json)' `
                -Constraint '(tracked)' -Rule 'tracked-auth-json'
        }
        continue
    }

    # composer.json — only committed manifests are in scope.
    if (-not (Test-GitTracked -FilePath $file)) { continue }
    $composerCount++

    try {
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Could not parse ${file}: $($_.Exception.Message)"
        continue
    }
    if ($null -eq $json) { continue }

    # 1. Unsafe codenzia/* constraints across require + require-dev.
    foreach ($section in @('require', 'require-dev')) {
        if ($json.PSObject.Properties.Name -notcontains $section) { continue }
        foreach ($pair in (Get-RequirePairs -RequireObject $json.$section)) {
            if ($pair.Name -notlike 'codenzia/*') { continue }
            $reason = Get-ConstraintViolation -Constraint $pair.Value
            if ($reason) {
                Add-Violation -AbsFile $file -Dependency $pair.Name `
                    -Constraint $pair.Value -Rule "unsafe-constraint: $reason"
            }
        }
    }

    # 2. Non-stable minimum-stability on application manifests.
    if (Test-IsApplicationManifest -Json $json) {
        if ($json.PSObject.Properties.Name -contains 'minimum-stability') {
            $ms = "$($json.'minimum-stability')".Trim()
            if ($ms -ne '' -and $ms -ne 'stable') {
                Add-Violation -AbsFile $file -Dependency '(minimum-stability)' `
                    -Constraint $ms -Rule 'nonstable-minimum-stability'
            }
        }
    }

    # 3. Committed path-repository overlay.
    if ($json.PSObject.Properties.Name -contains 'repositories' -and $null -ne $json.repositories) {
        $repoEntries = @()
        if ($json.repositories -is [System.Array]) {
            $repoEntries = $json.repositories
        } else {
            foreach ($p in $json.repositories.PSObject.Properties) { $repoEntries += $p.Value }
        }
        foreach ($repo in $repoEntries) {
            if ($null -eq $repo) { continue }
            if (($repo.PSObject.Properties.Name -contains 'type') -and $repo.type -eq 'path') {
                $url = if ($repo.PSObject.Properties.Name -contains 'url') { "$($repo.url)" } else { '(path)' }
                Add-Violation -AbsFile $file -Dependency '(path repository)' `
                    -Constraint $url -Rule 'committed-path-repository'
            }
        }
    }
}

# --- Baseline tolerance. ------------------------------------------------------
$baselineEntries = @()
if ($Baseline) {
    if (-not (Test-Path -LiteralPath $Baseline)) {
        throw "Baseline file not found: $Baseline"
    }
    try {
        $parsed = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $parsed) {
            $baselineEntries = @($parsed)
        }
    } catch {
        throw "Could not parse baseline file ${Baseline}: $($_.Exception.Message)"
    }
}

function Test-Baselined {
    param($Violation)
    foreach ($b in $baselineEntries) {
        $fields = $b.PSObject.Properties.Name
        $match = $true
        foreach ($f in @('file', 'dependency', 'constraint', 'rule')) {
            if ($fields -contains $f -and $null -ne $b.$f) {
                if ("$($b.$f)" -ne "$($Violation.$f)") { $match = $false; break }
            }
        }
        if ($match) { return $true }
    }
    return $false
}

$active = [System.Collections.Generic.List[object]]::new()
$baselined = [System.Collections.Generic.List[object]]::new()
foreach ($v in $violations) {
    if ((Test-Baselined -Violation $v)) { $baselined.Add($v) } else { $active.Add($v) }
}

# --- Human-readable output. ---------------------------------------------------
Write-Host ''
Write-Host "Codenzia in-house dependency check  (mode: $Mode)" -ForegroundColor Cyan
Write-Host "Root: $RootPath"
Write-Host "Committed composer.json inspected: $composerCount"
Write-Host ''

if ($violations.Count -eq 0) {
    Write-Host 'No violations found.' -ForegroundColor Green
} else {
    $violations |
        Select-Object `
            @{ n = 'file'; e = { $_.file } },
            @{ n = 'dependency'; e = { $_.dependency } },
            @{ n = 'constraint'; e = { $_.constraint } },
            @{ n = 'rule'; e = { $_.rule } },
            @{ n = 'baselined'; e = { if (Test-Baselined -Violation $_) { 'yes' } else { '' } } } |
        Format-Table -AutoSize -Wrap |
        Out-String -Width 4096 |
        Write-Host
}

# --- Rule-level summary counts. ----------------------------------------------
Write-Host 'Summary by rule:' -ForegroundColor Cyan
$grouped = $violations |
    Group-Object { ($_.rule -split ':')[0].Trim() } |
    Sort-Object Count -Descending
foreach ($g in $grouped) {
    Write-Host ("  {0,-32} {1}" -f $g.Name, $g.Count)
}
Write-Host ''
Write-Host ("Totals: {0} violation(s), {1} active, {2} baselined." -f `
        $violations.Count, $active.Count, $baselined.Count)

# --- Machine-readable JSON. ---------------------------------------------------
$report = [pscustomobject]@{
    mode        = $Mode
    root        = ($RootPath -replace '\\', '/')
    inspected   = $composerCount
    total       = $violations.Count
    active      = $active.Count
    baselined   = $baselined.Count
    violations  = @($violations | ForEach-Object {
            [pscustomobject]@{
                file       = $_.file
                dependency = $_.dependency
                constraint = $_.constraint
                rule       = $_.rule
                baselined  = [bool](Test-Baselined -Violation $_)
            }
        })
}
$json = $report | ConvertTo-Json -Depth 6

if ($JsonReport) {
    $json | Set-Content -LiteralPath $JsonReport -Encoding utf8
    Write-Host "JSON report written to: $JsonReport"
}

Write-Host ''
Write-Host '---JSON---'
Write-Host $json

# --- Exit code. ---------------------------------------------------------------
if ($Mode -eq 'Enforce' -and $active.Count -gt 0) {
    Write-Host ''
    Write-Host ("Enforce mode: {0} active violation(s) — failing." -f $active.Count) -ForegroundColor Red
    exit 1
}

exit 0
