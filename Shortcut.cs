// ショートカット（.lnk）の作成・読み取り。StickyChecklist.exe とセットアップの両方で使う。
using System;
using System.IO;
using System.Reflection;

static class Shortcut
{
    public const string AppName = "付箋チェックリスト";

    public static string DesktopLink
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppName + ".lnk"); }
    }

    public static string StartupLink
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), AppName + ".lnk"); }
    }

    public static void Create(string lnkPath, string target)
    {
        object lnk = Open(lnkPath);
        Type lt = lnk.GetType();
        lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
        lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { Path.GetDirectoryName(target) });
        lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { target + ",0" });
        lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { AppName });
        lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
    }

    // ショートカットの起動先（無ければ null）
    public static string GetTarget(string lnkPath)
    {
        if (!File.Exists(lnkPath)) return null;
        object lnk = Open(lnkPath);
        return (string)lnk.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, lnk, null);
    }

    // ショートカットがあって、別の場所の exe を指していたら、今の exe に向け直す
    public static bool Repair(string lnkPath, string exePath)
    {
        string current = GetTarget(lnkPath);
        if (current == null || string.Equals(current, exePath, StringComparison.OrdinalIgnoreCase)) return false;
        Create(lnkPath, exePath);
        return true;
    }

    static object Open(string lnkPath)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(t);
        return t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
    }
}
