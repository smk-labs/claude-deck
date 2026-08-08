# claude-deck.ps1: run many Claude Desktop accounts side by side on one Windows PC.
#
# Windows twin of claude-deck.sh. Teaches the Windows Claude Desktop app a
# --profile=NAME argument. Each profile gets its own Electron userData dir,
# so you can be logged into several accounts at once, plus the same local
# usage dashboard.
#
# Works on stock Windows PowerShell 5.1 (preinstalled on Windows 10/11) and
# PowerShell 7+. Auto-installs a local Node if you don't have one. Needs NO
# admin rights: the Claude app lives in %LOCALAPPDATA%, which you own.
#
# Usage:
#   .\claude-deck.ps1 patch [--force] [--verify-launch]  # apply (idempotent)
#   .\claude-deck.ps1 revert            # restore original app.asar
#   .\claude-deck.ps1 status            # show patch state, backup info
#   .\claude-deck.ps1 open [name] [org-uuid]  # launch a profile (no name =
#                                             # default), optionally switched
#                                             # to a specific org first
#   .\claude-deck.ps1 list              # list known profiles
#   .\claude-deck.ps1 dash [port]       # run the local usage dashboard
#   .\claude-deck.ps1 doctor            # repair session-index links
#   .\claude-deck.ps1 install           # copy to ~\.claude-deck\bin + profile alias
#   .\claude-deck.ps1 uninstall         # remove the alias only
#   .\claude-deck.ps1 help
#
# Safety model (mirrors the macOS script):
#   1. Preflight gate: nothing is modified unless the asar has the expected
#      entry point AND claude.exe does not enforce asar integrity (Electron's
#      EnableEmbeddedAsarIntegrityValidation fuse). On Windows that hash is
#      baked into the exe itself and cannot be safely rewritten, so if the
#      fuse is on we refuse outright instead of producing an app that dies
#      at startup with a "corrupted" dialog.
#   2. Pristine backup of app.asar (+ app.asar.unpacked) before any change.
#   3. Rollback on any failure between first mutation and post-validation.
#   4. Post-validation: marker present, unpacked native-module set identical
#      to the original (losing it is what bricks Electron apps on repack).
#   Nothing here signs or re-signs anything: Windows does not gate app launch
#   on Authenticode, and we never modify claude.exe, only the app.asar data.

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# argv scan: flags shared by several subcommands
# ---------------------------------------------------------------------------

$script:Force = $false
$script:VerifyLaunch = $false
$script:Fix = $false
$script:AppOverride = $null
if ($env:CLAUDE_DECK_APP) { $script:AppOverride = $env:CLAUDE_DECK_APP }
$Positional = @()
for ($i = 0; $i -lt $Rest.Count; $i++) {
  switch -Regex ($Rest[$i]) {
    '^(--force|-Force)$'                { $script:Force = $true }
    '^(--fix|-Fix)$'                    { $script:Fix = $true }
    '^(--verify-launch|-VerifyLaunch)$' { $script:VerifyLaunch = $true }
    '^(--app|-App)$'                    { $i++; $script:AppOverride = $Rest[$i] }
    '^--app=(.+)$'                      { $script:AppOverride = $Matches[1] }
    default                             { $Positional += $Rest[$i] }
  }
}

# ---------------------------------------------------------------------------
# paths and constants
# ---------------------------------------------------------------------------

$StateDir   = Join-Path $env:USERPROFILE '.claude-deck'
$ClaudeRoot = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$Marker      = 'claude-deck.js'   # presence in asar means "patched"
$OtherMarker = 'rtl-fix.js'       # marker used by the sibling claude-rtl patch
$ProfilesDir = Join-Path $StateDir 'profiles'
# MSIX write-virtualization escape (2026-07-21): Windows virtualizes the
# packaged app's AppData writes into %LOCALAPPDATA%\Packages\Claude_...\
# LocalCache, forking the app's view of every profile file from the real
# one (session saves ENOENT'd on new org dirs, archives silently
# reverted). Data dirs therefore live OUTSIDE the virtualized known
# folders, at ~\ClaudeProfiles (default instance included, as
# ~\ClaudeProfiles\default). The migration script creates that root;
# until it exists every path stays legacy, so nothing changes behavior
# before the one-time migration has run.
$EscapedDataRoot = Join-Path $env:USERPROFILE 'ClaudeProfiles'
if (Test-Path -LiteralPath $EscapedDataRoot) {
  $ProfilesUserDataRoot = $EscapedDataRoot
  $DefaultUserDataDir   = Join-Path $EscapedDataRoot 'default'
} else {
  $ProfilesUserDataRoot = Join-Path $env:APPDATA 'Claude Profiles'
  $DefaultUserDataDir   = Join-Path $env:APPDATA 'Claude'
}
$SharedSessionsDir = Join-Path $DefaultUserDataDir 'claude-code-sessions'
$LocalNodeVersion = '22.12.0'   # 22 LTS; >=22.5 gives node:sqlite for the org-switch cookie write
$ScriptDir = $PSScriptRoot
$CanonicalDir  = Join-Path $StateDir 'bin'
$CanonicalPath = Join-Path $CanonicalDir 'claude-deck.ps1'

function Step($m) { Write-Host "-> $m" }
function Note($m) { Write-Host $m -ForegroundColor DarkGray }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# Every JSON file this script writes is read back by Claude (and by node) with
# JSON.parse, which rejects a leading BOM outright. `Set-Content -Encoding
# UTF8` cannot be used for them: it is BOM-less on PowerShell 7 but always
# BOM-ful on Windows PowerShell 5.1, so the same line silently produces an
# unparseable file depending only on which host ran it.
function Set-JsonFile($Path, $Text) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ($Text.TrimEnd("`r", "`n") + "`r`n"), $utf8NoBom)
}

# ---------------------------------------------------------------------------
# app resolution
# ---------------------------------------------------------------------------

# Claude Desktop on Windows now ships as an MSIX package (under
# C:\Program Files\WindowsApps\Claude_<ver>_x64__<hash>\app\). MSIX cannot
# and must not be patched, and it does not need to be: the app has a
# built-in CLAUDE_USER_DATA_DIR env hook (an unconditional block in
# .vite/build/index.pre.js calls app.setPath('userData', dir) right before
# the single-instance lock), so `open` launches profiles purely via that
# env var. Verified live: a second instance runs side by side with its own
# login. Older machines may still carry the legacy Squirrel install
# (%LOCALAPPDATA%\AnthropicClaude\app-<version>\); we resolve MSIX first
# and fall back to Squirrel, and only Squirrel targets are patchable.
#
# Resolution is lazy (not at script start) so commands that don't touch the
# app bundle (install, uninstall, help, dash, list) still work on a machine
# where Claude isn't installed yet.
$script:AppDir = $null
$script:Res = $null
$script:Asar = $null
$script:Unpacked = $null
$script:Exe = $null
$script:IsMsix = $false
$IsRealInstall = (-not $script:AppOverride)

function Find-AppDir {
  if ($script:AppOverride) {
    $dir = $script:AppOverride
    if (-not (Test-Path (Join-Path (Join-Path $dir 'resources') 'app.asar'))) { return $null }
    return (Resolve-Path $dir).Path
  }
  # MSIX first: the packaged app dir is <InstallLocation>\app, holding
  # Claude.exe and resources\app.asar in the same relative layout as a
  # Squirrel app-<version> dir, so everything downstream just works.
  try {
    $pkg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue
    if ($pkg -and $pkg.InstallLocation) {
      $appDir = Join-Path $pkg.InstallLocation 'app'
      if (Test-Path (Join-Path $appDir 'Claude.exe')) {
        $script:IsMsix = $true
        return $appDir
      }
    }
  } catch {}
  if (-not (Test-Path $ClaudeRoot)) { return $null }
  $dirs = @(Get-ChildItem -Path $ClaudeRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path (Join-Path $_.FullName 'resources') 'app.asar') })
  if ($dirs.Count -eq 0) { return $null }
  $sorted = $dirs | Sort-Object -Property @{ Expression = {
    try { [version]($_.Name.Substring(4)) } catch { [version]'0.0' }
  } }, LastWriteTime
  return ($sorted | Select-Object -Last 1).FullName
}

function Resolve-AppPaths {
  if ($script:AppDir) { return $true }
  $found = Find-AppDir
  if (-not $found) { return $false }
  $script:AppDir   = $found
  $script:Res      = Join-Path $found 'resources'
  $script:Asar     = Join-Path $script:Res 'app.asar'
  $script:Unpacked = Join-Path $script:Res 'app.asar.unpacked'
  $script:Exe      = Join-Path $found 'claude.exe'
  return $true
}

function Require-AppPaths {
  if (-not (Resolve-AppPaths)) {
    if ($script:AppOverride) {
      Die "--app target '$($script:AppOverride)' has no resources\app.asar."
    }
    Die "Claude Desktop not found (no MSIX package named Claude, and no Squirrel app-* directory at $ClaudeRoot). Install it from claude.ai/download first."
  }
}

# Backups for an alternate --app target live in their own tree so a smoke
# test against a scratch copy can never read from or clobber the real backup.
$BackupDir = Join-Path $StateDir 'backup'
if (-not $IsRealInstall) { $BackupDir = Join-Path $StateDir 'backup-alt' }
$BackupAsar     = Join-Path $BackupDir 'app.asar.orig'
$BackupUnpacked = Join-Path $BackupDir 'app.asar.unpacked.orig'
$BackupVersion  = Join-Path $BackupDir 'claude-version.txt'

function Get-ClaudeVersion {
  if ($script:IsMsix) {
    # MSIX: the version lives in the package name, one level above app\.
    $pkgDir = Split-Path (Split-Path $AppDir -Parent) -Leaf
    if ($pkgDir -match '^Claude_([0-9.]+)_') { return $Matches[1] }
    return '?'
  }
  $name = Split-Path $AppDir -Leaf
  if ($name -match '^app-(.+)$') { return $Matches[1] }
  return '?'
}

# ---------------------------------------------------------------------------
# Node + @electron/asar bootstrap
# ---------------------------------------------------------------------------

function Ensure-Node {
  if (Get-Variable -Name NodeBin -Scope Script -ErrorAction SilentlyContinue) { return }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) {
    $v = 0
    try {
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try { $v = [int](& $node.Source -p 'parseInt(process.versions.node)' 2>$null) } finally { $ErrorActionPreference = $prev }
    } catch { $v = 0 }
    if ($v -ge 18) {
      $script:NodeBin = $node.Source
      $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
      if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
      if ($npm) {
        $script:NpmBin = $npm.Source
        return
      }
    }
  }
  # Bootstrap a local Node into $StateDir\node (one-time, ~30MB), never
  # system-wide.
  $archId = 'win-x64'
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $archId = 'win-arm64' }
  $nodeRoot = Join-Path $StateDir 'node'
  $nodeDir = Join-Path $nodeRoot "node-v$LocalNodeVersion-$archId"
  if (-not (Test-Path (Join-Path $nodeDir 'node.exe'))) {
    Step "No usable Node found. Bootstrapping local Node $LocalNodeVersion (~30 MB, one-time)..."
    New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null
    $zip = Join-Path $env:TEMP 'claude-deck-node.zip'
    $url = "https://nodejs.org/dist/v$LocalNodeVersion/node-v$LocalNodeVersion-$archId.zip"
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
      Expand-Archive -Path $zip -DestinationPath $nodeRoot -Force
    } catch {
      Die "Failed to download Node from $url (check your network). $_"
    } finally {
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
  }
  $script:NodeBin = Join-Path $nodeDir 'node.exe'
  $script:NpmBin  = Join-Path $nodeDir 'npm.cmd'
}

