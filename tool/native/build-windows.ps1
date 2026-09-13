# Build libsmb2.dll for Windows (x86_64 + arm64) from the UNMODIFIED
# upstream libsmb2 sources vendored at third_party/libsmb2.
# The submodule must be pinned to the official libsmb2-6.2 tag.
#
# Outputs (under build/native/dist/):
#   libsmb2_windows-x86_64.dll
#   libsmb2_windows-arm64.dll
#
# Uses the MSVC toolchain (Visual Studio generator), which statically
# carries no extra runtime beyond the UCRT that ships with Windows 10+.
#
# Requirements: Visual Studio 2022 Build Tools (x64 + ARM64 compilers),
# CMake >= 3.16.
$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Src  = Join-Path $Root 'third_party\libsmb2'
$Out  = Join-Path $Root 'build\native\windows'
$Dist = Join-Path $Root 'build\native\dist'
$ExpectedLibsmb2Commit = 'd67e213a5c4e7e4969fd81f0b95e4ca5831fbba1'
$ActualLibsmb2Commit = (git -C $Src rev-parse HEAD).Trim()
if ($ActualLibsmb2Commit -ne $ExpectedLibsmb2Commit) {
    throw "third_party/libsmb2 must be pinned to libsmb2-6.2 ($ExpectedLibsmb2Commit), got $ActualLibsmb2Commit"
}

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }

$Targets = @(
    @{ Platform = 'x64';   Artifact = 'libsmb2_windows-x86_64.dll' },
    @{ Platform = 'ARM64'; Artifact = 'libsmb2_windows-arm64.dll' }
)

foreach ($t in $Targets) {
    $bdir = Join-Path $Out $t.Platform
    Write-Host "── building Windows $($t.Platform)"
    cmake -S $Src -B $bdir -A $t.Platform `
        -DBUILD_SHARED_LIBS=ON `
        -DENABLE_EXAMPLES=OFF `
        -DENABLE_LIBKRB5=OFF `
        -DENABLE_GSSAPI=OFF `
        -DHAVE_LIBKRB5=0 `
        -DHAVE_GSSAPI_GSSAPI_H=0
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
    cmake --build $bdir --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

    # The upstream target is `smb2`, so MSVC emits smb2.dll; the package
    # loads by file name (DynamicLibrary.open('libsmb2.dll')), so the file
    # is renamed here — the PE-internal name is irrelevant for that.
    $dll = Join-Path $bdir 'lib\Release\smb2.dll'
    if (-not (Test-Path $dll)) {
        $dll = Get-ChildItem -Recurse -Path $bdir -Filter 'smb2.dll' | Select-Object -First 1 -ExpandProperty FullName
    }
    Copy-Item $dll (Join-Path $Dist $t.Artifact) -Force
    Write-Host "── wrote $(Join-Path $Dist $t.Artifact)"
}

Write-Host "Done. Artifacts in $Dist"
