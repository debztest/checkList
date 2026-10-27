# 付箋チェックリスト
# 画面上に常に表示される付箋風のチェックリスト。複数人での共有にも対応。
#
# 設定は exe（またはこのスクリプト）と同じフォルダの StickyChecklist.ini に書く（無ければ初回起動時に作られる）。
#   PersonalFile : 自分用チェックリストの保存先（ネットワーク上に置けば複数の端末で使える）
#   SharedFile   : 共有チェックリストの保存先（全員が読み書きできる共有フォルダ）。空なら共有はオフ
#   UserName / Members : 自分の名前 / 共有範囲で選べるメンバー
#
# チェックリストのファイル形式（1行1項目・タブ区切り。文字列の改行は \n、タブは \t、\ は \\）
#   id, 完了[0/1], 重要[0/1], 期日[yyyy-MM-dd], 時刻[HH:mm], ステータス, 案件, 内容, 詳細メモ, 作成者, 共有範囲, 更新日時, 更新者,
#   ステータスコメント（最新）, 添付ファイル名（| 区切り）
# 自分用・共有とも、変更した項目だけを id で書き換える（書き込み中はロック）ので、同時に使っても他の変更を消さない。
# 進捗の履歴は、チェックリストのファイルと同じ場所の「〇〇.history.txt」に追記する（id, 日時, 更新者, ステータス, コメント）。
# 添付ファイルは、チェックリストのファイルと同じ場所の attachments\<id>\ に置く。
# ウィンドウ位置などの設定は %APPDATA%\StickyChecklist\data.json に保存。

param(
    [string]$BaseDir = $PSScriptRoot,   # 設定ファイルを置くフォルダ（exe から起動したときは exe のフォルダ）
    [string]$IconSource                 # アイコン（.ico または .exe）。省略時は BaseDir の StickyChecklist.ico
)
if (-not $IconSource) { $IconSource = Join-Path $BaseDir 'StickyChecklist.ico' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeDrag {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
    // テキストボックスに薄い文字の案内（プレースホルダー）を出す
    public static void SetCue(IntPtr hWnd, string text) { SendMessage(hWnd, 0x1501, (IntPtr)1, text); }
    // テキストボックスが今の幅で折り返したときの行数
    public static int LineCount(IntPtr hWnd) { return (int)SendMessage(hWnd, 0xBA, 0, 0); }
    // 読み取り専用の文字欄で、点滅する縦線（キャレット）を出さない
    [DllImport("user32.dll")] public static extern bool HideCaret(IntPtr hWnd);
}
'@

# 一覧の中のテキストボックス（項目の文字・詳細メモ）。マウスホイールはテキストボックスで止めず、一覧のスクロールに回す
# （止まると、一番下まで行ったあと上にスクロールできなくなる）
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class RowTextBox : TextBox {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x020A) {   // WM_MOUSEWHEEL
            Control p = this.Parent;
            while (p != null && !(p is FlowLayoutPanel)) p = p.Parent;
            if (p != null) { SendMessage(p.Handle, m.Msg, m.WParam, m.LParam); return; }
        }
        base.WndProc(ref m);
    }
}
'@

# Ctrl＋ホイールを、付箋のどこで回しても受け取る（文字の拡大・縮小に使う）
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
// あわせて、どこかをクリックしたとき（コピー用の選択を外す）と Ctrl＋C（選んだ文字をコピー）も受け取る
public class CtrlWheelFilter : IMessageFilter {
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] static extern short GetKeyState(int vKey);
    public IntPtr MainWindow;
    public Action<int> OnZoom;
    public Action<IntPtr> OnMouseDown;
    public Func<bool> OnCopy;
    public bool PreFilterMessage(ref Message m) {
        // 左・右・中ボタンを押した（枠やスクロールバーの上も）
        if (m.Msg == 0x201 || m.Msg == 0x203 || m.Msg == 0x204 || m.Msg == 0x207 || m.Msg == 0xA1 || m.Msg == 0xA4) {
            if (OnMouseDown != null) OnMouseDown(m.HWnd);
            return false;
        }
        if (m.Msg == 0x100 && m.WParam.ToInt64() == 0x43 && (GetKeyState(0x11) & 0x8000) != 0) {   // Ctrl＋C
            return OnCopy != null && OnCopy();                               // コピーしたらそこで止める
        }
        if (m.Msg != 0x020A) return false;                                   // WM_MOUSEWHEEL
        long w = m.WParam.ToInt64();
        if ((w & 0x0008) == 0) return false;                                 // Ctrl を押していない
        if (GetAncestor(m.HWnd, 2) != MainWindow) return false;              // 付箋の本体の上だけ（編集画面などは対象外）
        if (OnZoom != null) OnZoom((short)((w >> 16) & 0xFFFF));
        return true;                                                         // スクロールはしない
    }
}
'@

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$dataDir  = Join-Path $env:APPDATA 'StickyChecklist'
$dataFile = Join-Path $dataDir 'data.json'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

# ---------- 設定ファイル（StickyChecklist.ini） ----------
$configFile = Join-Path $BaseDir 'StickyChecklist.ini'
if (-not (Test-Path $configFile)) {
    $defaultConfig = @"
; 付箋チェックリスト 設定ファイル
; 変更したら付箋を閉じて、起動し直してください。
; パスは絶対パス、またはこのファイルがあるフォルダからの相対パス。%USERPROFILE% なども使えます。

[基本]
; 自分の名前（共有した項目の作成者として表示されます）
UserName=$env:USERNAME

; 自分用チェックリストの保存先
PersonalFile=checklist.txt

[共有]
; 共有チェックリストの保存先。全員が読み書きできる共有フォルダ（ファイルサーバーなど）のファイルを指定します。
; 例: SharedFile=\\fileserver\share\付箋チェックリスト\shared.txt
; 空欄なら共有機能はオフです。
SharedFile=

; 共有範囲で選べるメンバー（カンマ区切り）。共有ファイルに出てくる人は自動で追加されます。
; 例: Members=佐藤,鈴木,田中
Members=

; 念のための更新確認の間隔（秒）。ふだんは変更をすぐ反映しますが、ネットワーク越しで通知が届かないときのため
RefreshSeconds=10

[更新]
; 新しい版の配布元。ここに置かれた StickyChecklist.exe が新しくなると、各自の付箋が自動で入れ替わって起動し直します。
; 空欄なら SharedFile と同じフォルダの StickyChecklist.exe を見ます。
; 例: UpdateFrom=\\fileserver\share\付箋チェックリスト\StickyChecklist.exe
UpdateFrom=
"@
    [System.IO.File]::WriteAllText($configFile, $defaultConfig, $utf8Bom)
}

$config = @{}
foreach ($line in [System.IO.File]::ReadAllLines($configFile, [System.Text.Encoding]::UTF8)) {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith(';') -or $l.StartsWith('#') -or $l.StartsWith('[')) { continue }
    $i = $l.IndexOf('=')
    if ($i -gt 0) {
        $v = $l.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) { $v = $v.Substring(1, $v.Length - 2).Trim() }   # "…" で囲んであっても読めるように
        $config[$l.Substring(0, $i).Trim()] = $v
    }
}

function Resolve-ConfigPath([string]$p) {
    if (-not $p) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $BaseDir $p }
    return $p
}

$script:me = if ($config['UserName']) { $config['UserName'] } else { $env:USERNAME }
$personalFile = Resolve-ConfigPath $(if ($config['PersonalFile']) { $config['PersonalFile'] } else { 'checklist.txt' })
$sharedFile   = Resolve-ConfigPath $config['SharedFile']
$script:configWarning = ''
if ($sharedFile -and [System.IO.Path]::GetFullPath($sharedFile) -eq [System.IO.Path]::GetFullPath($personalFile)) {
    # 同じファイルを「自分用」と「共有」の両方にすると項目が混ざるので、共有はオフにする
    $script:configWarning = "設定ファイルの SharedFile（共有）と PersonalFile（自分用）が同じファイルになっています。`n共有は別のファイル（例: shared.txt）を指定してください。それまで共有はオフにします。`n`n$sharedFile"
    $sharedFile = ''
}
$sharingOn    = [bool]$sharedFile
$script:configMembers = @(($config['Members'] -split '[,、，]') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$script:knownNames = New-Object System.Collections.Generic.List[string]   # 共有ファイルに出てきた名前
$refreshSec = 10
# 新しい版の配布元（exe で動いているときだけ使う。入れ替えは exe 本体が起動時・終了時に行う）
$script:updateSource = ''
if ($IconSource -like '*.exe') {
    $us = if ($config['UpdateFrom']) { Resolve-ConfigPath $config['UpdateFrom'] } elseif ($sharedFile) { Join-Path (Split-Path $sharedFile -Parent) 'StickyChecklist.exe' } else { '' }
    try { if ($us -and [System.IO.Path]::GetFullPath($us) -ne [System.IO.Path]::GetFullPath($IconSource)) { $script:updateSource = $us } } catch { }
}
$script:restartForUpdate = $false
if ($config['RefreshSeconds'] -match '^\d+$' -and [int]$config['RefreshSeconds'] -ge 3) { $refreshSec = [int]$config['RefreshSeconds'] }

$script:stamps = @{}            # ファイルごとの、最後に読んだ／書いたときの更新日時
$script:sharedError = ''
$script:applying = $false       # ファイルの内容を画面に反映中（変更扱いにしない）
$script:pendingHistory = New-Object System.Collections.ArrayList   # 書き込めなかった履歴（あとで再試行）
$script:hiddenStatuses = New-Object System.Collections.Generic.List[string]   # 絞り込みで隠すステータス

# ---------- 色・フォント ----------
$noteColor  = [System.Drawing.Color]::FromArgb(255, 247, 170)
$barColor   = [System.Drawing.Color]::FromArgb(250, 225, 100)
$pinColor   = [System.Drawing.Color]::FromArgb(235, 195, 60)
$redColor   = [System.Drawing.Color]::FromArgb(220, 40, 40)
$shareColor = [System.Drawing.Color]::FromArgb(40, 120, 210)
$memoBack   = [System.Drawing.Color]::FromArgb(255, 253, 225)
$font      = New-Object System.Drawing.Font('Yu Gothic UI', 10)
$fontDone  = New-Object System.Drawing.Font('Yu Gothic UI', 10, [System.Drawing.FontStyle]::Strikeout)
$fontBar   = New-Object System.Drawing.Font('Yu Gothic UI', 9, [System.Drawing.FontStyle]::Bold)
$fontDays  = New-Object System.Drawing.Font('Yu Gothic UI', 9)
$fontTime  = New-Object System.Drawing.Font('Yu Gothic UI', 7.5)
$fontBadge = New-Object System.Drawing.Font('Yu Gothic UI', 7, [System.Drawing.FontStyle]::Bold)
$fontTag   = New-Object System.Drawing.Font('Yu Gothic UI', 8, [System.Drawing.FontStyle]::Bold)
$script:loading = $true

# 一覧の文字の大きさ（Ctrl＋ホイールで変える。倍率は data.json に保存）
$script:zoom = 1.0
function Set-ListFonts {
    $z = $script:zoom
    $script:zItem  = New-Object System.Drawing.Font('Yu Gothic UI', [single](10 * $z))
    $script:zDone  = New-Object System.Drawing.Font('Yu Gothic UI', [single](10 * $z), [System.Drawing.FontStyle]::Strikeout)
    $script:zSmall = New-Object System.Drawing.Font('Yu Gothic UI', [single](9 * $z))
    $script:zTiny  = New-Object System.Drawing.Font('Yu Gothic UI', [single](7.5 * $z))
    # アイコン・上部・下部も同じ倍率で（100% でも以前より大きめ）
    $script:zBadge  = New-Object System.Drawing.Font('Yu Gothic UI', [single](8 * $z), [System.Drawing.FontStyle]::Bold)
    $script:zTag    = New-Object System.Drawing.Font('Yu Gothic UI', [single](8.5 * $z), [System.Drawing.FontStyle]::Bold)
    $script:zIcon   = New-Object System.Drawing.Font('Segoe UI Symbol', [single](13 * $z))
    $script:zIconS  = New-Object System.Drawing.Font('Segoe UI Symbol', [single](11 * $z))
    $script:zToggle = New-Object System.Drawing.Font('Segoe UI Symbol', [single](9 * $z))
    $script:zDel    = New-Object System.Drawing.Font('Yu Gothic UI', [single](12 * $z))
    $script:zUi     = New-Object System.Drawing.Font('Yu Gothic UI', [single](9.5 * $z))
    $script:zUiBold = New-Object System.Drawing.Font('Yu Gothic UI', [single](9.5 * $z), [System.Drawing.FontStyle]::Bold)
    $script:zInput  = New-Object System.Drawing.Font('Yu Gothic UI', [single](10.5 * $z))
    $script:zTotals = New-Object System.Drawing.Font('Yu Gothic UI', [single](8.5 * $z))
    $script:badgeW  = [int](34 * $z)          # 重要・共有の丸の大きさ
    $script:rowPad  = [int](7 * $z)           # 行の上の余白（文字・アイコンの縦位置）
}
function Z([double]$n) { return [int][Math]::Round($n * $script:zoom) }   # 倍率をかけた大きさ
Set-ListFonts

# ステータス（チェック□とは連動しない。どちらも手で変える）
$statusList = @('未着手', '進行中', '確認待ち', '差戻', '修正', '保留', '完了')
function New-Color($r, $g, $b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
$statusColors = @{   # 札の色（背景, 文字）
    '未着手'   = @((New-Color 235 235 235), (New-Color 110 110 110))
    '進行中'   = @((New-Color 255 228 170), (New-Color 150 90 0))
    '確認待ち' = @((New-Color 230 215 255), (New-Color 100 50 170))
    '差戻'     = @((New-Color 255 210 210), (New-Color 180 20 20))
    '修正'     = @((New-Color 210 228 255), (New-Color 20 70 170))
    '保留'     = @((New-Color 225 225 205), (New-Color 100 100 60))
    '完了'     = @((New-Color 205 240 210), (New-Color 30 120 50))
}
$unreadColor = New-Color 222 236 255   # 他の人が更新した項目の目印

# ---------- フォーム ----------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'SizableToolWindow'   # タイトルバー無し＋枠でサイズ変更可
$form.ControlBox = $false
$form.Text = ''
$form.ShowInTaskbar = $true
$form.TopMost = $true
$form.BackColor = $noteColor
if (Test-Path $IconSource) {   # タスクバーのアイコン
    try {
        if ($IconSource -like '*.exe') { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconSource) }
        else { $form.Icon = New-Object System.Drawing.Icon($IconSource) }
    } catch { }
}
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size(300, 440)
$form.MinimumSize = New-Object System.Drawing.Size(250, 260)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - 320), ($wa.Top + 40))

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000   # 説明を長めに出す（元に戻すの注釈など）

# 編集画面などを開くときに使う。開いている間は付箋本体の説明（ToolTip）を止める
# （止めないと、編集画面の上に後ろの一覧の説明が出てしまう）
$script:modalDepth = 0
function Show-Modal($dlg, $owner) {
    $script:modalDepth++
    $tip.Active = $false
    try { return $dlg.ShowDialog($owner) }
    finally {
        $script:modalDepth--
        if ($script:modalDepth -le 0) { $script:modalDepth = 0; $tip.Active = $true }   # 編集画面から進捗画面を開いた場合は、全部閉じてから戻す
    }
}

# ---------- 丸バッジ（Name が imp なら「重要」赤、share なら「共有」青。Tag が $true で塗りつぶし） ----------
$badgePaint = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $h = [Math]::Min($s.ClientSize.Height, $s.ClientSize.Width + 2)   # 折り返しで行が高くなっても丸は1行目の位置
    $d = [Math]::Min($s.ClientSize.Width, $h) - 3
    $x = [int](($s.ClientSize.Width - $d) / 2)
    $y = [int](($h - $d) / 2)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $rectF = New-Object System.Drawing.RectangleF([single]$x, [single]($y + 1), [single]$d, [single]$d)
    $label = if ($s.Name -eq 'share') { '共有' } else { '重要' }
    $color = if ($s.Name -eq 'share') { $shareColor } else { $redColor }
    if (-not $s.Enabled) { $color = [System.Drawing.Color]::Gainsboro }
    if ([bool]$s.Tag) {
        $b = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($b, $x, $y, $d, $d)
        $g.DrawString($label, $script:zBadge, [System.Drawing.Brushes]::White, $rectF, $sf)
        $b.Dispose()
    } else {
        $c = if ($s.Enabled) { [System.Drawing.Color]::DarkGray } else { [System.Drawing.Color]::Gainsboro }
        $p = New-Object System.Drawing.Pen($c, 1.5)
        $tb = New-Object System.Drawing.SolidBrush($c)
        $g.DrawEllipse($p, $x, $y, $d, $d)
        $g.DrawString($label, $script:zBadge, $tb, $rectF, $sf)
        $p.Dispose(); $tb.Dispose()
    }
    $sf.Dispose()
}

function New-Badge([string]$kind, [bool]$on) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Name = $kind
    $p.Width = 30
    $p.Height = 28
    $p.Tag = $on
    $p.Add_Paint($badgePaint)
    return $p
}

# 期日の表示（1行目に日付と残り日数、時刻があれば2行目に小さく）
$duePaint = {
    param($s, $e)
    $d = $s.Tag
    if (-not $d) { return }
    $flags = [System.Windows.Forms.TextFormatFlags]'Right, NoPadding'
    $y = $script:rowPad
    if ($d.upd) {   # 最終更新日時（薄いグレーで小さく）
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $d.upd, $script:zTiny, (New-Object System.Drawing.Rectangle(0, ($y - 2), $s.Width, ($script:zTiny.Height + 2))), [System.Drawing.Color]::FromArgb(160, 160, 160), $flags)
        $y += $script:zTiny.Height
    }
    if (-not $d.line1) { return }
    if ($d.today) {   # 今日が締め日: 赤地に白文字
        $tw = [System.Windows.Forms.TextRenderer]::MeasureText($d.line1, $script:zSmall, [System.Drawing.Size]::Empty, [System.Windows.Forms.TextFormatFlags]::NoPadding).Width + 6
        $b = New-Object System.Drawing.SolidBrush($redColor)
        $e.Graphics.FillRectangle($b, ($s.Width - $tw), $y, $tw, ($script:zSmall.Height + 1))
        $b.Dispose()
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $d.line1, $script:zSmall, (New-Object System.Drawing.Rectangle(0, $y, ($s.Width - 3), ($script:zSmall.Height + 2))), [System.Drawing.Color]::White, $flags)
    } else {
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $d.line1, $script:zSmall, (New-Object System.Drawing.Rectangle(0, $y, $s.Width, ($script:zSmall.Height + 2))), $d.color, $flags)
    }
    if ($d.line2) {
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $d.line2, $script:zTiny, (New-Object System.Drawing.Rectangle(0, ($y + $script:zSmall.Height + 2), $s.Width, ($script:zTiny.Height + 2))), $d.color, $flags)
    }
}

# 最終更新日時の表示（「10/27 15:22」。更新の記録がなければ記載日時）
function Get-UpdatedText($t) {
    $at = if ($t.updatedAt) { [string]$t.updatedAt } else { [string]$t.createdAt }
    $dt = [datetime]::MinValue
    if ($at -and [datetime]::TryParse($at, [ref]$dt)) { return $dt.ToString('M/d HH:mm') }
    return ''
}

# 状態（差戻・修正）の札
$statusPaint = {
    param($s, $e)
    $st = [string]$s.Tag
    if (-not $st -or -not $statusColors.ContainsKey($st)) { return }
    $w = $s.Width - 6
    $h = $script:zTag.Height + 4
    $y = [Math]::Max(2, $script:rowPad - 1)
    $back = New-Object System.Drawing.SolidBrush($statusColors[$st][0])
    $e.Graphics.FillRectangle($back, 3, $y, $w, $h)
    $back.Dispose()
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $st, $script:zTag, (New-Object System.Drawing.Rectangle(3, $y, $w, $h)), $statusColors[$st][1],
        [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, NoPadding')
}

# ---------- 共有範囲の選択（▾ を押すとチェック付きの一覧。何も選ばなければ「全員」） ----------
function Get-Members {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($script:configMembers) + @($script:knownNames)) {
        if ($n -and $n -ne '全員' -and $n -ne $script:me -and -not $list.Contains($n)) { $list.Add($n) }
    }
    return $list.ToArray()   # 名前を1つずつ返す（@(…) で囲んでも1件にまとまらないように）
}

function Get-ScopeText($sel) {
    if ($sel.Count -eq 0) { return '全員' }
    return ($sel -join '、')
}

function Update-ScopeButton($btn) {
    $btn.Text = (Get-ScopeText $btn.Tag) + ' ▾'
    if ($btn.Name -ne 'dlgPicker') { $tip.SetToolTip($btn, '共有範囲: ' + (Get-ScopeText $btn.Tag)) }   # 編集画面のものは付箋本体の説明に登録しない
}

function New-ScopePicker {
    $b = New-Object System.Windows.Forms.Button
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::DarkGray
    $b.BackColor = [System.Drawing.Color]::White
    $b.Font = $fontDays
    $b.TextAlign = 'MiddleLeft'
    $b.AutoEllipsis = $true
    $b.Cursor = 'Hand'
    $b.TabStop = $false
    $b.Tag = New-Object System.Collections.Generic.List[string]   # 選んだメンバー（空 = 全員）
    $b.Add_Click({ param($s, $e) Show-ScopeMenu $s })
    Update-ScopeButton $b
    return $b
}

function Show-ScopeMenu($btn) {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Tag = $btn
    $all = New-Object System.Windows.Forms.ToolStripMenuItem('全員')
    $all.Tag = '*'
    $m.Items.Add($all) | Out-Null
    $m.Items.Add('-') | Out-Null
    $members = @(Get-Members)
    foreach ($n in $members) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($n)
        $mi.Tag = $n
        $m.Items.Add($mi) | Out-Null
    }
    if ($members.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem('（メンバーは設定ファイルの Members に追加）')
        $none.Enabled = $false
        $m.Items.Add($none) | Out-Null
    }
    $refresh = {
        param($menu)
        $sel = $menu.Tag.Tag
        foreach ($it in $menu.Items) {
            if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.Tag) {
                $it.Checked = if ($it.Tag -eq '*') { $sel.Count -eq 0 } else { $sel.Contains([string]$it.Tag) }
            }
        }
    }
    & $refresh $m
    $m.Add_ItemClicked({
        param($s, $e)
        $sel = $s.Tag.Tag
        $tagv = [string]$e.ClickedItem.Tag
        if ($tagv -eq '*') { $sel.Clear() }
        elseif ($tagv) { if ($sel.Contains($tagv)) { $sel.Remove($tagv) | Out-Null } else { $sel.Add($tagv) } }
        foreach ($it in $s.Items) {
            if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.Tag) {
                $it.Checked = if ($it.Tag -eq '*') { $sel.Count -eq 0 } else { $sel.Contains([string]$it.Tag) }
            }
        }
        Update-ScopeButton $s.Tag
    })
    # 項目を押しても閉じない（複数選べるように）
    $m.Add_Closing({ param($s, $e) if ($e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) { $e.Cancel = $true } })
    if ($btn -eq $scopeInput) {
        # 付箋の一番下にあるので上に開く
        $m.Show($btn, (New-Object System.Drawing.Point(0, 0)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveRight)
    } else {
        $m.Show($btn, 0, $btn.Height)
    }
}

function Set-PickerScope($btn, [string[]]$scope) {
    $btn.Tag.Clear()
    foreach ($n in $scope) { if ($n -and $n -ne '全員' -and -not $btn.Tag.Contains($n)) { $btn.Tag.Add($n) } }
    Update-ScopeButton $btn
}

# ---------- 上部バー（ドラッグで移動） ----------
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Top'
$bar.Height = 28
$bar.BackColor = $barColor

$title = New-Object System.Windows.Forms.Label
$title.Text = '✔ チェックリスト'
$title.Font = $fontBar
$title.Dock = 'Left'
$title.AutoSize = $true
$title.TextAlign = 'MiddleLeft'
$title.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

# 件数表示「全○件（未○件：済○件）」
$lblTotals = New-Object System.Windows.Forms.Label
$lblTotals.Dock = 'Fill'
$lblTotals.Font = New-Object System.Drawing.Font('Yu Gothic UI', 8)
$lblTotals.ForeColor = [System.Drawing.Color]::FromArgb(110, 90, 30)
$lblTotals.TextAlign = 'MiddleLeft'
$lblTotals.AutoEllipsis = $true
# 件数は必ず1行で描く（大きくしたときに2行に折り返さないように。入りきらない分は「…」）
$lblTotals.Add_Paint({
    param($s, $e)
    $flags = [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis'
    $e.Graphics.Clear($s.BackColor)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Tag, $s.Font, $s.ClientRectangle, $s.ForeColor, $flags)
})

# 新しい版のお知らせ（件数表示の場所に青地・白文字で出す。ⓘ にマウスを乗せると変更内容）
$updPanel = New-Object System.Windows.Forms.Panel
$updPanel.Dock = 'Fill'
$updPanel.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 200)
$updPanel.Visible = $false
$lblUpdMsg = New-Object System.Windows.Forms.Label
$lblUpdMsg.Text = 'Verが変更されました。反映するには更新アイコンを押して下さい'
$lblUpdMsg.Dock = 'Left'
$lblUpdMsg.AutoSize = $true
$lblUpdMsg.Font = New-Object System.Drawing.Font('Yu Gothic UI', 8, [System.Drawing.FontStyle]::Bold)
$lblUpdMsg.ForeColor = [System.Drawing.Color]::White
$lblUpdMsg.TextAlign = 'MiddleLeft'
$lblUpdMsg.UseMnemonic = $false
$lblUpdMsg.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$lblUpdInfo = New-Object System.Windows.Forms.Label
$lblUpdInfo.Text = 'ⓘ'
$lblUpdInfo.Dock = 'Left'
$lblUpdInfo.AutoSize = $true
$lblUpdInfo.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 11)
$lblUpdInfo.ForeColor = [System.Drawing.Color]::White
$lblUpdInfo.TextAlign = 'MiddleLeft'
$lblUpdInfo.Cursor = [System.Windows.Forms.Cursors]::Help
$updTip = New-Object System.Windows.Forms.ToolTip   # 変更内容は長いので、長めに出しておく
$updTip.AutoPopDelay = 32000
$updTip.InitialDelay = 100
$updTip.ToolTipTitle = '新しい版の変更内容'
$updPanel.Controls.Add($lblUpdInfo)
$updPanel.Controls.Add($lblUpdMsg)   # 左から: お知らせ・ⓘ