# Install @electron/asar locally once. Pinned to ^3: v4+ is ESM-only and
# renamed the bin, which breaks node bin/asar.js invocation (same pin as the
# macOS script). The pin lives in package.json (not on the npm command line)
# because cmd.exe would eat the ^ in '@electron/asar@^3'.
function Ensure-AsarTool {
  Ensure-Node
  $script:ToolDir = Join-Path $StateDir 'tool'
  $asarJs = [IO.Path]::Combine($ToolDir, 'node_modules', '@electron', 'asar', 'bin', 'asar.js')
  if (-not (Test-Path $asarJs)) {
    if (Test-Path $ToolDir) { Remove-Item -Recurse -Force $ToolDir }
    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
    Set-Content -Path (Join-Path $ToolDir 'package.json') -Encoding Ascii -Value `
      '{"name":"claude-deck-tool","private":true,"dependencies":{"@electron/asar":"^3"}}'
    Step 'Installing @electron/asar (pinned to ^3)...'
    Push-Location $ToolDir
    try {
      & $script:NpmBin install --no-audit --no-fund --loglevel=error | Out-Null
    } finally { Pop-Location }
    if (-not (Test-Path $asarJs)) { Die "Failed to install @electron/asar into $ToolDir" }
  }
  $script:AsarJs = $asarJs
  Write-HelperScripts
}

# Small Node helper scripts written into the tool dir. Kept as files (not
# `node -e` one-liners) because Windows PowerShell 5.1 mangles multi-line
# strings passed as native-command arguments.
function Write-HelperScripts {
  $lib = Join-Path $ToolDir 'node_modules'

  # Prints every path in an asar's header marked unpacked:true, one per line,
  # sorted, forward slashes. Same logic as the macOS asar_unpacked_list.
  Set-Content -Encoding Ascii -Path (Join-Path $ToolDir 'unpacked-list.js') -Value @'
const asar = require('@electron/asar');
const { header } = asar.getRawHeader(process.argv[2]);
function walk(node, prefix, out) {
  if (!node.files) return;
  for (const name of Object.keys(node.files)) {
    const entry = node.files[name];
    const p = prefix ? prefix + '/' + name : name;
    if (entry.files) walk(entry, p, out);
    else if (entry.unpacked) out.push(p);
  }
}
const out = [];
walk(header, '', out);
out.sort();
process.stdout.write(out.join('\n'));
if (out.length) process.stdout.write('\n');
'@

  # Packs argv[2] (extracted tree) into argv[3] with argv[4] as the unpack
  # glob. @electron/asar matches `unpack` against each file's BASENAME
  # (minimatch with matchBase), so callers pass basename globs.
  Set-Content -Encoding Ascii -Path (Join-Path $ToolDir 'pack-unpacked.js') -Value @'
const asar = require('@electron/asar');
asar.createPackageWithOptions(process.argv[2], process.argv[3], { unpack: process.argv[4] })
  .then(() => process.exit(0))
  .catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
'@

  # Reads Electron's fuse wire out of argv[2] (claude.exe) and prints either
  # "no-sentinel" or "<version>:<embeddedAsarIntegrityValidation state>".
  # Wire layout (@electron/fuses): 32-byte sentinel, then 1 version byte,
  # then 1 length byte, then one state byte per fuse ('0' off, '1' on,
  # 'r' removed). EnableEmbeddedAsarIntegrityValidation is fuse #5 (1-based),
  # so its state byte sits at sentinelEnd + 2 + 4.
  Set-Content -Encoding Ascii -Path (Join-Path $ToolDir 'fuse-check.js') -Value @'
const fs = require('fs');
const buf = fs.readFileSync(process.argv[2]);
const SENTINEL = 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX';
const idx = buf.indexOf(SENTINEL);
if (idx < 0) { console.log('no-sentinel'); process.exit(0); }
const base = idx + SENTINEL.length;
// Version and length are RAW bytes (0x01, not ASCII '1'); only the fuse
// state bytes are ASCII. Reading the version as a char produced an
// invisible control character and a baffling "unknown version ('')".
const version = buf[base];
const length = buf[base + 1];
let state = '?';
if (length >= 5) state = String.fromCharCode(buf[base + 2 + 4]);
console.log(version + ':' + state);
'@

  if (-not (Test-Path $lib)) { Die "tool dir is missing node_modules; re-run after deleting $ToolDir" }
}

function Invoke-Asar {
  # asar.js resolves its own requires; cwd only matters for extract-file,
  # which callers handle themselves with Push-Location.
  & $script:NodeBin $script:AsarJs @args
}

# Runs a native command with stderr silenced. Windows PowerShell 5.1 wraps
# redirected native stderr lines as ErrorRecords, which under
# $ErrorActionPreference = 'Stop' turns harmless stderr chatter into a
# terminating NativeCommandError. Relax the preference around exactly these
# calls; $LASTEXITCODE still reflects the command's real exit code after.
function Invoke-NativeQuiet([scriptblock]$block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $block 2>$null } finally { $ErrorActionPreference = $prev }
}

function Get-AsarList($target) {
  $out = Invoke-NativeQuiet { & $script:NodeBin $script:AsarJs list $target }
  if ($LASTEXITCODE -ne 0) { return @() }
  # asar list prints platform separators; normalize to forward slashes.
  return @($out | ForEach-Object { "$_" -replace '\\', '/' })
}

function Get-UnpackedList($target) {
  $out = & $script:NodeBin (Join-Path $ToolDir 'unpacked-list.js') $target
  if ($LASTEXITCODE -ne 0) { Die "Could not read the unpacked-file list from $target" }
  return @($out | Where-Object { $_ })
}

function Lists-Equal([string[]]$a, [string[]]$b) {
  return (($a -join "`n") -eq ($b -join "`n"))
}

function Is-Patched {
  return [bool]((Get-AsarList $Asar) | Where-Object { $_ -like "*/$Marker" })
}

function Has-OtherPatch {
  return [bool]((Get-AsarList $Asar) | Where-Object { $_ -like "*/$OtherMarker" })
}

# ---------------------------------------------------------------------------
# process handling
# ---------------------------------------------------------------------------

# Main Claude processes only: on Windows every Electron child (renderer, GPU,
# utility) is also claude.exe, but children always carry --type=<something>
# and never --profile=. Filtering out --type= leaves exactly the main
# process per running instance. The executable-path filter matters too: the
# Claude Code CLI also runs as claude.exe (no --type=, no --profile=) and
# would otherwise read as "default profile running" forever.
function Get-ClaudeMainProcesses {
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
        $_.ExecutablePath -and (
          $_.ExecutablePath -like '*\WindowsApps\Claude_*' -or
          $_.ExecutablePath -like '*\AnthropicClaude\*'
        )
      })
  } catch { return @() }
}

function Profile-Running($name) {
  $procs = Get-ClaudeMainProcesses
  if ($name -eq 'default') {
    return [bool]($procs | Where-Object { $_.CommandLine -notmatch '--profile=' })
  }
  $rx = '--profile=' + [regex]::Escape($name) + '("|\s|$)'
  return [bool]($procs | Where-Object { $_.CommandLine -match $rx })
}

# SSH connections ("Add SSH connection" in the app) are stored per userData at
# <profile>\ssh_configs.json, so a connection added under one profile is
# invisible under every other one. Every profile shares ~/.claude already, and
# a remote box you can reach is a property of the machine, not of the account,
# so this file should be shared too.
#
# Merge, don't link: the app rewrites this file wholesale, which would break a
# hardlink and silently fork the profiles again. Instead we union every
# profile's file at launch and write the union back. Whatever a profile added
# last session propagates to the rest on the next launch, from either
# direction, with no daemon.
#
# Tradeoff, deliberate: union means a deleted connection comes back as long as
# any other profile still lists it. Removing one for good means removing it
# from each profile, or deleting the entry from every ssh_configs.json at once.
#
# Running profiles are skipped as write targets: the live app owns its copy in
# memory and would overwrite us on quit. They still contribute their entries.
# Never fatal: any failure here just means profiles stay unsynced.
function Sync-SshConfigs($launching) {
  try {
    if (-not (Test-Path -LiteralPath $ProfilesUserDataRoot)) { return }

    $dirs = @()
    if ($DefaultUserDataDir -ne (Join-Path $ProfilesUserDataRoot 'default')) {
      $dirs += ,@{ Name = 'default'; Dir = $DefaultUserDataDir }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $ProfilesUserDataRoot -Directory -ErrorAction SilentlyContinue)) {
      $dirs += ,@{ Name = $d.Name; Dir = $d.FullName }
    }
    if ($dirs.Count -lt 2) { return }

    # Union pass. Keyed by id when the app gave one, else by host+name, so the
    # same connection saved separately under two profiles collapses to one.
    $byKey = [ordered]@{}
    $hosts = [ordered]@{}
    foreach ($p in $dirs) {
      $f = Join-Path $p.Dir 'ssh_configs.json'
      if (-not (Test-Path -LiteralPath $f)) { continue }
      $data = $null
      try { $data = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
      if (-not $data) { continue }
      foreach ($c in @($data.configs)) {
        if (-not $c) { continue }
        $key = if ($c.id) { "id:$($c.id)" } else { "hn:$($c.sshHost)|$($c.name)" }
        if (-not $byKey.Contains($key)) { $byKey[$key] = $c }
      }
      foreach ($h in @($data.trustedHosts)) {
        if ($h -and -not $hosts.Contains($h)) { $hosts[$h] = $true }
      }
    }
    if ($byKey.Count -eq 0) { return }

    $merged = [pscustomobject]@{
      configs      = @($byKey.Values)
      trustedHosts = @($hosts.Keys)
    }
    $json = $merged | ConvertTo-Json -Depth 6

    $wrote = 0
    foreach ($p in $dirs) {
      if ($p.Name -ne $launching -and (Profile-Running $p.Name)) { continue }
      $f = Join-Path $p.Dir 'ssh_configs.json'
      $old = $null
      if (Test-Path -LiteralPath $f) {
        try { $old = Get-Content -LiteralPath $f -Raw -Encoding UTF8 } catch {}
      }
      if ($old -and ($old.Trim() -eq $json.Trim())) { continue }
      try {
        New-Item -ItemType Directory -Force -Path $p.Dir | Out-Null
        Set-JsonFile $f $json
        $wrote++
      } catch {}
    }
    if ($wrote -gt 0) {
      Note "  Synced $($byKey.Count) SSH connection(s) to $wrote profile(s)."
    }
  } catch {}
}

# Never kill Claude as a side effect of patching a --app scratch target: the
# process match is name-based and would hit the real running app regardless
# of which bundle is being patched. Only act on the real install.
function Quit-Claude {
  if (-not $IsRealInstall) {
    Note "Skipping quit: target is $AppDir, not the real install."
    return
  }
  $procs = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return }
  Step 'Quitting Claude...'
  foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch {} }
  for ($i = 0; $i -lt 5; $i++) {
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) { break }
  }
  Get-Process -Name 'claude' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

function Cmd-Status {
  Require-AppPaths
  Note "Claude version:  $(Get-ClaudeVersion)"
  Note "App directory:   $AppDir"
  if ($script:IsMsix) {
    Ok '[*] MSIX install: no patch needed. Profiles launch via the app''s built-in CLAUDE_USER_DATA_DIR hook.'
    $n = 0
    if (Test-Path $ProfilesDir) {
      $n = @(Get-ChildItem -Path $ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    }
    Note "Known profiles (captured session keys): $n"
    return
  }
  Ensure-AsarTool
  if (Is-Patched) {
    Ok '[*] PATCHED (--profile support active)'
  } else {
    Warn '[ ] not patched'
  }
  if (Has-OtherPatch) {
    Warn '  note: claude-rtl patch is also present in this asar.'
  }
  if (Test-Path $BackupAsar) {
    Note "Backup present: $BackupAsar"
    if (Test-Path $BackupVersion) { Note "Backup taken from Claude version: $(Get-Content $BackupVersion)" }
  } else {
    Note 'No backup recorded.'
  }
  $n = 0
  if (Test-Path $ProfilesDir) {
    $n = @(Get-ChildItem -Path $ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
  }
  Note "Known profiles (captured session keys): $n"
}

# ---------------------------------------------------------------------------
# patch
# ---------------------------------------------------------------------------

# Preflight: refuse to patch if claude.exe enforces asar integrity. On
# Windows Electron stores the expected asar-header hash inside the exe's own
# resources and only checks it when the EnableEmbeddedAsarIntegrityValidation
# fuse is flipped on. We cannot update that embedded hash without rewriting
# the (Authenticode-signed) exe, so if the fuse is on, a modified asar means
# Claude dies at startup. Better to refuse cleanly, before anything changes.
function Assert-AsarIntegrityNotEnforced {
  if (-not (Test-Path $Exe)) {
    Die "claude.exe not found at $Exe; cannot verify the integrity fuse. Nothing was modified."
  }
  $out = & $script:NodeBin (Join-Path $ToolDir 'fuse-check.js') $Exe
  if ($LASTEXITCODE -ne 0 -or -not $out) {
    Die 'Could not read the Electron fuse wire from claude.exe. Nothing was modified.'
  }
  $out = "$out".Trim()
  if ($out -eq 'no-sentinel') {
    Note '  no fuse wire found in claude.exe (older Electron): integrity is not enforced.'
    return
  }
  $parts = $out.Split(':')
  if ($parts[0] -ne '1') {
    Die "claude.exe uses an unknown fuse-wire version ('$($parts[0])'); cannot confirm asar integrity is off. Refusing to patch. Nothing was modified."
  }
  if ($parts[1] -eq '1') {
    Die 'claude.exe has EnableEmbeddedAsarIntegrityValidation switched ON: a modified app.asar would make Claude refuse to start, and the expected hash is baked into the signed exe where it cannot be safely rewritten. Refusing to patch. Nothing was modified.'
  }
  Note "  asar-integrity fuse state: '$($parts[1])' (off): safe to modify app.asar."
}

function Snapshot-BackupIfNeeded {
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  if ((Test-Path $BackupAsar) -and (Test-Path $BackupVersion)) {
    $backedUp = (Get-Content $BackupVersion -ErrorAction SilentlyContinue | Select-Object -First 1)
    $installed = Get-ClaudeVersion
    if ("$backedUp" -ne "$installed") {
      Warn "Backup was taken from Claude $backedUp, but $installed is installed."
      Warn 'Refreshing backup (a new app-<version> directory is always pristine).'
      Step "Refreshing pristine backup -> $BackupAsar"
      Copy-Item -Force $Asar $BackupAsar
      Backup-UnpackedDir
      Set-Content -Path $BackupVersion -Value $installed -Encoding Ascii
    } else {
      Note "Reusing existing backup at $BackupAsar"
    }
    return
  }
  Step "Saving pristine backup -> $BackupAsar"
  Copy-Item -Force $Asar $BackupAsar
  Backup-UnpackedDir
  Set-Content -Path $BackupVersion -Value (Get-ClaudeVersion) -Encoding Ascii
}

function Backup-UnpackedDir {
  if (Test-Path $BackupUnpacked) { Remove-Item -Recurse -Force $BackupUnpacked }
  if (Test-Path $Unpacked) {
    Copy-Item -Recurse -Force $Unpacked $BackupUnpacked
  }
}

# Repacks $extractDir into $outAsar preserving whichever files were
# unpacked:true in the original asar. Native .node modules (and node-pty's
# conpty helpers on Windows) cannot be dlopen'd/executed from inside an asar
# archive: losing this set on repack means the main process crashes before
# any window opens. Primary strategy is an exact basename brace-glob;
# fallback is a generic pattern. Either way the caller re-verifies set
# equality before installing anything.
function Pack-PreservingUnpacked($extractDir, $outAsar, [string[]]$origList) {
  if ($origList.Count -eq 0) {
    # Nothing was unpacked in the original: a plain pack reproduces that
    # exactly. (The generic fallback glob would be WRONG here: it could
    # unpack files the original kept packed, and the caller's set-equality
    # check would then refuse to install.)
    Step 'Repacking (original asar had no unpacked files)...'
    & $script:NodeBin (Join-Path $ToolDir 'pack-unpacked.js') $extractDir $outAsar
    if ($LASTEXITCODE -ne 0) { Die 'asar pack failed.' }
    return
  }
  if ($origList.Count -gt 0) {
    $basenames = @($origList | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object -Unique)
    # minimatch does not brace-expand a single-element {x}, so pass one name bare.
    if ($basenames.Count -eq 1) { $pattern = $basenames[0] }
    else { $pattern = '{' + ($basenames -join ',') + '}' }
    Step "Repacking with exact unpacked-basename list ($($basenames.Count) names)..."
    & $script:NodeBin (Join-Path $ToolDir 'pack-unpacked.js') $extractDir $outAsar $pattern
    if ($LASTEXITCODE -ne 0) { Die 'asar pack (exact-basename unpack) failed.' }
    $newList = Get-UnpackedList $outAsar
    if (Lists-Equal $origList $newList) { return }
    Warn 'Exact unpacked-basename match failed to reproduce the original set; falling back to pattern match.'
  }
  Step 'Repacking with generic unpacked pattern (**/*.node, **/*.dll, **/*.exe)...'
  & $script:NodeBin (Join-Path $ToolDir 'pack-unpacked.js') $extractDir $outAsar '{**/*.node,**/*.dll,**/*.exe,**/*.dylib,**/spawn-helper}'
  if ($LASTEXITCODE -ne 0) { Die 'asar pack (fallback pattern unpack) failed.' }
}

function Cmd-Patch {
  if ($script:VerifyLaunch -and $IsRealInstall) {
    Die '--verify-launch refuses to run against the real Claude install. Use --app <scratch-copy> to smoke-test a launch.'
  }

  Require-AppPaths
  if ($script:IsMsix) {
    Die 'Claude is installed as an MSIX package now: it cannot and must not be patched, and it does not need to be. Profiles work without any patch: just run  claude-deck open <name>  (the app''s built-in CLAUDE_USER_DATA_DIR hook does the isolation). Nothing was modified.'
  }
  Ensure-AsarTool

  if ((Is-Patched) -and (-not $script:Force)) {
    Ok 'Already patched. Nothing to do.'
    Note "Run with 'revert' to undo, 'status' to inspect, or '--force' to re-apply."
    return
  }

  if (Has-OtherPatch) {
    Warn 'Warning: the claude-rtl patch is already applied to this app.asar.'
    Warn 'Patching on top means the backup this script takes will include that'
    Warn 'patch too: reverting claude-deck later will NOT bring back a pristine app.'
    if (-not $script:Force) {
      $reply = Read-Host 'Continue anyway? [y/N]'
      if ($reply -notmatch '^(y|Y|yes|YES)$') { Die 'Aborted. Re-run with --force to skip this prompt.' }
    } else {
      Note '--force given, continuing despite claude-rtl patch being present.'
    }
  }

  # Preflight gate, before touching anything. If Claude's internal layout no
  # longer has the entry point we inject into, find out now, not after the
  # original asar has already been overwritten.
  Step 'Preflight: checking asar layout...'
  if (-not ((Get-AsarList $Asar) | Where-Object { $_ -like '*/.vite/build/index.pre.js' })) {
    Die "Entry point .vite/build/index.pre.js not found in $Asar. Claude's internal app layout has changed; nothing was modified. Please check for a claude-deck update."
  }
  Step 'Preflight: checking the asar-integrity fuse in claude.exe...'
  Assert-AsarIntegrityNotEnforced

  Quit-Claude
  Snapshot-BackupIfNeeded

  # From here on, any failure must leave the installed app exactly as it was
  # (restored from the known-good backup), never half-patched. The finally
  # block below is the rollback trap.
  $rollbackArmed = $true
  $tmpRoot = Join-Path $env:TEMP ('claude-deck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $work = Join-Path $tmpRoot 'asar'
    Step "Extracting asar -> $work"
    Invoke-Asar extract $Asar $work
    if ($LASTEXITCODE -ne 0) { Die 'asar extract failed.' }

    Step 'Writing claude-deck injector module...'
    Write-Injector (Join-Path $work $Marker)

    Step 'Wiring injector into entry point...'
    $entry = Join-Path (Join-Path (Join-Path $work '.vite') 'build') 'index.pre.js'
    if (-not (Test-Path $entry)) { Die "Entry point not found: $entry (Claude internal layout changed?)" }
    $entryText = [IO.File]::ReadAllText($entry)
    if ($entryText.IndexOf($Marker) -lt 0) {
      $prefix = "try { require('../../$Marker'); } catch (e) { console.error('claude-deck load failed:', e); }`n"
      [IO.File]::WriteAllText($entry, $prefix + $entryText)
    }

    Step 'Recording which files are unpacked in the ORIGINAL asar...'
    $origUnpacked = Get-UnpackedList $Asar
    Note "  $($origUnpacked.Count) unpacked file(s) in the original asar."
    # (No executable-bit restore here, unlike macOS: NTFS has no exec bit,
    # so extraction cannot lose one.)

    Step 'Repacking asar (preserving unpacked native modules)...'
    $tmpAsar = Join-Path $tmpRoot 'app.asar.new'
    Pack-PreservingUnpacked $work $tmpAsar $origUnpacked

    Step "Verifying the repacked asar's unpacked set matches the original..."
    $newUnpacked = Get-UnpackedList $tmpAsar
    if (-not (Lists-Equal $origUnpacked $newUnpacked)) {
      Write-Host 'Original unpacked set:' -ForegroundColor Red
      $origUnpacked | ForEach-Object { Write-Host "  $_" }
      Write-Host 'New unpacked set:' -ForegroundColor Red
      $newUnpacked | ForEach-Object { Write-Host "  $_" }
      Die "Repacked asar's unpacked file set does not match the original. Refusing to install (rollback will restore the app)."
    }

    Step 'Installing new asar + app.asar.unpacked...'
    Move-Item -Force $tmpAsar $Asar
    # createPackageWithOptions writes its own sibling .unpacked dir next to
    # the asar it produced. Install it wholesale so the native files are the
    # ones actually alongside the new asar. If nothing was unpacked, leave
    # whatever was already in resources alone.
    if (Test-Path "$tmpAsar.unpacked") {
      if (Test-Path $Unpacked) { Remove-Item -Recurse -Force $Unpacked }
      Move-Item -Force "$tmpAsar.unpacked" $Unpacked
    }

    Step 'Post-validation...'
    if (-not (Is-Patched)) {
      Die "Post-validation failed: marker $Marker not found in installed asar."
    }
    $finalUnpacked = Get-UnpackedList $Asar
    if (-not (Lists-Equal $origUnpacked $finalUnpacked)) {
      Die "Post-validation failed: installed asar's unpacked set no longer matches the original."
    }

    if ($script:VerifyLaunch) { Verify-LaunchStaysAlive }

    $rollbackArmed = $false
  } finally {
    if ($rollbackArmed) { Invoke-PatchRollback }
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
  }

  Ok '[OK] Patched. Claude now understands --profile=NAME.'
  Note "Try: claude-deck open work   (launches a second, independent instance)"
  Note 'Revert anytime with: claude-deck revert'
  Note 'Note: a Claude auto-update installs a fresh app folder; just re-run patch after updates.'
}

