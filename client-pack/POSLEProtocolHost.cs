using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;

// The shell passes an untrusted URI as a process argument. This small native
// Windows protocol target never forwards that argument to PowerShell. It
// dispatches one fixed action only after exact validation.
internal static class POSLEProtocolHost
{
    // Register-PlayProtocol.ps1 replaces these markers with source hashes
    // before compiling the per-user executable. They are not read from a
    // mutable receipt during URI activation.
    private const string HelperSha256 = "POSLE_HELPER_SHA256_PLACEHOLDER";
    private const string ReadinessSha256 = "POSLE_READINESS_SHA256_PLACEHOLDER";
    private const string ManifestSha256 = "POSLE_MANIFEST_SHA256_PLACEHOLDER";

    private static bool HasReparsePointInPath(string path)
    {
        string current = Path.GetFullPath(path);
        while (!string.IsNullOrEmpty(current))
        {
            if (File.Exists(current) || Directory.Exists(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                {
                    return true;
                }
            }
            string parent = Path.GetDirectoryName(
                current.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (string.IsNullOrEmpty(parent) || parent == current) { break; }
            current = parent;
        }
        return false;
    }

    private static bool IsPinnedRegularFile(string path, string expectedSha256)
    {
        if (!File.Exists(path) || HasReparsePointInPath(path)) { return false; }
        using (var sha = SHA256.Create())
        using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            string actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
            return string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static bool WasRecentlyOpened(string statePath)
    {
        if (Directory.Exists(statePath)) { throw new IOException("Activation state is a directory."); }
        if (!File.Exists(statePath)) { return false; }
        if (HasReparsePointInPath(statePath)) { throw new IOException("Activation state is a link."); }
        long ticks;
        if (!long.TryParse(File.ReadAllText(statePath).Trim(), out ticks))
        {
            throw new IOException("Activation state is invalid.");
        }
        var last = new DateTime(ticks, DateTimeKind.Utc);
        TimeSpan elapsed = DateTime.UtcNow - last;
        return elapsed >= TimeSpan.Zero && elapsed < TimeSpan.FromSeconds(60);
    }

    private static string InstallationMutexName(string root, string sid)
    {
        // Independent installations, including disposable test fixtures, must
        // not suppress one another. The same installation still serializes all
        // activations for the Windows user, regardless of the caller process.
        string canonicalRoot = Path.GetFullPath(root).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToUpperInvariant();
        using (var sha = SHA256.Create())
        {
            byte[] fingerprint = sha.ComputeHash(Encoding.UTF8.GetBytes(canonicalRoot));
            string suffix = BitConverter.ToString(fingerprint, 0, 12).Replace("-", "");
            return "Local\\POSLE.PlayHandler." + sid + "." + suffix;
        }
    }

    private static int Main(string[] args)
    {
        if (args.Length != 1 ||
            (string.CompareOrdinal(args[0], "posle://play") != 0 &&
             string.CompareOrdinal(args[0], "posle://play/") != 0))
        {
            Console.Error.WriteLine("Unsupported POSLE action.");
            return 2;
        }

        string helper = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
            "Invoke-LocalPlay.ps1");
        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        string builtinModules = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "Modules");
        if (!File.Exists(powershell) || !Directory.Exists(builtinModules))
        {
            Console.Error.WriteLine("Windows PowerShell or its built-in modules are missing.");
            return 3;
        }
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string statePath = Path.Combine(root, "last-success-utc.txt");
        string sid = WindowsIdentity.GetCurrent().User.Value;
        using (var mutex = new Mutex(false, InstallationMutexName(root, sid)))
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired)
            {
                Console.WriteLine("POSLE play is already opening.");
                return 0;
            }
            try
            {
                try
                {
                    if (HasReparsePointInPath(root) ||
                        !IsPinnedRegularFile(helper, HelperSha256) ||
                        !IsPinnedRegularFile(Path.Combine(root, "Forge-ClientReadiness.ps1"), ReadinessSha256) ||
                        !IsPinnedRegularFile(Path.Combine(root, "client-modpack.json"), ManifestSha256))
                    {
                        Console.Error.WriteLine("POSLE play handler files changed after installation.");
                        return 5;
                    }
                    if (WasRecentlyOpened(statePath))
                    {
                        Console.WriteLine("TLauncher was already opened recently.");
                        return 0;
                    }
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine("Could not verify POSLE play handler: " + error.Message);
                    return 5;
                }

                try
                {
                    var start = new ProcessStartInfo();
                    start.FileName = powershell;
                    start.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" +
                        helper + "\" -PlayUri posle://play";
                    start.WorkingDirectory = root;
                    start.UseShellExecute = false;
                    // Shell activation may inherit a PowerShell 7 PSModulePath.
                    // PowerShell 5.1 cannot load the PS7 Utility module, which
                    // hides Get-FileHash used for client integrity checks.
                    start.EnvironmentVariables["PSModulePath"] = builtinModules;
                    using (Process child = Process.Start(start))
                    {
                        if (child == null) { return 4; }
                        child.WaitForExit();
                        if (child.ExitCode == 0)
                        {
                            if (File.Exists(statePath) && HasReparsePointInPath(statePath))
                            {
                                throw new IOException("Activation state is a link.");
                            }
                            File.WriteAllText(statePath, DateTime.UtcNow.Ticks.ToString());
                        }
                        return child.ExitCode;
                    }
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine("Could not start POSLE play helper: " + error.Message);
                    return 4;
                }
            }
            finally { mutex.ReleaseMutex(); }
        }
    }
}