function New-BarButton([string]$text, [int]$width, [string]$tooltip) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Dock = 'Right'
    $b.Width = $width
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $fontBar
    $b.Cursor = 'Hand'
    $b.TabStop = $false
    $tip.SetToolTip($b, $tooltip)
    return $b
}
$btnClose = New-BarButton '×' 28 '閉じる'
$btnPin   = New-BarButton '★' 30 '最前面に固定 ON/OFF'
$btnSort  = New-BarButton '⇅' 30 '並べ替え'
$btnFilter = New-BarButton '🔍' 30 '絞り込み'
$btnReload = New-BarButton '⟳' 30 '今すぐ更新（他の人・他の端末の変更を読み込む）'
$btnUndo = New-BarButton '↶' 30 '元に戻す（Ctrl＋Z）'
$btnRedo = New-BarButton '↷' 30 'やり直す（Ctrl＋Y）'
$fontIcon = New-Object System.Drawing.Font('Segoe UI Symbol', 11)
$btnPin.Font  = $fontIcon
$btnSort.Font = $fontIcon
$btnFilter.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 9)
$btnReload.Font = $fontIcon
$btnUndo.Font = $fontIcon
$btnRedo.Font = $fontIcon

# Dock は後から追加したものが先に配置される
$bar.Controls.Add($lblTotals)
$bar.Controls.Add($updPanel)   # 新しい版があるときは件数の代わりに出す
$bar.Controls.Add($title)
$bar.Controls.Add($btnUndo)
$bar.Controls.Add($btnRedo)
$bar.Controls.Add($btnReload)
$bar.Controls.Add($btnFilter)
$bar.Controls.Add($btnSort)
$bar.Controls.Add($btnPin)
$bar.Controls.Add($btnClose)

$dragHandler = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [NativeDrag]::ReleaseCapture() | Out-Null
        [NativeDrag]::SendMessage($form.Handle, 0xA1, 2, 0) | Out-Null   # WM_NCLBUTTONDOWN / HTCAPTION
    }
}
$bar.Add_MouseDown($dragHandler)
$title.Add_MouseDown($dragHandler)
$lblTotals.Add_MouseDown($dragHandler)
$updPanel.Add_MouseDown($dragHandler)
$lblUpdMsg.Add_MouseDown($dragHandler)

# バーの右クリック: 設定ファイルを開く・共有を今すぐ更新
$barMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miConfig = $barMenu.Items.Add('設定ファイルを開く（StickyChecklist.ini）')
$miRefresh = $barMenu.Items.Add('今すぐ更新（他の人・他の端末の変更を読み込む）')
$miClearUnread = $barMenu.Items.Add('更新の目印をすべて消す')
$miZoomReset = $barMenu.Items.Add('文字の大きさを元に戻す（Ctrl＋0）')
foreach ($c in $bar, $title, $lblTotals, $updPanel, $lblUpdMsg) { $c.ContextMenuStrip = $barMenu }

# ---------- リスト ----------
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.FlowDirection = 'TopDown'
$flow.WrapContents = $false
$flow.Padding = New-Object System.Windows.Forms.Padding(2, 4, 2, 4)
$flow.AutoScroll = $true

# スクロールできる範囲を「最後の行の下端＋余白」にする（自動の計算だと最後の行が少し見切れるため）
function Update-ScrollExtent {
    $flow.PerformLayout()
    $bottomMost = 0
    foreach ($r in $flow.Controls) {
        if ($r.Tag -and -not $r.Tag.shown) { continue }
        $b = $r.Bottom - $flow.DisplayRectangle.Y + $r.Margin.Bottom   # スクロール位置に関係ない位置
        if ($b -gt $bottomMost) { $bottomMost = $b }
    }
    $h = $bottomMost + $flow.Padding.Bottom + 8
    if ($flow.AutoScrollMinSize.Height -ne $h) { $flow.AutoScrollMinSize = New-Object System.Drawing.Size(0, $h) }
}

# 行の幅。縦スクロールバーの分を最初から空けておき、バーが出ても横スクロールにならないようにする
function Get-RowWidth {
    $w = $flow.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - $flow.Padding.Horizontal - 4
    return [Math]::Max(50, $w)
}

# ---------- 絞り込み欄（🔍 ボタンで表示/非表示） ----------
$filterPanel = New-Object System.Windows.Forms.Panel
$filterPanel.Dock = 'Top'
$filterPanel.Height = 87
$filterPanel.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 2)
$filterPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 150)
$filterPanel.Visible = $false

$fLine1 = New-Object System.Windows.Forms.Panel
$fLine1.Dock = 'Top'
$fLine1.Height = 25

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Dock = 'Fill'
$txtSearch.Font = $fontDays
$txtSearch.BorderStyle = 'FixedSingle'

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Dock = 'Right'
$lblCount.AutoSize = $true
$lblCount.Font = $fontDays
$lblCount.ForeColor = [System.Drawing.Color]::DimGray
$lblCount.Padding = New-Object System.Windows.Forms.Padding(4, 4, 2, 0)

$btnFilterReset = New-Object System.Windows.Forms.Button
$btnFilterReset.Text = '解除'
$btnFilterReset.Dock = 'Right'
$btnFilterReset.Width = 40
$btnFilterReset.FlatStyle = 'Flat'
$btnFilterReset.FlatAppearance.BorderSize = 0
$btnFilterReset.Font = $fontBar
$btnFilterReset.Cursor = 'Hand'
$btnFilterReset.TabStop = $false
$tip.SetToolTip($btnFilterReset, '絞り込みを全部解除')

$fLine1.Controls.Add($txtSearch)
$fLine1.Controls.Add($lblCount)
$fLine1.Controls.Add($btnFilterReset)

$fGrid = New-Object System.Windows.Forms.TableLayoutPanel
$fGrid.Dock = 'Bottom'
$fGrid.Height = 54
$fGrid.ColumnCount = 3
$fGrid.RowCount = 2
foreach ($pct in 30, 33, 37) {
    $fGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $pct))) | Out-Null
}
foreach ($i in 1, 2) {
    $fGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
}

# 絞り込みのプルダウン。選択肢は「すべて」などそのまま。閉じているときは左に小さく灰色で項目名（完了・重要…）を描く
function New-FilterCombo([string]$caption, [string[]]$items, [string]$tooltip) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'
    $c.Dock = 'Fill'
    $c.Font = $fontDays
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 2, 3, 0)
    $c.AccessibleName = $caption
    # 絞り込み中は背景に色を付けるため、選んでいる値の部分を自分で描く（標準の見た目だと色が付かない）
    $c.DrawMode = 'OwnerDrawFixed'
    $c.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $isEdit = ($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
        $isSel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $back = if ($isEdit) { $s.BackColor } elseif ($isSel) { [System.Drawing.SystemColors]::Highlight } else { [System.Drawing.Color]::White }
        $fore = if (-not $isEdit -and $isSel) { [System.Drawing.SystemColors]::HighlightText } else { [System.Drawing.Color]::Black }
        $b = New-Object System.Drawing.SolidBrush($back); $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
        $r = $e.Bounds
        if ($isEdit -and $s.AccessibleName) {
            $capFont = $script:zTiny
            $cw = [System.Windows.Forms.TextRenderer]::MeasureText($s.AccessibleName, $capFont).Width
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.AccessibleName, $capFont, $r, [System.Drawing.Color]::Gray, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
            $r = New-Object System.Drawing.Rectangle(($r.X + $cw + 2), $r.Y, [Math]::Max(0, $r.Width - $cw - 2), $r.Height)
        }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $r, $fore, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
    })
    $c.Items.AddRange($items)
    $c.SelectedIndex = 0
    $tip.SetToolTip($c, $tooltip)
    return $c
}
$cmbDone   = New-FilterCombo '完了' @('すべて', '未完了', '完了') 'チェックの有無で絞り込み'
$cmbImp    = New-FilterCombo '重要' @('すべて', '重要のみ', '重要以外') '重要かどうかで絞り込み'
$cmbDue    = New-FilterCombo '期日' @('すべて', '期限切れ', '今日まで', '3日以内', '7日以内', '期日あり', '期日なし') '期日で絞り込み（「今日まで」「○日以内」は期限切れも含む）'
# ステータスの絞り込み（▾ でチェック付きの一覧。チェックを外したステータスを隠す。設定は覚えておく）
$btnStatusFilter = New-Object System.Windows.Forms.Button
$btnStatusFilter.Dock = 'Fill'
$btnStatusFilter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 3, 0)
$btnStatusFilter.FlatStyle = 'Flat'
$btnStatusFilter.FlatAppearance.BorderColor = [System.Drawing.Color]::DarkGray
$btnStatusFilter.BackColor = [System.Drawing.Color]::White
$btnStatusFilter.Font = $fontDays
$btnStatusFilter.TextAlign = 'MiddleLeft'
$btnStatusFilter.Cursor = 'Hand'
$btnStatusFilter.TabStop = $false

function Update-StatusFilterButton {
    $shown = @($statusList | Where-Object { -not $script:hiddenStatuses.Contains($_) })
    $btnStatusFilter.Text = if ($shown.Count -eq $statusList.Count) { 'ステータス　すべて ▾' } elseif ($shown.Count -eq 0) { 'ステータス　なし ▾' } else { "ステータス　$($shown.Count)/$($statusList.Count) ▾" }
    $tip.SetToolTip($btnStatusFilter, 'ステータスで絞り込み' + $(if ($script:hiddenStatuses.Count) { "（隠す: $($script:hiddenStatuses -join '、')）" } else { '' }))
}

function Show-StatusFilterMenu {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($st in $statusList) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($st)
        $mi.Tag = $st
        $mi.Checked = -not $script:hiddenStatuses.Contains($st)
        $m.Items.Add($mi) | Out-Null
    }
    $m.Items.Add('-') | Out-Null
    $miAll = New-Object System.Windows.Forms.ToolStripMenuItem('すべて表示')
    $miAll.Tag = '*all'
    $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('完了・保留を隠す')
    $miOpen.Tag = '*open'
    $m.Items.AddRange(@($miAll, $miOpen))
    $m.Add_ItemClicked({
        param($s, $e)
        $v = [string]$e.ClickedItem.Tag
        if ($v -eq '*all') { $script:hiddenStatuses.Clear() }
        elseif ($v -eq '*open') { $script:hiddenStatuses.Clear(); $script:hiddenStatuses.Add('完了'); $script:hiddenStatuses.Add('保留') }
        elseif ($v) { if ($script:hiddenStatuses.Contains($v)) { $script:hiddenStatuses.Remove($v) | Out-Null } else { $script:hiddenStatuses.Add($v) } }
        foreach ($it in $s.Items) {
            if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $statusList -contains [string]$it.Tag) { $it.Checked = -not $script:hiddenStatuses.Contains([string]$it.Tag) }
        }
        Update-StatusFilterButton
        Apply-Filter
        Save-Data
    })
    $m.Add_Closing({ param($s, $e) if ($e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) { $e.Cancel = $true } })
    $m.Show($btnStatusFilter, 0, $btnStatusFilter.Height)
}
$btnStatusFilter.Add_Click({ Show-StatusFilterMenu })
$cmbShare  = New-FilterCombo '共有' @('すべて', '共有のみ', '自分用のみ', '自分が作成', '他の人が作成') '共有かどうかで絞り込み'
# 担当での絞り込み（メンバーは開くたびに作り直す）
$cmbAssign = New-FilterCombo '担当' @('すべて', '自分（Main・Sub）', '自分がMain', '自分がSub', '担当なし') '担当者で絞り込み（Main＝担当者、Sub＝サブ担当者）'
$script:assignFixed = 5   # 先頭の決まった選択肢の数（その後ろはメンバー名）
# 担当の選択肢のうしろにメンバー名（自分・Members・項目に出てくる担当者）を並べる。選んでいた名前はそのまま
function Update-AssignItems {
    $keep = [string]$cmbAssign.SelectedItem
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($script:me) + @(Get-Members) + @($flow.Controls | ForEach-Object { $_.Tag.assignee; $_.Tag.subAssignee })) {
        if ($n -and -not $names.Contains([string]$n)) { $names.Add([string]$n) }
    }
    while ($cmbAssign.Items.Count -gt $script:assignFixed) { $cmbAssign.Items.RemoveAt($cmbAssign.Items.Count - 1) }
    foreach ($n in $names) { $cmbAssign.Items.Add($n) | Out-Null }
    $i = $cmbAssign.Items.IndexOf($keep)
    $cmbAssign.SelectedIndex = if ($i -ge 0) { $i } else { 0 }
}

$fGrid.Controls.Add($cmbDone, 0, 0)
$fGrid.Controls.Add($cmbImp, 1, 0)
$fGrid.Controls.Add($cmbDue, 2, 0)
$fGrid.Controls.Add($btnStatusFilter, 0, 1)
$fGrid.SetColumnSpan($btnStatusFilter, 1)
$fGrid.Controls.Add($cmbShare, 1, 1)
$fGrid.Controls.Add($cmbAssign, 2, 1)

$filterPanel.Controls.Add($fLine1)
$filterPanel.Controls.Add($fGrid)

# ---------- 下部 入力欄（1段目: 案件・内容・追加 / 2段目: 期日・時刻 / 3段目: 共有範囲・共有・重要） ----------
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = 116
$bottom.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)

$line1 = New-Object System.Windows.Forms.Panel
$line1.Dock = 'Top'
$line1.Height = 50   # 2行分。長い内容も折り返して見える

# 入力欄の薄い案内文字（2行の入力欄では Windows の案内表示が使えないので自前で出す）
function Add-Placeholder($tb, [string]$text) {
    $ph = New-Object System.Windows.Forms.Label
    $ph.Text = $text
    $ph.AutoSize = $true
    $ph.ForeColor = [System.Drawing.Color]::DarkGray
    $ph.BackColor = [System.Drawing.Color]::White
    $ph.Font = $tb.Font
    $ph.Location = New-Object System.Drawing.Point(1, 1)
    $ph.Cursor = 'IBeam'
    $ph.Tag = $tb
    $ph.Add_Click({ param($s, $e) $s.Tag.Focus() | Out-Null })
    $tb.Controls.Add($ph)
    $tb.Tag = $ph
    # 案内文字は、空欄で入力していないときだけ出す（入力中に出すと文字カーソルが隠れる）
    # （Enter・Leave の時点では Focused がまだ切り替わっていないので、それぞれ決め打ちにする）
    $tb.Add_TextChanged({ param($s, $e) $s.Tag.Visible = ($s.Text -eq '' -and -not $s.Focused) })
    $tb.Add_Enter({ param($s, $e) $s.Tag.Visible = $false })
    $tb.Add_Leave({ param($s, $e) $s.Tag.Visible = ($s.Text -eq '') })
}

# 入力欄は白い枠で包み、内側に少し余白を取る（文字カーソルが枠にくっついて見えにくいため）。
# 入力中の欄は枠をオレンジの太線にして、どこに入力しているか分かるようにする。
$inputFocusColor = [System.Drawing.Color]::FromArgb(235, 150, 30)
function New-InputHost($tb) {
    $h = New-Object System.Windows.Forms.Panel
    $h.BackColor = [System.Drawing.Color]::White
    $h.Padding = New-Object System.Windows.Forms.Padding(6, 5, 3, 2)
    $h.Cursor = 'IBeam'
    $tb.BorderStyle = 'None'
    $tb.Dock = 'Fill'
    $h.Controls.Add($tb)
    $h.Add_Paint({
        param($s, $e)
        $focused = $s.Controls[0].Focused
        $w = if ($focused) { 2 } else { 1 }
        $p = New-Object System.Drawing.Pen($(if ($focused) { $inputFocusColor } else { [System.Drawing.Color]::DarkGray }), $w)
        $off = [int]($w / 2)
        $e.Graphics.DrawRectangle($p, $off, $off, $s.ClientSize.Width - $w, $s.ClientSize.Height - $w)
        $p.Dispose()
    })
    $h.Add_Click({ param($s, $e) $s.Controls[0].Focus() | Out-Null })   # 余白を押しても入力欄へ
    $tb.Add_Enter({ param($s, $e) $s.Parent.Invalidate() })
    $tb.Add_Leave({ param($s, $e) $s.Parent.Invalidate() })
    return $h
}

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Multiline = $true
$txtKey.WordWrap = $true
$txtKey.Font = $font
$tip.SetToolTip($txtKey, '案件名（【】で表示されます）')
Add-Placeholder $txtKey '案件名'
$keyHost = New-InputHost $txtKey
$keyHost.Dock = 'Left'
$keyHost.Width = 110

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Multiline = $true
$txtInput.WordWrap = $true
$txtInput.Font = $font
Add-Placeholder $txtInput '内容（Enterで追加）'
$inputHost = New-InputHost $txtInput
$inputHost.Dock = 'Fill'

# 案件名欄は入力欄の幅の約35%（付箋の幅に合わせて伸び縮み）
$line1.Add_Resize({ $keyHost.Width = [Math]::Max((Z 110), [Math]::Min((Z 240), [int](($line1.Width - $btnAdd.Width) * 0.35))) })

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = '追加'
$btnAdd.Dock = 'Right'
$btnAdd.Width = 48
$btnAdd.FlatStyle = 'Flat'
$btnAdd.BackColor = $barColor
$btnAdd.Font = $fontBar
$btnAdd.Cursor = 'Hand'

$line1.Controls.Add($inputHost)
$line1.Controls.Add($keyHost)
$line1.Controls.Add($btnAdd)

$line2 = New-Object System.Windows.Forms.Panel
$line2.Dock = 'Top'
$line2.Height = 30
$line2.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)

$lblDue = New-Object System.Windows.Forms.Label
$lblDue.Text = '期日'
$lblDue.Font = $fontBar
$lblDue.Dock = 'Left'
$lblDue.Width = 34
$lblDue.TextAlign = 'MiddleLeft'

$dtpDue = New-Object System.Windows.Forms.DateTimePicker
$dtpDue.Format = 'Short'
$dtpDue.ShowCheckBox = $true
$dtpDue.Dock = 'Left'
$dtpDue.Width = 118
$dtpDue.Font = $fontDays
$tip.SetToolTip($dtpDue, 'チェックを入れると期日を設定')

# 時刻（チェックを入れたときだけ使う。DateTimePicker 自体のチェックだと、未設定時に現在時刻が出てしまうので別にする）
$chkTime = New-Object System.Windows.Forms.CheckBox
$chkTime.Dock = 'Left'
$chkTime.Width = 22
$chkTime.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$tip.SetToolTip($chkTime, 'チェックを入れると時刻も設定（24時間表示）')

$dtpTime = New-Object System.Windows.Forms.DateTimePicker
$dtpTime.Format = 'Custom'
$dtpTime.CustomFormat = 'HH:mm'
$dtpTime.ShowUpDown = $true
$dtpTime.Dock = 'Left'
$dtpTime.Width = 58
$dtpTime.Font = $fontDays
$dtpTime.Enabled = $false
$chkTime.Add_CheckedChanged({ $dtpTime.Enabled = $chkTime.Checked })

$line2.Controls.Add($dtpTime)
$line2.Controls.Add($chkTime)
$line2.Controls.Add($dtpDue)
$line2.Controls.Add($lblDue)

$line3 = New-Object System.Windows.Forms.Panel
$line3.Dock = 'Top'
$line3.Height = 30

$lblShare = New-Object System.Windows.Forms.Label
$lblShare.Text = '共有先'
$lblShare.Font = $fontBar
$lblShare.Dock = 'Left'
$lblShare.Width = 44
$lblShare.TextAlign = 'MiddleLeft'

$scopeInput = New-ScopePicker
$scopeInput.Dock = 'Fill'
$scopeInput.Margin = New-Object System.Windows.Forms.Padding(0)

$scopeHost = New-Object System.Windows.Forms.Panel   # ボタンの上下に少し余白
$scopeHost.Dock = 'Fill'
$scopeHost.Padding = New-Object System.Windows.Forms.Padding(0, 2, 4, 2)   # ボタンの高さが 26 未満だと文字が消える
$scopeHost.Controls.Add($scopeInput)

$tglShare = New-Badge 'share' $false
$tglShare.Dock = 'Right'
$tglShare.Cursor = 'Hand'
$tglShare.Add_Click({ if ($tglShare.Enabled) { $tglShare.Tag = -not [bool]$tglShare.Tag; $tglShare.Invalidate() } })

$tglImportant = New-Badge 'imp' $false
$tglImportant.Dock = 'Right'
$tglImportant.Cursor = 'Hand'
$tip.SetToolTip($tglImportant, '重要（ONにすると一番上に追加）')
$tglImportant.Add_Click({ $tglImportant.Tag = -not [bool]$tglImportant.Tag; $tglImportant.Invalidate() })

$line3.Controls.Add($scopeHost)
$line3.Controls.Add($lblShare)
$line3.Controls.Add($tglShare)
$line3.Controls.Add($tglImportant)

if ($sharingOn) {
    $tip.SetToolTip($tglShare, '共有（ONにすると共有先の人に共有して追加）')
} else {
    $tglShare.Enabled = $false
    $scopeInput.Enabled = $false
    $lblShare.ForeColor = [System.Drawing.Color]::Gray
    $tip.SetToolTip($tglShare, '設定ファイル（StickyChecklist.ini）の SharedFile を指定すると共有できます')
}

# Top 同士は後から追加したものが上
$bottom.Controls.Add($line3)
$bottom.Controls.Add($line2)
$bottom.Controls.Add($line1)

$form.Controls.Add($flow)
$form.Controls.Add($filterPanel)   # バーの下に出る
$form.Controls.Add($bar)
$form.Controls.Add($bottom)

# 一番下: 「〇〇 が入力中…」（共有している人が書いているとき）
$typingBar = New-Object System.Windows.Forms.Label
$typingBar.Dock = 'Bottom'
$typingBar.Height = 20
$typingBar.Font = New-Object System.Drawing.Font('Yu Gothic UI', 8.5)
$typingBar.ForeColor = [System.Drawing.Color]::FromArgb(90, 80, 40)
$typingBar.BackColor = [System.Drawing.Color]::FromArgb(250, 235, 160)
$typingBar.TextAlign = 'MiddleLeft'
$typingBar.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$typingBar.AutoEllipsis = $true
$typingBar.UseMnemonic = $false
$typingBar.Visible = $false
$form.Controls.Add($typingBar)


function Reset-InputOptions {
    $txtKey.Text = ''
    $dtpDue.Value = (Get-Date).Date
    $dtpDue.Checked = $false
    $dtpTime.Value = (Get-Date).Date.AddHours(17)
    $chkTime.Checked = $false
    $tglImportant.Tag = $false
    $tglImportant.Invalidate()
    $tglShare.Tag = $false
    $tglShare.Invalidate()
    Set-PickerScope $scopeInput @()
}

# ---------- 右クリックメニュー ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miCopySel = $menu.Items.Add('選択した文字をコピー')
$miCopyAll = $menu.Items.Add('内容をすべてコピー')
$menu.Items.Add('-') | Out-Null
$miEdit = $menu.Items.Add('編集')
$miProgress = $menu.Items.Add('進捗・履歴…（ステータスとコメントを記録）')
$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem('ステータスをすぐ変える')
foreach ($st in $statusList) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($st)
    $mi.Tag = $st
    $mi.Add_Click({ param($s, $e) $src = $menu.SourceControl; if ($src) { Set-RowStatus (Get-RowOf $src) ([string]$s.Tag) '' } })
    $miStatus.DropDownItems.Add($mi) | Out-Null
}
$menu.Items.Add($miStatus) | Out-Null
$miAttach = $menu.Items.Add('ファイルを添付…')
$miOpenFolder = $menu.Items.Add('添付フォルダを開く')
$menu.Items.Add('-') | Out-Null
$miDel  = $menu.Items.Add('削除')
$menu.Add_Opening({
    param($s, $e)
    $row = Get-RowOf $menu.SourceControl
    # 選んだ行を右クリック（または2件以上選んでいる）なら、一括操作のメニューを出す
    $sel = Get-SelectedRows
    if ($sel.Count -ge 2 -or ($sel.Count -ge 1 -and $row -and $row.Tag.selected)) {
        $e.Cancel = $true
        Show-BulkMenu
        return
    }
    foreach ($mi in $miStatus.DropDownItems) { $mi.Checked = ($row -and [string]$mi.Tag -eq [string]$row.Tag.status) }
    $miOpenFolder.Enabled = ($row -and $row.Tag.files.Count -gt 0)
    $src = $menu.SourceControl
    $miCopySel.Enabled = ($src -is [System.Windows.Forms.TextBox] -and $src.SelectionLength -gt 0)
    if ($row) { Clear-Unread $row }
})

function Copy-Text([string]$text) {
    if ($text) { try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { } }
}

