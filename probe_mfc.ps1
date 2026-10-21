Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetBuild = [int]$env:TARGET_BUILD
$targetPathPattern = "(?<![0-9])$targetBuild(?![0-9])"
$targetVersionPattern = "^\d+\.\d+\.$targetBuild(\.|$)"
$mfcPathPattern = '(?i)(mfc|afx)'
$vcMspPattern = '(?i)(\bVC|VC[_-]|Visual C\+\+|KB4338871)'
$captureByteCap = [int64]$env:CAPTURE_BYTE_CAP

$buildRoot = $env:APPVEYOR_BUILD_FOLDER
$captureRoot = Join-Path $buildRoot 'capture-root'
$metadataRoot = Join-Path $buildRoot 'capture-metadata'
New-Item -ItemType Directory -Force -Path $captureRoot, $metadataRoot | Out-Null

$pf86 = ${env:ProgramFiles(x86)}
$roots = [ordered]@{
  PackageCache   = 'C:\ProgramData\Package Cache'
  VSPackages     = 'C:\ProgramData\Microsoft\VisualStudio\Packages'
  VS14           = Join-Path $pf86 'Microsoft Visual Studio 14.0'
  MergeModules   = Join-Path $pf86 'Common Files\Merge Modules'
  PatchCache     = Join-Path $env:SystemRoot 'Installer\$PatchCache$'
  Installer      = Join-Path $env:SystemRoot 'Installer'
  System32       = Join-Path $env:SystemRoot 'System32'
  SysWOW64       = Join-Path $env:SystemRoot 'SysWOW64'
}
# MSPs already captured by the v140-msp-probe runs.
$knownMspSha256 = @(
  'da9176bc6114c1effe084483ec97975cc0a06c2c107b1572d7440b4a4a07e523'
  'f5b96f2067c2cc5487b3ee37a7d36d50a174dceab7780ea43eceb7b2137ba7d5'
  '6efde51cb390a21fe9b65e792fdc82b5e7e76fee883f7c5ea9a2a4cd78bf1483'
)

function Get-Sha256([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile($value, [string]$name) {
  ConvertTo-Json -InputObject @($value) -Depth 8 |
    Set-Content -LiteralPath (Join-Path $metadataRoot $name) -Encoding UTF8
}

function Get-RootRelative([string]$path) {
  foreach ($key in $roots.Keys) {
    $prefix = $roots[$key].TrimEnd('\') + '\'
    if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ root = $key; relative = $path.Substring($prefix.Length) }
    }
  }
  throw "path outside known roots: $path"
}

function Get-TreeFiles([string]$root) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName)
}

function Test-TargetBuild([System.IO.FileInfo]$file) {
  if ($file.Length -gt 64MB) { return $false }
  try { return ($file.VersionInfo.FileBuildPart -eq $targetBuild) } catch { return $false }
}

function Get-NumericVersion($versionInfo) {
  if ($versionInfo.FileMajorPart -eq 0 -and $versionInfo.FileMinorPart -eq 0 -and
      $versionInfo.FileBuildPart -eq 0 -and $versionInfo.FilePrivatePart -eq 0) {
    return $null
  }
  return '{0}.{1}.{2}.{3}' -f $versionInfo.FileMajorPart, $versionInfo.FileMinorPart,
    $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart
}

# --- Worker identity -------------------------------------------------------------------------
@(
  "APPVEYOR_BUILD_WORKER_IMAGE=$env:APPVEYOR_BUILD_WORKER_IMAGE",
  "APPVEYOR_BUILD_ID=$env:APPVEYOR_BUILD_ID",
  "APPVEYOR_JOB_ID=$env:APPVEYOR_JOB_ID",
  "APPVEYOR_BUILD_VERSION=$env:APPVEYOR_BUILD_VERSION",
  "APPVEYOR_REPO_COMMIT=$env:APPVEYOR_REPO_COMMIT",
  "os_version=$([System.Environment]::OSVersion.VersionString)",
  "powershell_version=$($PSVersionTable.PSVersion.ToString())"
) | Set-Content -LiteralPath (Join-Path $metadataRoot 'worker.txt') -Encoding ASCII