# Restores the app from the pristine backup after a mid-patch failure. Runs
# from the finally block in Cmd-Patch, so it fires on Die, on any thrown
# error, and on Ctrl-C during the mutation window.
function Invoke-PatchRollback {
  Warn 'Patch failed partway through: restoring the app from backup...'
  $restoreOk = $true
  try {
    if (Test-Path $BackupAsar) { Copy-Item -Force $BackupAsar $Asar }
  } catch { $restoreOk = $false; Warn "Could not restore app.asar: $_" }
  try {
    if (Test-Path $BackupUnpacked) {
      if (Test-Path $Unpacked) { Remove-Item -Recurse -Force $Unpacked }
      Copy-Item -Recurse -Force $BackupUnpacked $Unpacked
    } elseif (Test-Path $Unpacked) {
      Remove-Item -Recurse -Force $Unpacked
    }
  } catch { $restoreOk = $false; Warn "Could not restore app.asar.unpacked: $_" }
  if ($restoreOk) {
    Warn 'App restored to its pre-patch state. Nothing is broken.'
  } else {
    Write-Host "Rollback could not fully restore the app. Re-run '.\claude-deck.ps1 revert' by hand; the pristine backup is at $BackupAsar." -ForegroundColor Red
  }
}

# Spawns the just-patched app with a throwaway userData dir and confirms the
# process is still alive 8 seconds later. Guarded by the caller to only ever
# run for a non-real --app target.
function Verify-LaunchStaysAlive {
  if (-not (Test-Path $Exe)) { Die "--verify-launch: executable not found at $Exe" }
  $scratch = Join-Path $env:TEMP ('claude-deck-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  Step "Launching $Exe --profile=verifylaunch for an 8s liveness check..."
  $p = Start-Process -FilePath $Exe -ArgumentList @('--profile=verifylaunch', "--user-data-dir=$scratch") -PassThru
  Start-Sleep -Seconds 8
  $alive = $false
  try { $alive = -not $p.HasExited } catch { $alive = $false }
  if ($alive) {
    Ok "  Process $($p.Id) is still alive after 8s: launch verified."
    try { $p.CloseMainWindow() | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
  } else {
    Die '--verify-launch failed: the patched app did not stay running for 8s. Rolling back.'
  }
  Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}

# Writes the injected main-process module. IMPORTANT: this JS is kept
# byte-identical to the copy inside claude-deck.sh (_write_injector); the
# code itself branches on process.platform where behavior must differ
# (directory links are junctions on Windows). Keep the twins in sync.
function Write-Injector($out) {
  $js = @'
// Injected by claude-deck: adds --profile=NAME support so multiple
// Claude accounts can run simultaneously, each with its own userData dir,
// and reports each profile's session key locally for the usage dashboard.
// Everything here is wrapped defensively: this module must never be able
// to crash the app, even if Claude's internals change under us.
const { app, session, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');

function safeRun(fn) {
  try { fn(); } catch (e) { /* never let injected code crash the app */ }
}

// Directory links: junctions on Windows (they work without admin rights or
// Developer Mode, unlike real directory symlinks), plain symlinks elsewhere.
function linkDir(target, linkPath) {
  if (process.platform === 'win32') fs.symlinkSync(target, linkPath, 'junction');
  else fs.symlinkSync(target, linkPath);
}

function getProfileArg() {
  var argv = process.argv || [];
  for (var i = 0; i < argv.length; i++) {
    var a = argv[i];
    if (typeof a === 'string' && a.indexOf('--profile=') === 0) {
      var raw = a.slice('--profile='.length);
      var clean = raw.replace(/[^A-Za-z0-9_-]/g, '');
      if (clean.length > 32) clean = clean.slice(0, 32);
      return clean.length > 0 ? clean : null;
    }
  }
  return null;
}

var PROFILE = null;
safeRun(function () { PROFILE = getProfileArg(); });
var LABEL = PROFILE || 'default';

// 1) Separate userData (and best-effort sessionData) per profile, so each
//    profile is a fully independent Electron app instance: separate cookies,
//    separate localStorage, separate login.
safeRun(function () {
  if (PROFILE) {
    var base = path.join(app.getPath('appData'), 'Claude Profiles', PROFILE);
    app.setPath('userData', base);
    safeRun(function () { app.setPath('sessionData', base); });
  }
});

// 1b) Share one Claude Code session index across every profile. Claude
//     Desktop keeps its Claude Code session list per-userData at
//     <userData>/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json.
//     Transcripts live in the shared ~/.claude/projects, but the app only
//     lists sessions it finds in this per-profile index, so a second
//     profile of the same account shows "no Code sessions" even though the
//     transcripts are right there. Fix: symlink each profile's index dir at
//     the default app's index dir, migrating any existing per-profile
//     sessions in first so nothing is lost. Silent no-op on any failure:
//     this must never block app launch, and never deletes data.
safeRun(function () {
  if (!PROFILE) return;
  var shared = path.join(app.getPath('appData'), 'Claude', 'claude-code-sessions');
  // Recompute the profile dir here: 'base' in the userData block above is
  // function-scoped to its own safeRun callback and is NOT visible here.
  // Referencing it threw a silent ReferenceError and made this whole block
  // a no-op (real bug, caught in production on 2026-07-06).
  var mine = path.join(app.getPath('appData'), 'Claude Profiles', PROFILE, 'claude-code-sessions');

  safeRun(function () { fs.mkdirSync(shared, { recursive: true }); });

  var mineStat = null;
  safeRun(function () { mineStat = fs.lstatSync(mine); });

  // Claude 1.25927+ refuses writes when mine itself is a reparse point
  // (PlantDetectedError). Keep mine as a REAL directory and junction/symlink
  // each child of shared into it.
  function linkSharedChildren() {
    safeRun(function () { fs.mkdirSync(mine, { recursive: true }); });
    var kids = [];
    safeRun(function () { kids = fs.readdirSync(shared); });
    for (var i = 0; i < kids.length; i++) {
      (function (name) {
        var src = path.join(shared, name);
        var dst = path.join(mine, name);
        safeRun(function () {
          if (fs.existsSync(dst)) return;
          linkDir(src, dst);
        });
      })(kids[i]);
    }
  }

  // A dir whose entries are ALL links is the per-child link farm this code
  // built on an earlier launch, not a profile's own unshared index. Without
  // this test every launch "migrates" the link farm into the shared dir it
  // already points at and renames it aside, leaving one more
  // claude-code-sessions.migrated-<stamp> per launch, forever. (Node reports a
  // Windows junction as a symlink here, so one test covers both platforms.)
  function isLinkFarm(dir) {
    var kids = [];
    safeRun(function () { kids = fs.readdirSync(dir); });
    for (var i = 0; i < kids.length; i++) {
      var st = null;
      var kid = path.join(dir, kids[i]);
      safeRun(function () { st = fs.lstatSync(kid); });
      if (!st || !st.isSymbolicLink()) return false;
    }
    return true;
  }

  if (mineStat && mineStat.isSymbolicLink()) {
    // Old top-level link: replace with a real dir + per-child links.
    safeRun(function () { fs.unlinkSync(mine); });
    mineStat = null;
  }

  if (mineStat && mineStat.isDirectory() && !isLinkFarm(mine)) {
    // Existing per-profile index: migrate its contents into the shared dir
    // additively (never overwrite a file already in shared), then keep the
    // original around as a timestamped backup instead of deleting it.
    safeRun(function () {
      if (typeof fs.cpSync === 'function') {
        try {
          fs.cpSync(mine, shared, { recursive: true, force: false, errorOnExist: false });
        } catch (e) {
          copyRecursiveSkipExisting(mine, shared);
        }
      } else {
        copyRecursiveSkipExisting(mine, shared);
      }
    });
    safeRun(function () {
      fs.renameSync(mine, mine + '.migrated-' + Date.now());
    });
    mineStat = null;
  }

  // Unconditional, and idempotent by construction: it only creates children
  // that are missing. Running it even when the farm already exists is what
  // links an account folder that appeared in the shared root after this
  // profile was last converted.
  linkSharedChildren();
});

// Manual recursive copy that skips any file/dir already present at the
// destination. Used only as a fallback when fs.cpSync is unavailable or
// throws, so the shared-index migration above still completes.
function copyRecursiveSkipExisting(srcDir, destDir) {
  safeRun(function () {
    fs.mkdirSync(destDir, { recursive: true });
    var entries = fs.readdirSync(srcDir, { withFileTypes: true });
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      var srcPath = path.join(srcDir, entry.name);
      var destPath = path.join(destDir, entry.name);
      safeRun(function () {
        if (entry.isDirectory()) {
          copyRecursiveSkipExisting(srcPath, destPath);
        } else if (entry.isFile()) {
          if (!fs.existsSync(destPath)) {
            fs.copyFileSync(srcPath, destPath);
          }
        }
      });
    }
  });
}

// 2) Tag window titles with the profile name so Mission Control, Cmd+Tab,
//    and launchers like Raycast can tell instances apart at a glance.
safeRun(function () {
  app.on('browser-window-created', function (_evt, win) {
    safeRun(function () {
      if (!PROFILE || !win || !win.webContents) return;
      win.webContents.on('page-title-updated', function (evt, title) {
        safeRun(function () {
          evt.preventDefault();
          win.setTitle('[' + PROFILE + '] ' + title);
        });
      });
    });
  });
});

// 3) Session-key reporter: writes ~/.claude-deck/profiles/<label>.json so the
//    local dashboard can read usage without the app doing any network calls
//    itself. Merges into any existing file so a cached orgId survives.
var STATE_DIR = path.join(os.homedir(), '.claude-deck');
var PROFILES_DIR = path.join(STATE_DIR, 'profiles');

function readExistingProfile(file) {
  var result = {};
  safeRun(function () {
    if (fs.existsSync(file)) {
      var raw = fs.readFileSync(file, 'utf8');
      var parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') result = parsed;
    }
  });
  return result;
}

function writeProfileFile(sessionKey) {
  safeRun(function () {
    if (!sessionKey) return;
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    fs.mkdirSync(PROFILES_DIR, { recursive: true, mode: 0o700 });
    var file = path.join(PROFILES_DIR, LABEL + '.json');
    var existing = readExistingProfile(file);
    existing.name = LABEL;
    existing.sessionKey = sessionKey;
    existing.updatedAt = new Date().toISOString();
    // existing.orgId (if any) is preserved as-is: the dashboard caches it.
    fs.writeFileSync(file, JSON.stringify(existing), { mode: 0o600 });
    safeRun(function () { fs.chmodSync(file, 0o600); });
  });
}

function pullSessionKey(ses) {
  safeRun(function () {
    ses.cookies.get({ url: 'https://claude.ai', name: 'sessionKey' })
      .then(function (cookies) {
        safeRun(function () {
          if (cookies && cookies.length > 0 && cookies[0].value) {
            writeProfileFile(cookies[0].value);
          }
        });
      })
      .catch(function () {});
  });
}

// 3b) Session seeding (login import): the reverse of the reporter above,
//     so a profile JSON copied from another machine signs in on first
//     launch. A raw userData copy cannot carry a login across machines:
//     Electron encrypts cookies at rest with an OS-bound key (macOS
//     Keychain / Windows DPAPI), so a copied cookie store is
//     undecryptable there. The plain sessionKey in the JSON can simply
//     be planted as a fresh cookie instead. Seeds ONLY when the session
//     has no sessionKey cookie at all: a live login always wins and is
//     never overwritten. Always resolves (true only when a seed landed),
//     never rejects, so callers can chain on it safely.
function seedSessionKey(ses) {
  return new Promise(function (resolve) {
    var settled = false;
    function finish(seeded) {
      if (!settled) { settled = true; resolve(seeded); }
    }
    try {
      var saved = readExistingProfile(path.join(PROFILES_DIR, LABEL + '.json'));
      var key = (saved && typeof saved.sessionKey === 'string') ? saved.sessionKey : '';
      if (!key) { finish(false); return; }
      ses.cookies.get({ url: 'https://claude.ai', name: 'sessionKey' })
        .then(function (cookies) {
          if (cookies && cookies.length > 0) { finish(false); return; }
          return ses.cookies.set({
            url: 'https://claude.ai',
            name: 'sessionKey',
            value: key,
            secure: true,
            httpOnly: true,
            sameSite: 'lax',
            expirationDate: Math.floor(Date.now() / 1000) + 60 * 24 * 60 * 60
          }).then(function () { finish(true); });
        })
        .catch(function () { finish(false); });
    } catch (e) {
      finish(false);
    }
  });
}

// If the first window loaded claude.ai before the seed landed, it rendered
// the logged-out page: reload every window already created at that point,
// once, so the seeded login takes effect. Windows created after the seed
// see the cookie anyway.
function reloadOpenWindows() {
  safeRun(function () {
    var wins = BrowserWindow.getAllWindows();
    for (var i = 0; i < wins.length; i++) {
      safeRun(function () {
        var win = wins[i];
        if (win && !win.isDestroyed() && win.webContents) win.webContents.reload();
      });
    }
  });
}

safeRun(function () {
  app.whenReady().then(function () {
    safeRun(function () {
      var ses = (PROFILE ? session.defaultSession : session.defaultSession);
      // Seed before the first pull: pulling first could re-write the
      // profile JSON from a cookie read taken before the seed landed.
      seedSessionKey(ses).then(function (seeded) {
        safeRun(function () {
          if (seeded) reloadOpenWindows();
          pullSessionKey(ses);
        });
      }).catch(function () {});
      // Re-pull periodically in case the cookie change event is missed
      // (e.g. token silently refreshed without a 'changed' event).
      setInterval(function () { pullSessionKey(ses); }, 30 * 60 * 1000);
      safeRun(function () {
        ses.cookies.on('changed', function (_evt, cookie, _cause, removed) {
          safeRun(function () {
            if (removed) return;
            if (cookie && cookie.name === 'sessionKey' && cookie.domain && cookie.domain.indexOf('claude.ai') !== -1) {
              writeProfileFile(cookie.value);
            }
          });
        });
      });
    });
  }).catch(function () {});
});
'@
  # Normalize to LF (a Windows checkout with autocrlf would otherwise embed
  # CRLF) and restore the trailing newline that here-strings drop, so the
  # installed module is byte-identical to the macOS twin.
  [IO.File]::WriteAllText($out, $js.Replace("`r`n", "`n") + "`n")
}

# ---------------------------------------------------------------------------
# revert
# ---------------------------------------------------------------------------

function Cmd-Revert {
  Require-AppPaths
  if ($script:IsMsix) {
    Die 'Claude is an MSIX package now: it was never patched, so there is nothing to revert. Profiles need no patch (they use the built-in CLAUDE_USER_DATA_DIR hook). Nothing was modified.'
  }
  if (-not (Test-Path $BackupAsar)) { Die "No backup found at ${BackupAsar}: nothing to revert." }

  Quit-Claude

  Step "Restoring original app.asar from $BackupAsar..."
  Copy-Item -Force $BackupAsar $Asar

  Step 'Restoring original app.asar.unpacked...'
  if (Test-Path $BackupUnpacked) {
    if (Test-Path $Unpacked) { Remove-Item -Recurse -Force $Unpacked }
    Copy-Item -Recurse -Force $BackupUnpacked $Unpacked
  } elseif (Test-Path $Unpacked) {
    # The pristine backup had no unpacked dir, but the patched install has
    # one: remove it so revert is exact.
    Remove-Item -Recurse -Force $Unpacked
  }

  Ok '[OK] Reverted. Claude is back to its original, byte-identical content.'
  Note "Backup retained at $BackupAsar. Delete $StateDir if you don't need it."
}

# ---------------------------------------------------------------------------
# open / list / doctor
# ---------------------------------------------------------------------------

function Validate-ProfileName($name) {
  if (-not $name) { Die 'Profile name cannot be empty.' }
  if ($name.Length -gt 32) { Die "Profile name too long (max 32 chars): $name" }
  if ($name -notmatch '^[A-Za-z0-9_-]+$') { Die "Profile name must match [A-Za-z0-9_-]: $name" }
}

# PowerShell twin of the Claude Code session-index link that the injected
# claude-deck.js sets up inside the app's main process. Calling this from the
# shell, on every open/dash, makes the fix self-healing even when the
# installed app carries an outdated injection. Never destructive: a real
# directory found at the link path is migrated additively and kept as a
# timestamped backup, never deleted. The profile's claude-code-sessions path
# itself must stay a real directory (Claude 1.25927+ PlantDetected); only the
# per-account children are junctions onto the shared index.
function Ensure-ProfileIndexLink($name) {
  $profileDir = Join-Path $ProfilesUserDataRoot $name
  $link = Join-Path $profileDir 'claude-code-sessions'

  # Under the escaped root the default instance's own dir hosts the shared
  # index physically; linking it onto itself would be circular.
  if ($link -ieq $SharedSessionsDir) { return $true }

  New-Item -ItemType Directory -Force -Path $SharedSessionsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

  if (Profile-Running $name) {
    Note "Profile '$name' is running: leaving its session index alone for now."
    return $false
  }

  $item = $null
  try { $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue } catch {}

  # Claude Desktop 1.25927+ refuses writes when claude-code-sessions itself is
  # a reparse point (PlantDetectedError: "Refusing non-directory at private
  # dir path"). The old design made that path a junction onto the shared
  # index; that now bricks session saves. Keep a REAL directory per profile
  # and junction only the per-account children into the shared root.
  if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Step "Converting top-level session-index junction for '$name' (Claude PlantDetected)..."
    # rmdir removes a junction without touching the shared target.
    cmd.exe /c ('rmdir "' + $link + '"') | Out-Null
    $item = $null
  }

  # A dir whose entries are ALL reparse points is the per-child link farm this
  # function built on an earlier run, not a profile's own unshared index.
  # Telling the two apart is load-bearing: without it every run "migrates" the
  # link farm into the shared dir it already points at (a no-op copy, same
  # files on both sides) and then renames it aside, so each launch leaves
  # another claude-code-sessions.migrated-<stamp> behind, forever.
  $needsMigration = $false
  if ($item -and $item.PSIsContainer) {
    foreach ($kid in @(Get-ChildItem -LiteralPath $link -Force -ErrorAction SilentlyContinue)) {
      if (-not ($kid.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $needsMigration = $true
        break
      }
    }
  }

  if ($item -and $item.PSIsContainer -and $needsMigration) {
    Step "Migrating existing session index for '$name' into the shared index..."
    $copied = 0
    Get-ChildItem -LiteralPath $link -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $rel = $_.FullName.Substring($link.Length).TrimStart([char]92, [char]47)
      $dest = Join-Path $SharedSessionsDir $rel
      if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -ErrorAction SilentlyContinue
        $copied++
      }
    }
    Note "  merged $copied session file(s) into $SharedSessionsDir"
    try {
      Rename-Item -LiteralPath $link -NewName ("claude-code-sessions.migrated-" + [DateTimeOffset]::Now.ToUnixTimeSeconds())
    } catch { Warn "Could not set aside the old index dir: $_"; return $false }
    $item = $null
  }

  New-Item -ItemType Directory -Force -Path $link | Out-Null

  # foreach over a materialized array, NOT ForEach-Object over the pipeline.
  # Two things went wrong with the pipeline form, both fatal under
  # Set-StrictMode 2: anything reaching the block without a .Name property
  # (a null, an error record) threw PropertyNotFoundStrict and took the whole
  # launch down with it -- `claude-deck dash` died on this line before the
  # dashboard ever started -- and `$linked++` inside a ForEach-Object block
  # increments a block-local copy, so the count was always reported as 0.
  $linked = 0
  $children = @()
  try {
    $children = @(Get-ChildItem -LiteralPath $SharedSessionsDir -Force -ErrorAction SilentlyContinue)
  } catch { $children = @() }
  foreach ($child in $children) {
    if (-not $child) { continue }
    if (-not $child.PSObject.Properties['Name']) { continue }
    $dst = Join-Path $link $child.Name
    if (Test-Path -LiteralPath $dst) { continue }
    try {
      New-Item -ItemType Junction -Path $dst -Target $child.FullName -ErrorAction Stop | Out-Null
      $linked++
    } catch {
      Warn "Could not link $($child.Name) for '$name': $_"
    }
  }
  if ($linked -gt 0) { Note "  linked $linked account folder(s) into $link" }

  $made = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
  if (-not ($made -and $made.PSIsContainer)) {
    Warn "Could not materialize session-index dir for '$name'."
    return $false
  }
  if ($made.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Warn "Session-index for '$name' is still a reparse point; Claude will refuse writes."
    return $false
  }
  return $true
}


