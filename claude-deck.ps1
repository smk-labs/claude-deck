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
$script:AppOverride = $null
if ($env:CLAUDE_DECK_APP) { $script:AppOverride = $env:CLAUDE_DECK_APP }
$Positional = @()
for ($i = 0; $i -lt $Rest.Count; $i++) {
  switch -Regex ($Rest[$i]) {
    '^(--force|-Force)$'                { $script:Force = $true }
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
$ProfilesUserDataRoot = Join-Path $env:APPDATA 'Claude Profiles'
$SharedSessionsDir    = Join-Path (Join-Path $env:APPDATA 'Claude') 'claude-code-sessions'
$LocalNodeVersion = '22.12.0'   # 22 LTS; >=22.5 gives node:sqlite for the org-switch cookie write
$ScriptDir = $PSScriptRoot
$CanonicalDir  = Join-Path $StateDir 'bin'
$CanonicalPath = Join-Path $CanonicalDir 'claude-deck.ps1'

function Step($m) { Write-Host "-> $m" }
function Note($m) { Write-Host $m -ForegroundColor DarkGray }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

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

  if (mineStat && mineStat.isSymbolicLink()) {
    return; // already linked, nothing to do
  }

  if (mineStat && mineStat.isDirectory()) {
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
    safeRun(function () {
      linkDir(shared, mine);
    });
    return;
  }

  if (!mineStat) {
    // Nothing at all yet for this profile: just point it at the shared dir.
    safeRun(function () { linkDir(shared, mine); });
  }
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
# timestamped backup, never deleted. Uses a junction (not a symlink) because
# junctions need no admin rights and no Developer Mode.
function Ensure-ProfileIndexLink($name) {
  $profileDir = Join-Path $ProfilesUserDataRoot $name
  $link = Join-Path $profileDir 'claude-code-sessions'

  New-Item -ItemType Directory -Force -Path $SharedSessionsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

  $item = $null
  try { $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue } catch {}
  if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    return $true  # already linked
  }

  if (Profile-Running $name) {
    Note "Profile '$name' is running: leaving its session index alone for now."
    return $false
  }

  if ($item -and $item.PSIsContainer) {
    Step "Migrating existing session index for '$name' into the shared index..."
    $copied = 0
    Get-ChildItem -LiteralPath $link -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $rel = $_.FullName.Substring($link.Length).TrimStart('\', '/')
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
  }

  try {
    New-Item -ItemType Junction -Path $link -Target $SharedSessionsDir | Out-Null
  } catch {
    Warn "Could not create the session-index junction for '$name': $_"
    return $false
  }
  # New-Item can silently no-op in edge cases; trust the filesystem, not the
  # absence of an exception.
  $made = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
  if (-not ($made -and ($made.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
    Warn "Could not create the session-index junction for '$name'."
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
    $env:CLAUDE_USER_DATA_DIR = $dir
    try {
      Start-Process -FilePath $Exe -ArgumentList "--profile=$name" -WorkingDirectory $AppDir
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
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      if (-not $Quiet) { Write-Host ('  {0,-20} already-linked' -f $name) }
      continue
    }
    if (Profile-Running $name) {
      Write-Host ('  {0,-20} skipped-running' -f $name)
      continue
    }
    $wasDir = ($item -and $item.PSIsContainer)
    $okLink = Ensure-ProfileIndexLink $name
    if ($wasDir -and $okLink) {
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

function Cmd-Doctor {
  Step 'Repairing session-index links for every named profile...'
  Repair-AllProfiles

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

function Cmd-Dash($port) {
  if (-not $port) { $port = 8965 }
  Repair-AllProfiles -Quiet
  Ensure-Node

  $serverJs = Join-Path (Join-Path $ScriptDir 'dashboard') 'server.js'
  if (-not (Test-Path $serverJs)) { Die "dashboard\server.js not found next to this script ($ScriptDir)." }

  Step "Starting dashboard on http://127.0.0.1:$port ..."
  # Open the browser after a beat so the server is listening first.
  Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-Command', "Start-Sleep 1; Start-Process 'http://127.0.0.1:$port'"
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
  claude-deck doctor     repair every profile's session-index link, check
                         patch freshness
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
  'doctor'    { Cmd-Doctor }
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