# 行の文字をコピー用に選んでいるところ（青）。コピーしたとき・他のところをクリックしたときに外す
$script:selLabel = $null
function Clear-TextSelection {
    $l = $script:selLabel
    $script:selLabel = $null
    if ($l -and -not $l.IsDisposed -and $l.SelectionLength -gt 0) { $l.Select(0, 0) }
}
function Copy-SelectedText {
    $l = $script:selLabel
    if (-not $l -or $l.IsDisposed -or $l.SelectionLength -eq 0) { return $false }
    Copy-Text $l.SelectedText
    $copyPop.Close()
    Clear-TextSelection
    return $true
}
$miCopySel.Add_Click({ $src = $menu.SourceControl; if ($src -is [System.Windows.Forms.TextBox]) { Copy-Text $src.SelectedText; Clear-TextSelection } })
$miCopyAll.Add_Click({ $row = Get-RowOf $menu.SourceControl; if ($row) { Copy-Text (Get-DisplayText $row.Tag) } })

# 文字をドラッグで選んだときにマウスの近くに出す「コピー」
$copyPop = New-Object System.Windows.Forms.ContextMenuStrip
$copyPop.ShowImageMargin = $false
$miPopCopy = $copyPop.Items.Add('コピー')
$miPopCopy.Font = $fontBar
$miPopCopy.Add_Click({ if ($copyPop.Tag) { Copy-Text $copyPop.Tag.SelectedText; Clear-TextSelection } })

# ---------- 並べ替えメニュー ----------
$script:sortMode = 'imp-desc'
$script:seq = 0   # 追加した順番
$sortMenu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($m in @(
    @('imp-desc',  '重要を上に → 期日が近い順（標準）'),
    @('imp-asc',   '重要を下に → 期日が近い順'),
    @('-'),
    @('due-asc',   '期日が近い順（昇順）'),
    @('due-desc',  '期日が遠い順（降順）'),
    @('-'),
    @('name-asc',  '名前順（あ→ん / A→Z）'),
    @('name-desc', '名前順（ん→あ / Z→A）'),
    @('-'),
    @('added',     '追加した順')
)) {
    if ($m[0] -eq '-') { $sortMenu.Items.Add('-') | Out-Null; continue }
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($m[1])
    $mi.Tag = $m[0]
    $mi.Add_Click({ param($s, $e) $script:sortMode = $s.Tag; Sort-Rows; Save-Data })
    $sortMenu.Items.Add($mi) | Out-Null
}
$sortMenu.Add_Opening({
    foreach ($mi in $sortMenu.Items) {
        if ($mi -is [System.Windows.Forms.ToolStripMenuItem]) { $mi.Checked = ($mi.Tag -eq $script:sortMode) }
    }
})

# ---------- ファイルの読み書き ----------
# 文字列は1行に収めて保存する（改行→\n、タブ→\t、\→\\）
function ConvertTo-Field([string]$s) {
    if ($null -eq $s) { return '' }
    return $s.Replace('\', '\\').Replace("`t", '\t').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n')
}
function ConvertFrom-Field([string]$s) {
    if (-not $s) { return '' }
    return [regex]::Replace($s, '\\(.)', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        switch ($m.Groups[1].Value) { 'n' { "`r`n" } 't' { "`t" } default { $m.Groups[1].Value } }
    })
}

$fileHeader = @(
    '#StickyChecklist v2',
    '# id TAB 完了 TAB 重要 TAB 期日 TAB 時刻 TAB ステータス TAB 案件 TAB 内容 TAB 詳細メモ TAB 作成者 TAB 共有範囲 TAB 更新日時 TAB 更新者 TAB ステータスコメント TAB 添付 TAB 記載日 TAB 担当者 TAB サブ担当者'
)
# 後ろに列を足しても、古いファイル（列が少ない）はそのまま読める
$fieldNames = 'id', 'done', 'important', 'due', 'time', 'status', 'key', 'text', 'memo', 'owner', 'scope', 'updatedAt', 'updatedBy', 'note', 'files', 'createdAt', 'assignee', 'subAssignee'

function New-Id { return [guid]::NewGuid().ToString('N').Substring(0, 12) }

# 先頭の【案件】［案件］[案件] を案件名として取り出す（旧形式からの引き継ぎ用）
function Split-KeyTitle([string]$text) {
    $m = [regex]::Match($text, '^\s*[【［\[]([^】］\]]+)[】］\]]\s*(.*)$')
    if ($m.Success) { return @($m.Groups[1].Value.Trim(), $m.Groups[2].Value.Trim()) }
    return @('', $text.Trim())
}

# ファイルの中身 → 項目（ハッシュテーブル）の一覧
function ConvertFrom-ItemText([string]$content) {
    $list = New-Object System.Collections.ArrayList
    if (-not $content) { return ,$list }
    $lines = $content -split "`r?`n"
    $v2 = ($lines.Count -gt 0 -and $lines[0].StartsWith('#StickyChecklist v2'))
    foreach ($line in $lines) {
        if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
        if ($v2) {
            $p = $line.Split("`t")
            if ($p.Count -lt 8) { continue }
            $rec = @{}
            for ($i = 0; $i -lt $fieldNames.Count; $i++) { $rec[$fieldNames[$i]] = if ($i -lt $p.Count) { ConvertFrom-Field $p[$i] } else { '' } }
            if (-not $rec.id) { $rec.id = New-Id }
        } else {
            # 旧形式: 完了 TAB 重要 TAB 期日 TAB 内容 TAB 詳細メモ（内容だけの行も可）
            $p = $line.Split("`t", 5)
            if ($p.Count -lt 4) { $p = @('0', '0', '', $line.Trim()) }
            $kt = Split-KeyTitle $p[3]
            $rec = @{
                id = New-Id; done = $p[0].Trim(); important = $p[1].Trim(); due = $p[2].Trim(); time = ''; status = ''
                key = $kt[0]; text = $kt[1]; memo = $(if ($p.Count -ge 5) { ConvertFrom-Field $p[4] } else { '' })
                owner = ''; scope = ''; updatedAt = ''; updatedBy = ''; note = ''; files = ''; createdAt = ''; assignee = ''; subAssignee = ''
            }
        }
        if (($rec.text + $rec.key).Trim() -ne '') { $list.Add($rec) | Out-Null }
    }
    return ,$list
}

function ConvertTo-ItemLine($rec) {
    return (($fieldNames | ForEach-Object { ConvertTo-Field ([string]$rec[$_]) }) -join "`t")
}

function ConvertTo-ItemText($records) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $fileHeader) { [void]$sb.AppendLine($h) }
    foreach ($r in $records) { [void]$sb.AppendLine((ConvertTo-ItemLine $r)) }
    return $sb.ToString()
}

# ファイルを他の人・他の端末と取り合わないように開く（使用中なら少し待つ）。開けなければ $null
function Open-Locked([string]$path, [System.IO.FileMode]$mode, [System.IO.FileAccess]$access, [System.IO.FileShare]$share, [int]$tries = 30) {
    for ($i = 0; $i -lt $tries; $i++) {
        try { return [System.IO.File]::Open($path, $mode, $access, $share) }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 100 }   # 他の人が書き込み中
    }
    return $null
}

function Get-Stamp([string]$path) {
    if (Test-Path -LiteralPath $path) { return [System.IO.File]::GetLastWriteTimeUtc($path) }
    return [datetime]::MinValue
}

# チェックリストのファイルを読む。失敗したら $null
function Read-ItemFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return ,(New-Object System.Collections.ArrayList) }
    $fs = Open-Locked $path ([System.IO.FileMode]::Open) ([System.IO.FileAccess]::Read) ([System.IO.FileShare]::ReadWrite) 20
    if (-not $fs) { return $null }
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        $text = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    $script:stamps[$path] = Get-Stamp $path
    return ,(ConvertFrom-ItemText $text)
}

# チェックリストのファイルをロックして読み、$mutate で一覧を書き換えて保存する
function Update-ItemFile([string]$path, [scriptblock]$mutate, $arg) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { throw "フォルダが見つかりません: $dir" }
    $fs = Open-Locked $path ([System.IO.FileMode]::OpenOrCreate) ([System.IO.FileAccess]::ReadWrite) ([System.IO.FileShare]::None)
    if (-not $fs) { throw 'ファイルが使用中のため保存できませんでした（あとで自動でやり直します）' }
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
        $records = ConvertFrom-ItemText ($sr.ReadToEnd())
        $sr.Dispose()
        & $mutate $records $arg
        $pre = $utf8Bom.GetPreamble()
        $body = $utf8Bom.GetBytes((ConvertTo-ItemText $records))
        $fs.SetLength(0)
        $fs.Position = 0
        $fs.Write($pre, 0, $pre.Length)
        $fs.Write($body, 0, $body.Length)
        $fs.Flush()
    } finally { $fs.Dispose() }
    $script:stamps[$path] = Get-Stamp $path
}

function Remove-FromItemFile([string]$path, [string]$id) {
    Update-ItemFile $path { param($list, $id) @($list | Where-Object { $_.id -eq $id }) | ForEach-Object { $list.Remove($_) } } $id
}

# ---------- 進捗の履歴（〇〇.history.txt に追記） ----------
function Get-HistoryPath([string]$storePath) {
    return Join-Path (Split-Path $storePath -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($storePath) + '.history.txt')
}

# 履歴を1行追記する。書けなかったら覚えておいて、あとで再試行
function Write-HistoryLine([string]$histPath, [string]$line) {
    $fs = Open-Locked $histPath ([System.IO.FileMode]::OpenOrCreate) ([System.IO.FileAccess]::ReadWrite) ([System.IO.FileShare]::Read) 20
    if (-not $fs) { return $false }
    try {
        $bytes = $utf8Bom.GetBytes($line + "`r`n")
        if ($fs.Length -eq 0) { $pre = $utf8Bom.GetPreamble(); $fs.Write($pre, 0, $pre.Length) }
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    return $true
}

function Add-History($row, [string]$status, [string]$comment) {
    $t = $row.Tag
    $line = (@($t.id, (Get-Date).ToString('yyyy-MM-dd HH:mm'), $script:me, $status, $comment) | ForEach-Object { ConvertTo-Field ([string]$_) }) -join "`t"
    $path = Get-HistoryPath (Get-StorePath $t)
    try { $ok = Write-HistoryLine $path $line } catch { $ok = $false }
    if (-not $ok) { $script:pendingHistory.Add(@($path, $line)) | Out-Null }
}

function Send-PendingHistory {
    foreach ($p in @($script:pendingHistory)) {
        try { if (Write-HistoryLine $p[0] $p[1]) { $script:pendingHistory.Remove($p) } } catch { }
    }
}

# この項目の履歴（新しい順）
function Read-History($t) {
    $path = Get-HistoryPath (Get-StorePath $t)
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return ,$list }
    $fs = Open-Locked $path ([System.IO.FileMode]::Open) ([System.IO.FileAccess]::Read) ([System.IO.FileShare]::ReadWrite) 20
    if (-not $fs) { return ,$list }
    try { $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)).ReadToEnd() } finally { $fs.Dispose() }
    foreach ($line in ($text -split "`r?`n")) {
        $p = $line.Split("`t")
        if ($p.Count -ge 5 -and $p[0] -eq $t.id) {
            $list.Insert(0, [pscustomobject]@{ at = $p[1]; by = (ConvertFrom-Field $p[2]); status = (ConvertFrom-Field $p[3]); comment = (ConvertFrom-Field $p[4]) })
        }
    }
    foreach ($p in $script:pendingHistory) {   # まだ書き込めていない分も出す
        $q = $p[1].Split("`t")
        if ($q[0] -eq $t.id) { $list.Insert(0, [pscustomobject]@{ at = $q[1]; by = (ConvertFrom-Field $q[2]); status = (ConvertFrom-Field $q[3]); comment = (ConvertFrom-Field $q[4]) + '（未保存）' }) }
    }
    return ,$list
}

# 自分用 ⇔ 共有 を切り替えたとき、履歴を移す（元のファイルの行はそのまま残る）
function Copy-History([string]$id, [string]$fromStore, [string]$toStore) {
    $from = Get-HistoryPath $fromStore
    if (-not (Test-Path -LiteralPath $from)) { return }
    $lines = @([System.IO.File]::ReadAllLines($from, [System.Text.Encoding]::UTF8) | Where-Object { $_.StartsWith("$id`t") })
    foreach ($l in $lines) { Write-HistoryLine (Get-HistoryPath $toStore) $l | Out-Null }
}

# ---------- 添付ファイル（attachments\<id>\） ----------
function Get-AttachDir($t, [string]$storePath = '') {
    if (-not $storePath) { $storePath = Get-StorePath $t }
    return Join-Path (Join-Path (Split-Path $storePath -Parent) 'attachments') $t.id
}

function Update-AttachList($row) {
    $dir = Get-AttachDir $row.Tag
    $names = @()
    if (Test-Path -LiteralPath $dir) { $names = @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object { $_.Name }) }
    $row.Tag.files = $names   # 1件でも配列のまま
}

function Add-Attachments($row, [string[]]$paths) {
    $dir = Get-AttachDir $row.Tag
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $names = @()
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $name = [System.IO.Path]::GetFileName($p)
        $dest = Join-Path $dir $name
        $n = 2
        while (Test-Path -LiteralPath $dest) {   # 同じ名前があれば (2), (3)… を付ける
            $dest = Join-Path $dir ("{0} ({1}){2}" -f [System.IO.Path]::GetFileNameWithoutExtension($name), $n, [System.IO.Path]::GetExtension($name))
            $n++
        }
        Copy-Item -LiteralPath $p -Destination $dest
        $names += [System.IO.Path]::GetFileName($dest)
    }
    if ($names.Count -eq 0) { return }
    Update-AttachList $row
    Add-History $row $row.Tag.status ("添付: " + ($names -join '、'))
    Set-Dirty $row
    Update-Row $row
    Save-Data
}

function Remove-Attachment($row, [string]$name) {
    $path = Join-Path (Get-AttachDir $row.Tag) $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Update-AttachList $row
    Add-History $row $row.Tag.status "添付を削除: $name"
    Set-Dirty $row
    Update-Row $row
    Save-Data
}

# 自分用 ⇔ 共有 を切り替えたとき、添付フォルダを移す
function Move-Attachments($t, [string]$fromStore, [string]$toStore) {
    $from = Get-AttachDir $t $fromStore
    $to = Get-AttachDir $t $toStore
    if (-not (Test-Path -LiteralPath $from) -or $from -eq $to) { return }
    if (-not (Test-Path -LiteralPath $to)) { New-Item -ItemType Directory -Path $to -Force | Out-Null }
    Get-ChildItem -LiteralPath $from -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $to $_.Name) -Force }
    Remove-Item -LiteralPath $from -Recurse -Force
}

function Open-Attachment($t, [string]$name) {
    $path = Join-Path (Get-AttachDir $t) $name
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath $path }
    else { [System.Windows.Forms.MessageBox]::Show($form, "ファイルが見つかりません。`n$path", '添付', 'OK', 'Warning') | Out-Null }
}

function Open-AttachFolder($t) {
    $dir = Get-AttachDir $t
    if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe -ArgumentList ('"' + $dir + '"') }
}

# 項目の保存先（共有なら共有ファイル、そうでなければ自分用ファイル）
function Get-StorePath($t) {
    if ($t.shared) { return $sharedFile }
    return $personalFile
}

# 自分に見える共有項目か（作成者、全員宛て、または共有範囲に自分が入っている）
function Test-Visible($rec) {
    if ($rec.owner -eq $script:me) { return $true }
    $scope = @(([string]$rec.scope) -split ',' | Where-Object { $_ -ne '' })
    return ($scope.Count -eq 0 -or $scope -contains '全員' -or $scope -contains $script:me)
}

# ---------- 行の表示 ----------
function Get-RowOf($ctrl) {
    $c = $ctrl
    while ($c -and -not ($c.Tag -is [psobject] -and $c.Tag.PSObject.Properties['cb'])) { $c = $c.Parent }
    return $c
}

function Get-DisplayText($t) {
    if ($t.key) { return "【$($t.key)】$($t.text)" }
    return $t.text
}

function Get-ScopeLabel($t) {
    if ($t.scope.Count -eq 0) { return '全員' }
    return ($t.scope -join '、')
}

# 右側の「担当・ステータス・期日」の幅（全部の行で同じ幅にして、縦にそろえる）
$script:colW = $null
function Get-ColumnWidths {
    $names = @(Get-Members) + @($script:me)
    $key = "$($script:zoom)|" + ($names -join ',')
    if ($script:colW -and $script:colW.key -eq $key) { return $script:colW }
    $m = { param($text, $font) [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font).Width }
    $due = 0
    foreach ($x in '12/31(99日超過)', '12/31(残99日)') { $due = [Math]::Max($due, (& $m $x $script:zSmall) + 4) }   # +4: 今日が締め日のときの赤地の余白
    $due = [Math]::Max($due, (& $m '12/31 23:59' $script:zTiny))   # 最終更新日時
    $st = 0
    foreach ($x in $statusList) { $st = [Math]::Max($st, (& $m $x $script:zTag)) }
    $bold = New-Object System.Drawing.Font($script:zTiny, [System.Drawing.FontStyle]::Bold)
    $role = 0
    foreach ($n in $names) { if ($n) { $role = [Math]::Max($role, (& $m "Main:$n" $bold)) } }
    $bold.Dispose()
    $script:colW = [pscustomobject]@{ key = $key; due = $due + 2; status = $st + 14; role = $role }
    return $script:colW
}

function Update-Row($row) {
    $t = $row.Tag
    $cb = $t.cb
    $cw = Get-ColumnWidths
    $t.label.Text = Get-DisplayText $t
    if ($cb.Checked) {
        $t.label.Font = $script:zDone
        $t.label.ForeColor = [System.Drawing.Color]::Gray
    } else {
        $t.label.Font = $script:zItem
        $t.label.ForeColor = [System.Drawing.Color]::Black
    }

    $t.badge.Visible = $t.important
    $t.shareBadge.Visible = $t.shared

    # 期日（上に最終更新日時を小さく、時刻があれば下に小さく）
    $t.dueAt = $null
    $tipText = $t.label.Text
    $upd = Get-UpdatedText $t
    if ($t.due) {
        $days = ($t.due.Date - (Get-Date).Date).Days
        $md = $t.due.ToString('M/d')
        $line1 = if ($days -gt 0) { "$md(残${days}日)" } elseif ($days -eq 0) { "$md(今日)" } else { "$md($(-$days)日超過)" }
        $color = if ($cb.Checked) { [System.Drawing.Color]::Gray } elseif ($days -le 3) { $redColor } else { [System.Drawing.Color]::DimGray }
        $t.dueAt = $t.due.Date
        if ($t.time) { try { $t.dueAt = $t.due.Date + [TimeSpan]::Parse($t.time) } catch { } }
        $t.dueBox.Tag = [pscustomobject]@{ upd = $upd; line1 = $line1; line2 = $t.time; color = $color; today = ($days -eq 0 -and -not $cb.Checked) }
        $w1 = [System.Windows.Forms.TextRenderer]::MeasureText($line1, $script:zSmall).Width
        $w2 = if ($t.time) { [System.Windows.Forms.TextRenderer]::MeasureText($t.time, $script:zTiny).Width } else { 0 }
        $t.dueBox.Width = [Math]::Max($cw.due, [Math]::Max($w1, $w2) + 2)
        $t.dueBox.Invalidate()
        $tipText += "`n期日: " + $t.due.ToString('yyyy/MM/dd (ddd)') + $(if ($t.time) { ' ' + $t.time } else { '' })
    } else {
        $t.dueBox.Tag = $(if ($upd) { [pscustomobject]@{ upd = $upd; line1 = ''; line2 = ''; color = [System.Drawing.Color]::Gray; today = $false } } else { $null })   # 期日がなくても幅は取っておく（列をそろえるため）
        $t.dueBox.Width = $cw.due
        $t.dueBox.Invalidate()
    }
    $t.dueBox.Visible = $true

    # ステータスの札（押すと進捗・履歴の画面）
    $t.statusBox.Tag = $t.status
    $t.statusBox.Width = [Math]::Max($cw.status, [System.Windows.Forms.TextRenderer]::MeasureText($t.status, $script:zTag).Width + 14)
    $t.statusBox.Visible = $true
    $t.statusBox.Invalidate()
    $statusTip = "ステータス: $($t.status)" + $(if ($t.note) { "`n" + $t.note } else { '' })
    $tipText += "`n$statusTip"
    $tip.SetToolTip($t.statusBox, $statusTip + "`n（クリックで進捗・履歴）")

    # 担当（Main:〇〇 Sub:〇〇）
    $parts = @()
    if ($t.assignee) { $parts += "Main:$($t.assignee)" }
    if ($t.subAssignee) { $parts += "Sub:$($t.subAssignee)" }
    $t.roleLbl.Text = $parts -join "`r`n"   # Main と Sub は縦に2行で
    $t.roleLbl.Visible = $true   # 担当がなくても幅は取っておく（列をそろえるため）
    $mine = ($t.assignee -eq $script:me -or $t.subAssignee -eq $script:me)
    $t.roleLbl.ForeColor = if ($mine) { [System.Drawing.Color]::FromArgb(30, 80, 170) } else { [System.Drawing.Color]::FromArgb(110, 110, 110) }
    $t.roleLbl.Font = if ($mine) { New-Object System.Drawing.Font($script:zTiny, [System.Drawing.FontStyle]::Bold) } else { $script:zTiny }
    $need = 0
    foreach ($x in $parts) { $need = [Math]::Max($need, [System.Windows.Forms.TextRenderer]::MeasureText($x, $t.roleLbl.Font).Width) }
    $t.roleLbl.Width = [Math]::Max($cw.role, $need) + $t.roleLbl.Padding.Horizontal

    # 添付
    $t.clip.Visible = $t.files.Count -gt 0
    if ($t.files.Count -gt 0) {
        $t.clip.Text = "📎$($t.files.Count)"
        $tip.SetToolTip($t.clip, "添付 $($t.files.Count)件（クリックで開く）`n" + ($t.files -join "`n"))
        $tipText += "`n添付: " + ($t.files -join '、')
    }

    # 他の人が更新した項目は色を付ける（触ると消える）
    $row.BackColor = if ($t.selected) { $selectColor } elseif ($t.current) { $currentColor } else { [System.Drawing.Color]::Transparent }   # 選択中 > 今の行（他の人の更新は背景色ではなく「更新」「New」の札で出す）
    $t.label.BackColor = if ($t.selected) { $selectColor } elseif ($t.current) { $currentColor } else { $noteColor }   # テキストボックスは透明にできないので同じ色に

    if ($t.shared) {
        $shareTip = "共有: $(Get-ScopeLabel $t)`n記載者: $($t.owner)"
        if ($t.updatedBy) { $shareTip += "`n最終更新: $($t.updatedBy) $($t.updatedAt)" }
        $tipText += "`n$shareTip"
        $tip.SetToolTip($t.shareBadge, $shareTip)
    }
    if ($t.assignee -or $t.subAssignee) { $tipText += "`n担当: $(Get-PersonText $t.assignee)　サブ: $(Get-PersonText $t.subAssignee)" }
    if ($t.memoHost.Visible) { Update-MemoInfo $row }

    $memoText = $t.memo.Text.Trim()
    if ($memoText -ne '') {
        if ($memoText.Length -gt 200) { $memoText = $memoText.Substring(0, 200) + '…' }
        $tipText += "`n――――――`n" + $memoText
    }
    $tip.SetToolTip($t.label, $tipText)
    Update-MemoToggle $row
    Update-RowHeight $row
}

# ▼ボタン: メモがあれば濃い色、開いているときは▲
function Update-MemoToggle($row) {
    $t = $row.Tag
    $hasMemo = $t.memo.Text.Trim() -ne ''
    $t.toggle.Text = if ($t.memoHost.Visible) { '▲' } else { '▼' }
    $t.toggle.ForeColor = if ($hasMemo) { [System.Drawing.Color]::FromArgb(200, 120, 0) } else { [System.Drawing.Color]::Silver }
    $tip.SetToolTip($t.toggle, $(if ($t.memoHost.Visible) { '詳細メモを閉じる' } elseif ($hasMemo) { '詳細メモあり（クリックで開く）' } else { '詳細メモを書く' }))
}

$memoFlags = [System.Windows.Forms.TextFormatFlags]'WordBreak, TextBoxControl'

# テキストボックス1行分の高さ（2行と1行の差で測る）
$script:lineHeights = @{}
function Get-LineHeight($f) {
    $k = $f.ToString()
    if (-not $script:lineHeights.ContainsKey($k)) {
        $flags = [System.Windows.Forms.TextFormatFlags]'TextBoxControl'
        $one = [System.Windows.Forms.TextRenderer]::MeasureText('あ', $f, (New-Object System.Drawing.Size(1000, 1000)), $flags).Height
        $two = [System.Windows.Forms.TextRenderer]::MeasureText("あ`nあ", $f, (New-Object System.Drawing.Size(1000, 1000)), $flags).Height
        $script:lineHeights[$k] = $two - $one
    }
    return $script:lineHeights[$k]
}

# 内容が全部見えるように、折り返した行数に合わせて行の高さを変える（メモを開いていればその分も）
function Update-RowHeight($row) {
    $t = $row.Tag
    $memoH = 0
    if ($t.memoHost.Visible) {
        $left = $t.num.Width + $t.toggle.Width + $(if ($t.important) { $t.badge.Width } else { 0 }) + $(if ($t.shared) { $t.shareBadge.Width } else { 0 }) + 2   # □の位置にそろえる
        $t.memoHost.Padding = New-Object System.Windows.Forms.Padding($left, 0, 8, 4)
        $mw = [Math]::Max(20, $row.Width - $t.memoHost.Padding.Horizontal - 10)
        $mt = if ($t.memo.Text -eq '') { 'あ' } else { $t.memo.Text + ' ' }
        $ms = [System.Windows.Forms.TextRenderer]::MeasureText($mt, $script:zSmall, (New-Object System.Drawing.Size($mw, 10000)), $memoFlags)
        $memoH = [Math]::Max(44, $ms.Height + 10) + $t.memoHost.Padding.Vertical + $t.memoInfo.Height
        $t.memoHost.Height = $memoH
    }
    $row.PerformLayout()
    # 文字欄（テキストボックス）に、今の幅で折り返したときの行数を聞く（表示と必ず一致する）
    $lines = [Math]::Max(1, [NativeDrag]::LineCount($t.label.Handle))
    $textH = $lines * (Get-LineHeight $t.label.Font) + 4
    # 期日の欄: 最終更新日時・期日・時刻を縦に並べた高さ
    $dueH = $script:rowPad + $(if (Get-UpdatedText $t) { $script:zTiny.Height } else { 0 }) + $(if ($t.due) { $script:zSmall.Height + 2 } else { 0 }) + $(if ($t.due -and $t.time) { $script:zTiny.Height } else { 0 }) + 4
    $minH = [Math]::Max($script:badgeW + 2, $dueH)   # 丸の大きさ、期日の欄の高さ
    if ($t.assignee -and $t.subAssignee) { $minH = [Math]::Max($minH, $script:rowPad + 2 * $script:zTiny.Height + 6) }   # Main・Sub の2行分
    $row.Height = [Math]::Max($minH, $textH + 6) + $memoH
    if (-not $script:loading) { Update-ScrollExtent }
}