# Launch one Claude instance, profile-aware. Profiles ride the app's own
# CLAUDE_USER_DATA_DIR hook (no patch involved): set the env var, spawn,
# clear it. --profile=<name> is passed as an inert marker so
# Profile-Running can identify the instance from its command line.
# Chromium/Electron child markers (CHROME_*, ELECTRON_*) are scrubbed
# first: a terminal hosted inside Claude Desktop leaks
# CHROME_CRASHPAD_PIPE_NAME, which makes the spawned app misbehave as if
# it were a crashed child process.
function Start-ClaudeInstance($name) {
  foreach ($e in @(Get-ChildItem Env:)) {
    if ($e.Name -match '^(CHROME_|ELECTRON_)') {
      Remove-Item "Env:$($e.Name)" -ErrorAction SilentlyContinue
    }
  }
  if ($name -and $name -ne 'default') {
    $dir = Join-Path $ProfilesUserDataRoot $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Sync-SshConfigs $name
    $env:CLAUDE_USER_DATA_DIR = $dir
    try {
      Start-Process -FilePath $Exe -ArgumentList "--profile=$name" -WorkingDirectory $AppDir
    } finally {
      Remove-Item Env:CLAUDE_USER_DATA_DIR -ErrorAction SilentlyContinue
    }
  } elseif ($ProfilesUserDataRoot -eq $EscapedDataRoot) {
    # Escaped root active: the default instance must also live outside the
    # virtualized AppData, or its writes keep landing in the MSIX overlay.
    New-Item -ItemType Directory -Force -Path $DefaultUserDataDir | Out-Null
    Sync-SshConfigs 'default'
    $env:CLAUDE_USER_DATA_DIR = $DefaultUserDataDir
    try {
      Start-Process -FilePath $Exe -WorkingDirectory $AppDir
    } finally {
      Remove-Item Env:CLAUDE_USER_DATA_DIR -ErrorAction SilentlyContinue
    }
  } else {
    Remove-Item Env:CLAUDE_USER_DATA_DIR -ErrorAction SilentlyContinue
    Start-Process -FilePath $Exe -WorkingDirectory $AppDir
  }
}

