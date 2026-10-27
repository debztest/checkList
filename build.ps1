# StickyChecklist.ps1 を埋め込んだ StickyChecklist.exe と、
# それを埋め込んだインストーラー StickyChecklistSetup.exe（配布用）を作成する。
# StickyChecklist.ps1 を変更したら、このスクリプトを実行して exe を作り直す。
#   powershell -ExecutionPolicy Bypass -File build.ps1

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sma  = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter 'System.Management.Automation.dll' |
        Select-Object -First 1 -ExpandProperty FullName
$out  = Join-Path $here 'StickyChecklist.exe'

# 起動中の exe は上書きできないが名前は変えられるので、古い方を .old に退避してから作る
$old = "$out.old"
if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
if (Test-Path $out) { Move-Item $out $old -Force }

& $csc /nologo /target:winexe /optimize+ /codepage:65001 `
    "/out:$out" `
    "/win32icon:$(Join-Path $here 'StickyChecklist.ico')" `
    "/resource:$(Join-Path $here 'StickyChecklist.ps1'),StickyChecklist.ps1" `
    "/reference:$sma" /reference:System.Windows.Forms.dll /reference:System.Core.dll `
    (Join-Path $here 'Launcher.cs') (Join-Path $here 'Shortcut.cs')
if ($LASTEXITCODE -ne 0) { throw 'ビルドに失敗しました' }
"作成しました: $out"

# インストーラー（本体 exe を中に入れる）
$setup = Join-Path $here 'StickyChecklistSetup.exe'
& $csc /nologo /target:winexe /optimize+ /codepage:65001 `
    "/out:$setup" `
    "/win32icon:$(Join-Path $here 'StickyChecklist.ico')" `
    "/resource:$out,StickyChecklist.exe" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    (Join-Path $here 'Setup.cs') (Join-Path $here 'Shortcut.cs')
if ($LASTEXITCODE -ne 0) { throw 'インストーラーのビルドに失敗しました' }
"作成しました: $setup"