# 記載日（記録がない古い項目は、進捗の履歴の「作成」の日時を使う）
function Get-CreatedAt($t) {
    if (-not $t.createdAt) {
        try {
            $h = @(Read-History $t)
            if ($h.Count) { $t.createdAt = [string]$h[$h.Count - 1].at }   # いちばん古い記録
        } catch { }
    }
    return [string]$t.createdAt
}

function Get-PersonText([string]$name) { if ($name) { return $name } return '—' }

# ▼の中の「記載者・記載日・担当・サブ」
function Update-MemoInfo($row) {
    $t = $row.Tag
    $created = Get-CreatedAt $t
    $day = if ($created) { $created.Substring(0, [Math]::Min(10, $created.Length)).Replace('-', '/') } else { '—' }
    $t.memoInfo.Text = "記載者: $(Get-PersonText $t.owner)　記載日: $day　担当: $(Get-PersonText $t.assignee)　サブ: $(Get-PersonText $t.subAssignee)"
    $tip.SetToolTip($t.memoInfo, $t.memoInfo.Text)
}

function Switch-Memo($row) {
    $t = $row.Tag
    $t.memoHost.Visible = -not $t.memoHost.Visible
    if ($t.memoHost.Visible) { Update-MemoInfo $row }
    Update-MemoToggle $row
    Update-RowHeight $row
    if ($t.memoHost.Visible) {
        $flow.ScrollControlIntoView($row)
        $t.memo.Focus() | Out-Null
        $t.memo.SelectionStart = $t.memo.TextLength
    }
}

function Update-AllRows {
    foreach ($r in $flow.Controls) { Update-Row $r }
}

function Update-PinButton {
    $btnPin.BackColor = if ($form.TopMost) { $pinColor } else { $barColor }
    $btnPin.Text = if ($form.TopMost) { '★' } else { '☆' }
}

# 選んだ並べ替え方法で並べる（同じ順位なら追加した順）
function Sort-Rows {
    $mode  = $script:sortMode
    $seq   = @{ Expression = { $_.Tag.seq } }
    $imp   = @{ Expression = { [int]$_.Tag.important }; Descending = ($mode -ne 'imp-asc') }
    $noDue = @{ Expression = { $null -eq $_.Tag.dueAt } }   # 期日なしは常に下
    $dueAsc = @{ Expression = { $_.Tag.dueAt } }
    $keys = switch ($mode) {
        'due-asc'   { $noDue, $dueAsc, $imp, $seq }
        'due-desc'  { $noDue, @{ Expression = { $_.Tag.dueAt }; Descending = $true }, $imp, $seq }
        'imp-asc'   { $imp, $noDue, $dueAsc, $seq }
        'name-asc'  { @{ Expression = { $_.Tag.label.Text } }, $seq }
        'name-desc' { @{ Expression = { $_.Tag.label.Text }; Descending = $true }, $seq }
        'added'     { $seq }
        default     { $imp, $noDue, $dueAsc, $seq }   # imp-desc（標準）: 重要 → 期日が近い順
    }
    $ordered = @($flow.Controls | Sort-Object -Property $keys)
    $flow.SuspendLayout()
    for ($i = 0; $i -lt $ordered.Count; $i++) { $flow.Controls.SetChildIndex($ordered[$i], $i) }
    $flow.ResumeLayout()

    $label = ($sortMenu.Items | Where-Object { $_.Tag -eq $mode } | Select-Object -First 1).Text
    $tip.SetToolTip($btnSort, "並べ替え（今: $label）")
    Update-Numbers
}

# ---------- 項目の番号（一度付けたら変わらない。全員で同じ番号を見る） ----------
# 番号は「〇〇.numbers.txt」（id と番号のタブ区切り）に保存する。共有しているなら共有ファイルの隣に置き、自分用の項目も同じ通し番号にする
# （項目ファイルとは別にしておくと、古い版の付箋が項目ファイルを書き換えても番号は消えない）
$script:numbers = @{}           # id → 番号
$script:numbersRetryAt = [datetime]::MinValue
function Get-NumbersPath {
    $base = if ($sharingOn) { $sharedFile } else { $personalFile }
    return Join-Path (Split-Path $base -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($base) + '.numbers.txt')
}
function Read-NumbersText([string]$text) {
    foreach ($line in ($text -split "`r?`n")) {
        $p = $line.Split("`t")
        if ($p.Count -ge 2 -and $p[0] -and $p[1] -match '^\d+$') { $script:numbers[$p[0]] = [int]$p[1] }
    }
}
# 番号のない項目に、続きの番号を付けて保存する（古いもの＝記載日の早いものから）
function Add-Numbers {
    $missing = @($flow.Controls | Where-Object { $_.Tag.id -and -not $script:numbers.ContainsKey($_.Tag.id) })
    if (-not $missing.Count -or [datetime]::Now -lt $script:numbersRetryAt) { return }
    $path = Get-NumbersPath
    try {
        $fs = Open-Locked $path ([System.IO.FileMode]::OpenOrCreate) ([System.IO.FileAccess]::ReadWrite) ([System.IO.FileShare]::Read) 10
    } catch { $fs = $null }
    if (-not $fs) { $script:numbersRetryAt = [datetime]::Now.AddSeconds(30); return }   # 共有フォルダに届かない → 少しあとで
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
        Read-NumbersText ($sr.ReadToEnd())   # 他の人が付けた番号を先に取り込む
        $sr.Dispose()
        $max = 0
        foreach ($v in $script:numbers.Values) { if ($v -gt $max) { $max = $v } }
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in @($missing | Where-Object { -not $script:numbers.ContainsKey($_.Tag.id) } | Sort-Object { [string]$_.Tag.createdAt }, { $_.Tag.seq })) {
            $max++
            $script:numbers[$r.Tag.id] = $max
            [void]$sb.Append("$($r.Tag.id)`t$max`r`n")
        }
        if ($sb.Length) {
            if ($fs.Length -eq 0) { $pre = $utf8Bom.GetPreamble(); $fs.Write($pre, 0, $pre.Length) }
            $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $bytes = $utf8Bom.GetBytes($sb.ToString())
            $fs.Write($bytes, 0, $bytes.Length)
        }
    } catch { $script:numbersRetryAt = [datetime]::Now.AddSeconds(30) }
    finally { $fs.Dispose() }
}

# 行番号（項目ごとに決まった番号。絞り込み・並べ替えをしても変わらない）
function Update-Numbers {
    Add-Numbers
    $max = 0
    foreach ($v in $script:numbers.Values) { if ($v -gt $max) { $max = $v } }
    $w = if ($max -ge 1000) { Z 40 } elseif ($max -ge 100) { Z 32 } else { Z 24 }   # 桁が増えたら少し広げる
    foreach ($r in $flow.Controls) {
        $t = $r.Tag
        $no = $script:numbers[$t.id]
        $t.num.Text = $(if ($no) { "$no" } else { '' })
        if ($t.num.Width -ne $w) { $t.num.Width = $w; Update-RowHeight $r }
    }
    Update-ScrollExtent   # 並べ替え・絞り込みのあとも、スクロール範囲を合わせる
}

# 絞り込み条件に合うか
function Test-RowMatch($t, [string[]]$words) {
    switch ($cmbDone.SelectedIndex) {
        1 { if ($t.cb.Checked) { return $false } }
        2 { if (-not $t.cb.Checked) { return $false } }
    }
    switch ($cmbImp.SelectedIndex) {
        1 { if (-not $t.important) { return $false } }
        2 { if ($t.important) { return $false } }
    }
    if ($cmbDue.SelectedIndex -gt 0) {
        $days = if ($t.due) { ($t.due.Date - (Get-Date).Date).Days } else { $null }
        $ok = switch ($cmbDue.SelectedIndex) {
            1 { $null -ne $days -and $days -lt 0 }
            2 { $null -ne $days -and $days -le 0 }
            3 { $null -ne $days -and $days -le 3 }
            4 { $null -ne $days -and $days -le 7 }
            5 { $null -ne $days }
            6 { $null -eq $days }
        }
        if (-not $ok) { return $false }
    }
    if ($script:hiddenStatuses.Contains([string]$t.status)) { return $false }
    $ok = switch ($cmbShare.SelectedIndex) {
        1 { $t.shared }
        2 { -not $t.shared }
        3 { $t.shared -and $t.owner -eq $script:me }
        4 { $t.shared -and $t.owner -ne $script:me }
        default { $true }
    }
    if (-not $ok) { return $false }
    $ai = $cmbAssign.SelectedIndex
    $ok = switch ($ai) {
        0 { $true }
        1 { $t.assignee -eq $script:me -or $t.subAssignee -eq $script:me }
        2 { $t.assignee -eq $script:me }
        3 { $t.subAssignee -eq $script:me }
        4 { -not $t.assignee -and -not $t.subAssignee }
        default { $n = [string]$cmbAssign.SelectedItem; $t.assignee -eq $n -or $t.subAssignee -eq $n }   # メンバー（Main・Sub どちらでも）
    }
    if (-not $ok) { return $false }
    foreach ($w in $words) {   # スペース区切りで複数語（すべて含むもの）。案件・詳細メモ・作成者・ステータス・添付名も対象
        $hay = $t.label.Text + "`n" + $t.memo.Text + "`n" + $t.owner + "`n" + $t.assignee + "`n" + $t.subAssignee + "`n" + $t.status + "`n" + $t.note + "`n" + ($t.files -join "`n")
        if ($hay.IndexOf($w, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Apply-Filter {
    $words = @($txtSearch.Text -split '[\s　]+' | Where-Object { $_ -ne '' })
    $total = 0; $shown = 0
    $flow.SuspendLayout()
    foreach ($r in $flow.Controls) {
        $total++
        $match = Test-RowMatch $r.Tag $words
        $r.Visible = $match
        $r.Tag.shown = $match
        if ($match) { $shown++ }
    }
    $flow.ResumeLayout()

    $active = $words.Count -gt 0 -or $cmbDone.SelectedIndex -gt 0 -or $cmbImp.SelectedIndex -gt 0 -or $cmbDue.SelectedIndex -gt 0 -or $script:hiddenStatuses.Count -gt 0 -or $cmbShare.SelectedIndex -gt 0 -or $cmbAssign.SelectedIndex -gt 0
    $btnFilter.BackColor = if ($active) { $pinColor } else { $barColor }   # 絞り込み中は色を付ける
    $lblCount.Text = "${shown}/${total}件"
    # 絞り込んでいる項目には色を付ける
    $on = [System.Drawing.Color]::FromArgb(255, 214, 120)
    foreach ($c in $cmbDone, $cmbImp, $cmbDue, $cmbShare, $cmbAssign) { $c.BackColor = if ($c.SelectedIndex -gt 0) { $on } else { [System.Drawing.Color]::White }; $c.Invalidate() }
    $txtSearch.BackColor = if ($words.Count) { $on } else { [System.Drawing.Color]::White }
    $btnStatusFilter.BackColor = if ($script:hiddenStatuses.Count) { $on } else { [System.Drawing.Color]::White }
    Update-Numbers
    Update-Totals
    $tip.SetToolTip($btnFilter, $(if ($active) { "絞り込み中（${shown}/${total}件表示）" } else { '絞り込み' }))
}

# バーの件数（絞り込みに関係なく全体の数）と共有の状態
function Update-Totals {
    $total = $flow.Controls.Count
    $doneCount = @($flow.Controls | Where-Object { $_.Tag.cb.Checked }).Count
    $sharedCnt = @($flow.Controls | Where-Object { $_.Tag.shared }).Count
    $mineCnt = @($flow.Controls | Where-Object { $_.Tag.assignee -eq $script:me -or $_.Tag.subAssignee -eq $script:me }).Count
    $text = "全${total}件（未$($total - $doneCount)：済${doneCount}）｜個別$($total - $sharedCnt) 共有${sharedCnt} 担当${mineCnt}"
    $breakdown = "`n内訳: 個別（自分用）$($total - $sharedCnt)件・共有${sharedCnt}件`n自分が担当（サブ含む）: ${mineCnt}件"
    $tipText = $text + $breakdown + "`n自分用ファイル: $personalFile"
    if ($sharingOn) {
        $sharedCount = @($flow.Controls | Where-Object { $_.Tag.shared }).Count
        $tipText += "`n共有 ${sharedCount}件（$script:me として参加中）`n共有ファイル: $sharedFile"
    }
    $selCount = @($flow.Controls | Where-Object { $_.Tag.selected }).Count
    if ($selCount -gt 0) {
        $text = "選択$selCount  " + $text
        $tipText += "`n選択中 ${selCount}件（右クリックでまとめて変更、普通のクリックで解除）"
    }
    $unread = @($flow.Controls | Where-Object { $_.Tag.unread }).Count
    if ($unread -gt 0) {
        $text = "●更新$unread  " + $text
        $tipText += "`n● 他の人が更新した項目が ${unread}件あります（色の付いた行）"
    }
    if ($script:sharedError) {
        $text = '⚠ ' + $text
        $tipText += "`n⚠ $script:sharedError"
        $lblTotals.ForeColor = $redColor
    } else {
        $lblTotals.ForeColor = [System.Drawing.Color]::FromArgb(110, 90, 30)
    }
    $lblTotals.Tag = $text   # 表示は Paint で1行に描く
    $lblTotals.Invalidate()
    $tip.SetToolTip($lblTotals, $tipText)
}

function Reset-Filter {
    $txtSearch.Text = ''
    foreach ($c in $cmbDone, $cmbImp, $cmbDue, $cmbShare, $cmbAssign) { $c.SelectedIndex = 0 }
    $script:hiddenStatuses.Clear()
    Update-StatusFilterButton
    Apply-Filter
    Save-Data
}

# ---------- 項目の作成・変更・削除 ----------
# 変更した印（共有項目は次の保存で共有ファイルに書き込む）
function Set-Dirty($row) {
    $row.Tag.dirty = $true
    $row.Tag.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $row.Tag.updatedBy = $script:me
}

function ConvertTo-Record($row) {
    $t = $row.Tag
    return @{
        id = $t.id; done = [string][int]$t.cb.Checked; important = [string][int]$t.important
        due = $(if ($t.due) { $t.due.ToString('yyyy-MM-dd') } else { '' }); time = [string]$t.time; status = [string]$t.status
        key = [string]$t.key; text = [string]$t.text; memo = $t.memo.Text
        owner = [string]$t.owner; scope = $(if ($t.shared) { if ($t.scope.Count -eq 0) { '全員' } else { $t.scope -join ',' } } else { '' })
        updatedAt = [string]$t.updatedAt; updatedBy = [string]$t.updatedBy
        note = [string]$t.note; files = ($t.files -join '|')
        createdAt = [string]$t.createdAt; assignee = [string]$t.assignee; subAssignee = [string]$t.subAssignee
    }
}

function ConvertTo-Date([string]$s) {
    if (-not $s) { return $null }
    try { return [datetime]::ParseExact($s.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function ConvertTo-Scope([string]$s) {
    return @(($s -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -ne '全員' })
}

# 項目の内容を行に反映（共有ファイルから読んだときにも使う）
function Set-RowFromRecord($row, $rec, [bool]$shared) {
    $t = $row.Tag
    $script:applying = $true
    try {
        $t.id = $rec.id
        $t.cb.Checked = ($rec.done -eq '1')
        $t.important = ($rec.important -eq '1')
        $t.due = ConvertTo-Date $rec.due
        $t.time = if ($rec.time -match '^\d{1,2}:\d{2}$') { $rec.time } else { '' }
        $t.status = if ($statusList -contains $rec.status) { $rec.status } else { '未着手' }   # 旧形式の「なし」も未着手
        $t.key = [string]$rec.key
        $t.text = [string]$rec.text
        if (-not $t.memo.Focused -and $t.memo.Text -ne $rec.memo) { $t.memo.Text = [string]$rec.memo }   # 入力中のメモは上書きしない
        $t.shared = $shared
        $t.owner = [string]$rec.owner
        $t.scope = ConvertTo-Scope $rec.scope
        $t.updatedAt = [string]$rec.updatedAt
        $t.updatedBy = [string]$rec.updatedBy
        $t.note = [string]$rec.note
        $t.files = @(([string]$rec.files) -split '\|' | Where-Object { $_ -ne '' })
        $t.createdAt = [string]$rec.createdAt
        $t.assignee = [string]$rec.assignee
        $t.subAssignee = [string]$rec.subAssignee
    } finally { $script:applying = $false }
    Update-Row $row
}

# 更新の目印を消す（行を触ったとき）
function Clear-Unread($row) {
    if ($row -and $row.Tag.unread) {
        $row.Tag.unread = $false
        $row.Tag.flashLbl.Visible = $false
        Update-Row $row
        Update-Totals
    }
}

# 他の人が追加・更新した行に「New」「更新」を数秒だけ出す
$script:flashSeconds = 6
function Set-Flash($row, [string]$text) {
    $t = $row.Tag
    $t.unread = $true
    $t.flashUntil = (Get-Date).AddSeconds($script:flashSeconds)
    $t.flashLbl.Tag = $text
    $t.flashLbl.Width = [System.Windows.Forms.TextRenderer]::MeasureText($text, $script:zTag).Width + 14
    $t.flashLbl.Visible = $true
    $t.flashLbl.Invalidate()
    $tip.SetToolTip($t.flashLbl, $(if ($text -eq 'New') { "$($t.updatedBy) さんが追加" } else { "$($t.updatedBy) さんが更新（$($t.updatedAt)）" }))
}
$flashTimer = New-Object System.Windows.Forms.Timer
$flashTimer.Interval = 1000
$flashTimer.Add_Tick({
    $now = Get-Date
    $changed = $false
    foreach ($r in $flow.Controls) {
        $t = $r.Tag
        if ($t.flashLbl.Visible -and $t.flashUntil -and $now -ge $t.flashUntil) {
            $t.flashLbl.Visible = $false
            $t.unread = $false
            $changed = $true
        }
    }
    if ($changed) { Update-Totals }
})

# 直近で変更した人（「〇〇さんが入力中…」に数秒出す）
$script:recentEditors = @{}
function Add-RecentEditor([string]$name) {
    if (-not $name -or $name -eq $script:me) { return }
    $script:recentEditors[$name] = (Get-Date).AddSeconds($script:flashSeconds)
}

# メモ欄などの複数行の入力欄: Enter に加えて Shift＋Enter・Ctrl＋Enter・Alt＋Enter でも改行する
function Add-NewlineKeys($tb) {
    $tb.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and ($e.Shift -or $e.Control -or $e.Alt) -and -not $s.ReadOnly) {
            $s.SelectedText = "`r`n"
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })
}

# 行の文字以外のところをダブルクリックしたらチェックを切り替える（□ と同じく、1回のクリックでは変わらない）。切り替えたら true
function Test-RowDoubleClick($ctrl, $e) {
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return $false }
    if ([System.Windows.Forms.Control]::ModifierKeys -ne [System.Windows.Forms.Keys]::None) { return $false }   # Ctrl・Shift は選択用
    $r = Get-RowOf $ctrl
    if (-not $r) { return $false }
    $t = $r.Tag
    $now = [Environment]::TickCount
    if ($t.lastBlankClick -and ($now - $t.lastBlankClick) -le [System.Windows.Forms.SystemInformation]::DoubleClickTime) {
        $t.lastBlankClick = 0
        $t.cb.Checked = -not $t.cb.Checked
        return $true
    }
    $t.lastBlankClick = $now
    return $false
}

# 内容のテキストボックスで、その位置に文字がないか（行末より右・最後の行より下・空欄）
function Test-BlankText($tb, [System.Drawing.Point]$pt) {
    if ($tb.TextLength -eq 0) { return $true }
    $i = $tb.GetCharIndexFromPosition($pt)
    $ch = $tb.Text[$i]
    if ($ch -eq "`r" -or $ch -eq "`n") { return $true }
    $pos = $tb.GetPositionFromCharIndex($i)
    $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$ch, $tb.Font, [System.Drawing.Size]::Empty, [System.Windows.Forms.TextFormatFlags]::NoPadding).Width
    return ($pt.X -gt $pos.X + $w + 2 -or $pt.Y -gt $pos.Y + $tb.Font.Height + 1)
}

function New-Row {
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 28
    $row.Width = (Get-RowWidth)
    $row.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)

    # □ だけのチェックボックス（文字は隣のラベル。チェックボックスの文字は折り返し幅が読めず高さを合わせられないため）
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.AutoSize = $false
    $cb.Dock = 'Left'
    $cb.Width = 18
    $cb.CheckAlign = 'TopLeft'
    $cb.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $cb.Cursor = 'Hand'
    $cb.TabStop = $false
    # 誤操作防止: 1回のクリックでは変わらず、ダブルクリックでチェックを切り替える
    $cb.AutoCheck = $false
    $tip.SetToolTip($cb, 'ダブルクリックでチェック')
    $cb.Add_MouseUp({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $t = $s.Parent.Tag
        $now = [Environment]::TickCount
        if ($t.lastClick -and ($now - $t.lastClick) -le [System.Windows.Forms.SystemInformation]::DoubleClickTime) {
            $t.lastClick = 0
            $s.Checked = -not $s.Checked
        } else {
            $t.lastClick = $now
        }
    })
    $cb.ContextMenuStrip = $menu
    $cb.Add_CheckedChanged({
        param($s, $e)
        if ($script:applying) { return }
        $r = $s.Parent
        $r.Tag.unread = $false
        $before = ConvertTo-Record $r                         # 元に戻す用（チェックだけ前の状態に）
        $before.done = $(if ($s.Checked) { '0' } else { '1' })
        Set-Dirty $r
        Push-Undo "$(if ($s.Checked) { 'チェックを付けた' } else { 'チェックを外した' })$(Get-ShortName $r.Tag)" (New-UndoItem $r $before (ConvertTo-Record $r))
        Update-Row $r; Apply-Filter; Save-Data
    })

    # 内容（読み取り専用のテキストボックス。マウスで範囲選択してコピーできる）
    $label = New-Object RowTextBox
    $label.ReadOnly = $true
    $label.Multiline = $true
    $label.WordWrap = $true
    $label.BorderStyle = 'None'
    $label.BackColor = $noteColor
    $label.Dock = 'Fill'
    $label.TabStop = $false
    $label.HideSelection = $false   # 「コピー」を出したときも選択を見えたままに
    $label.ContextMenuStrip = $menu
    $label.Add_GotFocus({ param($s, $e) [NativeDrag]::HideCaret($s.Handle) | Out-Null })
    $label.Add_MouseUp({
        param($s, $e)
        [NativeDrag]::HideCaret($s.Handle) | Out-Null
        # 文字のないところ（行末より右・最終行より下）のダブルクリックはチェックの切り替え
        if (Test-BlankText $s $e.Location) {
            if (Test-RowDoubleClick $s $e) { $s.Select(0, 0); return }
        } else { $s.Parent.Parent.Tag.lastBlankClick = 0 }
        # 文字を選んで離したら、マウスの近くに「コピー」を出す
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $s.SelectionLength -gt 0) {
            $script:selLabel = $s
            $copyPop.Tag = $s
            $copyPop.Show($s, (New-Object System.Drawing.Point(($e.X + 4), ($e.Y + 14))))
        }
    })
    $label.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) { Clear-TextSelection; $s.SelectAll(); $script:selLabel = $s; $e.SuppressKeyPress = $true }   # Ctrl+A ですべて選択
        elseif (-not $e.Control -and -not $e.Shift -and ($e.KeyCode -eq 'Up' -or $e.KeyCode -eq 'Down')) {
            Move-CurrentRow $(if ($e.KeyCode -eq 'Up') { -1 } else { 1 })   # ↑↓で上下の行へ（一番下で↓なら内容欄へ）
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })

    # 文字の位置を □ にそろえるための余白（テキストボックスは Padding が使えないので外側に置く）
    $labelHost = New-Object System.Windows.Forms.Panel
    $labelHost.Dock = 'Fill'
    $labelHost.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $labelHost.ContextMenuStrip = $menu
    $labelHost.Controls.Add($label)

    # 添付の数（📎2）。押すと開く（1件ならそのファイル、複数ならフォルダ）
    # 他の人が追加・更新した行に数秒だけ出す「New」「更新」の札（□の右）
    $flashLbl = New-Object System.Windows.Forms.Panel
    $flashLbl.Dock = 'Left'
    $flashLbl.Visible = $false
    $flashLbl.ContextMenuStrip = $menu
    $flashLbl.Add_Paint({
        param($s, $e)
        $txt = [string]$s.Tag
        if (-not $txt) { return }
        $back = if ($txt -eq 'New') { [System.Drawing.Color]::FromArgb(40, 160, 70) } else { [System.Drawing.Color]::FromArgb(235, 140, 20) }
        $h = $script:zTag.Height + 4
        $y = [Math]::Max(2, $script:rowPad - 1)
        $b = New-Object System.Drawing.SolidBrush($back)
        $e.Graphics.FillRectangle($b, 2, $y, $s.Width - 4, $h)
        $b.Dispose()
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $script:zTag, (New-Object System.Drawing.Rectangle(2, $y, ($s.Width - 4), $h)), [System.Drawing.Color]::White,
            [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, NoPadding')
    })

    # 担当（ステータスの左に小さく「Main:〇〇 Sub:〇〇」。自分が担当なら太字の青）
    $roleLbl = New-Object System.Windows.Forms.Label
    $roleLbl.Dock = 'Right'
    $roleLbl.AutoSize = $false   # 幅は Update-Row で全行そろえる
    $roleLbl.UseMnemonic = $false
    $roleLbl.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $roleLbl.Visible = $false
    $roleLbl.ContextMenuStrip = $menu

    $clip = New-Object System.Windows.Forms.Label
    $clip.Dock = 'Right'
    $clip.AutoSize = $true
    $clip.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 8)
    $clip.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $clip.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $clip.Cursor = 'Hand'
    $clip.Visible = $false
    $clip.ContextMenuStrip = $menu
    $clip.Add_Click({
        param($s, $e)
        $t = $s.Parent.Tag
        Clear-Unread $s.Parent
        if ($t.files.Count -eq 1) { Open-Attachment $t $t.files[0] } else { Open-AttachFolder $t }
    })

    $dueBox = New-Object System.Windows.Forms.Panel
    $dueBox.Dock = 'Right'
    $dueBox.Visible = $false
    $dueBox.ContextMenuStrip = $menu
    $dueBox.Add_Paint($duePaint)

    $statusBox = New-Object System.Windows.Forms.Panel
    $statusBox.Dock = 'Right'
    $statusBox.Cursor = 'Hand'
    $statusBox.ContextMenuStrip = $menu
    $statusBox.Add_Paint($statusPaint)
    $statusBox.Add_Click({ param($s, $e) Show-ProgressDialog $s.Parent })

    $del = New-Object System.Windows.Forms.Button
    $del.Text = '×'
    $del.Dock = 'Right'
    $del.Width = 26
    $del.TextAlign = 'TopCenter'
    $del.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
    $del.FlatStyle = 'Flat'
    $del.FlatAppearance.BorderSize = 0
    $del.ForeColor = [System.Drawing.Color]::DimGray
    $del.Cursor = 'Hand'
    $del.TabStop = $false
    $tip.SetToolTip($del, '削除')
    $del.Add_Click({ param($s, $e) Remove-Row $s.Parent })

    $edit = New-Object System.Windows.Forms.Button
    $edit.Text = '✎'
    $edit.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 10)
    $edit.Dock = 'Right'
    $edit.Width = 24
    $edit.TextAlign = 'TopCenter'
    $edit.Padding = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)
    $edit.FlatStyle = 'Flat'
    $edit.FlatAppearance.BorderSize = 0
    $edit.ForeColor = [System.Drawing.Color]::DimGray
    $edit.Cursor = 'Hand'
    $edit.TabStop = $false
    $tip.SetToolTip($edit, '編集（案件・内容・期日・ステータス・重要・共有・詳細メモ・添付）')
    $edit.Add_Click({ param($s, $e) Edit-Row $s.Parent })

    $badge = New-Badge 'imp' $true
    $badge.Dock = 'Left'
    $badge.ContextMenuStrip = $menu

    $shareBadge = New-Badge 'share' $true
    $shareBadge.Dock = 'Left'
    $shareBadge.ContextMenuStrip = $menu

    # ▼ 詳細メモの開閉
    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 7)
    $toggle.Dock = 'Left'
    $toggle.Width = 18
    $toggle.TextAlign = 'TopCenter'
    $toggle.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
    $toggle.FlatStyle = 'Flat'
    $toggle.FlatAppearance.BorderSize = 0
    $toggle.Cursor = 'Hand'
    $toggle.TabStop = $false
    $toggle.Add_Click({ param($s, $e) Switch-Memo $s.Parent })

    # 詳細メモ欄（行の下側。▼で表示）
    $memoHost = New-Object System.Windows.Forms.Panel
    $memoHost.Dock = 'Bottom'
    $memoHost.Padding = New-Object System.Windows.Forms.Padding(22, 0, 8, 4)
    $memoHost.Visible = $false

    $memo = New-Object RowTextBox
    $memo.Multiline = $true
    $memo.AcceptsReturn = $true
    Add-NewlineKeys $memo
    $memo.WordWrap = $true
    $memo.Dock = 'Fill'
    $memo.Font = $script:zSmall
    $memo.BorderStyle = 'FixedSingle'
    $memo.BackColor = $memoBack
    $memo.Add_TextChanged({
        param($s, $e)
        $r = $s.Parent.Parent
        if (-not $r.Tag) { return }
        if (-not $script:applying) {
            Set-Dirty $r
            $saveTimer.Stop(); $saveTimer.Start()   # 入力が止まったら保存
            Send-TypingForRow $r   # 共有の項目なら「入力中…」を知らせる
        }
        Update-Row $r   # 高さ・▼の色・ツールチップを更新
    })
    $memoHost.Controls.Add($memo)

    # ▼を開いたときにメモの上に出す「記載者・記載日・担当・サブ」
    $memoInfo = New-Object System.Windows.Forms.Label
    $memoInfo.Dock = 'Top'
    $memoInfo.Height = $script:zTiny.Height + 6
    $memoInfo.Font = $script:zTiny
    $memoInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 90, 30)
    $memoInfo.AutoEllipsis = $true
    $memoInfo.UseMnemonic = $false
    $memoHost.Controls.Add($memoInfo)

    # 行番号（一番左）
    $num = New-Object System.Windows.Forms.Label
    $num.Dock = 'Left'
    $num.Width = 22
    $num.Font = $script:zSmall
    $num.ForeColor = [System.Drawing.Color]::FromArgb(150, 130, 70)
    $num.TextAlign = 'TopRight'
    $num.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $num.ContextMenuStrip = $menu

    # Dock は後から追加したものが先に配置される
    # 左から: 番号・重要・共有・▼・□・内容 … 📎・ステータス・期日・✎・×   （メモ欄は一番下の全幅）
    $row.Controls.Add($labelHost)
    $row.Controls.Add($flashLbl)   # □の右に「New」「更新」
    $row.Controls.Add($cb)
    $row.Controls.Add($clip)
    $row.Controls.Add($roleLbl)    # ステータスの左に「Main:〇〇 Sub:〇〇」
    $row.Controls.Add($statusBox)
    $row.Controls.Add($dueBox)
    $row.Controls.Add($edit)
    $row.Controls.Add($del)
    $row.Controls.Add($toggle)
    $row.Controls.Add($shareBadge)
    $row.Controls.Add($badge)
    $row.Controls.Add($num)
    $row.Controls.Add($memoHost)
    $row.Tag = [pscustomobject]@{
        cb = $cb; label = $label; labelHost = $labelHost; flashLbl = $flashLbl; roleLbl = $roleLbl; edit = $edit; del = $del; clip = $clip; dueBox = $dueBox; statusBox = $statusBox; badge = $badge; shareBadge = $shareBadge
        toggle = $toggle; memoHost = $memoHost; memo = $memo; memoInfo = $memoInfo; num = $num
        id = ''; key = ''; text = ''; important = $false; due = $null; time = ''; dueAt = $null; status = '未着手'; note = ''; files = @(); createdAt = ''; assignee = ''; subAssignee = ''
        shared = $false; owner = ''; scope = @(); updatedAt = ''; updatedBy = ''
        seq = (++$script:seq); shown = $true; dirty = $false; unread = $false; lastClick = 0; lastBlankClick = 0; selected = $false; current = $false; flashUntil = $null
    }

    # ファイルを行にドラッグ＆ドロップすると添付
    foreach ($c in @($row) + @($row.Controls | Where-Object { $_ -ne $memoHost }) + @($label)) {
        $c.AllowDrop = $true
        $c.Add_DragEnter({
            param($s, $e)
            if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
        })
        $c.Add_DragDrop({
            param($s, $e)
            $r = Get-RowOf $s
            $files = [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            if ($r -and $files) { Add-Attachments $r $files }
        })
        $c.Add_MouseDown({
            param($s, $e)
            $r = Get-RowOf $s
            Clear-Unread $r
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            $mods = [System.Windows.Forms.Control]::ModifierKeys
            $ctrl = ($mods -band [System.Windows.Forms.Keys]::Control) -ne 0
            $shift = ($mods -band [System.Windows.Forms.Keys]::Shift) -ne 0
            if ($shift) { Select-Range $r $ctrl }                                        # Shift＋クリック: 起点からここまでまとめて選ぶ（Ctrl も押していれば足す）
            elseif ($ctrl) { Switch-Select $r; $script:anchorRow = $r }                 # Ctrl＋クリックで選ぶ/外す
            else { Clear-Selection; Set-CurrentRow $r; $script:anchorRow = $r }         # 普通のクリック: 選択を解除して、その行を「今の行」（薄い緑）に
        })
    }
    # 文字以外のところ（余白・番号・札・担当・期日など）のダブルクリックでチェック。ボタン類と □（独自に処理）は除く
    foreach ($c in @($row, $labelHost, $flashLbl, $roleLbl, $dueBox, $badge, $shareBadge, $num)) {
        $c.Add_MouseUp({ param($s, $e) Test-RowDoubleClick $s $e | Out-Null })
    }
    Apply-RowScale $row   # アイコン・余白を今の倍率に
    $flow.Controls.Add($row)
    return $row
}