function Validate-OrgUuid($uuid) {
  if ($uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    Die "Org id must be a UUID: $uuid"
  }
}

# Splices <org> into <name>'s own lastActiveOrg cookie via
# dashboard/cookie-crypto.js so launching lands on that org instead of
# whatever was last active. Pure filesystem work on the profile's own Cookies
# sqlite file: no app bundle, no patch. Never fatal: a missing cookie (never
# logged in), a node without node:sqlite (< 22.5), or any other failure just
# falls through to a normal launch.
#
# The caller (Cmd-Open) must only reach this from the "not running" branch:
# writing to a live Cookies WAL file is externally silent (no crash, no lock
# error) but the running app can later overwrite or ignore it, so the
# not-running check has to gate this call through real control flow.
function Seed-ActiveOrg($name, $org) {
  $cookies = Join-Path (Join-Path $ProfilesUserDataRoot $name) 'Network\Cookies'
  if (-not (Test-Path $cookies)) {
    Note "  Profile '$name' has no Cookies file yet (never logged in): skipping org switch."
    return
  }
  $helper = Join-Path (Join-Path $ScriptDir 'dashboard') 'cookie-crypto.js'
  if (-not (Test-Path $helper)) {
    Warn '  cookie-crypto.js not found next to this script: skipping org switch.'
    return
  }
  Ensure-Node
  Step "Switching '$name' to org $org before launch..."
  & $script:NodeBin $helper seed-org $cookies $org 2>$null
  switch ($LASTEXITCODE) {
    0       { Note '  org cookie updated.' }
    2       { Note "  '$name' has no active-org cookie yet (or this node lacks node:sqlite): launching normally." }
    default { Warn '  could not switch org (continuing with a normal launch).' }
  }
}

