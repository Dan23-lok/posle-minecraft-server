function Notify-PlayProtocolAssociationChanged {
    [CmdletBinding()]
    param([switch]$CompileOnly)

    # Windows caches URI and file associations. Notify only after a successful
    # registry mutation; CompileOnly verifies the P/Invoke without signaling.
    if (-not ('POSLE.ProtocolShellNotify' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace POSLE {
    public static class ProtocolShellNotify {
        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern void SHChangeNotify(int eventId, uint flags,
            IntPtr item1, IntPtr item2);
    }
}
'@ -ErrorAction Stop
    }
    if ($CompileOnly) { return $true }
    # SHCNE_ASSOCCHANGED = 0x08000000; SHCNF_IDLIST = 0.
    [POSLE.ProtocolShellNotify]::SHChangeNotify(0x08000000, 0,
        [IntPtr]::Zero, [IntPtr]::Zero)
}