function Add-RowFromRecord($rec, [bool]$shared) {
    $row = New-Row
    Set-RowFromRecord $row $rec $shared
    return $row
}

function Find-Row([string]$id) {
    foreach ($r in $flow.Controls) { if ($r.Tag.id -eq $id) { return $r } }
    return $null
}

function Add-FromInput {
    $text = ($txtInput.Text -replace "[\t\r\n]+", ' ').Trim()   # 貼り付けた改行は空白に
    $key = ($txtKey.Text -replace "[\t\r\n]+", ' ').Trim()
    if ($text -ne '') {
        $due = if ($dtpDue.Checked) { $dtpDue.Value.Date } elseif ($chkTime.Checked) { (Get-Date).Date } else { $null }   # 時刻だけなら今日
        $shared = $sharingOn -and [bool]$tglShare.Tag
        $rec = @{
            id = New-Id; done = '0'; important = [string][int][bool]$tglImportant.Tag
            due = $(if ($due) { $due.ToString('yyyy-MM-dd') } else { '' })
            time = $(if ($due -and $chkTime.Checked) { $dtpTime.Value.ToString('HH:mm') } else { '' })
            status = '未着手'; key = $key; text = $text; memo = ''
            owner = $script:me; scope = $(if ($shared) { if ($scopeInput.Tag.Count -eq 0) { '全員' } else { $scopeInput.Tag -join ',' } } else { '' })
            updatedAt = ''; updatedBy = ''; note = ''; files = ''
            createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm'); assignee = ''; subAssignee = ''
        }
        $row = Add-RowFromRecord $rec $shared
        Set-Dirty $row
        Push-Undo "追加$(Get-ShortName $row.Tag)" (New-UndoItem $row $null (ConvertTo-Record $row))
        Add-History $row '未着手' '作成'
        Register-KeyUse $key
        Sort-Rows
        Apply-Filter
        if ($row.Visible) { $flow.ScrollControlIntoView($row) }
        $txtInput.Text = ''
        Reset-InputOptions
        Clear-MyTyping   # 追加したので「入力中…」を消す
        Save-Data
    }
    $txtInput.Focus() | Out-Null
}

# ステータスを変える（コメントは理由。ステータスが同じでもコメントだけ記録できる）
function Set-RowStatus($row, [string]$status, [string]$comment) {
    if (-not $row) { return }
    $t = $row.Tag
    $comment = ([string]$comment).Trim()
    $statusChanged = $status -ne $t.status
    if (-not $statusChanged -and -not $comment) { return }
    $before = ConvertTo-Record $row
    Add-History $row $status $comment
    $t.status = $status
    if ($comment) { $t.note = $comment }
    elseif ($statusChanged) { $t.note = '' }   # 理由なしでステータスだけ変えたら、前の理由は消す
    $t.unread = $false
    Set-Dirty $row
    if ($statusChanged) { Push-Undo "ステータスを「$status」に$(Get-ShortName $t)" (New-UndoItem $row $before (ConvertTo-Record $row)) }
    Update-Row $row
    Apply-Filter
    Save-Data
}

function Remove-Row($row) {
    $t = $row.Tag
    $hasFiles = $t.files.Count -gt 0
    if ($t.shared -or $hasFiles) {
        $msg = if ($t.shared) { "共有している項目です。削除すると、共有している全員の一覧から消えます。" } else { "この項目を削除します。" }
        if ($hasFiles) { $msg += "`n添付ファイル（$($t.files.Count)件）も削除されます。" }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, "$msg`n`n$(Get-DisplayText $t)", '削除の確認', 'OKCancel', 'Warning')
        if ($ans -ne 'OK') { return }
    }
    $before = ConvertTo-Record $row
    try {
        Remove-FromItemFile (Get-StorePath $t) $t.id
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "ファイルから削除できませんでした。`n$($_.Exception.Message)", '削除', 'OK', 'Error') | Out-Null
        return
    }
    if ($hasFiles) { try { Remove-Item -LiteralPath (Get-AttachDir $t) -Recurse -Force } catch { } }
    if ($hasFiles) { $before.files = '' }   # 添付は消えるので、戻しても添付なし
    Push-Undo "削除$(Get-ShortName $t)" (New-UndoItem $row $before $null)
    if ($script:currentRow -eq $row) { $script:currentRow = $null }
    $flow.Controls.Remove($row)
    $row.Dispose()
    Apply-Filter
    Save-Data
}

# ---------- ファイルとの同期（自分用・共有とも同じ仕組み） ----------
# 変更した項目を、それぞれの保存先ファイルに書き込む（その項目だけを id で書き換え）
function Sync-Stores {
    $errors = @()
    foreach ($shared in $false, $true) {
        if ($shared -and -not $sharingOn) { continue }
        $path = if ($shared) { $sharedFile } else { $personalFile }
        $dirty = @($flow.Controls | Where-Object { $_.Tag.shared -eq $shared -and $_.Tag.dirty })
        if ($dirty.Count -eq 0) { continue }
        $recs = @($dirty | ForEach-Object { ConvertTo-Record $_ })
        try {
            Update-ItemFile $path {
                param($list, $recs)
                foreach ($rec in $recs) {
                    $found = $false
                    for ($i = 0; $i -lt $list.Count; $i++) {
                        if ($list[$i].id -eq $rec.id) { $list[$i] = $rec; $found = $true; break }
                    }
                    if (-not $found) { $list.Add($rec) | Out-Null }
                }
            } $recs
            foreach ($r in $dirty) { $r.Tag.dirty = $false }
        } catch {
            $errors += "$(if ($shared) { '共有' } else { '自分用' })ファイルに保存できませんでした: $($_.Exception.Message)"
        }
    }
    Send-PendingHistory
    $script:sharedError = ($errors -join "`n")
    Update-Totals
}

# ファイルを読み直して画面に反映（他の人・他の端末の追加・変更・削除）。変化があれば $true
function Update-FromStore([bool]$shared, [switch]$Force, [switch]$Initial) {
    if ($shared -and -not $sharingOn) { return $false }
    $path = if ($shared) { $sharedFile } else { $personalFile }
    $name = if ($shared) { '共有' } else { '自分用' }
    if (-not $Force -and $script:stamps.ContainsKey($path) -and (Get-Stamp $path) -eq $script:stamps[$path]) { return $false }
    try { $records = Read-ItemFile $path } catch { $records = $null }
    if ($null -eq $records) {
        $script:sharedError = "${name}ファイルを読めませんでした: $path"
        Update-Totals
        return $false
    }
    if ($script:sharedError -like "${name}ファイルを読めません*") { $script:sharedError = '' }

    $changed = $false
    $seen = @{}
    foreach ($rec in $records) {
        if ($shared) {
            foreach ($n in @($rec.owner) + (ConvertTo-Scope $rec.scope)) {
                if ($n -and -not $script:knownNames.Contains($n)) { $script:knownNames.Add($n) }
            }
            if (-not (Test-Visible $rec)) { continue }
        }
        $seen[$rec.id] = $true
        $row = Find-Row $rec.id
        $byOther = (-not $Initial) -and $rec.updatedBy -and $rec.updatedBy -ne $script:me
        if ($row) {
            if ($row.Tag.dirty -or $row.Tag.shared -ne $shared) { continue }   # 自分の未保存の変更を優先
            if ((ConvertTo-ItemLine (ConvertTo-Record $row)) -ne (ConvertTo-ItemLine $rec)) {
                Set-RowFromRecord $row $rec $shared
                if ($byOther) { Set-Flash $row '更新'; Add-RecentEditor $rec.updatedBy }
                $changed = $true
            }
        } else {
            $row = Add-RowFromRecord $rec $shared
            if ($byOther) { Set-Flash $row 'New'; Add-RecentEditor $rec.updatedBy }
            $changed = $true
        }
    }
    # ファイルから消えた（または共有範囲から外れた）項目を消す
    foreach ($r in @($flow.Controls | Where-Object { $_.Tag.shared -eq $shared -and -not $_.Tag.dirty -and -not $seen.ContainsKey($_.Tag.id) })) {
        $flow.Controls.Remove($r)
        $r.Dispose()
        $changed = $true
    }
    Update-Totals
    return $changed
}

function Invoke-Refresh([switch]$Force) {
    Sync-Stores
    $a = Update-FromStore $false -Force:$Force
    $b = Update-FromStore $true -Force:$Force
    if ($a -or $b) {
        Sort-Rows
        Apply-Filter
    }
}

