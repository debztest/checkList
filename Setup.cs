// 付箋チェックリスト セットアップ
// StickyChecklist.exe を埋め込んでおき、選んだフォルダに置いてショートカット（デスクトップ・スタートアップ）を作る。
// ビルドは build.ps1 で行う（StickyChecklist.exe を作ったあとにこれを作る）。
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Setup
{
    const string AppName = Shortcut.AppName;
    const string ExeName = "StickyChecklist.exe";
    const string IniName = "StickyChecklist.ini";
    // 設定ファイルのひな形の配布元（セットアップと同じフォルダに ini が無いとき、ここの設定を引き継ぐ。読むだけで書き換えない）
    const string DefaultIniSource = @"\\192.168.1.221\WebApps\CheckList\StickyChecklist.ini";

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.Run(new SetupForm());
    }

    // すでにインストールされている場所（ショートカットの起動先）。無ければ null
    public static string FindInstalledDir()
    {
        foreach (string lnk in new[] { Shortcut.StartupLink, Shortcut.DesktopLink })
        {
            try
            {
                string target = Shortcut.GetTarget(lnk);
                if (!string.IsNullOrEmpty(target) && File.Exists(target)) return Path.GetDirectoryName(target);
            }
            catch { }
        }
        return null;
    }

    // ini の値（コメント行は見ない）。無ければ null
    public static string ReadIniValue(string path, string key)
    {
        try
        {
            if (!File.Exists(path)) return null;
            Match m = Regex.Match(File.ReadAllText(path, Encoding.UTF8), @"^[ \t]*" + key + @"[ \t]*=([^\r\n]*)", RegexOptions.Multiline | RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value.Trim() : null;
        }
        catch { return null; }
    }

    // ini の値を書き換える。項目が無ければ [基本] の下（無ければ先頭）に足す
    public static string SetIniValue(string text, string key, string value)
    {
        var re = new Regex(@"^([ \t]*" + key + @"[ \t]*=)[^\r\n]*", RegexOptions.Multiline | RegexOptions.IgnoreCase);
        if (re.IsMatch(text)) return re.Replace(text, m => m.Groups[1].Value + value, 1);
        Match sec = Regex.Match(text, @"^\[基本\][^\r\n]*\r?\n", RegexOptions.Multiline);
        int at = sec.Success ? sec.Index + sec.Length : 0;
        return text.Insert(at, key + "=" + value + "\r\n");
    }

    // 新しく置く ini のひな形：セットアップと同じフォルダの ini、無ければ配布元の ini。どちらも無ければ null
    public static string FindIniTemplate()
    {
        string local = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), IniName);
        foreach (string p in new[] { local, DefaultIniSource })
        {
            try { if (File.Exists(p)) return p; } catch { }
        }
        return null;
    }

    public static bool IsAppRunning()
    {
        Mutex m;
        if (Mutex.TryOpenExisting(@"Local\StickyChecklist", out m)) { m.Dispose(); return true; }
        return false;
    }

    class SetupForm : Form
    {
        readonly TextBox txtDir = new TextBox();
        readonly TextBox txtName = new TextBox();
        readonly CheckBox chkDesktop = new CheckBox();
        readonly CheckBox chkStartup = new CheckBox();
        readonly CheckBox chkLaunch = new CheckBox();

        public SetupForm()
        {
            Text = AppName + " セットアップ";
            Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(255, 247, 170);
            Font = new Font("Yu Gothic UI", 9);
            ClientSize = new Size(440, 300);

            var title = new Label
            {
                Text = "✔ " + AppName + " をインストールします",
                Font = new Font("Yu Gothic UI", 12, FontStyle.Bold),
                AutoSize = true,
                Location = new Point(16, 14)
            };

            var lblDir = new Label { Text = "インストール先フォルダ", AutoSize = true, Location = new Point(16, 54) };
            txtDir.Location = new Point(16, 74);
            txtDir.Width = 330;
            txtDir.Text = FindInstalledDir()
                ?? Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);   // 既定はセットアップを置いたフォルダ

            var btnBrowse = new Button { Text = "参照…", Location = new Point(352, 72), Width = 72, FlatStyle = FlatStyle.Flat };
            btnBrowse.Click += delegate
            {
                using (var dlg = new FolderBrowserDialog { Description = "インストール先のフォルダを選んでください", SelectedPath = txtDir.Text })
                {
                    if (dlg.ShowDialog(this) == DialogResult.OK) txtDir.Text = dlg.SelectedPath;
                }
            };

            var note = new Label
            {
                Text = "設定ファイル（StickyChecklist.ini）とチェックリストもこのフォルダに置かれます。",
                AutoSize = true,
                ForeColor = Color.DimGray,
                Location = new Point(16, 100)
            };

            // 名前（共有した項目の作成者・記入者として表示される）。入れ直したときは今の設定を出す
            var lblName = new Label { Text = "あなたの名前（共有した項目の作成者として表示されます）", AutoSize = true, Location = new Point(16, 128) };
            txtName.Location = new Point(16, 148);
            txtName.Width = 200;
            string installed = FindInstalledDir();
            if (installed != null) txtName.Text = ReadIniValue(Path.Combine(installed, IniName), "UserName") ?? "";

            chkDesktop.Text = "デスクトップにショートカットを作る";
            chkStartup.Text = "Windows 起動時に自動で立ち上げる（スタートアップに登録）";
            chkLaunch.Text = "インストール後に起動する";
            int y = 180;
            foreach (var c in new[] { chkDesktop, chkStartup, chkLaunch })
            {
                c.Checked = true;
                c.AutoSize = true;
                c.Location = new Point(16, y);
                y += 24;
            }

            var btnInstall = new Button
            {
                Text = "インストール",
                Location = new Point(240, 260),
                Size = new Size(96, 28),
                BackColor = Color.FromArgb(250, 225, 100),
                FlatStyle = FlatStyle.Flat
            };
            btnInstall.Click += delegate { Install(); };
            var btnCancel = new Button { Text = "キャンセル", Location = new Point(344, 260), Size = new Size(80, 28), FlatStyle = FlatStyle.Flat };
            btnCancel.Click += delegate { Close(); };

            Controls.AddRange(new Control[] { title, lblDir, txtDir, btnBrowse, note, lblName, txtName, chkDesktop, chkStartup, chkLaunch, btnInstall, btnCancel });
            AcceptButton = btnInstall;
            CancelButton = btnCancel;
        }

        void Install()
        {
            string dir = txtDir.Text.Trim();
            if (dir == "") { MessageBox.Show(this, "インストール先を指定してください。", Text); return; }
            string name = txtName.Text.Trim();
            if (name == "") { MessageBox.Show(this, "あなたの名前を入力してください。", Text); txtName.Focus(); return; }

            // 起動中だと exe を置き換えられないので閉じてもらう
            while (IsAppRunning())
            {
                var r = MessageBox.Show(this,
                    AppName + " が起動中です。\n付箋を × で閉じてから「再試行」を押してください。",
                    Text, MessageBoxButtons.RetryCancel, MessageBoxIcon.Information);
                if (r != DialogResult.Retry) return;
            }

            try
            {
                string oldDir = FindInstalledDir();
                Directory.CreateDirectory(dir);
                string exePath = Path.Combine(dir, ExeName);

                // 埋め込んである本体を書き出す
                using (var src = Assembly.GetExecutingAssembly().GetManifestResourceStream(ExeName))
                using (var dst = File.Create(exePath))
                {
                    src.CopyTo(dst);
                }

                // 設定ファイル：すでにあればそのまま、無ければひな形（共有フォルダなどを設定済みの ini）の設定を引き継ぐ。
                // ひな形の名前と自分用の保存先は他の人のものなので、名前は入力したもの・保存先は既定に置き換える
                string iniDst = Path.Combine(dir, IniName);
                string ini;
                if (File.Exists(iniDst)) ini = File.ReadAllText(iniDst, Encoding.UTF8);
                else
                {
                    Cursor = Cursors.WaitCursor;
                    string tmpl = FindIniTemplate();
                    Cursor = Cursors.Default;
                    ini = tmpl != null
                        ? SetIniValue(File.ReadAllText(tmpl, Encoding.UTF8), "PersonalFile", "checklist.txt")
                        : "[基本]\r\n";
                }
                File.WriteAllText(iniDst, SetIniValue(ini, "UserName", name), new UTF8Encoding(true));

                // 別の場所から移す場合は、チェックリストのデータを引き継ぐか聞く
                if (oldDir != null && !string.Equals(Path.GetFullPath(oldDir).TrimEnd('\\'), Path.GetFullPath(dir).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    string oldList = Path.Combine(oldDir, "checklist.txt");
                    string newList = Path.Combine(dir, "checklist.txt");
                    if (File.Exists(oldList) && !File.Exists(newList))
                    {
                        var r = MessageBox.Show(this,
                            "以前の場所にあるチェックリストを引き継ぎますか？\n\n" + oldList,
                            Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                        if (r == DialogResult.Yes) File.Copy(oldList, newList);
                    }
                }

                SetShortcut(Shortcut.DesktopLink, chkDesktop.Checked, exePath);
                SetShortcut(Shortcut.StartupLink, chkStartup.Checked, exePath);

                // 本体の「初回に登録しますか？」は出さない（ここで選んだので）
                string settingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StickyChecklist");
                Directory.CreateDirectory(settingsDir);
                File.WriteAllText(Path.Combine(settingsDir, "shortcut-asked"), DateTime.Now.ToString("s"));

                MessageBox.Show(this, "インストールしました。\n\n" + exePath, Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                if (chkLaunch.Checked) Process.Start(new ProcessStartInfo(exePath) { WorkingDirectory = dir });
                Close();
            }
            catch (UnauthorizedAccessException)
            {
                MessageBox.Show(this,
                    "このフォルダには書き込めません。\nドキュメントやデスクトップなど、自分のフォルダを選んでください。\n\n" + dir,
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "インストールできませんでした。\n\n" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        static void SetShortcut(string lnk, bool wanted, string exePath)
        {
            if (wanted) Shortcut.Create(lnk, exePath);
            else if (File.Exists(lnk)) File.Delete(lnk);   // チェックを外したら消す
        }
    }
}