function Cmd-Open($name, $org) {
  Require-AppPaths
  if (-not $name -or $name -eq 'default') {
    if (Profile-Running 'default') {
      # Default already running: never spawn a second instance on the same
      # userData dir (it would corrupt its session store). Best-effort focus.
      Step 'Claude (default profile) is already running.'
      try { (New-Object -ComObject WScript.Shell).AppActivate('Claude') | Out-Null } catch {}
    } else {
      Step 'Opening Claude (default profile)...'
      Start-ClaudeInstance 'default'
    }
    return
  }

  Validate-ProfileName $name
  Ensure-ProfileIndexLink $name | Out-Null

  if (Profile-Running $name) {
    Step "Profile '$name' already running: focusing its window..."
    # Best-effort: MSIX instances have no [name] title prefix (that came
    # from the retired asar injection), so try the tagged title first for
    # legacy patched installs, then fall back to the plain app title.
    $sh = New-Object -ComObject WScript.Shell
    $ok = $false
    try { $ok = $sh.AppActivate("[$name]") } catch {}
    if (-not $ok) { try { $sh.AppActivate('Claude') | Out-Null } catch {} }
  } else {
    if ($org) {
      Validate-OrgUuid $org
      Seed-ActiveOrg $name $org
    }
    Step "Launching new Claude instance for profile '$name'..."
    Start-ClaudeInstance $name
  }
}