function Save-Data {
    if ($script:loading) { return }

    # 変更した項目 → 自分用ファイル・共有ファイル
    Sync-Stores

    # ウィンドウ設定 → data.json
    $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $obj = [pscustomobject]@{
        x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height
        topMost = $form.TopMost
        sort = $script:sortMode
        hiddenStatuses = @($script:hiddenStatuses)
        zoom = $script:zoom
        filter = [pscustomobject]@{   # 絞り込みの状態（次に起動したときも同じ絞り込みで開く）
            search = $txtSearch.Text; done = $cmbDone.SelectedIndex; imp = $cmbImp.SelectedIndex
            due = $cmbDue.SelectedIndex; share = $cmbShare.SelectedIndex; assign = [string]$cmbAssign.SelectedItem; open = $filterPanel.Visible
        }
        keyStats = @($script:keyStats.GetEnumerator() | ForEach-Object { [pscustomobject]@{ key = $_.Key; count = $_.Value.count; last = $_.Value.last } })
    }
    $json = ConvertTo-Json $obj -Depth 5
    try { [System.IO.File]::WriteAllText($dataFile, $json, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

# ---------- 進捗・履歴の画面 ----------
function Show-ProgressDialog($row, $owner = $form) {
    if (-not $row) { return }
    $t = $row.Tag
    Clear-Unread $row
    $dlg = New-Object System.Windows.Forms.Form
    $dlgTip = New-Object System.Windows.Forms.ToolTip   # この画面専用の説明（付箋本体の説明と混ざらないように）
    $dlgTip.AutoPopDelay = 20000
    $dlg.Text = '進捗・履歴'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $noteColor
    $dlg.Font = $fontDays
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 440)
    $dlg.MinimumSize = New-Object System.Drawing.Size(380, 360)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = Get-DisplayText $t
    $lblTitle.Font = $fontBar
    $lblTitle.AutoEllipsis = $true
    $lblTitle.Location = New-Object System.Drawing.Point(12, 10)
    $lblTitle.Size = New-Object System.Drawing.Size(436, 20)
    $lblTitle.Anchor = 'Top, Left, Right'
    $dlgTip.SetToolTip($lblTitle, $lblTitle.Text)

    $cmbSt = New-Object System.Windows.Forms.ComboBox
    $cmbSt.DropDownStyle = 'DropDownList'
    $cmbSt.Items.AddRange([object[]]$statusList)
    $cmbSt.SelectedIndex = [Math]::Max(0, [array]::IndexOf($statusList, [string]$t.status))
    $cmbSt.Location = New-Object System.Drawing.Point(90, 38)
    $cmbSt.Width = 110

    $tbComment = New-Object System.Windows.Forms.TextBox
    $tbComment.Multiline = $true
    $tbComment.AcceptsReturn = $true
    Add-NewlineKeys $tbComment
    $tbComment.ScrollBars = 'Vertical'
    $tbComment.BackColor = $memoBack
    $tbComment.Location = New-Object System.Drawing.Point(12, 92)
    $tbComment.Size = New-Object System.Drawing.Size(436, 58)
    $tbComment.Anchor = 'Top, Left, Right'

    $btnRecord = New-Object System.Windows.Forms.Button
    $btnRecord.Text = '記録する'
    $btnRecord.BackColor = $barColor
    $btnRecord.FlatStyle = 'Flat'
    $btnRecord.Size = New-Object System.Drawing.Size(90, 28)
    $btnRecord.Location = New-Object System.Drawing.Point(358, 156)
    $btnRecord.Anchor = 'Top, Right'

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = 'ステータスが同じままでも、コメントだけ記録できます。'
    $lblHint.AutoSize = $true
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Location = New-Object System.Drawing.Point(12, 162)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.HideSelection = $false
    $lv.Location = New-Object System.Drawing.Point(12, 214)
    $lv.Size = New-Object System.Drawing.Size(436, 180)
    $lv.Anchor = 'Top, Bottom, Left, Right'
    foreach ($c in @(@('日時', 105), @('更新者', 70), @('ステータス', 70), @('コメント', 300))) { $lv.Columns.Add($c[0], $c[1]) | Out-Null }

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '閉じる'
    $btnClose.DialogResult = 'Cancel'
    $btnClose.FlatStyle = 'Flat'
    $btnClose.Size = New-Object System.Drawing.Size(80, 28)
    $btnClose.Location = New-Object System.Drawing.Point(368, 402)
    $btnClose.Anchor = 'Bottom, Right'

    $fill = {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($h in (Read-History $t)) {
            $it = New-Object System.Windows.Forms.ListViewItem($h.at)
            $it.SubItems.Add($h.by) | Out-Null
            $it.SubItems.Add($h.status) | Out-Null
            $it.SubItems.Add(($h.comment -replace "`r?`n", ' / ')) | Out-Null
            $it.ToolTipText = $h.comment
            if ($statusColors.ContainsKey($h.status)) { $it.UseItemStyleForSubItems = $false; $it.SubItems[2].BackColor = $statusColors[$h.status][0] }
            $lv.Items.Add($it) | Out-Null
        }
        $lv.EndUpdate()
        $lblCur.Text = "現在: $($t.status)" + $(if ($t.note) { "　（$($t.note -replace "`r?`n", ' ')）" } else { '' })
    }
    $lv.ShowItemToolTips = $true

    $lblCur = New-Object System.Windows.Forms.Label
    $lblCur.AutoEllipsis = $true
    $lblCur.ForeColor = [System.Drawing.Color]::FromArgb(90, 70, 20)
    $lblCur.Location = New-Object System.Drawing.Point(210, 42)
    $lblCur.Size = New-Object System.Drawing.Size(238, 20)
    $lblCur.Anchor = 'Top, Left, Right'

    $btnRecord.Add_Click({
        $st = [string]$cmbSt.SelectedItem
        if ($st -eq $t.status -and -not $tbComment.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show($dlg, 'ステータスを変えるか、コメントを入力してください。', '進捗', 'OK', 'Information') | Out-Null
            return
        }
        Set-RowStatus $row $st $tbComment.Text
        $tbComment.Text = ''
        & $fill
    })

    $dlg.Controls.AddRange(@(
        $lblTitle,
        (New-DlgLabel 'ステータス' 12 41), $cmbSt, $lblCur,
        (New-DlgLabel 'コメント（ステータスの理由・進み具合など）' 12 70), $tbComment, $lblHint, $btnRecord,
        (New-DlgLabel '進捗の履歴（新しい順）' 12 194), $lv,
        $btnClose))
    $dlg.CancelButton = $btnClose
    & $fill
    $tbComment.Add_TextChanged({ Send-TypingForRow $row })   # 共有の項目なら「入力中…」
    $dlg.Add_Shown({ $tbComment.Focus() | Out-Null })
    Show-Modal $dlg $owner | Out-Null
    Clear-MyTyping
    $dlg.Dispose()
}

# ---------- 編集画面 ----------
function New-DlgLabel([string]$text, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = $fontBar
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}

function Show-EditDialog($row) {
    $t = $row.Tag
    $dlg = New-Object System.Windows.Forms.Form
    $dlgTip = New-Object System.Windows.Forms.ToolTip   # この画面専用の説明（付箋本体の説明と混ざらないように）
    $dlgTip.AutoPopDelay = 20000
    $dlg.Text = '編集'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $noteColor
    $dlg.Font = $fontDays
    $dlg.ClientSize = New-Object System.Drawing.Size(320, 558)

    $tbKey = New-Object System.Windows.Forms.TextBox
    $tbKey.Font = $font
    $tbKey.Text = $t.key
    $tbKey.Location = New-Object System.Drawing.Point(60, 8)
    $tbKey.Width = 248
    # 入力に合わせて、これまでの案件名を候補に出す
    $tbKey.AutoCompleteMode = 'SuggestAppend'
    $tbKey.AutoCompleteSource = 'CustomSource'
    $keys = @($script:keyStats.GetEnumerator() | Sort-Object { $_.Value.last } -Descending | ForEach-Object { [string]$_.Key })
    if ($keys.Count) { $tbKey.AutoCompleteCustomSource.AddRange([string[]]$keys) }

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true            # 長い内容も折り返して全部見える（Enter は OK）
    $tb.WordWrap = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Font = $font
    $tb.Text = $t.text
    $tb.Location = New-Object System.Drawing.Point(12, 60)
    $tb.Size = New-Object System.Drawing.Size(296, 52)

    $dp = New-Object System.Windows.Forms.DateTimePicker
    $dp.Format = 'Short'
    $dp.ShowCheckBox = $true
    $dp.Location = New-Object System.Drawing.Point(60, 122)
    $dp.Width = 130
    if ($t.due) { $dp.Value = $t.due; $dp.Checked = $true }
    else { $dp.Value = (Get-Date).Date; $dp.Checked = $false }
    $dlgTip.SetToolTip($dp, 'チェックを外すと期日なし')

    $chkTp = New-Object System.Windows.Forms.CheckBox
    $chkTp.Location = New-Object System.Drawing.Point(200, 126)
    $chkTp.Size = New-Object System.Drawing.Size(16, 16)
    $chkTp.Checked = [bool]$t.time
    $dlgTip.SetToolTip($chkTp, 'チェックを入れると時刻も設定（24時間表示）')

    $tp = New-Object System.Windows.Forms.DateTimePicker
    $tp.Format = 'Custom'
    $tp.CustomFormat = 'HH:mm'
    $tp.ShowUpDown = $true
    $tp.Location = New-Object System.Drawing.Point(220, 122)
    $tp.Width = 62
    $tp.Value = (Get-Date).Date.AddHours(17)
    if ($t.time) { try { $tp.Value = (Get-Date).Date + [TimeSpan]::Parse($t.time) } catch { } }
    $tp.Enabled = $chkTp.Checked
    $chkTp.Add_CheckedChanged({ $tp.Enabled = $chkTp.Checked })

    $cmbSt = New-Object System.Windows.Forms.ComboBox
    $cmbSt.DropDownStyle = 'DropDownList'
    $cmbSt.Items.AddRange([object[]]$statusList)
    $cmbSt.SelectedIndex = [Math]::Max(0, [array]::IndexOf($statusList, [string]$t.status))
    $cmbSt.Location = New-Object System.Drawing.Point(60, 154)
    $cmbSt.Width = 90

    # ステータスの理由（入れると進捗の履歴に残る。ステータスが同じでもコメントだけ記録できる）
    $tbNote = New-Object System.Windows.Forms.TextBox
    $tbNote.Location = New-Object System.Drawing.Point(156, 154)
    $tbNote.Width = 152
    $dlgTip.SetToolTip($tbNote, 'ステータスの理由・進み具合（進捗の履歴に残ります）')

    $btnHistory = New-Object System.Windows.Forms.Button
    $btnHistory.Text = '進捗・履歴…'
    $btnHistory.FlatStyle = 'Flat'
    $btnHistory.Location = New-Object System.Drawing.Point(214, 184)
    $btnHistory.Size = New-Object System.Drawing.Size(94, 26)
    $btnHistory.Add_Click({
        Show-ProgressDialog $row $dlg
        $cmbSt.SelectedIndex = [Math]::Max(0, [array]::IndexOf($statusList, [string]$t.status))   # 履歴画面で変えた分を反映
    })

    $chkImp = New-Object System.Windows.Forms.CheckBox
    $chkImp.Text = '重要（一番上に表示）'
    $chkImp.Font = $fontBar
    $chkImp.AutoSize = $true
    $chkImp.Checked = $t.important
    $chkImp.Location = New-Object System.Drawing.Point(12, 188)

    $chkShare = New-Object System.Windows.Forms.CheckBox
    $chkShare.Text = '共有する'
    $chkShare.Font = $fontBar
    $chkShare.AutoSize = $true
    $chkShare.Checked = $t.shared
    $chkShare.Location = New-Object System.Drawing.Point(12, 218)

    $picker = New-ScopePicker
    $picker.Name = 'dlgPicker'   # 説明は付箋本体の ToolTip に登録しない
    $tip.SetToolTip($picker, $null)
    $picker.Location = New-Object System.Drawing.Point(100, 214)
    $picker.Size = New-Object System.Drawing.Size(208, 26)
    Set-PickerScope $picker $t.scope

    # 記載者・記載日（見るだけ）
    $info = New-Object System.Windows.Forms.Label
    $info.AutoSize = $true
    $info.ForeColor = [System.Drawing.Color]::DimGray
    $info.Location = New-Object System.Drawing.Point(12, 246)
    $created = Get-CreatedAt $t
    $info.Text = "記載者: $(Get-PersonText $t.owner)　記載日: $(if ($created) { $created.Replace('-', '/') } else { '—' })" + $(if (-not $t.shared) { '　（自分用）' } else { '' })
    if ($t.updatedBy) { $dlgTip.SetToolTip($info, "最終更新: $($t.updatedBy) $($t.updatedAt)") }

    # 担当者・サブ担当者（一覧から選ぶ。一覧にない名前も入力できる）
    function New-PersonCombo([string]$value, [int]$x) {
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDown'
        $c.Location = New-Object System.Drawing.Point($x, 267)
        $c.Width = 100
        $c.Items.Add('') | Out-Null   # 空 = なし
        foreach ($n in @($script:me) + @(Get-Members)) { if ($n -and -not $c.Items.Contains($n)) { $c.Items.Add($n) | Out-Null } }
        if ($value -and -not $c.Items.Contains($value)) { $c.Items.Add($value) | Out-Null }
        $c.Text = $value
        $c.AutoCompleteMode = 'SuggestAppend'
        $c.AutoCompleteSource = 'ListItems'
        return $c
    }
    $cmbAssignee = New-PersonCombo $t.assignee 60
    $cmbSub = New-PersonCombo $t.subAssignee 208
    $dlgTip.SetToolTip($cmbAssignee, '担当者（空欄ならなし）')
    $dlgTip.SetToolTip($cmbSub, 'サブ担当者（空欄ならなし）')

    if (-not $sharingOn) {
        $chkShare.Enabled = $false
        $picker.Enabled = $false
        $dlgTip.SetToolTip($chkShare, '設定ファイル（StickyChecklist.ini）の SharedFile を指定すると共有できます')
    }
    $picker.Enabled = $sharingOn -and $chkShare.Checked
    $chkShare.Add_CheckedChanged({ $picker.Enabled = $chkShare.Checked })

    $tbMemo = New-Object System.Windows.Forms.TextBox
    $tbMemo.Multiline = $true
    $tbMemo.AcceptsReturn = $true    # メモ欄の Enter は改行
    Add-NewlineKeys $tbMemo
    $tbMemo.WordWrap = $true
    $tbMemo.ScrollBars = 'Vertical'
    $tbMemo.Font = $fontDays
    $tbMemo.BackColor = $memoBack
    $tbMemo.Text = $t.memo.Text
    $tbMemo.Location = New-Object System.Drawing.Point(12, 320)
    $tbMemo.Size = New-Object System.Drawing.Size(296, 84)

    # 添付（ここでの追加・削除はすぐに反映される）
    $lbFiles = New-Object System.Windows.Forms.ListBox
    $lbFiles.Location = New-Object System.Drawing.Point(12, 434)
    $lbFiles.Size = New-Object System.Drawing.Size(220, 76)
    $lbFiles.HorizontalScrollbar = $true
    $dlgTip.SetToolTip($lbFiles, 'ダブルクリックで開く。ファイルをここへドラッグしても添付できます')
    $refreshFiles = { $lbFiles.Items.Clear(); foreach ($f in $t.files) { $lbFiles.Items.Add($f) | Out-Null } }
    & $refreshFiles
    $lbFiles.Add_DoubleClick({ if ($lbFiles.SelectedItem) { Open-Attachment $t ([string]$lbFiles.SelectedItem) } })
    $lbFiles.AllowDrop = $true
    $lbFiles.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } })
    $lbFiles.Add_DragDrop({ param($s, $e) Add-Attachments $row ([string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)); & $refreshFiles })

    function New-SmallButton([string]$text, [int]$y) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.FlatStyle = 'Flat'
        $b.Location = New-Object System.Drawing.Point(238, $y)
        $b.Size = New-Object System.Drawing.Size(70, 24)
        return $b
    }
    $btnAddFile = New-SmallButton '追加…' 434
    $btnOpenFile = New-SmallButton '開く' 460
    $btnDelFile = New-SmallButton '削除' 486
    $btnAddFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Multiselect = $true
        $ofd.Title = '添付するファイルを選んでください'
        if ((Show-Modal $ofd $dlg) -eq 'OK') { Add-Attachments $row $ofd.FileNames; & $refreshFiles }
    })
    $btnOpenFile.Add_Click({ if ($lbFiles.SelectedItem) { Open-Attachment $t ([string]$lbFiles.SelectedItem) } })
    $btnDelFile.Add_Click({
        $name = [string]$lbFiles.SelectedItem
        if (-not $name) { return }
        if ([System.Windows.Forms.MessageBox]::Show($dlg, "添付ファイルを削除します。`n$name", '添付の削除', 'OKCancel', 'Warning') -eq 'OK') {
            Remove-Attachment $row $name; & $refreshFiles
        }
    })

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = 'OK'
    $ok.BackColor = $barColor
    $ok.FlatStyle = 'Flat'
    $ok.Location = New-Object System.Drawing.Point(146, 522)
    $ok.Size = New-Object System.Drawing.Size(76, 26)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'
    $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'
    $cancel.Location = New-Object System.Drawing.Point(230, 522)
    $cancel.Size = New-Object System.Drawing.Size(78, 26)

    $dlg.Controls.AddRange(@(
        (New-DlgLabel '案件' 12 11), $tbKey,
        (New-DlgLabel '内容' 12 40), $tb,
        (New-DlgLabel '期日' 12 125), $dp, $chkTp, $tp,
        (New-DlgLabel '状態' 12 157), $cmbSt, $tbNote,
        $chkImp, $btnHistory, $chkShare, $picker, $info,
        (New-DlgLabel '担当' 12 270), $cmbAssignee, (New-DlgLabel 'サブ' 168 270), $cmbSub,
        (New-DlgLabel '詳細メモ' 12 300), $tbMemo,
        (New-DlgLabel '添付ファイル' 12 414), $lbFiles, $btnAddFile, $btnOpenFile, $btnDelFile,
        $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    foreach ($c in $tbKey, $tb, $tbNote, $tbMemo) { $c.Add_TextChanged({ Send-TypingForRow $row }) }   # 共有の項目なら「入力中…」
    $dlg.Add_Shown({ $tb.Focus(); $tb.SelectionStart = $tb.TextLength })

    $res = Show-Modal $dlg $form
    $due = if ($dp.Checked) { $dp.Value.Date } elseif ($chkTp.Checked) { (Get-Date).Date } else { $null }   # 時刻だけなら今日
    $result = [pscustomobject]@{
        ok        = ($res -eq [System.Windows.Forms.DialogResult]::OK)
        key       = ($tbKey.Text -replace "[\t\r\n]+", ' ').Trim()
        text      = ($tb.Text -replace "[\t\r\n]+", ' ').Trim()
        due       = $due
        time      = if ($due -and $chkTp.Checked) { $tp.Value.ToString('HH:mm') } else { '' }
        status    = $statusList[$cmbSt.SelectedIndex]
        note      = $tbNote.Text.Trim()
        important = $chkImp.Checked
        shared    = $sharingOn -and $chkShare.Checked
        scope     = @($picker.Tag)
        memo      = $tbMemo.Text.TrimEnd()
        assignee    = ($cmbAssignee.Text -replace "[\t\r\n,]+", ' ').Trim()
        subAssignee = ($cmbSub.Text -replace "[\t\r\n,]+", ' ').Trim()
    }
    $dlg.Dispose()
    return $result
}

# 自分用 ⇔ 共有 を切り替える（元のファイルから消して、履歴と添付も移す）。できたら $true
function Move-RowStore($row, [bool]$toShared) {
    $t = $row.Tag
    if ($t.shared -eq $toShared) { return $true }
    $oldStore = Get-StorePath $t
    $newStore = if ($toShared) { $sharedFile } else { $personalFile }
    try {
        Remove-FromItemFile $oldStore $t.id
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "ファイルを更新できませんでした。`n$($_.Exception.Message)", '共有の切り替え', 'OK', 'Error') | Out-Null
        return $false
    }
    try { Copy-History $t.id $oldStore $newStore } catch { }
    try { Move-Attachments $t $oldStore $newStore } catch { }
    $t.shared = $toShared
    if ($toShared -and -not $t.owner) { $t.owner = $script:me }
    return $true
}

function Edit-Row($row) {
    $t = $row.Tag
    Clear-Unread $row
    $r = Show-EditDialog $row
    Clear-MyTyping
    if (-not $r.ok -or $r.text -eq '') { return }
    $undoBefore = ConvertTo-Record $row
    $canUndo = ($t.shared -eq $r.shared)   # 自分用⇔共有の切り替えは戻せない

    # 自分用 ⇔ 共有 を切り替える → 元のファイルから消して、履歴と添付も移す
    if ($t.shared -ne $r.shared) {
        if ($t.shared) {
            $ans = [System.Windows.Forms.MessageBox]::Show($form,
                '共有をやめると、他の人の一覧からこの項目が消えて、あなた専用になります。よろしいですか？',
                '共有の解除', 'OKCancel', 'Question')
            if ($ans -ne 'OK') { return }
        }
        if (-not (Move-RowStore $row $r.shared)) { return }
    }

    # ステータスが変わった、または理由が入った → 進捗の履歴に残す
    if ($r.status -ne $t.status -or $r.note) {
        Add-History $row $r.status $r.note
        if ($r.note) { $t.note = $r.note } elseif ($r.status -ne $t.status) { $t.note = '' }
        $t.status = $r.status
    }

    if ($r.key -and $r.key -ne $t.key) { Register-KeyUse $r.key }
    $t.key = $r.key
    $t.text = $r.text
    $t.due = $r.due
    $t.time = $r.time
    $t.important = $r.important
    $t.scope = @($r.scope)

    # 担当者が変わったら進捗の履歴にも残す
    $changes = @()
    if ($r.assignee -ne [string]$t.assignee) { $changes += "担当者: $(Get-PersonText $t.assignee) → $(Get-PersonText $r.assignee)" }
    if ($r.subAssignee -ne [string]$t.subAssignee) { $changes += "サブ担当者: $(Get-PersonText $t.subAssignee) → $(Get-PersonText $r.subAssignee)" }
    if ($changes.Count) { Add-History $row $t.status ($changes -join '、') }
    $t.assignee = $r.assignee
    $t.subAssignee = $r.subAssignee
    if (-not $t.createdAt) { $t.createdAt = Get-CreatedAt $t }   # 古い項目も、分かる記載日は記録しておく
    $script:applying = $true
    if ($t.memo.Text -ne $r.memo) { $t.memo.Text = $r.memo }
    $script:applying = $false
    Update-AttachList $row
    Set-Dirty $row
    if ($canUndo) { Push-Undo "編集$(Get-ShortName $t)" (New-UndoItem $row $undoBefore (ConvertTo-Record $row)) }
    Update-Row $row
    Sort-Rows
    Apply-Filter
    Save-Data
}

# ---------- 文字の拡大・縮小（Ctrl＋ホイール、Ctrl＋0 で元に戻す） ----------
$zoomLabelTimer = New-Object System.Windows.Forms.Timer
$zoomLabelTimer.Interval = 1500
$zoomLabelTimer.Add_Tick({ $zoomLabelTimer.Stop(); $title.Text = '✔ チェックリスト' })

function Set-Zoom([double]$z) {
    $z = [Math]::Round([Math]::Max(0.7, [Math]::Min(2.0, $z)), 1)   # 70%〜200%
    $title.Text = "✔ チェックリスト $([int]($z * 100))%"             # 少しの間だけ倍率を出す
    $zoomLabelTimer.Stop(); $zoomLabelTimer.Start()
    if ($z -eq $script:zoom) { return }
    $script:zoom = $z
    Set-ListFonts
    Apply-UiScale
    $flow.SuspendLayout()
    foreach ($r in $flow.Controls) { Apply-RowScale $r; Update-Row $r }
    $flow.ResumeLayout()
    Update-Numbers
    Update-ScrollExtent
    if (-not $script:loading) { $saveTimer.Stop(); $saveTimer.Start() }   # 倍率を保存
}

# 行のアイコン・文字・余白を今の倍率に合わせる
function Apply-RowScale($row) {
    $t = $row.Tag
    $lh = Get-LineHeight $script:zItem
    $script:rowPad = [Math]::Max(3, [int](($script:badgeW - $lh) / 2))   # 1行目の文字を丸の高さの真ん中に
    $pad = $script:rowPad
    $t.badge.Width = $script:badgeW
    $t.shareBadge.Width = $script:badgeW
    $t.toggle.Width = Z 22
    $t.toggle.Font = $script:zToggle
    $t.toggle.Padding = New-Object System.Windows.Forms.Padding(0, [Math]::Max(0, $pad - 1), 0, 0)
    $t.cb.Width = [Math]::Max(18, (Z 20))
    $t.cb.Padding = New-Object System.Windows.Forms.Padding(0, [Math]::Max(0, $pad + [int](($lh - 14) / 2)), 0, 0)
    $t.labelHost.Padding = New-Object System.Windows.Forms.Padding(0, $pad, 0, 0)
    $t.num.Font = $script:zSmall
    $t.num.Padding = New-Object System.Windows.Forms.Padding(0, ($pad + 1), 0, 0)
    $t.edit.Width = Z 30
    $t.edit.Font = $script:zIconS
    $t.edit.Padding = New-Object System.Windows.Forms.Padding(0, [Math]::Max(0, $pad - 3), 0, 0)
    $t.del.Width = Z 30
    $t.del.Font = $script:zDel
    $t.del.Padding = New-Object System.Windows.Forms.Padding(0, [Math]::Max(0, $pad - 5), 0, 0)
    $t.clip.Font = $script:zToggle
    $t.clip.Padding = New-Object System.Windows.Forms.Padding(0, $pad, 0, 0)
    $t.flashLbl.Font = $script:zTag
    $t.flashLbl.Margin = New-Object System.Windows.Forms.Padding(0)
    $t.roleLbl.Font = $script:zTiny
    $t.roleLbl.Padding = New-Object System.Windows.Forms.Padding(2, ($pad + 1), 4, 0)
    $t.memo.Font = $script:zSmall
    $t.memoInfo.Font = $script:zTiny
    $t.memoInfo.Height = $script:zTiny.Height + 6
}

# 上部（バー・絞り込み）と下部（入力欄）の大きさを今の倍率に合わせる
function Apply-UiScale {
    # 上部のバー
    $bar.Height = Z 34
    $title.Font = $script:zUiBold
    $lblTotals.Font = $script:zTotals
    $lblUpdMsg.Font = New-Object System.Drawing.Font($script:zTotals, [System.Drawing.FontStyle]::Bold)
    $lblUpdInfo.Font = New-Object System.Drawing.Font('Segoe UI Symbol', [single](11 * $script:zoom))
    foreach ($b in $btnUndo, $btnRedo, $btnReload, $btnSort, $btnPin) { $b.Width = Z 36; $b.Font = $script:zIcon }
    $btnFilter.Width = Z 36; $btnFilter.Font = $script:zIconS
    $btnClose.Width = Z 34; $btnClose.Font = New-Object System.Drawing.Font('Yu Gothic UI', [single](11 * $script:zoom), [System.Drawing.FontStyle]::Bold)
    # 絞り込み欄
    $rowH = Z 28
    $fLine1.Height = $rowH
    $txtSearch.Font = $script:zUi
    $lblCount.Font = $script:zUi
    $btnFilterReset.Font = $script:zUiBold; $btnFilterReset.Width = Z 46
    foreach ($c in $cmbDone, $cmbImp, $cmbDue, $cmbShare, $cmbAssign) { $c.Font = $script:zUi; $c.ItemHeight = $script:zUi.Height + 4 }
    $btnStatusFilter.Font = $script:zUi
    $fGrid.Height = 2 * ($script:zUi.Height + 12)
    $filterPanel.Height = $filterPanel.Padding.Vertical + $fLine1.Height + $fGrid.Height + 4
    # 下部の入力欄
    $line1.Height = 2 * $script:zInput.Height + 12   # 2行分
    foreach ($tb in $txtKey, $txtInput) { $tb.Font = $script:zInput; $tb.Tag.Font = $script:zInput }   # Tag は薄い案内文字
    $btnAdd.Font = $script:zUiBold; $btnAdd.Width = Z 56
    $line2.Height = [Math]::Max((Z 32), $script:zUi.Height + 14)
    $lblDue.Font = $script:zUiBold; $lblDue.Width = Z 40
    $dtpDue.Font = $script:zUi; $dtpDue.Width = Z 132
    $chkTime.Width = Z 24
    $dtpTime.Font = $script:zUi; $dtpTime.Width = Z 66
    $line3.Height = [Math]::Max($script:badgeW + 2, $script:zUi.Height + 14)
    $lblShare.Font = $script:zUiBold; $lblShare.Width = Z 52
    $scopeInput.Font = $script:zUi
    foreach ($g in $tglShare, $tglImportant) { $g.Width = $script:badgeW + 2; $g.Invalidate() }
    $bottom.Height = $bottom.Padding.Vertical + $line1.Height + $line2.Height + $line3.Height + 2
    $typingBar.Font = $script:zTotals
    $typingBar.Height = $script:zTotals.Height + 8
    $line1.PerformLayout()
    $keyHost.Width = [Math]::Max((Z 110), [Math]::Min((Z 240), [int](($line1.Width - $btnAdd.Width) * 0.35)))
}

$zoomFilter = New-Object CtrlWheelFilter
$zoomFilter.OnZoom = [Action[int]]{ param($delta) Set-Zoom ($script:zoom + $(if ($delta -gt 0) { 0.1 } else { -0.1 })) }
# どこかをクリックしたら、コピー用の選択（青）を外す（選んでいる文字そのものの上と、「コピー」などのメニューの上は除く）
$zoomFilter.OnMouseDown = [Action[IntPtr]]{
    param($h)
    $l = $script:selLabel
    if (-not $l -or $l.IsDisposed -or $h -eq $l.Handle) { return }
    if ([System.Windows.Forms.Control]::FromHandle($h) -is [System.Windows.Forms.ToolStrip]) { return }
    Clear-TextSelection
}
# Ctrl＋C: 行の文字を選んでいればコピー（入力欄で文字を選んでいるときは、その入力欄のコピー）
$zoomFilter.OnCopy = [Func[bool]]{
    if ($script:modalDepth -gt 0) { return $false }   # 編集画面などを開いているときは、その画面のコピーに任せる
    $ac = $form.ActiveControl
    if ($ac -is [System.Windows.Forms.TextBoxBase] -and $ac -ne $script:selLabel -and $ac.Focused -and $ac.SelectionLength -gt 0) { return $false }
    return [bool](Copy-SelectedText)
}

# ---------- 「〇〇 が入力中…」 ----------
# 共有の項目を書いているあいだ、共有フォルダの typing\<名前>.txt に「名前・時刻・何を・共有範囲」を書く（2秒に1回まで）。
# 他の人の付箋はそれを読んで一番下に表示する。8秒書き込みがなければ消える。自分用の項目の入力は知らせない。
$typingDir = if ($sharingOn) { Join-Path (Split-Path $sharedFile -Parent) 'typing' } else { '' }
$script:lastTypingSent = [datetime]::MinValue
$script:typingPeople = @()
$script:typingDots = 0
$script:typingTicks = 0

function Get-TypingFile([string]$name) {
    return Join-Path $typingDir ([regex]::Replace($name, '[\\/:*?"<>|]', '_') + '.txt')
}

function Send-Typing([string]$what, [string]$scope) {
    if (-not $sharingOn) { return }
    $now = [datetime]::UtcNow
    if (($now - $script:lastTypingSent).TotalSeconds -lt 2) { return }
    $script:lastTypingSent = $now
    try {
        if (-not (Test-Path -LiteralPath $typingDir)) { New-Item -ItemType Directory -Path $typingDir -Force | Out-Null }
        $line = (@($script:me, $now.ToString('o'), $what, $scope) | ForEach-Object { ConvertTo-Field ([string]$_) }) -join "`t"
        [System.IO.File]::WriteAllText((Get-TypingFile $script:me), $line, $utf8Bom)
    } catch { }
}

function Get-ScopeString($scope) { $s = @(@($scope) | Where-Object { $_ }); if ($s.Count) { return ($s -join ',') } return '全員' }

function Send-TypingForRow($row) {
    if ($row -and $row.Tag.shared) { Send-Typing (Get-DisplayText $row.Tag) (Get-ScopeString $row.Tag.scope) }
}

function Clear-MyTyping {
    if (-not $sharingOn) { return }
    $script:lastTypingSent = [datetime]::MinValue
    try { Remove-Item -LiteralPath (Get-TypingFile $script:me) -Force -ErrorAction SilentlyContinue } catch { }
}