# --- Full trees of the package caches (the "folder" candidates) ------------------------------
$cacheFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($key in @('PackageCache', 'VSPackages', 'PatchCache')) {
  $files = Get-TreeFiles $roots[$key]
  $prefix = $roots[$key].TrimEnd('\') + '\'
  $files | ForEach-Object {
    $cacheFiles.Add($_)
    "$($_.FullName.Substring($prefix.Length))`t$($_.Length)`t$($_.LastWriteTimeUtc.ToString('o'))"
  } | Set-Content -LiteralPath (Join-Path $metadataRoot "$key-tree.tsv") -Encoding UTF8
}
$cachePathTargetMatches = @($cacheFiles | Where-Object { (Get-RootRelative $_.FullName).relative -match $targetPathPattern })

# --- MFC file inventory with PE versions -----------------------------------------------------
$inventoryFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($key in @('VS14', 'MergeModules')) {
  $prefix = $roots[$key].TrimEnd('\') + '\'
  Get-TreeFiles $roots[$key] |
    Where-Object { $_.FullName.Substring($prefix.Length) -match $mfcPathPattern } |
    ForEach-Object { $inventoryFiles.Add($_) }
}
foreach ($key in @('System32', 'SysWOW64')) {
  Get-ChildItem -LiteralPath $roots[$key] -Force -File -Filter 'mfc*' -ErrorAction SilentlyContinue |
    ForEach-Object { $inventoryFiles.Add($_) }
}
$cacheFiles | Where-Object { (Get-RootRelative $_.FullName).relative -match $mfcPathPattern -or (Test-TargetBuild $_) } |
  ForEach-Object { $inventoryFiles.Add($_) }

$inventoryRows = foreach ($file in $inventoryFiles) {
  $location = Get-RootRelative $file.FullName
  $versionInfo = $file.VersionInfo
  $numericVersion = Get-NumericVersion $versionInfo
  [pscustomobject]@{
    root = $location.root
    relative = $location.relative
    path = $file.FullName
    size = $file.Length
    last_write_utc = $file.LastWriteTimeUtc.ToString('o')
    sha256 = if ($file.Length -lt 512MB) { Get-Sha256 $file.FullName } else { $null }
    file_version = $numericVersion
    file_version_string = $versionInfo.FileVersion
    product_version = $versionInfo.ProductVersion
    target_version_match = ($null -ne $numericVersion -and $numericVersion -match $targetVersionPattern)
    target_path_match = ($location.relative -match $targetPathPattern)
  }
}
$inventoryRows = @($inventoryRows)
Write-JsonFile $inventoryRows 'mfc-inventory.json'

# --- MSI / MSM File tables -------------------------------------------------------------------
$installer = New-Object -ComObject WindowsInstaller.Installer
$invokeMethod = [System.Reflection.BindingFlags]::InvokeMethod
$getProperty = [System.Reflection.BindingFlags]::GetProperty

function Invoke-Com($target, [string]$name, $flags, [object[]]$arguments) {
  return $target.GetType().InvokeMember($name, $flags, $null, $target, $arguments)
}

function Get-MsiRows($database, [string]$sql, [scriptblock]$filter) {
  $rows = New-Object 'System.Collections.Generic.List[object]'
  $view = Invoke-Com $database 'OpenView' $invokeMethod @($sql)
  try {
    [void](Invoke-Com $view 'Execute' $invokeMethod @())
    while ($true) {
      $record = Invoke-Com $view 'Fetch' $invokeMethod @()
      if ($null -eq $record) { break }
      $first = Invoke-Com $record 'StringData' $getProperty @(1)
      if (& $filter $first) {
        $fieldCount = Invoke-Com $record 'FieldCount' $getProperty @()
        $values = @($first)
        for ($i = 2; $i -le $fieldCount; $i++) { $values += Invoke-Com $record 'StringData' $getProperty @($i) }
        $rows.Add($values)
      }
      [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
    }
    [void](Invoke-Com $view 'Close' $invokeMethod @())
  }
  finally {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
  }
  return ,$rows.ToArray()
}

function Get-MsiProperty($database, [string]$name) {
  try {
    $rows = Get-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' { param($p) $p -eq $name }
    if ($rows.Count -gt 0) { return $rows[0][1] }
  }
  catch { }
  return $null
}

$databaseFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
$cacheFiles | Where-Object { $_.Extension -match '(?i)^\.(msi|msm)$' } | ForEach-Object { $databaseFiles.Add($_) }
Get-ChildItem -LiteralPath $roots.Installer -Force -File -Filter '*.msi' -ErrorAction SilentlyContinue |
  ForEach-Object { $databaseFiles.Add($_) }
$inventoryFiles | Where-Object { $_.Extension -match '(?i)^\.msm$' -and (Get-RootRelative $_.FullName).root -eq 'MergeModules' } |
  ForEach-Object { $databaseFiles.Add($_) }

$databaseRows = foreach ($file in $databaseFiles) {
  $row = [ordered]@{
    root = (Get-RootRelative $file.FullName).root
    path = $file.FullName
    size = $file.Length
    product_name = $null
    product_version = $null
    module_signature = $null
    mfc_files = @()
    target_version_match = $false
    error = $null
  }
  $database = $null
  try {
    $database = Invoke-Com $installer 'OpenDatabase' $invokeMethod @($file.FullName, 0)
    $row.product_name = Get-MsiProperty $database 'ProductName'
    $row.product_version = Get-MsiProperty $database 'ProductVersion'
    if ($file.Extension -match '(?i)^\.msm$') {
      try {
        $signature = Get-MsiRows $database 'SELECT `ModuleID`, `Version` FROM `ModuleSignature`' { param($p) $true }
        if ($signature.Count -gt 0) { $row.module_signature = "$($signature[0][0]) $($signature[0][1])" }
      }
      catch { }
    }
    try {
      $fileRows = Get-MsiRows $database 'SELECT `FileName`, `Version`, `FileSize`, `File` FROM `File`' {
        param($name) $name -match $mfcPathPattern
      }
      $row.mfc_files = @($fileRows | ForEach-Object {
        [pscustomobject]@{ file_name = $_[0]; version = $_[1]; size = $_[2]; key = $_[3] }
      })
      $row.target_version_match = (@($row.mfc_files | Where-Object { $_.version -match $targetVersionPattern }).Count -gt 0)
    }
    catch { }
  }
  catch {
    $row.error = $_.Exception.Message
  }
  finally {
    if ($null -ne $database) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
  }
  [pscustomobject]$row
}
$databaseRows = @($databaseRows)
Write-JsonFile @($databaseRows | Where-Object { @($_.mfc_files).Count -gt 0 -or $_.error }) 'msi-mfc-files.json'
$databaseRows | ForEach-Object { "$($_.path)`t$($_.size)`t$($_.product_name)`t$($_.product_version)`t$($_.module_signature)`t$(@($_.mfc_files).Count)" } |
  Set-Content -LiteralPath (Join-Path $metadataRoot 'msi-products.tsv') -Encoding UTF8

# --- MSP summaries ---------------------------------------------------------------------------
$patchFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
$cacheFiles | Where-Object { $_.Extension -match '(?i)^\.msp$' } | ForEach-Object { $patchFiles.Add($_) }
Get-ChildItem -LiteralPath $roots.Installer -Force -File -Filter '*.msp' -ErrorAction SilentlyContinue |
  ForEach-Object { $patchFiles.Add($_) }

$patchRows = foreach ($file in $patchFiles) {
  $row = [ordered]@{
    root = (Get-RootRelative $file.FullName).root
    path = $file.FullName
    size = $file.Length
    sha256 = Get-Sha256 $file.FullName
    title = $null; subject = $null; comments = $null; patch_code = $null; created = $null
    vc_candidate = $false; already_known = $false; error = $null
  }
  try {
    $summary = Invoke-Com $installer 'SummaryInformation' $getProperty @($file.FullName, 0)
    $row.title = Invoke-Com $summary 'Property' $getProperty @(2)
    $row.subject = Invoke-Com $summary 'Property' $getProperty @(3)
    $row.comments = Invoke-Com $summary 'Property' $getProperty @(6)
    $row.patch_code = Invoke-Com $summary 'Property' $getProperty @(9)
    $created = Invoke-Com $summary 'Property' $getProperty @(12)
    if ($null -ne $created) { $row.created = $created.ToString('o') }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($summary)
  }
  catch {
    $row.error = $_.Exception.Message
  }
  $row.already_known = $knownMspSha256 -contains $row.sha256
  $row.vc_candidate = ("$($row.title) $($row.subject) $($file.Name)" -match $vcMspPattern)
  [pscustomobject]$row
}
$patchRows = @($patchRows)
Write-JsonFile $patchRows 'msp-summaries.json'

# --- Applied patches and installed products from the registry --------------------------------
$uninstallRows = foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
  Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue | ForEach-Object {
    $properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
    $name = if ($properties -and $properties.PSObject.Properties['DisplayName']) { $properties.DisplayName } else { $null }
    if ($name -and $name -match '(?i)(mfc|visual c\+\+|visual studio|\bvc\b|KB\d+)') {
      [pscustomobject]@{
        key = $_.PSChildName
        display_name = $name
        display_version = if ($properties.PSObject.Properties['DisplayVersion']) { $properties.DisplayVersion } else { $null }
        install_source = if ($properties.PSObject.Properties['InstallSource']) { $properties.InstallSource } else { $null }
      }
    }
  }
}
Write-JsonFile @($uninstallRows) 'installed-products.json'

$appliedPatchRows = foreach ($product in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' -ErrorAction SilentlyContinue)) {
  $productName = (Get-ItemProperty -LiteralPath (Join-Path $product.PSPath 'InstallProperties') -ErrorAction SilentlyContinue)
  $productName = if ($productName -and $productName.PSObject.Properties['DisplayName']) { $productName.DisplayName } else { $null }
  foreach ($patch in @(Get-ChildItem -LiteralPath (Join-Path $product.PSPath 'Patches') -ErrorAction SilentlyContinue)) {
    $properties = Get-ItemProperty -LiteralPath $patch.PSPath -ErrorAction SilentlyContinue
    [pscustomobject]@{
      product = $productName
      patch = $patch.PSChildName
      display_name = if ($properties -and $properties.PSObject.Properties['DisplayName']) { $properties.DisplayName } else { $null }
      installed = if ($properties -and $properties.PSObject.Properties['Installed']) { $properties.Installed } else { $null }
    }
  }
}
Write-JsonFile @($appliedPatchRows) 'applied-patches.json'

# --- Compiler builds inside MFC/ATL static libraries -----------------------------------------
$libPaths = @($inventoryFiles | Where-Object { $_.Extension -match '(?i)^\.lib$' } | ForEach-Object { $_.FullName } | Sort-Object -Unique)
$libRows = @()
if ($libPaths.Count -gt 0) {
  $python = $null
  $pythonCandidates = @(Get-ChildItem -Path 'C:\Python3*-x64\python.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
  if ($pythonCandidates.Count -gt 0) {
    $python = $pythonCandidates[0].FullName
  }
  else {
    $python = (Get-Command 'python.exe' -ErrorAction Stop).Source
  }
  $libList = Join-Path $buildRoot 'lib-paths.txt'
  $libJson = Join-Path $metadataRoot 'lib-builds.json'
  [System.IO.File]::WriteAllLines($libList, [string[]]$libPaths)
  $process = Start-Process -FilePath $python -ArgumentList @("`"$(Join-Path $buildRoot 'mfc_lib_builds.py')`"", "`"$libList`"", $targetBuild, "`"$libJson`"") `
    -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $metadataRoot 'lib-builds.stdout.txt') `
    -RedirectStandardError (Join-Path $metadataRoot 'lib-builds.stderr.txt')
  if ($process.ExitCode -eq 0) {
    # Windows PowerShell emits a parsed JSON array as one object; unroll it explicitly.
    $parsedLibRows = Get-Content -LiteralPath $libJson -Raw | ConvertFrom-Json
    $libRows = @($parsedLibRows | ForEach-Object { $_ })
  }
}

# --- Capture ---------------------------------------------------------------------------------
$captureRows = New-Object 'System.Collections.Generic.List[object]'
$captured = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$capturedBytes = [int64]0

function Add-Capture([string]$source, [string]$reason) {
  if (-not $captured.Add($source)) { return }
  $location = Get-RootRelative $source
  $item = Get-Item -LiteralPath $source -Force
  $omitted = ($script:capturedBytes + $item.Length -gt $captureByteCap)
  if (-not $omitted) {
    $destination = Join-Path (Join-Path $captureRoot $location.root) $location.relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $script:capturedBytes += $item.Length
  }
  $captureRows.Add([pscustomobject]@{
    root = $location.root; relative = $location.relative; size = $item.Length
    reason = $reason; omitted_by_cap = $omitted
  })
}

foreach ($file in $cachePathTargetMatches) { Add-Capture $file.FullName 'cache path names target build' }
foreach ($row in @($databaseRows | Where-Object { $_.target_version_match })) {
  Add-Capture $row.path 'database carries target MFC file version'
  if ($row.root -ne 'Installer') {
    Get-ChildItem -LiteralPath (Split-Path -Parent $row.path) -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { Add-Capture $_.FullName 'sibling of database carrying target MFC file version' }
  }
}
foreach ($row in @($inventoryRows | Where-Object { $_.target_version_match -or $_.target_path_match })) {
  Add-Capture $row.path 'file with target version'
}
foreach ($row in @($patchRows | Where-Object { $_.vc_candidate -and -not $_.already_known })) {
  Add-Capture $row.path 'uncaptured VC servicing patch'
}
foreach ($row in @($libRows | Where-Object { $_.PSObject.Properties['target_objects'] -and $_.target_objects -gt 0 })) {
  Add-Capture $row.path 'static library with target-build objects'
}
Write-JsonFile $captureRows.ToArray() 'captures.json'

# --- Result ----------------------------------------------------------------------------------
$mfcDllVersions = @($inventoryRows | Where-Object { $_.relative -match '(?i)mfc140u?d?\.dll$' } |
  ForEach-Object { "$($_.root)\$($_.relative) $($_.file_version)" })
$libSummary = @($libRows | Where-Object { $_.PSObject.Properties['dominant_build'] } |
  Group-Object dominant_build | ForEach-Object { [pscustomobject]@{ dominant_build = $_.Name; libraries = $_.Count } })

[pscustomobject]@{
  image = $env:APPVEYOR_BUILD_WORKER_IMAGE
  target_build = $targetBuild
  package_cache_file_count = @($cacheFiles | Where-Object { (Get-RootRelative $_.FullName).root -eq 'PackageCache' }).Count
  vs_packages_file_count = @($cacheFiles | Where-Object { (Get-RootRelative $_.FullName).root -eq 'VSPackages' }).Count
  patch_cache_file_count = @($cacheFiles | Where-Object { (Get-RootRelative $_.FullName).root -eq 'PatchCache' }).Count
  cache_target_path_matches = @($cachePathTargetMatches | Select-Object -First 200 | ForEach-Object { (Get-RootRelative $_.FullName).relative })
  inventory_count = $inventoryRows.Count
  inventory_target_matches = @($inventoryRows | Where-Object { $_.target_version_match -or $_.target_path_match } |
    ForEach-Object { "$($_.root)\$($_.relative) $($_.file_version)" })
  mfc_dll_versions = $mfcDllVersions
  database_count = $databaseRows.Count
  database_target_matches = @($databaseRows | Where-Object { $_.target_version_match } | ForEach-Object { $_.path })
  patch_count = $patchRows.Count
  vc_patches = @($patchRows | Where-Object { $_.vc_candidate } |
    ForEach-Object { "$($_.path) | $($_.title) | known=$($_.already_known)" })
  library_count = $libRows.Count
  library_dominant_builds = $libSummary
  libraries_with_target_objects = @($libRows | Where-Object { $_.PSObject.Properties['target_objects'] -and $_.target_objects -gt 0 } |
    ForEach-Object { "$($_.path) target=$($_.target_objects) dominant=$($_.dominant_build)" })
  captured_file_count = @($captureRows | Where-Object { -not $_.omitted_by_cap }).Count
  captured_bytes = $capturedBytes
  omitted_by_cap_count = @($captureRows | Where-Object { $_.omitted_by_cap }).Count
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $metadataRoot 'RESULT.json') -Encoding UTF8

$metadataPrefix = $metadataRoot.TrimEnd('\') + '\'
Get-ChildItem -LiteralPath $metadataRoot -Recurse -File |
  Sort-Object FullName |
  ForEach-Object {
    "$($_.FullName.Substring($metadataPrefix.Length))`t$($_.Length)`t$(Get-Sha256 $_.FullName)"
  } | Set-Content -LiteralPath (Join-Path $metadataRoot 'SHA256SUMS.tsv') -Encoding ASCII

# Empty directories are not uploaded as artifacts; keep the payload artifact present.
if (@(Get-ChildItem -LiteralPath $captureRoot -Recurse -File).Count -eq 0) {
  'no files captured' | Set-Content -LiteralPath (Join-Path $captureRoot 'EMPTY.txt') -Encoding ASCII
}
Get-Content -LiteralPath (Join-Path $metadataRoot 'RESULT.json') | Write-Host