function Cmd-List {
  $names = @()
  if (Test-Path $ProfilesDir) {
    $names += @(Get-ChildItem -Path $ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  }
  if (Test-Path $ProfilesUserDataRoot) {
    $names += @(Get-ChildItem -Path $ProfilesUserDataRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  }
  $names = @($names | Sort-Object -Unique)
  if ($names.Count -eq 0) {
    Note 'No profiles found yet. Use: claude-deck open <name>'
    return
  }
  foreach ($n in $names) {
    $running = 'no'; if (Profile-Running $n) { $running = 'yes' }
    $hasKey = 'no'; if (Test-Path (Join-Path $ProfilesDir "$n.json")) { $hasKey = 'yes' }
    Write-Host ('{0,-20} running={1,-4} key={2,-4}' -f $n, $running, $hasKey)
  }
}

function Repair-AllProfiles([switch]$Quiet) {
  if (-not (Test-Path $ProfilesUserDataRoot)) {
    if (-not $Quiet) { Note "No named profiles found under: $ProfilesUserDataRoot" }
    return
  }
  $dirs = @(Get-ChildItem -Path $ProfilesUserDataRoot -Directory -ErrorAction SilentlyContinue)
  foreach ($d in $dirs) {
    $name = $d.Name
    $link = Join-Path $d.FullName 'claude-code-sessions'
    $item = $null
    try { $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue } catch {}
    if (Profile-Running $name) {
      Write-Host ('  {0,-20} skipped-running' -f $name)
      continue
    }
    $wasReparse = ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
    $wasDir = ($item -and $item.PSIsContainer -and -not $wasReparse)
    $okLink = Ensure-ProfileIndexLink $name
    if ($wasReparse -and $okLink) {
      Write-Host ('  {0,-20} converted-plant-safe' -f $name)
    } elseif ($wasReparse) {
      Write-Host ('  {0,-20} convert FAILED (see warning above)' -f $name)
    } elseif ($wasDir -and $okLink) {
      Write-Host ('  {0,-20} migrated-and-linked' -f $name)
    } elseif ($wasDir) {
      Write-Host ('  {0,-20} migrated (but linking FAILED; see warning above)' -f $name)
    } elseif ($okLink) {
      if (-not $Quiet) { Write-Host ('  {0,-20} linked' -f $name) }
    }
  }
}

# Best-effort: extracts just claude-deck.js from the installed asar and
# checks whether it still contains the old buggy scoped reference. Silent
# no-op on any failure: this check is a bonus, not load bearing.
function Doctor-CheckInjectionFreshness {
  if (-not (Resolve-AppPaths)) { return }
  if (-not (Test-Path $Asar)) { return }
  try { Ensure-AsarTool } catch { return }
  $tmp = Join-Path $env:TEMP ('claude-deck-doc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Push-Location $tmp
    try { & $script:NodeBin $script:AsarJs extract-file $Asar $Marker 2>$null | Out-Null } finally { Pop-Location }
    $extracted = Join-Path $tmp $Marker
    if ((Test-Path $extracted) -and (Select-String -LiteralPath $extracted -Pattern "join\(base, 'claude-code-sessions'\)" -Quiet)) {
      Warn 'Warning: the installed app carries an old injection with a known scoping bug'
      Warn '(session-index linking silently failed). Recommend: claude-deck patch --force'
    }
  } catch {
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# mcp-doctor: local absolute paths in mcpServers
# ---------------------------------------------------------------------------
# An mcpServers entry that names a local absolute path is a CACHE of where a
# file sits on THIS machine, not per-profile state. The filesystem is the only
# authority for it. Profiles legitimately differ on identity (env, tokens,
# ${VAR} headers, per-account servers) and those are never touched here; they
# must never disagree about where a plugin server file lives.
#
# Behaviourally identical twins: Get-McpBrokenPaths in sync\claude-sync.ps1,
# brokenPaths() in sync/claude-sync.sh, _mcp_broken_paths in claude-deck.sh.
# The one deliberate platform difference is PATHEXT, below.
function Test-McpLooksAbsolute($Value) {
  # Windows drive path, UNC share, or POSIX absolute. Anything else is not
  # ours to judge: a bare command resolved through PATH, a URL, a flag, or a
  # ${VAR} placeholder we cannot expand.
  if ($null -eq $Value) { return $false }
  $s = [string]$Value
  if (-not $s) { return $false }
  if ($s.Contains('${') -or $s.Contains('://')) { return $false }
  return ($s -match '^[A-Za-z]:[\\/]' -or $s -match '^\\\\[^\\]' -or $s -match '^/[^/]')
}

function Test-McpPathPresent($Path, [bool]$IsCommand) {
  # $IsCommand: Windows spawns a command through PATHEXT, so
  # "C:\Program Files\nodejs\node" really does run even though no file has
  # exactly that name. Only the command slot gets that benefit of the doubt;
  # a script path in args must exist literally.
  if (Test-Path -LiteralPath $Path) { return $true }
  if ($IsCommand -and $env:PATHEXT) {
    foreach ($ext in $env:PATHEXT.Split(';')) {
      if ($ext -and (Test-Path -LiteralPath ($Path + $ext))) { return $true }
    }
  }
  return $false
}

function Get-McpPathSlots($Def) {
  # Every local absolute path a definition names, tagged with its slot
  # ('command' or 'args[<i>]'). Repairs match slot for slot, so only the path
  # token changes and everything else in the entry survives untouched.
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Def) { return ,$out }
  try {
    $cmd = $Def.PSObject.Properties['command']
    if ($cmd -and (Test-McpLooksAbsolute $cmd.Value)) {
      $out.Add(@{ Slot = 'command'; Value = [string]$cmd.Value; IsCommand = $true })
    }
    $ar = $Def.PSObject.Properties['args']
    if ($ar -and $null -ne $ar.Value) {
      $list = @($ar.Value)
      for ($i = 0; $i -lt $list.Count; $i++) {
        if (Test-McpLooksAbsolute $list[$i]) {
          $out.Add(@{ Slot = "args[$i]"; Value = [string]$list[$i]; IsCommand = $false })
        }
      }
    }
  } catch {}
  return ,$out
}

function Get-McpConfigTargets {
  # Every claude_desktop_config.json a Claude instance or a plugin hook can
  # touch on this machine: the default instance, every named profile, and the
  # legacy %APPDATA%\Claude copy, which survives the MSIX-escape migration and
  # is still what a hook with a hardcoded path writes to.
  $dirs = New-Object System.Collections.Generic.List[object]
  # Under the escaped root the default instance lives INSIDE the profiles
  # root, so the enumeration below already covers it. Same test Sync-SshConfigs
  # uses, and it beats comparing path strings: one side can arrive as an 8.3
  # short path or in different case, and then the string dedup below silently
  # lists the default instance twice.
  if ($DefaultUserDataDir -ne (Join-Path $ProfilesUserDataRoot 'default')) {
    $dirs.Add(@{ Name = 'default'; Dir = $DefaultUserDataDir })
  }
  if (Test-Path -LiteralPath $ProfilesUserDataRoot) {
    foreach ($d in @(Get-ChildItem -LiteralPath $ProfilesUserDataRoot -Directory -ErrorAction SilentlyContinue)) {
      $dirs.Add(@{ Name = $d.Name; Dir = $d.FullName })
    }
  }
  $dirs.Add(@{ Name = 'appdata-legacy'; Dir = (Join-Path $env:APPDATA 'Claude') })

  $out  = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($d in $dirs) {
    $p = Join-Path $d.Dir 'claude_desktop_config.json'
    $key = $p.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $seen[$key] = $true
    $out.Add(@{ Name = $d.Name; Path = $p })
  }
  return ,$out
}

function Cmd-McpDoctor {
  $targets = Get-McpConfigTargets
  if ($targets.Count -eq 0) {
    Note "No claude_desktop_config.json found under: $ProfilesUserDataRoot"
    return
  }

  # Pass 1: read every config, list every path slot, and remember the first
  # definition per server name whose paths all resolve. That one is the donor:
  # disk truth, not the newest file, decides what a repair writes.
  $rows   = New-Object System.Collections.Generic.List[object]
  $donor  = @{}
  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($t in $targets) {
    $json = $null
    try { $json = (Get-Content -LiteralPath $t.Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {
      Warn ("  {0}: not valid JSON, skipped ({1})" -f $t.Name, $t.Path)
      continue
    }
    $mProp = $null
    if ($json) { $mProp = $json.PSObject.Properties['mcpServers'] }
    if (-not $mProp -or $null -eq $mProp.Value) { continue }
    $parsed.Add(@{ Target = $t; Servers = $mProp.Value })
    foreach ($prop in @($mProp.Value.PSObject.Properties)) {
      $slots = Get-McpPathSlots $prop.Value
      if ($slots.Count -eq 0) { continue }   # npx/remote: no local path to judge
      $healthy = $true
      foreach ($s in $slots) {
        $exists = Test-McpPathPresent $s.Value ([bool]$s.IsCommand)
        if (-not $exists) { $healthy = $false }
        $rows.Add(@{ Profile = $t.Name; Server = $prop.Name; Slot = $s.Slot
                     Path = $s.Value; Exists = $exists; Action = '-'; Replacement = $null })
      }
      if ($healthy -and -not $donor.ContainsKey($prop.Name)) { $donor[$prop.Name] = $slots }
    }
  }

  # Pass 2: decide an action for every broken row. Healthy rows keep '-'.
  $fixable = 0
  foreach ($r in $rows) {
    if ($r.Exists) { continue }
    if (-not $donor.ContainsKey($r.Server)) { $r.Action = 'no donor'; continue }
    $repl = $null
    foreach ($s in $donor[$r.Server]) { if ($s.Slot -eq $r.Slot) { $repl = $s.Value } }
    if (-not $repl -or $repl -eq $r.Path) { $r.Action = 'no donor'; continue }
    $r.Replacement = $repl
    $r.Action = if ($script:Fix) { 'repair' } else { 'would repair' }
    $fixable++
  }

  # Pass 3: apply, one file at a time, as a targeted token swap. The path is
  # replaced as a JSON string literal in the raw text, so every other byte of
  # the file (key order, indentation, env blocks, tokens) is preserved exactly.
  if ($script:Fix -and $fixable -gt 0) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    foreach ($t in $targets) {
      $mine = @($rows | Where-Object { $_.Profile -eq $t.Name -and $_.Action -eq 'repair' })
      if ($mine.Count -eq 0) { continue }
      $text = [System.IO.File]::ReadAllText($t.Path)
      $orig = $text
      foreach ($r in $mine) {
        $from = ConvertTo-Json -InputObject $r.Path -Compress
        $to   = ConvertTo-Json -InputObject $r.Replacement -Compress
        if (-not $text.Contains($from)) { $r.Action = 'token not found'; continue }
        $text = $text.Replace($from, $to)
      }
      if ($text -eq $orig) { continue }
      # A text-level edit gets a parse check before it is trusted, and the
      # backup is written first so a bad write is always one copy from undone.
      $bad = $false
      try { ConvertFrom-Json $text | Out-Null } catch { $bad = $true }
      if ($bad) {
        Warn ("  {0}: repair would not re-parse as JSON, left untouched." -f $t.Name)
        foreach ($r in $mine) { if ($r.Action -eq 'repair') { $r.Action = 'aborted' } }
        continue
      }
      Copy-Item -LiteralPath $t.Path -Destination "$($t.Path).bak-mcp-path-$stamp" -Force
      [System.IO.File]::WriteAllText($t.Path, $text)
      foreach ($r in $mine) { if ($r.Action -eq 'repair') { $r.Action = 'repaired' } }
    }
  }

  if ($rows.Count -eq 0) {
    Note 'No mcpServers entry on this machine names a local absolute path.'
    return
  }

  $wp = [Math]::Max(7, (@($rows | ForEach-Object { $_.Profile.Length }) | Measure-Object -Maximum).Maximum)
  $ws = [Math]::Max(6, (@($rows | ForEach-Object { $_.Server.Length })  | Measure-Object -Maximum).Maximum)
  Write-Host ("{0,-$wp}  {1,-$ws}  {2,-6}  {3,-14}  {4}" -f 'PROFILE', 'SERVER', 'EXISTS', 'ACTION', 'PATH')
  foreach ($r in $rows) {
    $line = ("{0,-$wp}  {1,-$ws}  {2,-6}  {3,-14}  {4}" -f $r.Profile, $r.Server,
             $(if ($r.Exists) { 'yes' } else { 'no' }), $r.Action, $r.Path)
    if ($r.Exists) { Note $line } else { Warn $line }
  }

  $broken = @($rows | Where-Object { -not $_.Exists }).Count
  Write-Host ''
  if ($broken -eq 0) {
    Ok ("[OK] {0} path(s) across {1} config(s): all present." -f $rows.Count, $targets.Count)
  } elseif ($script:Fix) {
    $done = @($rows | Where-Object { $_.Action -eq 'repaired' }).Count
    Ok ("[OK] {0} of {1} broken path(s) repaired. Re-run to confirm." -f $done, $broken)
    if ($done -lt $broken) { Warn 'The rest have no working copy anywhere: reinstall the plugin, then re-run.' }
  } else {
    Warn ("{0} broken path(s) found; {1} can be repaired." -f $broken, $fixable)
    Note 'Run: claude-deck mcp-doctor -Fix'
  }
}

function Cmd-Doctor {
  Step 'Repairing session-index links for every named profile...'
  Repair-AllProfiles

  Step 'Checking mcpServers for local paths that no longer exist...'
  Cmd-McpDoctor

  try {
    if (Resolve-AppPaths) {
      if ($script:IsMsix) {
        Note 'MSIX install detected: no patch needed (profiles use CLAUDE_USER_DATA_DIR).'
      } elseif (Test-Path $Asar) {
        Step 'Checking installed patch freshness...'
        Doctor-CheckInjectionFreshness
        Ensure-AsarTool
        if (-not (Is-Patched)) {
          Warn 'The installed app is not patched (a Claude auto-update replaces the app folder).'
          Warn 'Run: claude-deck patch'
        }
      }
    }
  } catch {
    Note 'Could not check patch state (tooling unavailable); skipping.'
  }

  Ok '[OK] Doctor pass complete.'
}

# ---------------------------------------------------------------------------
# dash
# ---------------------------------------------------------------------------

# Owning pid of whatever is LISTENING on the port, or $null.
function Get-DashPidOnPort($port) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
  } catch {}
  # PS 5.1 on older builds may lack Get-NetTCPConnection; netstat is the fallback.
  try {
    $line = (Invoke-NativeQuiet { netstat -ano -p TCP }) | Where-Object { $_ -match "LISTENING" -and $_ -match ":$port\s" } | Select-Object -First 1
    if ($line -and ($line -split '\s+')[-1] -match '^\d+$') { return [int]($line -split '\s+')[-1] }
  } catch {}
  return $null
}

# True only for a node process running OUR server.js. The port is checked
# before anything is signalled, because killing whatever happens to hold 8965
# would be a fine way to shoot down an unrelated service.
function Test-PidIsOurDashboard($procId) {
  try {
    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction Stop).CommandLine
    return ($cl -and $cl -match 'dashboard[\\/]server\.js')
  } catch { return $false }
}

# `dash` always replaces a dashboard that is already up, rather than starting a
# second one behind it. Before this, Cmd-Dash never looked at the port: node hit
# EADDRINUSE and died on the spot, while the browser opener fired anyway and
# landed on the OLD process. So a re-run looked like it worked and silently kept
# serving whatever code that process had loaded at startup, which is stale the
# moment `install` copies a new dashboard\ over it. A restart is free here,
# since the server holds no state worth keeping. Twin of cmd_dash in
# claude-deck.sh; keep the two behaviourally identical.
function Cmd-Dash($port) {
  if (-not $port) { $port = 8965 }
  # Never let session-index housekeeping stop the dashboard from starting.
  # It is a best-effort repair of symlinks; `dash` failing because of it
  # leaves the user with no dashboard AND no way to see what went wrong.
  try { Repair-AllProfiles -Quiet } catch { Warn "Session-index repair failed, starting the dashboard anyway: $_" }
  Ensure-Node

  $serverJs = Join-Path (Join-Path $ScriptDir 'dashboard') 'server.js'
  if (-not (Test-Path $serverJs)) { Die "dashboard\server.js not found next to this script ($ScriptDir)." }

  $existing = Get-DashPidOnPort $port
  if ($existing) {
    if (Test-PidIsOurDashboard $existing) {
      Step "Replacing the dashboard already on port $port (pid $existing)..."
      try { Stop-Process -Id $existing -ErrorAction Stop } catch {}
      $waited = 0
      while ((Get-DashPidOnPort $port) -and $waited -lt 20) { Start-Sleep -Milliseconds 250; $waited++ }
      if (Get-DashPidOnPort $port) {
        Note '  it ignored the stop, forcing.'
        try { Stop-Process -Id $existing -Force -ErrorAction Stop } catch {}
        Start-Sleep -Seconds 1
      }
      if (Get-DashPidOnPort $port) { Die "Port $port is still held by pid $existing; could not free it." }
    } else {
      Die "Port $port is held by something that is not the claude-deck dashboard (pid $existing).`nUse a different port:  claude-deck dash <port>"
    }
  }

  Step "Starting dashboard on http://127.0.0.1:$port ..."
  # Wait for the NEW server to actually bind before opening the browser. The
  # old fixed one-second sleep is what made a failed start still look successful.
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-Command',
    "for (`$i = 0; `$i -lt 40; `$i++) { if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { Start-Process 'http://127.0.0.1:$port'; break }; Start-Sleep -Milliseconds 250 }"
  )
  $env:CLAUDE_DECK_PORT = "$port"
  & $script:NodeBin $serverJs
}

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------