function Update-TypingIndicator([switch]$Read) {
    if (-not $sharingOn) { return }
    if ($Read) {
        $list = @()
        try {
            if (Test-Path -LiteralPath $typingDir) {
                foreach ($f in @(Get-ChildItem -LiteralPath $typingDir -Filter '*.txt' -File)) {
                    $p = ([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)).Trim().Split("`t")
                    if ($p.Count -lt 2) { continue }
                    $name = ConvertFrom-Field $p[0]
                    if (-not $name -or $name -eq $script:me) { continue }
                    $at = [datetime]::Parse($p[1], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    if (([datetime]::UtcNow - $at).TotalSeconds -gt 8) { continue }   # 止まって8秒たったら消す
                    $sc = @((ConvertFrom-Field $(if ($p.Count -ge 4) { $p[3] } else { '' })) -split ',' | Where-Object { $_ })
                    if ($sc.Count -and $sc -notcontains '全員' -and $sc -notcontains $script:me) { continue }   # 共有範囲外の人には出さない
                    $list += [pscustomobject]@{ name = $name; what = $(if ($p.Count -ge 3) { ConvertFrom-Field $p[2] } else { '' }) }
                }
            }
        } catch { }
        $script:typingPeople = $list
    }
    $people = @($script:typingPeople)
    # 入力中の通知に加えて、直近（数秒以内）に変更した人も「入力中」として出す
    $now = Get-Date
    foreach ($n in @($script:recentEditors.Keys)) {
        if ($now -ge $script:recentEditors[$n]) { $script:recentEditors.Remove($n); continue }
        if (-not ($people | Where-Object { $_.name -eq $n })) { $people += [pscustomobject]@{ name = $n; what = '' } }
    }
    if ($people.Count -eq 0) { if ($typingBar.Visible) { $typingBar.Visible = $false }; return }
    $script:typingDots = ($script:typingDots + 1) % 3
    $text = (($people | ForEach-Object { "$($_.name)さん" }) -join '、') + 'が入力中' + ('・' * ($script:typingDots + 1))
    if ($people.Count -eq 1 -and $people[0].what) { $text += '　' + $people[0].what }
    $typingBar.Text = $text
    $tip.SetToolTip($typingBar, (($people | ForEach-Object { "$($_.name): $($_.what)" }) -join "`n"))
    if (-not $typingBar.Visible) { $typingBar.Visible = $true }
}

# 0.5秒ごとに点を動かし、2秒ごとに読み直す（ファイルが変わったときはすぐ読む）
$typingTimer = New-Object System.Windows.Forms.Timer
$typingTimer.Interval = 500
$typingTimer.Add_Tick({
    $script:typingTicks++
    Update-TypingIndicator -Read:($script:typingTicks % 4 -eq 0)
})
$script:typingWatcher = $null
function Start-TypingWatch {
    if (-not $sharingOn -or ($script:typingWatcher -and $script:typingWatcher.EnableRaisingEvents)) { return }
    try {
        if (-not (Test-Path -LiteralPath $typingDir)) { New-Item -ItemType Directory -Path $typingDir -Force | Out-Null }
        $w = New-Object System.IO.FileSystemWatcher($typingDir, '*.txt')
        $w.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, FileName, Size'
        $w.SynchronizingObject = $form
        $w.Add_Changed({ Update-TypingIndicator -Read })
        $w.Add_Created({ Update-TypingIndicator -Read })
        $w.Add_Deleted({ Update-TypingIndicator -Read })
        $w.Add_Error({ param($s, $e) $s.EnableRaisingEvents = $false })
        $w.EnableRaisingEvents = $true
        $script:typingWatcher = $w
    } catch { }
}

# ---------- 元に戻す・やり直す（↶ ↷ / Ctrl＋Z・Ctrl＋Y） ----------
# 操作ごとに「変える前」と「変えた後」の項目の内容を覚えておき、戻すときは前の内容、やり直すときは後の内容に置き換える。
# 内容が $null は「その項目がない」状態（追加の前・削除の後）。自分用⇔共有の切り替えは戻せない。
$script:undoStack = New-Object System.Collections.ArrayList
$script:redoStack = New-Object System.Collections.ArrayList

function Copy-Rec($rec) {
    if ($null -eq $rec) { return $null }
    $h = @{}
    foreach ($k in $rec.Keys) { $h[$k] = $rec[$k] }
    return $h
}

function New-UndoItem($row, $before, $after) {
    return [pscustomobject]@{ id = $row.Tag.id; shared = $row.Tag.shared; before = (Copy-Rec $before); after = (Copy-Rec $after) }
}

function Push-Undo([string]$label, $items) {
    $items = @($items | Where-Object { $_ })
    if ($items.Count -eq 0) { return }
    $script:undoStack.Add([pscustomobject]@{ label = $label; items = $items; at = (Get-Date).ToString('HH:mm') }) | Out-Null
    while ($script:undoStack.Count -gt 50) { $script:undoStack.RemoveAt(0) }
    $script:redoStack.Clear()   # 新しい操作をしたら、やり直しの分は消える
    Update-UndoButtons
}

function Get-ShortName($t) {
    $s = Get-DisplayText $t
    if ($s.Length -gt 24) { $s = $s.Substring(0, 24) + '…' }
    return "「$s」"
}

# 項目をある状態にする（$rec が $null なら消す）
function Set-ItemState($item, $rec) {
    $row = Find-Row $item.id
    if ($null -eq $rec) {
        if (-not $row) { return }
        try { Remove-FromItemFile (Get-StorePath $row.Tag) $row.Tag.id } catch { return }
        if ($script:currentRow -eq $row) { $script:currentRow = $null }
        $flow.Controls.Remove($row)
        $row.Dispose()
        return
    }
    if ($row) { Set-RowFromRecord $row $rec $item.shared } else { $row = Add-RowFromRecord $rec $item.shared }
    Set-Dirty $row
    Update-Row $row
}

# $count 回ぶん、まとめて戻す（進む）。↶ ↷ の右クリックの一覧から選んだところまで一気に動くときに使う
function Invoke-UndoRedo([bool]$undo, [int]$count = 1) {
    # if の結果を代入すると一覧がばらばらになるので、そのまま代入する
    $from = $script:undoStack; $to = $script:redoStack
    if (-not $undo) { $from = $script:redoStack; $to = $script:undoStack }
    if ($from.Count -eq 0) { return }
    $done = 0
    while ($done -lt $count -and $from.Count -gt 0) {
        $entry = $from[$from.Count - 1]
        $from.RemoveAt($from.Count - 1)
        $items = @($entry.items)
        if ($undo) { [array]::Reverse($items) }
        foreach ($it in $items) { Set-ItemState $it $(if ($undo) { $it.before } else { $it.after }) }
        $to.Add($entry) | Out-Null
        $done++
    }
    Sort-Rows
    Apply-Filter
    Save-Data
    Update-UndoButtons
    $n = if ($done -gt 1) { "（${done}件）" } else { '' }
    $title.Text = $(if ($undo) { "↶ 元に戻しました$n" } else { "↷ やり直しました$n" })   # 少しの間だけ出す
    $zoomLabelTimer.Stop(); $zoomLabelTimer.Start()
}

# ↶ ↷ を右クリック: 戻れる（進める）操作の一覧。選んだ操作のところまでまとめて戻る（進む）
function Show-UndoList([bool]$undo) {
    $stack = $script:undoStack; if (-not $undo) { $stack = $script:redoStack }
    $btn = if ($undo) { $btnUndo } else { $btnRedo }
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.ShowImageMargin = $false
    $m.Font = $fontDays
    $head = $m.Items.Add($(if ($undo) { 'ここまで元に戻す（上が新しい操作）' } else { 'ここまでやり直す（上が次の操作）' }))
    $head.Enabled = $false
    $m.Items.Add('-') | Out-Null
    if ($stack.Count -eq 0) {
        $none = $m.Items.Add($(if ($undo) { '戻せる操作はありません' } else { 'やり直せる操作はありません' }))
        $none.Enabled = $false
    }
    $n = 0
    for ($i = $stack.Count - 1; $i -ge 0; $i--) {
        $n++
        $e = $stack[$i]
        $mi = $m.Items.Add("$n. $(if ($e.at) { $e.at + '  ' })$($e.label)")
        $mi.Tag = [pscustomobject]@{ undo = $undo; count = $n }
        $mi.Add_Click({ param($s, $ev) Invoke-UndoRedo $s.Tag.undo $s.Tag.count })
    }
    $m.Add_Closed({ param($s, $ev) $s.BeginInvoke([Action]{ $s.Dispose() }.GetNewClosure()) | Out-Null })
    $script:undoMenu = $m
    $m.Show($btn, 0, $btn.Height)
}

# ↶ ↷ にマウスを乗せたときの説明: 次に戻る（進む）操作、その前の操作、戻せる・戻せないの注釈
$undoNote = @"
――――――――――――
戻せる: チェックを付けた・外した／追加／削除／編集／ステータスの変更／一括操作
戻せない: 自分用⇔共有の切り替え／削除した項目の添付ファイル／詳細メモの入力／他の人の変更
※ 記録は付箋を開いている間だけ（最大50件）。閉じると消えます
"@

function Get-UndoTip([bool]$undo) {
    $stack = $script:undoStack; if (-not $undo) { $stack = $script:redoStack }
    $head = if ($undo) { '↶ 元に戻す（Ctrl＋Z）　右クリックで一覧から選んでまとめて戻す' } else { '↷ やり直す（Ctrl＋Y）　右クリックで一覧から選んでまとめて進む' }
    if ($stack.Count -eq 0) {
        $body = if ($undo) { '戻せる操作はありません' } else { 'やり直せる操作はありません（元に戻したあとに使えます）' }
        return "$head`n$body`n$undoNote"
    }
    $verb = if ($undo) { '戻る' } else { '進む' }
    $lines = @("$head", "次に${verb}操作: $($stack[$stack.Count - 1].label)")
    $more = @()
    for ($i = $stack.Count - 2; $i -ge 0 -and $more.Count -lt 3; $i--) { $more += "　・$($stack[$i].label)" }
    if ($more.Count) { $lines += 'その次:'; $lines += $more }
    if ($stack.Count -gt 4) { $lines += "　…ほか $($stack.Count - 4) 件" }
    return (($lines -join "`n") + "`n$undoNote")
}

function Update-UndoButtons {
    # 戻せるものがなくても説明は出したいので、ボタンは押せるまま色だけ薄くする（押しても何も起きない）
    $btnUndo.ForeColor = if ($script:undoStack.Count) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::Silver }
    $btnRedo.ForeColor = if ($script:redoStack.Count) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::Silver }
    $tip.SetToolTip($btnUndo, (Get-UndoTip $true))
    $tip.SetToolTip($btnRedo, (Get-UndoTip $false))
}

# ---------- 複数選択と一括操作（Ctrl＋左クリックで選び、右クリックで一括操作） ----------
$selectColor = New-Color 255 222 150    # Ctrl＋クリックで選んだ行の色
$currentColor = New-Color 222 245 215   # 1回クリックした「今の行」の色（薄い緑）
$script:currentRow = $null
# キーボードで行を移る: 表示中の行（上から順）・行を選んで文字欄にフォーカス・上下に移動
function Get-VisibleRows { return ,@($flow.Controls | Where-Object { $_.Tag.shown }) }

function Focus-Row($row) {
    if (-not $row) { return }
    Clear-Selection
    Set-CurrentRow $row
    $flow.ScrollControlIntoView($row)
    $row.Tag.label.Focus() | Out-Null
    $row.Tag.label.SelectionLength = 0
}

function Move-CurrentRow([int]$dir) {
    $rows = Get-VisibleRows
    if ($rows.Count -eq 0) { return }
    $i = [array]::IndexOf($rows, $script:currentRow)
    $i = if ($i -lt 0) { $rows.Count - 1 } else { $i + $dir }
    if ($i -ge $rows.Count) {   # 一番下でさらに↓ → 内容欄へ
        $txtInput.Focus() | Out-Null
        $txtInput.SelectionStart = $txtInput.TextLength
        return
    }
    if ($i -lt 0) { $i = 0 }    # 一番上ではそのまま
    Focus-Row $rows[$i]
}

function Set-CurrentRow($row) {
    $old = $script:currentRow
    if ($old -eq $row) { return }
    $script:currentRow = $row
    if ($old -and -not $old.IsDisposed) { $old.Tag.current = $false; Update-Row $old }
    if ($row) { $row.Tag.current = $true; Update-Row $row }
}

function Get-SelectedRows { return ,@($flow.Controls | Where-Object { $_.Tag.selected }) }

function Switch-Select($row) {
    if (-not $row) { return }
    $row.Tag.selected = -not $row.Tag.selected
    Update-Row $row
    Update-Totals
}

# Shift＋クリックの範囲選択。起点（最後に普通のクリック・Ctrl＋クリックをした行）から $row まで、表示中の行を選ぶ
$script:anchorRow = $null
function Select-Range($row, [bool]$add) {
    if (-not $row) { return }
    $rows = Get-VisibleRows
    $anchor = $script:anchorRow
    if (-not $anchor -or $anchor.IsDisposed -or $rows -notcontains $anchor) { $anchor = $script:currentRow }
    if (-not $anchor -or $anchor.IsDisposed -or $rows -notcontains $anchor) { $anchor = $row }
    $i1 = [array]::IndexOf($rows, $anchor)
    $i2 = [array]::IndexOf($rows, $row)
    if (-not $add) { foreach ($r in $flow.Controls) { if ($r.Tag.selected) { $r.Tag.selected = $false; Update-Row $r } } }
    for ($i = [Math]::Min($i1, $i2); $i -le [Math]::Max($i1, $i2); $i++) {
        if (-not $rows[$i].Tag.selected) { $rows[$i].Tag.selected = $true; Update-Row $rows[$i] }
    }
    $row.Tag.label.SelectionLength = 0   # Shift＋クリックで文字が選ばれないように
    Update-Totals
}

function Clear-Selection {
    $sel = Get-SelectedRows
    foreach ($r in $sel) { $r.Tag.selected = $false; Update-Row $r }
    if ($sel.Count) { Update-Totals }
}

# 一括操作: 選んだ行それぞれに $action を実行し、最後にまとめて並べ替え・保存
function Invoke-Bulk([scriptblock]$action, $arg, [switch]$NoUndo, [string]$Label = '変更') {
    $rows = Get-SelectedRows
    $undo = @()
    foreach ($r in $rows) {
        $before = ConvertTo-Record $r
        & $action $r $arg
        Set-Dirty $r
        if (-not $NoUndo) { $undo += New-UndoItem $r $before (ConvertTo-Record $r) }
        Update-Row $r
    }
    if (-not $NoUndo) { Push-Undo "一括: ${Label}（$($rows.Count)件）" $undo }
    Sort-Rows
    Apply-Filter
    Save-Data
}

# 日付・時刻を選ぶ小さな画面。キャンセルなら $null
function Show-PickDialog([string]$title, [bool]$timeOnly) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlgTip = New-Object System.Windows.Forms.ToolTip   # この画面専用の説明（付箋本体の説明と混ざらないように）
    $dlgTip.AutoPopDelay = 20000
    $dlg.Text = $title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $noteColor
    $dlg.Font = $fontDays
    $dlg.ClientSize = New-Object System.Drawing.Size(220, 84)
    $dp = New-Object System.Windows.Forms.DateTimePicker
    $dp.Location = New-Object System.Drawing.Point(12, 12)
    $dp.Width = 196
    if ($timeOnly) { $dp.Format = 'Custom'; $dp.CustomFormat = 'HH:mm'; $dp.ShowUpDown = $true; $dp.Value = (Get-Date).Date.AddHours(17) }
    else { $dp.Format = 'Long'; $dp.Value = (Get-Date).Date }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.BackColor = $barColor; $ok.FlatStyle = 'Flat'
    $ok.Location = New-Object System.Drawing.Point(46, 48); $ok.Size = New-Object System.Drawing.Size(76, 26)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'; $cancel.DialogResult = 'Cancel'; $cancel.FlatStyle = 'Flat'
    $cancel.Location = New-Object System.Drawing.Point(130, 48); $cancel.Size = New-Object System.Drawing.Size(78, 26)
    $dlg.Controls.AddRange(@($dp, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = Show-Modal $dlg $form
    $v = $dp.Value
    $dlg.Dispose()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $v
}

function Set-BulkDue($due) {
    Invoke-Bulk { param($r, $d) $r.Tag.due = $d; if (-not $d) { $r.Tag.time = '' } } $due -Label $(if ($due) { "締め日を$($due.ToString('M/d'))に" } else { '締め日をなしに' })
}
function Set-BulkTime([string]$time) {
    # 時刻だけ付けて締め日がない項目は、今日を締め日にする（追加のときと同じ）
    Invoke-Bulk { param($r, $tm) $r.Tag.time = $tm; if ($tm -and -not $r.Tag.due) { $r.Tag.due = (Get-Date).Date } } $time -Label $(if ($time) { "時刻を${time}に" } else { '時刻をなしに' })
}
function Set-BulkPerson([string]$field, [string]$name) {
    $label = if ($field -eq 'assignee') { '担当者' } else { 'サブ担当者' }
    Invoke-Bulk {
        param($r, $a)
        $old = [string]$r.Tag.($a[0])
        if ($old -ne $a[1]) {
            Add-History $r $r.Tag.status "$($a[2]): $(Get-PersonText $old) → $(Get-PersonText $a[1])（一括変更）"
            $r.Tag.($a[0]) = $a[1]
        }
    } @($field, $name, $label) -Label "${label}を「$(Get-PersonText $name)」に"
}
function Set-BulkStatus([string]$status) {
    Invoke-Bulk {
        param($r, $st)
        if ($r.Tag.status -ne $st) { Add-History $r $st '（一括変更）'; $r.Tag.status = $st; $r.Tag.note = '' }
    } $status -Label "ステータスを「$status」に"
}
function Set-BulkShare([bool]$share, [string[]]$scope) {
    $rows = Get-SelectedRows
    if (-not $share -and @($rows | Where-Object { $_.Tag.shared }).Count) {
        $ans = [System.Windows.Forms.MessageBox]::Show($form,
            '共有をやめると、他の人の一覧から選んだ項目が消えて、あなた専用になります。よろしいですか？',
            '共有の解除', 'OKCancel', 'Question')
        if ($ans -ne 'OK') { return }
    }
    foreach ($r in $rows) { if (-not (Move-RowStore $r $share)) { return } }
    Invoke-Bulk { param($r, $sc) if ($r.Tag.shared) { $r.Tag.scope = @($sc) } } $scope -NoUndo   # 共有の切り替えは戻せない
}

function New-BulkItem($parent, [string]$text, [scriptblock]$onClick, $tag) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.Tag = $tag
    $mi.Add_Click($onClick)
    $parent.DropDownItems.Add($mi) | Out-Null
    return $mi
}

# 今の値の印: 選んだ項目が全部その値なら ✓、一部だけなら ■（どちらでもない場合は印なし）
function Set-BulkMark($mi, $rows, [scriptblock]$test) {
    $n = @($rows | Where-Object { & $test $_.Tag }).Count
    if ($n -gt 0 -and $n -eq $rows.Count) { $mi.CheckState = [System.Windows.Forms.CheckState]::Checked }
    elseif ($n -gt 0) { $mi.CheckState = [System.Windows.Forms.CheckState]::Indeterminate }
    return $mi
}

function Show-BulkMenu {
    $sel = Get-SelectedRows
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $head = $m.Items.Add("選択した $($sel.Count) 件をまとめて変更（✓全部 ■一部）")
    $head.Enabled = $false
    $m.Items.Add('-') | Out-Null

    $miI = New-Object System.Windows.Forms.ToolStripMenuItem('重要'); $m.Items.Add($miI) | Out-Null
    Set-BulkMark (New-BulkItem $miI '重要にする' { Invoke-Bulk { param($r, $x) $r.Tag.important = $true } $null -Label '重要にする' } $null) $sel { param($t) $t.important } | Out-Null
    Set-BulkMark (New-BulkItem $miI '重要を外す' { Invoke-Bulk { param($r, $x) $r.Tag.important = $false } $null -Label '重要を外す' } $null) $sel { param($t) -not $t.important } | Out-Null

    $miS = New-Object System.Windows.Forms.ToolStripMenuItem('共有'); $m.Items.Add($miS) | Out-Null
    $miS.Enabled = $sharingOn
    Set-BulkMark (New-BulkItem $miS '全員に共有' { Set-BulkShare $true @() } $null) $sel { param($t) $t.shared -and @(@($t.scope) | Where-Object { $_ }).Count -eq 0 } | Out-Null
    foreach ($n in (Get-Members)) {
        $mi = New-BulkItem $miS "$n と共有" { param($s, $e) Set-BulkShare $true @([string]$s.Tag) } $n
        $mi.CheckState = [System.Windows.Forms.CheckState]::Unchecked
        $c = @($sel | Where-Object { $_.Tag.shared -and @($_.Tag.scope) -contains $n }).Count
        if ($c -gt 0) { $mi.CheckState = if ($c -eq $sel.Count) { 'Checked' } else { 'Indeterminate' } }
    }
    $miS.DropDownItems.Add('-') | Out-Null
    Set-BulkMark (New-BulkItem $miS '共有をやめる（自分用にする）' { Set-BulkShare $false @() } $null) $sel { param($t) -not $t.shared } | Out-Null

    $today = (Get-Date).Date
    $miD = New-Object System.Windows.Forms.ToolStripMenuItem('締め日'); $m.Items.Add($miD) | Out-Null
    foreach ($q in @(@('今日', 0), @('明日', 1), @('1週間後', 7))) {
        $mi = New-BulkItem $miD $q[0] { param($s, $e) Set-BulkDue ((Get-Date).Date.AddDays([int]$s.Tag)) } $q[1]
        $day = $today.AddDays($q[1])
        $c = @($sel | Where-Object { $_.Tag.due -and $_.Tag.due.Date -eq $day }).Count
        if ($c -gt 0) { $mi.CheckState = if ($c -eq $sel.Count) { 'Checked' } else { 'Indeterminate' } }
    }
    # 今日・明日・1週間後以外の締め日は「日付を選ぶ…」に印と日付を出す
    $others = @($sel | Where-Object { $_.Tag.due -and @(0, 1, 7) -notcontains ($_.Tag.due.Date - $today).Days })
    $miPick = New-BulkItem $miD '日付を選ぶ…' { $v = Show-PickDialog '締め日を選ぶ' $false; if ($v) { Set-BulkDue $v.Date } } $null
    if ($others.Count) {
        $days = @($others | ForEach-Object { $_.Tag.due.ToString('M/d') } | Select-Object -Unique)
        $miPick.Text = '日付を選ぶ…（今: ' + ($days -join '、') + '）'
        $miPick.CheckState = if ($others.Count -eq $sel.Count -and $days.Count -eq 1) { 'Checked' } else { 'Indeterminate' }
    }
    $miD.DropDownItems.Add('-') | Out-Null
    Set-BulkMark (New-BulkItem $miD '締め日なし' { Set-BulkDue $null } $null) $sel { param($t) -not $t.due } | Out-Null

    $miT = New-Object System.Windows.Forms.ToolStripMenuItem('時間'); $m.Items.Add($miT) | Out-Null
    $quick = '09:00', '12:00', '17:00'
    foreach ($tm in $quick) {
        $mi = New-BulkItem $miT $tm { param($s, $e) Set-BulkTime ([string]$s.Tag) } $tm
        $c = @($sel | Where-Object { $_.Tag.time -and ([TimeSpan]::Parse($_.Tag.time)).ToString('hh\:mm') -eq $tm }).Count
        if ($c -gt 0) { $mi.CheckState = if ($c -eq $sel.Count) { 'Checked' } else { 'Indeterminate' } }
    }
    $othersT = @($sel | Where-Object { $_.Tag.time -and $quick -notcontains ([TimeSpan]::Parse($_.Tag.time)).ToString('hh\:mm') })
    $miPickT = New-BulkItem $miT '時刻を選ぶ…' { $v = Show-PickDialog '時刻を選ぶ' $true; if ($v) { Set-BulkTime $v.ToString('HH:mm') } } $null
    if ($othersT.Count) {
        $times = @($othersT | ForEach-Object { $_.Tag.time } | Select-Object -Unique)
        $miPickT.Text = '時刻を選ぶ…（今: ' + ($times -join '、') + '）'
        $miPickT.CheckState = if ($othersT.Count -eq $sel.Count -and $times.Count -eq 1) { 'Checked' } else { 'Indeterminate' }
    }
    $miT.DropDownItems.Add('-') | Out-Null
    Set-BulkMark (New-BulkItem $miT '時刻なし' { Set-BulkTime '' } $null) $sel { param($t) -not $t.time } | Out-Null

    foreach ($f in @(@('assignee', '担当者'), @('subAssignee', 'サブ担当者'))) {
        $miP = New-Object System.Windows.Forms.ToolStripMenuItem($f[1]); $m.Items.Add($miP) | Out-Null
        $field = $f[0]
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($n in @('') + @($script:me) + @(Get-Members) + @($sel | ForEach-Object { [string]$_.Tag.$field })) {   # 今の担当者が一覧にいなくても出す
            if (-not $names.Contains([string]$n)) { $names.Add([string]$n) }
        }
        foreach ($n in $names) {
            $mi = New-BulkItem $miP $(if ($n) { $n } else { '（なし）' }) { param($s, $e) Set-BulkPerson $s.Tag[0] $s.Tag[1] } @($field, $n)
            $c = @($sel | Where-Object { [string]$_.Tag.$field -eq $n }).Count
            if ($c -gt 0) { $mi.CheckState = if ($c -eq $sel.Count) { 'Checked' } else { 'Indeterminate' } }
        }
    }

    $miSt = New-Object System.Windows.Forms.ToolStripMenuItem('ステータス'); $m.Items.Add($miSt) | Out-Null
    foreach ($st in $statusList) {
        $mi = New-BulkItem $miSt $st { param($s, $e) Set-BulkStatus ([string]$s.Tag) } $st
        $c = @($sel | Where-Object { $_.Tag.status -eq $st }).Count
        if ($c -gt 0) { $mi.CheckState = if ($c -eq $sel.Count) { 'Checked' } else { 'Indeterminate' } }
    }

    $m.Items.Add('-') | Out-Null
    $miClear = $m.Items.Add('選択を解除')
    $miClear.Add_Click({ Clear-Selection })
    $m.Show([System.Windows.Forms.Cursor]::Position)
}

