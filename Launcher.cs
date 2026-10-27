// 付箋チェックリスト 起動用 exe
// StickyChecklist.ps1 を埋め込んでおき、PowerShell をこのプロセス内で動かす（コンソール窓なし・実行ポリシーの影響なし）。
// 起動時と、付箋から「更新して再起動」と言われたときに、更新元（共有フォルダ）の exe が新しければ入れ替えて起動し直す。
// ビルドは build.ps1 で行う。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Windows.Forms;

static class Launcher
{
    const string AppName = Shortcut.AppName;

    [STAThread]
    static int Main()
    {
        string exePath = Assembly.GetExecutingAssembly().Location;
        string baseDir = Path.GetDirectoryName(exePath);
        bool restart = false;

        bool createdNew;
        var mutex = new Mutex(true, @"Local\StickyChecklist", out createdNew);
        if (!createdNew)
        {
            // 更新で起動し直した直後は、前の付箋が閉じきるまで少し待つ
            bool got;
            try { got = mutex.WaitOne(5000); } catch (AbandonedMutexException) { got = true; }
            if (!got) { mutex.Dispose(); return 0; }   // すでに起動中
        }
        try
        {
            try { File.Delete(exePath + ".old"); } catch { }   // 前回の更新で残った古い exe

            // 起動時: 更新元に新しい版があれば入れ替えて起動し直す
            if (TryUpdate(exePath, baseDir)) { restart = true; return 0; }

            try { OfferShortcuts(exePath, baseDir); } catch { }

            string script;
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("StickyChecklist.ps1"))
            using (var r = new StreamReader(s, Encoding.UTF8))
            {
                script = r.ReadToEnd();
            }

            try
            {
                var iss = InitialSessionState.CreateDefault();
                using (var rs = RunspaceFactory.CreateRunspace(iss))
                {
                    rs.ApartmentState = ApartmentState.STA;
                    rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    rs.Open();
                    using (var ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddScript(script).AddParameter("BaseDir", baseDir).AddParameter("IconSource", exePath);
                        ps.Invoke();   // 付箋を閉じるまで戻らない（起動できない致命的エラーは下の catch で表示）
                    }
                    // 起動中に新しい版が見つかって閉じた場合は、入れ替えて起動し直す
                    object flag = rs.SessionStateProxy.GetVariable("restartForUpdate");
                    if (flag is bool && (bool)flag)
                    {
                        TryUpdate(exePath, baseDir);
                        restart = true;
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("起動できませんでした。\n\n" + ex.Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return 0;
        }
        finally
        {
            try { mutex.ReleaseMutex(); } catch { }
            mutex.Dispose();
            if (restart)
            {
                try { Process.Start(new ProcessStartInfo(exePath) { WorkingDirectory = baseDir, UseShellExecute = true }); } catch { }
            }
        }
    }

    // 更新元（設定の UpdateFrom、なければ SharedFile と同じフォルダの StickyChecklist.exe）
    static string GetUpdateSource(string baseDir)
    {
        string ini = Path.Combine(baseDir, "StickyChecklist.ini");
        if (!File.Exists(ini)) return null;
        string updateFrom = null, shared = null;
        foreach (string raw in File.ReadAllLines(ini, Encoding.UTF8))
        {
            string l = raw.Trim();
            if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#") || l.StartsWith("[")) continue;
            int i = l.IndexOf('=');
            if (i <= 0) continue;
            string k = l.Substring(0, i).Trim();
            string v = l.Substring(i + 1).Trim();
            if (v.Length >= 2 && ((v.StartsWith("\"") && v.EndsWith("\"")) || (v.StartsWith("'") && v.EndsWith("'")))) v = v.Substring(1, v.Length - 2).Trim();
            if (k.Equals("UpdateFrom", StringComparison.OrdinalIgnoreCase)) updateFrom = v;
            else if (k.Equals("SharedFile", StringComparison.OrdinalIgnoreCase)) shared = v;
        }
        string p = !string.IsNullOrEmpty(updateFrom) ? updateFrom
                 : !string.IsNullOrEmpty(shared) ? Path.Combine(Path.GetDirectoryName(Resolve(shared, baseDir)), "StickyChecklist.exe")
                 : null;
        return p == null ? null : Resolve(p, baseDir);
    }

    static string Resolve(string p, string baseDir)
    {
        p = Environment.ExpandEnvironmentVariables(p);
        if (!Path.IsPathRooted(p)) p = Path.Combine(baseDir, p);
        return Path.GetFullPath(p);
    }

    // 更新元のほうが新しければ、自分と入れ替える（動いている exe は名前を変えられるので .old にしてから置く）。入れ替えたら true
    static bool TryUpdate(string exePath, string baseDir)
    {
        try
        {
            string src = GetUpdateSource(baseDir);
            if (src == null || !File.Exists(src)) return false;
            if (string.Equals(Path.GetFullPath(src), Path.GetFullPath(exePath), StringComparison.OrdinalIgnoreCase)) return false;   // 自分が更新元
            if (File.GetLastWriteTimeUtc(src) <= File.GetLastWriteTimeUtc(exePath).AddSeconds(2)) return false;   // 新しくない
            string tmp = exePath + ".new";
            File.Copy(src, tmp, true);   // 日時もそのままコピーされる
            string old = exePath + ".old";
            try { File.Delete(old); } catch { }
            File.Move(exePath, old);
            File.Move(tmp, exePath);
            return true;
        }
        catch { return false; }   // 書き込めない場所などは、今の版のまま使う
    }

    // フォルダを移動していたらショートカットを今の場所に直す。
    // ショートカットが無ければ、初回だけ「デスクトップとスタートアップに登録しますか？」と聞く
    static void OfferShortcuts(string exePath, string baseDir)
    {
        try { Shortcut.Repair(Shortcut.DesktopLink, exePath); } catch { }
        try { Shortcut.Repair(Shortcut.StartupLink, exePath); } catch { }

        string settingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StickyChecklist");
        string marker = Path.Combine(settingsDir, "shortcut-asked");
        if (File.Exists(marker) || File.Exists(Shortcut.StartupLink)) return;

        Directory.CreateDirectory(settingsDir);
        File.WriteAllText(marker, DateTime.Now.ToString("s"));

        var answer = MessageBox.Show(
            "デスクトップにショートカットを作成し、Windows 起動時に自動で立ち上がるように登録しますか？",
            AppName, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer != DialogResult.Yes) return;

        Shortcut.Create(Shortcut.DesktopLink, exePath);
        Shortcut.Create(Shortcut.StartupLink, exePath);
    }
}