$RcBegin = '# >>> claude-deck shortcut >>>'
$RcEnd   = '# <<< claude-deck shortcut <<<'

function Cmd-Install {
  New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
  $sourcePath = Join-Path $ScriptDir 'claude-deck.ps1'
  if ($sourcePath -eq $CanonicalPath) {
    Note 'Running from canonical location: script already in place.'
  } else {
    Step "Installing script -> $CanonicalPath"
    Copy-Item -Force $sourcePath $CanonicalPath
    if (Test-Path (Join-Path $ScriptDir 'dashboard')) {
      Step "Copying dashboard\ -> $CanonicalDir\dashboard"
      if (Test-Path (Join-Path $CanonicalDir 'dashboard')) { Remove-Item -Recurse -Force (Join-Path $CanonicalDir 'dashboard') }
      Copy-Item -Recurse -Force (Join-Path $ScriptDir 'dashboard') (Join-Path $CanonicalDir 'dashboard')
    }
  }

  # Wire up a `claude-deck` function in the PowerShell profile of the shell
  # that ran this (sentinel-wrapped so uninstall can remove exactly it).
  $rcFile = $PROFILE
  $rcDir = Split-Path $rcFile -Parent
  New-Item -ItemType Directory -Force -Path $rcDir | Out-Null
  if (-not (Test-Path $rcFile)) { New-Item -ItemType File -Force -Path $rcFile | Out-Null }
  $rcText = Get-Content -Raw -Path $rcFile -ErrorAction SilentlyContinue
  if ($rcText -and $rcText.Contains($RcBegin)) {
    Warn "Alias already present in ${rcFile}: leaving it alone."
    Note "(Script at $CanonicalPath was refreshed.)"
  } else {
    Step "Adding 'claude-deck' function to $rcFile"
    Add-Content -Path $rcFile -Value @"

$RcBegin
function claude-deck { & "$CanonicalPath" @args }
$RcEnd
"@
  }

  Ok '[OK] Installed.'
  Note "Script is safe at: $CanonicalPath (original checkout can be removed)"
  Note "Open a new PowerShell (or: . `$PROFILE), then use:"
  Note '  claude-deck open work   # launch a profile (no patch needed on MSIX)'
  Note '  claude-deck list        # list profiles'
  Note '  claude-deck dash        # usage dashboard'
}

function Cmd-Uninstall {
  $rcFile = $PROFILE
  $rcText = ''
  if (Test-Path $rcFile) { $rcText = Get-Content -Raw -Path $rcFile }
  if (-not $rcText -or -not $rcText.Contains($RcBegin)) {
    Warn "No shortcut block found in ${rcFile}: nothing to remove."
    return
  }
  Step "Removing 'claude-deck' function from $rcFile"
  Copy-Item -Force $rcFile "$rcFile.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in (Get-Content -Path $rcFile)) {
    if ($line -eq $RcBegin) { $skip = $true; continue }
    if ($line -eq $RcEnd)   { $skip = $false; continue }
    if (-not $skip) { $out.Add($line) }
  }
  Set-Content -Path $rcFile -Value $out
  Ok '[OK] Removed. Open a new PowerShell for it to take effect.'
}

# ---------------------------------------------------------------------------
# help + dispatch
# ---------------------------------------------------------------------------

function Cmd-ResetAuth($name) {
  # Clears the latched session_stale_relogin state for one profile (or every
  # profile when name is empty / 'all'). Claude 1.25927+ will not mint an
  # elevated OAuth token from a session cookie that is still "valid" but too
  # old; a soft Sign-in-again leaves that cookie in place and the failure
  # latches. Fix: delete the sessionKey cookies, drop the dead oauth token
  # caches, and clear the stale key from ~/.claude-deck/profiles so nothing
  # can re-seed it. Profile must be closed. User then opens and logs in fresh.

  Ensure-Node | Out-Null
  $helper = Join-Path (Join-Path $ScriptDir 'dashboard') 'cookie-crypto.js'
  if (-not (Test-Path $helper)) { $helper = Join-Path (Join-Path $CanonicalDir 'dashboard') 'cookie-crypto.js' }
  if (-not (Test-Path $helper)) { Die "cookie-crypto.js not found next to this script." }

  $targets = @()
  if (-not $name -or $name -eq 'all') {
    if (Test-Path $ProfilesUserDataRoot) {
      $targets = @(Get-ChildItem -Path $ProfilesUserDataRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    if ($targets.Count -eq 0) { Die "No profiles found under $ProfilesUserDataRoot" }
  } else {
    Validate-ProfileName $name
    $targets = @($name)
  }

  $ok = 0
  foreach ($n in $targets) {
    if (Profile-Running $n) {
      Warn "Profile '$n' is running: close it first, then re-run reset-auth."
      continue
    }
    $dir = if ($n -eq 'default') { $DefaultUserDataDir } else { Join-Path $ProfilesUserDataRoot $n }
    if (-not (Test-Path $dir)) {
      Warn "Profile '$n' has no data dir yet: skipping."
      continue
    }

    $stamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $bakDir = Join-Path $StateDir (Join-Path 'reset-auth-backup' ($n + '-' + $stamp))
    New-Item -ItemType Directory -Force -Path $bakDir | Out-Null

    $cookies = Join-Path $dir 'Network\Cookies'
    if (Test-Path $cookies) {
      Copy-Item -LiteralPath $cookies -Destination (Join-Path $bakDir 'Cookies') -ErrorAction SilentlyContinue
      Step "Clearing sessionKey cookies for '$n'..."
      & $script:NodeBin $helper clear-session $cookies 2>&1 | ForEach-Object { Note "  $_" }
      if ($LASTEXITCODE -ne 0) { Warn "  clear-session failed for '$n' (continuing)." }
    } else {
      Note "Profile '$n' has no Cookies file yet."
    }

    $cfg = Join-Path $dir 'config.json'
    if (Test-Path $cfg) {
      Copy-Item -LiteralPath $cfg -Destination (Join-Path $bakDir 'config.json') -ErrorAction SilentlyContinue
      try {
        $j = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Json
        $changed = $false
        foreach ($k in @('oauth:tokenCacheV2', 'oauth:tokenCache')) {
          if ($null -ne $j.PSObject.Properties[$k]) {
            $j.PSObject.Properties.Remove($k)
            $changed = $true
          }
        }
        if ($changed) {
          Step "Dropping expired oauth token cache for '$n'..."
          Set-JsonFile $cfg ($j | ConvertTo-Json -Depth 40)
        }
      } catch {
        Warn "  could not edit config.json for '$n': $_"
      }
    }

    $pj = Join-Path $ProfilesDir ($n + '.json')
    if (Test-Path $pj) {
      Copy-Item -LiteralPath $pj -Destination (Join-Path $bakDir ($n + '.json')) -ErrorAction SilentlyContinue
      try {
        $p = Get-Content -Raw -LiteralPath $pj | ConvertFrom-Json
        if ($p.sessionKey) {
          Step "Clearing stale sessionKey from profiles\$n.json (prevents re-seed)..."
          $p.PSObject.Properties.Remove('sessionKey')
          $p | Add-Member -NotePropertyName updatedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
          Set-JsonFile $pj ($p | ConvertTo-Json -Depth 20)
        }
      } catch {
        Warn "  could not edit profiles\$n.json: $_"
      }
    }

    Note "  backup: $bakDir"
    $ok++
  }

  Ok ("[OK] reset-auth done for {0} profile(s)." -f $ok)
  Note "Next: claude-deck open <name>, sign in with real credentials (password/SSO),"
  Note "then confirm Logs\main.log shows [oauth-v2] using cached token (no session_stale_relogin)."
  Note "Do NOT reseed an old sessionKey from a backup - that recreates the latch."
}

function Cmd-Help {
  Write-Host @"
claude-deck: run many Claude Desktop accounts side by side on one PC (Windows)

Teaches Claude Desktop a --profile=NAME argument (separate Electron userData
per profile = separate simultaneous logins), plus a local usage dashboard.

Usage:
  claude-deck patch [--force] [--verify-launch]
                         apply the patch (idempotent; safe to re-run)
                         --verify-launch: smoke-test the launch (only allowed
                         with --app <scratch-copy>, never the real install)
  claude-deck revert     restore the original app.asar from backup
  claude-deck status     show patch state, backup info, profiles
  claude-deck open [name] [org-uuid]
                         launch a profile (no name = default profile). An
                         org-uuid switches it to that org first, and only on
                         a fresh launch (an already-running profile is just
                         focused, org untouched)
  claude-deck list       list known profiles (running? key captured?)
  claude-deck dash [port] run the local usage dashboard (default port 8965)
  claude-deck reset-auth [name|all]
                         clear latched stale sessions so a real login works
                         (deletes sessionKey cookies + dead oauth caches;
                         profile must be closed). No name = all profiles
  claude-deck doctor     repair every profile's session-index link, report
                         broken mcpServers paths, check patch freshness
  claude-deck mcp-doctor [-Fix]
                         list every mcpServers entry that names a local
                         absolute path, across all profiles and the live
                         config, with exists yes/no. -Fix rewrites a missing
                         path to the working copy found in another config
                         (backup first, path token only, idempotent)
  claude-deck install    add a 'claude-deck' function to your PS profile
  claude-deck uninstall  remove the 'claude-deck' function only
  claude-deck help       this message

Notes:
  - No admin rights needed: the app lives in %LOCALAPPDATA%\AnthropicClaude.
  - Backup of the original app.asar is saved in: $BackupDir
  - A Claude auto-update installs a fresh app-<version> folder, which removes
    the patch (never your logins or profiles). Re-run 'claude-deck patch'.
  - The macOS watchdog has no Windows equivalent yet; 'doctor' tells you when
    a re-patch is needed.
  - Profile session keys are cached in: $ProfilesDir
"@
}

switch ($Command) {
  'patch'     { Cmd-Patch }
  'revert'    { Cmd-Revert }
  'status'    { Cmd-Status }
  'open'      { Cmd-Open $(if ($Positional.Count -gt 0) { $Positional[0] } else { '' }) $(if ($Positional.Count -gt 1) { $Positional[1] } else { '' }) }
  'list'      { Cmd-List }
  'dash'      { Cmd-Dash $(if ($Positional.Count -gt 0) { $Positional[0] } else { '' }) }
  'doctor'     { Cmd-Doctor }
  'reset-auth' { Cmd-ResetAuth $(if ($Positional.Count -gt 0) { $Positional[0] } else { 'all' }) }
  'mcp-doctor' { Cmd-McpDoctor }
  'install'   { Cmd-Install }
  'uninstall' { Cmd-Uninstall }
  'watchdog'  {
    Warn 'The watchdog is macOS-only. On Windows a Claude auto-update installs a'
    Warn 'brand-new app-<version> folder, so just re-run: claude-deck patch'
  }
  ''          { Cmd-Help }
  'help'      { Cmd-Help }
  '--help'    { Cmd-Help }
  '-h'        { Cmd-Help }
  default     { Cmd-Help; exit 1 }
}