# ---------- 案件名の候補（検索エンジンのように、カーソルが入ると候補を出す） ----------
# 使った記録: 案件名 → 回数・最後に使った日時（data.json に保存）
$script:keyStats = @{}
function Register-KeyUse([string]$key) {
    if (-not $key) { return }
    $s = $script:keyStats[$key]
    if (-not $s) { $s = [pscustomobject]@{ count = 0; last = '' }; $script:keyStats[$key] = $s }
    $s.count++
    $s.last = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

# 記録にない案件名は、今ある項目から作る（項目数を回数、更新日時を最後に使った日時とする）
function Add-KeyStatsFromRows {
    foreach ($g in @($flow.Controls | Where-Object { $_.Tag.key } | Group-Object { $_.Tag.key })) {
        if ($script:keyStats.ContainsKey($g.Name)) { continue }
        $last = ($g.Group | ForEach-Object { [string]$_.Tag.updatedAt } | Sort-Object -Descending | Select-Object -First 1)
        $script:keyStats[$g.Name] = [pscustomobject]@{ count = $g.Count; last = [string]$last }
    }
}

# 候補: 「最近使った」（新しい順）と「よく使う」（回数の多い順）。入力中の文字で絞り込み、先頭一致を上に
function Get-KeySuggestions([string]$text) {
    $text = $text.Trim()
    $all = @($script:keyStats.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ key = $_.Key; count = $_.Value.count; last = $_.Value.last; prefix = $(if ($text) { $_.Key.StartsWith($text, [System.StringComparison]::CurrentCultureIgnoreCase) } else { $false }) }
    })
    if ($text) { $all = @($all | Where-Object { $_.key.IndexOf($text, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0 }) }
    $recent = @($all | Sort-Object @{ Expression = 'prefix'; Descending = $true }, @{ Expression = 'last'; Descending = $true } | Select-Object -First 5)
    $names = @($recent | ForEach-Object { $_.key })
    $freq = @($all | Where-Object { $names -notcontains $_.key } | Sort-Object @{ Expression = 'prefix'; Descending = $true }, @{ Expression = 'count'; Descending = $true }, @{ Expression = 'last'; Descending = $true } | Select-Object -First 8)
    $items = New-Object System.Collections.ArrayList
    if ($recent.Count) {
        $items.Add([pscustomobject]@{ header = $true; text = '最近使った'; count = 0 }) | Out-Null
        foreach ($r in $recent) { $items.Add([pscustomobject]@{ header = $false; text = $r.key; count = $r.count }) | Out-Null }
    }
    if ($freq.Count) {
        $items.Add([pscustomobject]@{ header = $true; text = 'よく使う'; count = 0 }) | Out-Null
        foreach ($r in $freq) { $items.Add([pscustomobject]@{ header = $false; text = $r.key; count = $r.count }) | Out-Null }
    }
    return ,$items
}

$sugList = New-Object System.Windows.Forms.ListBox
$sugList.DrawMode = 'OwnerDrawFixed'
$sugList.ItemHeight = 22
$sugList.IntegralHeight = $false
$sugList.BorderStyle = 'FixedSingle'
$sugList.Font = $font
$sugList.Visible = $false
$sugList.TabStop = $false
$sugList.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $it = $s.Items[$e.Index]
    $g = $e.Graphics
    $r = $e.Bounds
    if ($it.header) {
        $g.FillRectangle([System.Drawing.Brushes]::WhiteSmoke, $r)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $it.text, $fontTag, (New-Object System.Drawing.Rectangle(($r.X + 6), $r.Y, ($r.Width - 8), $r.Height)), [System.Drawing.Color]::Gray, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
        return
    }
    $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $back = if ($selected) { $pinColor } else { [System.Drawing.Color]::White }
    $b = New-Object System.Drawing.SolidBrush($back); $g.FillRectangle($b, $r); $b.Dispose()
    $countText = "$($it.count)件"
    $cw = [System.Windows.Forms.TextRenderer]::MeasureText($countText, $fontTime).Width
    [System.Windows.Forms.TextRenderer]::DrawText($g, $it.text, $font, (New-Object System.Drawing.Rectangle(($r.X + 14), $r.Y, ($r.Width - $cw - 22), $r.Height)), [System.Drawing.Color]::Black, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
    [System.Windows.Forms.TextRenderer]::DrawText($g, $countText, $fontTime, (New-Object System.Drawing.Rectangle(($r.Right - $cw - 6), $r.Y, ($cw + 2), $r.Height)), [System.Drawing.Color]::Gray, [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Right')
})
$form.Controls.Add($sugList)

function Hide-Suggestions { $sugList.Visible = $false }

function Show-Suggestions {
    $items = Get-KeySuggestions $txtKey.Text
    if ($items.Count -eq 0) { Hide-Suggestions; return }
    $sugList.BeginUpdate()
    $sugList.Items.Clear()
    foreach ($it in $items) { $sugList.Items.Add($it) | Out-Null }
    $sugList.EndUpdate()
    # 入力欄は付箋の一番下にあるので、候補は上に出す
    $pt = $form.PointToClient($keyHost.PointToScreen((New-Object System.Drawing.Point(0, 0))))   # 枠の上に出す
    $h = $items.Count * $sugList.ItemHeight + 2
    $top = [Math]::Max($bar.Bottom, $pt.Y - $h)
    $h = $pt.Y - $top
    $w = [Math]::Min([Math]::Max(220, $keyHost.Width), $form.ClientSize.Width - $pt.X - 4)
    $sugList.SetBounds($pt.X, $top, $w, $h)
    $sugList.BringToFront()
    $sugList.Visible = $true
}

# 見出しを飛ばして次（前）の候補へ
function Select-LastSuggestion {
    for ($i = $sugList.Items.Count - 1; $i -ge 0; $i--) {
        if (-not $sugList.Items[$i].header) { $sugList.SelectedIndex = $i; return }
    }
}

function Move-Suggestion([int]$dir) {
    $i = $sugList.SelectedIndex
    do { $i += $dir } while ($i -ge 0 -and $i -lt $sugList.Items.Count -and $sugList.Items[$i].header)
    if ($i -ge 0 -and $i -lt $sugList.Items.Count) { $sugList.SelectedIndex = $i }
}

function Select-Suggestion([int]$i) {
    if ($i -lt 0 -or $i -ge $sugList.Items.Count -or $sugList.Items[$i].header) { return }
    $txtKey.Text = $sugList.Items[$i].text
    Hide-Suggestions
    $txtInput.Focus() | Out-Null   # 案件名が決まったら内容の入力へ
}

$sugList.Add_MouseMove({
    param($s, $e)
    $i = $s.IndexFromPoint($e.Location)
    if ($i -ge 0 -and -not $s.Items[$i].header -and $s.SelectedIndex -ne $i) { $s.SelectedIndex = $i }
})
$sugList.Add_MouseDown({ param($s, $e) Select-Suggestion ($s.IndexFromPoint($e.Location)) })

# 案件名欄からフォーカスが外れたら閉じる（候補をクリックした場合は先にそちらを処理）
$sugHideTimer = New-Object System.Windows.Forms.Timer
$sugHideTimer.Interval = 150
$sugHideTimer.Add_Tick({ $sugHideTimer.Stop(); if (-not $txtKey.Focused -and -not $sugList.Focused) { Hide-Suggestions } })

$txtKey.Add_Enter({ Show-Suggestions })
$txtKey.Add_MouseDown({ if (-not $sugList.Visible) { Show-Suggestions } })
$txtKey.Add_TextChanged({ if ($txtKey.Focused) { Show-Suggestions } })
$txtKey.Add_Leave({ $sugHideTimer.Stop(); $sugHideTimer.Start() })
$form.Add_Move({ Hide-Suggestions })
$form.Add_Resize({ Hide-Suggestions })

# ---------- イベント ----------
$btnAdd.Add_Click({ Add-FromInput })
$enterAdds = {
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        Add-FromInput
    }
}
$txtInput.Add_KeyDown($enterAdds)
# 内容欄: ↑（1行目にいるとき）で一覧の行へ、←（先頭にいるとき）で案件名へ
$txtInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Up' -and $s.SelectionLength -eq 0 -and $s.GetLineFromCharIndex($s.SelectionStart) -eq 0) {
        $rows = Get-VisibleRows
        if ($rows.Count) {
            $target = if ($script:currentRow -and $rows -contains $script:currentRow) { $script:currentRow } else { $rows[$rows.Count - 1] }
            Focus-Row $target
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    }
    elseif ($e.KeyCode -eq 'Left' -and $s.SelectionLength -eq 0 -and $s.SelectionStart -eq 0) {
        $txtKey.Focus() | Out-Null
        $txtKey.SelectionStart = $txtKey.TextLength
        $e.Handled = $true; $e.SuppressKeyPress = $true
    }
})
# 入力欄で「共有」を ON にして書いているときは「入力中…」を知らせる（自分用の項目は知らせない）
$inputTyping = { if ($sharingOn -and [bool]$tglShare.Tag -and ($txtInput.Text -or $txtKey.Text)) { Send-Typing '新しい項目' (Get-ScopeString @($scopeInput.Tag)) } }
$txtInput.Add_TextChanged($inputTyping)
$txtKey.Add_TextChanged($inputTyping)
$txtKey.Add_KeyDown({
    param($s, $e)
    $k = $e.KeyCode
    # 候補は案件名欄の上に出るので、↑で候補の一番下へ入り、↑↓で移動。一番下で↓を押すと案件名欄に戻る
    if ($sugList.Visible -and $k -eq 'Up') {
        if ($sugList.SelectedIndex -lt 0) { Select-LastSuggestion } else { Move-Suggestion -1 }
        $e.Handled = $true; $e.SuppressKeyPress = $true; return
    }
    if ($sugList.Visible -and $k -eq 'Down') {
        if ($sugList.SelectedIndex -ge 0) {
            $before = $sugList.SelectedIndex
            Move-Suggestion 1
            if ($sugList.SelectedIndex -eq $before) { $sugList.SelectedIndex = -1 }   # 一番下 → 案件名欄に戻る
        }
        $e.Handled = $true; $e.SuppressKeyPress = $true; return
    }
    # → で内容へ（文字カーソルが末尾にあるとき）
    if ($k -eq 'Right' -and $s.SelectionLength -eq 0 -and $s.SelectionStart -ge $s.TextLength -and ($sugList.SelectedIndex -lt 0 -or -not $sugList.Visible)) {
        Hide-Suggestions
        $txtInput.Focus() | Out-Null
        $txtInput.SelectionStart = $txtInput.TextLength
        $e.Handled = $true; $e.SuppressKeyPress = $true; return
    }
    if ($sugList.Visible -and $k -eq 'Escape') { Hide-Suggestions; $e.SuppressKeyPress = $true; return }
    if ($k -eq 'Enter') {
        $e.SuppressKeyPress = $true
        if ($sugList.Visible -and $sugList.SelectedIndex -ge 0) { Select-Suggestion $sugList.SelectedIndex }   # 候補を選んでいればそれを入れる
        else { Hide-Suggestions; Add-FromInput }
    }
})

$btnSort.Add_Click({ $sortMenu.Show($btnSort, 0, $btnSort.Height) })
$btnFilter.Add_Click({
    $filterPanel.Visible = -not $filterPanel.Visible
    if ($filterPanel.Visible) { $txtSearch.Focus() | Out-Null } else { $txtInput.Focus() | Out-Null }
    Save-Data   # 絞り込み欄を開いているかも覚えておく
})
$btnFilterReset.Add_Click({ Reset-Filter })
$txtSearch.Add_TextChanged({ Apply-Filter; if (-not $script:loading) { $saveTimer.Stop(); $saveTimer.Start() } })   # 打ち終わったら保存
$txtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; $txtSearch.Text = '' }
})
foreach ($c in $cmbDone, $cmbImp, $cmbDue, $cmbShare, $cmbAssign) { $c.Add_SelectedIndexChanged({ Apply-Filter; Save-Data }) }
$btnClose.Add_Click({ $form.Close() })
$btnPin.Add_Click({ $form.TopMost = -not $form.TopMost; Update-PinButton; Save-Data })

$miDel.Add_Click({
    $row = Get-RowOf $menu.SourceControl
    if ($row) { Remove-Row $row }
})
$miEdit.Add_Click({
    $row = Get-RowOf $menu.SourceControl
    if ($row) { Edit-Row $row }
})
$miProgress.Add_Click({ Show-ProgressDialog (Get-RowOf $menu.SourceControl) })
$miAttach.Add_Click({
    $row = Get-RowOf $menu.SourceControl
    if (-not $row) { return }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Multiselect = $true
    $ofd.Title = '添付するファイルを選んでください'
    if ((Show-Modal $ofd $form) -eq 'OK') { Add-Attachments $row $ofd.FileNames }
})
$miOpenFolder.Add_Click({ $row = Get-RowOf $menu.SourceControl; if ($row) { Open-AttachFolder $row.Tag } })
$miConfig.Add_Click({
    try { Start-Process notepad.exe -ArgumentList ('"' + $configFile + '"') } catch { }
    [System.Windows.Forms.MessageBox]::Show($form, "設定を変更したら、付箋を閉じて起動し直してください。`n`n$configFile", '設定ファイル', 'OK', 'Information') | Out-Null
})
$miRefresh.Add_Click({ Invoke-Refresh -Force })
# ⟳: 今すぐ読み込む（押したことが分かるように少しだけ色を変える）
$reloadFlash = New-Object System.Windows.Forms.Timer
$reloadFlash.Interval = 400
$reloadFlash.Add_Tick({ $reloadFlash.Stop(); Update-ReloadButton })
$btnReload.Add_Click({
    if ($script:updateReady -and (Test-UpdateAvailable)) { Invoke-UpdateRestart; return }   # 新しい版があるときは、更新して再起動
    $btnReload.BackColor = $pinColor
    $btnReload.Refresh()
    Invoke-Refresh -Force
    Update-TypingIndicator -Read
    $reloadFlash.Stop(); $reloadFlash.Start()
})
$miClearUnread.Add_Click({
    foreach ($r in $flow.Controls) { if ($r.Tag.unread) { $r.Tag.unread = $false; Update-Row $r } }
    Update-Totals
})

$flow.Add_Resize({
    foreach ($r in $flow.Controls) {
        $r.Width = (Get-RowWidth)
        Update-RowHeight $r
    }
    # 幅を縮めたとき、行の幅を直す前の判定で出た横スクロールバーが残るので、スクロール判定をやり直す
    if ($flow.HorizontalScroll.Visible) {
        $flow.AutoScroll = $false
        $flow.AutoScroll = $true
    }
    Update-ScrollExtent
})
$form.Add_ResizeEnd({ Save-Data })
$form.Add_FormClosing({ Save-Data; Clear-MyTyping })

# 日付が変わったら「残○日」を更新
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-AllRows; Apply-Filter })

# 詳細メモは入力が 1 秒止まったら保存（閉じるときにも保存される）
$saveTimer = New-Object System.Windows.Forms.Timer
$saveTimer.Interval = 1000
$saveTimer.Add_Tick({ $saveTimer.Stop(); Save-Data })

# ---------- 他の人・他の端末の変更をすぐ反映 ----------
# ファイルが書き換わったら Windows から通知してもらい、少し待ってから読み込む（書き込みの途中で読まないように）
$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 400
$watchTimer.Add_Tick({ $watchTimer.Stop(); Invoke-Refresh })

$script:watchers = @{}   # 監視しているファイル → FileSystemWatcher
function Start-FileWatch([string]$path) {
    if (-not $path) { return }
    $old = $script:watchers[$path]
    if ($old -and $old.EnableRaisingEvents) { return }   # 監視中
    if ($old) { $old.Dispose(); $script:watchers.Remove($path) }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { return }   # 共有フォルダに届かないときは、定期確認で拾う
    try {
        $w = New-Object System.IO.FileSystemWatcher($dir, (Split-Path $path -Leaf))
        $w.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, FileName, Size'
        $w.SynchronizingObject = $form   # 通知を画面のスレッドで受け取る
        $kick = { $watchTimer.Stop(); $watchTimer.Start() }
        $w.Add_Changed($kick)
        $w.Add_Created($kick)
        $w.Add_Renamed($kick)
        $w.Add_Error({ param($s, $e) $s.EnableRaisingEvents = $false })   # 接続が切れたなど → 次の定期確認で張り直す
        $w.EnableRaisingEvents = $true
        $script:watchers[$path] = $w
    } catch { }
}
function Start-AllWatches {
    Start-FileWatch $personalFile
    if ($sharingOn) { Start-FileWatch $sharedFile }
}

# ---------- 新しい版の自動更新 ----------
# 1 分ごとに配布元の exe を確認し、新しければ上部の件数表示の場所にお知らせ（青地・白文字）を出して ⟳ を青くする。
# 勝手には再起動しない。⟳ を押したときに保存して再起動し、入れ替える（入れ替えは exe 本体が行う）
# 変更内容は配布元の exe と同じフォルダの StickyChecklist.changes.txt に書いておく。書き方:
#   [2026/10/27 16:20]      ← 配布した exe の日時（この版より新しいものだけ ⓘ に出す）
#   ・変更点 1
#   ・変更点 2
$script:updateReady = $false
$script:updateCheckIn = 5   # 次の確認までの秒（起動して少ししてから最初の確認）
function Test-UpdateAvailable {
    if (-not $script:updateSource) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $script:updateSource)) { return $false }
        return ([System.IO.File]::GetLastWriteTimeUtc($script:updateSource) -gt [System.IO.File]::GetLastWriteTimeUtc($IconSource).AddSeconds(2))
    } catch { return $false }
}
# 自分より新しい版の変更内容（新しい順）
function Get-UpdateNotes {
    $path = Join-Path (Split-Path $script:updateSource -Parent) 'StickyChecklist.changes.txt'
    $lines = @()
    try { if (Test-Path -LiteralPath $path) { $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8) } } catch { }
    $mine = [System.IO.File]::GetLastWriteTime($IconSource)
    $mine = $mine.AddSeconds(-$mine.Second).AddMilliseconds(-$mine.Millisecond)   # 分まででくらべる
    $sb = New-Object System.Text.StringBuilder
    $take = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(\d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2})\]') {
            $dt = [datetime]::MinValue
            $take = [datetime]::TryParse($Matches[1], [ref]$dt) -and $dt -gt $mine
            if ($take) { if ($sb.Length) { [void]$sb.Append("`r`n") }; [void]$sb.Append($dt.ToString('M/d HH:mm') + " の版`r`n") }
            continue
        }
        if ($take -and $line.Trim()) { [void]$sb.Append($line.TrimEnd() + "`r`n") }
    }
    if (-not $sb.Length) { return '変更内容の記録はありません' }
    return $sb.ToString().TrimEnd()
}

function Update-ReloadButton {
    $lblTotals.Visible = -not $script:updateReady   # 新しい版があるときは、件数の代わりにお知らせ
    $updPanel.Visible = $script:updateReady
    if ($script:updateReady) { $updTip.SetToolTip($lblUpdInfo, (Get-UpdateNotes)) }
    if ($script:updateReady) {
        $btnReload.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 200)
        $btnReload.ForeColor = [System.Drawing.Color]::White
        $tip.SetToolTip($btnReload, "新しい版があります。押すと保存してから再起動して更新します`n（他の人・他の端末の変更も読み込みます）")
    } else {
        $btnReload.BackColor = $barColor
        $btnReload.ForeColor = [System.Drawing.Color]::Black
        $tip.SetToolTip($btnReload, '今すぐ更新（他の人・他の端末の変更を読み込む）')
    }
}
function Invoke-UpdateRestart {
    if ($txtInput.Text.Trim() -or $txtKey.Text.Trim()) {   # 追加前の入力は保存されないので確認する
        $ans = [System.Windows.Forms.MessageBox]::Show($form, "入力欄に追加前の文字があります。更新すると消えますが、再起動して更新しますか？", '新しい版に更新', 'OKCancel', 'Question')
        if ($ans -ne 'OK') { return }
    }
    $updateTimer.Stop()
    Save-Data
    $script:restartForUpdate = $true; $global:restartForUpdate = $true   # exe 本体が終了後にこれを見て入れ替える
    $form.Close()
}
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1000
$updateTimer.Add_Tick({
    if (--$script:updateCheckIn -gt 0) { return }
    $script:updateCheckIn = 60
    $ready = Test-UpdateAvailable
    if ($ready -eq $script:updateReady -and -not $ready) { return }
    $script:updateReady = $ready
    Update-ReloadButton   # お知らせ中も、さらに新しい版が出たら変更内容を読み直す
})

# 念のための定期確認（ネットワーク越しだと通知が届かないことがあるため）。監視が切れていたら張り直す
$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = $refreshSec * 1000
$refreshTimer.Add_Tick({
    Start-AllWatches; Invoke-Refresh
    if (@($flow.Controls | Where-Object { $_.Tag.id -and -not $script:numbers.ContainsKey($_.Tag.id) }).Count) { Update-Numbers }   # 番号を付けられなかった項目（共有フォルダに届かなかったなど）
})

# ---------- 読み込み ----------
$d = $null
if (Test-Path $dataFile) {
    try {
        $d = Get-Content -Path $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rect = New-Object System.Drawing.Rectangle([int]$d.x, [int]$d.y, [int]$d.w, [int]$d.h)
        $onScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }
        if ($onScreen -and $d.w -gt 0) { $form.Bounds = $rect }
        if ($null -ne $d.topMost) { $form.TopMost = [bool]$d.topMost }
        if ($d.sort -and ($sortMenu.Items | Where-Object { $_.Tag -eq $d.sort })) { $script:sortMode = [string]$d.sort }
        foreach ($st in @($d.hiddenStatuses)) { if ($statusList -contains $st) { $script:hiddenStatuses.Add([string]$st) } }
        if ($d.filter) {   # 前回の絞り込みを戻す
            $txtSearch.Text = [string]$d.filter.search
            foreach ($pair in @(@($cmbDone, $d.filter.done), @($cmbImp, $d.filter.imp), @($cmbDue, $d.filter.due), @($cmbShare, $d.filter.share))) {
                $i = [int]$pair[1]
                if ($i -ge 0 -and $i -lt $pair[0].Items.Count) { $pair[0].SelectedIndex = $i }
            }
            $script:savedAssign = [string]$d.filter.assign   # 担当はメンバーを読み込んだあとで戻す
            $filterPanel.Visible = [bool]$d.filter.open
        }
        foreach ($k in @($d.keyStats)) { if ($k.key) { $script:keyStats[[string]$k.key] = [pscustomobject]@{ count = [int]$k.count; last = [string]$k.last } } }
        if ($d.zoom) { $script:zoom = [Math]::Max(0.7, [Math]::Min(2.0, [double]$d.zoom)); Set-ListFonts }   # 前回の文字の大きさ
    } catch { }
}
Update-StatusFilterButton

# 旧形式の自分用ファイルは、新しい形式で保存し直す（id を固定するため。元のファイルは .v1.bak に残す）
if (Test-Path -LiteralPath $personalFile) {
    try {
        $text = [System.IO.File]::ReadAllText($personalFile, [System.Text.Encoding]::UTF8)
        if ($text.Trim() -and -not $text.TrimStart([char]0xFEFF).StartsWith('#StickyChecklist v2')) {
            $bak = "$personalFile.v1.bak"
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $personalFile -Destination $bak }
            $recs = ConvertFrom-ItemText $text
            foreach ($rec in $recs) { if (-not $rec.status) { $rec.status = '未着手' } }
            [System.IO.File]::WriteAllText($personalFile, (ConvertTo-ItemText $recs), $utf8Bom)
        }
    } catch { }
}
Update-FromStore $false -Force -Initial | Out-Null
Update-FromStore $true -Force -Initial | Out-Null
Add-KeyStatsFromRows
# 担当の絞り込み: メンバー名を作り直し、前回の選択を戻す
Update-AssignItems
if ($script:savedAssign) { $i = $cmbAssign.Items.IndexOf($script:savedAssign); if ($i -ge 0) { $cmbAssign.SelectedIndex = $i } }
$cmbAssign.Add_DropDown({ Update-AssignItems })

Sort-Rows
Apply-Filter
Reset-InputOptions
Update-PinButton
$script:loading = $false
Save-Data
$timer.Start()
$refreshTimer.Start()
# Ctrl＋ホイールで文字の拡大・縮小、Ctrl＋0 で元に戻す
$zoomFilter.MainWindow = $form.Handle
[System.Windows.Forms.Application]::AddMessageFilter($zoomFilter)
$form.KeyPreview = $true
$form.Add_KeyDown({ param($s, $e) if ($e.Control -and ($e.KeyCode -eq [System.Windows.Forms.Keys]::D0 -or $e.KeyCode -eq [System.Windows.Forms.Keys]::NumPad0)) { Set-Zoom 1.0; $e.SuppressKeyPress = $true } })
# 元に戻す・やり直す（入力欄で文字を打っているときは、その入力欄の取り消しを優先）
$form.Add_KeyDown({
    param($s, $e)
    if (-not $e.Control) { return }
    $ac = $form.ActiveControl
    if ($ac -is [System.Windows.Forms.TextBoxBase] -and -not $ac.ReadOnly) { return }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Z) { Invoke-UndoRedo $true; $e.SuppressKeyPress = $true }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Y) { Invoke-UndoRedo $false; $e.SuppressKeyPress = $true }
})
$btnUndo.Add_Click({ Invoke-UndoRedo $true })
$btnRedo.Add_Click({ Invoke-UndoRedo $false })
$btnUndo.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-UndoList $true } })
$btnRedo.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-UndoList $false } })
Update-UndoButtons
$miZoomReset.Add_Click({ Set-Zoom 1.0 })
Apply-UiScale   # 上部・下部を保存されていた倍率で
if ($sharingOn) { Start-TypingWatch; $typingTimer.Start() }
$flashTimer.Start()
Start-AllWatches
if ($script:updateSource) { $updateTimer.Start() }

$form.Add_Shown({
    [NativeDrag]::SetCue($txtSearch.Handle, '単語で検索（スペースで複数語）')
    Reset-InputOptions   # 日付は画面に出てから入れ直す（先に入れると現在の日付に戻ることがある）
    $txtInput.Focus() | Out-Null
    if ($script:configWarning) {
        [System.Windows.Forms.MessageBox]::Show($form, $script:configWarning, '設定ファイルの確認', 'OK', 'Warning') | Out-Null
    }
})
[System.Windows.Forms.Application]::Run($form)
