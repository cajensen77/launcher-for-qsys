<#
=====================================================================
  LAUNCHER FOR Q-SYS  -  v0.22
  ---------------------------------------------------------------
  A front end for Q-SYS Designer:
    * Finds every installed version of Q-SYS Designer
    * Keeps an "address book" of Cores (name, building/group, IP, notes)
    * Asks each Core what it is running (platform, design, firmware)
    * Launches the Designer version that matches a Core's firmware
      (optionally pressing F8 = "Load from Core & Connect" for you)
    * Keeps Designer's shared hard-links file in sync with the address book
    * Follows a Core's LAN B address when DHCP changes it (from the Core's own announcement)
    * Stores each Core's LAN A (AV) and LAN B (campus) address; pick which goes to Designer

  WHY TWO FILES?
    Designer only understands a very small file:
        %AppData%\QSC\HardLink.json       -> { Mode, Links:[{IpAddress, IsEnabled}] }
        %AppData%\QSC\HardLinkNames.json  -> { Names:{ "ip":"name" } }
    Every Designer version on the PC reads that same file, so it can't hold
    extra info. This app keeps the "rich" list in its OWN file:
        %AppData%\QSysLauncher\systems.json
    and writes only the IPs/names back into Designer's file when you Sync.

  HOW IT RUNS
    It lives in the taskbar tray. At startup and every few minutes it checks every
    Core, merges duplicates, finds Cores whose DHCP address changed, and keeps
    Designer's hard links in sync - no buttons needed. Right-click the tray icon to
    launch Designer for a Core. Closing the window just hides it; use Exit to quit.

  REQUIREMENTS
    Windows 10/11 with the built-in Windows PowerShell 5.1. Nothing to install.
    Start it with "Start QSys Launcher.cmd" (it runs this script in STA mode,
    which WPF windows need).
=====================================================================
#>

# -Tray : start hidden in the taskbar tray (the "Start with Windows" shortcut uses this).
param([switch]$Tray)

# ---- The app's name, and the ID Windows' taskbar uses to tell it apart from PowerShell ----
# An independent community tool - deliberately not named or styled like a QSC product.
$AppName = 'Launcher for Q-SYS'
$AppId   = 'Community.LauncherForQSYS'

#region ==== 0. STARTUP SAFETY CHECKS ===============================

# WPF windows must run on a "single-threaded apartment" thread.
# If someone runs the .ps1 directly from a non-STA console, relaunch ourselves in STA mode.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    if ($Tray) { $relaunch += '-Tray' }
    Start-Process powershell.exe -ArgumentList $relaunch
    return
}

# Stop on errors inside our own functions so try/catch blocks actually catch them.
$ErrorActionPreference = 'Stop'

# Load the .NET pieces we need: WPF (PresentationFramework) and WinForms (for the clipboard/SendKeys helpers).
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# UI Automation = Windows' built-in accessibility API. It lets us "see" the buttons and text
# boxes inside another program's window (Designer's F8 dialog) and fill/click them by name,
# which is far more reliable than blindly sending keystrokes.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Microsoft.VisualBasic gives us a simple built-in InputBox (used by the group editor).
# System.Drawing is for the tray icon.
Add-Type -AssemblyName Microsoft.VisualBasic, System.Drawing

# ---- If anything stops the app during startup, say so instead of vanishing ----
# (It runs with a hidden console, so without this an error would just look like "nothing happened".)
trap {
    $msg = "$AppName stopped: $($_.Exception.Message)`n`n(script line $($_.InvocationInfo.ScriptLineNumber))"
    try {
        $dir = Join-Path $env:APPDATA 'QSysLauncher'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $dir 'launcher.log'), "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  CRASH: $($msg -replace '\s+', ' ')`r`n")
    } catch { }
    [System.Windows.MessageBox]::Show($msg, $AppName) | Out-Null
    break
}

# ---- Only one copy runs at a time ----
# A named "mutex" is a system-wide flag. If another copy already holds it, we poke that
# copy (through a named signal) so it pops its window up, and then this copy quits.
#   - Started with -Tray (Windows startup) while a copy is running: just show that copy.
#   - Started from the .cmd: ask the running copy to close, then take over. That way the
#     newest version of this script always ends up running after you update the file.
$AppVersion = '0.22'
$createdNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\QSysLauncher_SingleInstance', [ref]$createdNew)
$script:ShowSignal    = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\QSysLauncher_Show')
$script:ExitSignal    = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\QSysLauncher_Exit')
if (-not $createdNew) {
    if ($Tray) { [void]$script:ShowSignal.Set(); return }
    [void]$script:ExitSignal.Set()                       # "please close" (v0.9 and later listen for this)
    $got = $false
    try   { $got = $script:InstanceMutex.WaitOne(8000) }  # wait up to 8 s for it to let go
    catch { $got = $true }                                # "abandoned" = it closed without tidying up; still ours
    if (-not $got) {
        # An older copy that doesn't know the "please close" signal - show it instead.
        [void]$script:ShowSignal.Set()
        [System.Windows.MessageBox]::Show("An older copy of the launcher is still running in the tray.`n`nRight-click its tray icon > Exit, then start the launcher again to run version $AppVersion.", $AppName) | Out-Null
        return
    }
}

#endregion

#region ==== 1. SETTINGS & FILE LOCATIONS ===========================

# --- This script's own path (used for the "Start with Windows" shortcut) ---
$ScriptPath = $PSCommandPath

# --- Where Designer keeps its shared hard links (same for every Designer version) ---
$QscFolder          = Join-Path $env:APPDATA 'QSC'
$HardLinkFile       = Join-Path $QscFolder 'HardLink.json'
$HardLinkNamesFile  = Join-Path $QscFolder 'HardLinkNames.json'

# --- Where THIS app keeps its own data ---
$AppFolder     = Join-Path $env:APPDATA 'QSysLauncher'
$SystemsFile   = Join-Path $AppFolder 'systems.json'      # the address book + settings
$BackupFolder  = Join-Path $AppFolder 'backups'           # copies of HardLink.json before every write
$MaxBackups    = 20                                       # keep the newest N backups

# --- Where Designer versions get installed ---
$DesignerRoots = @()
foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($pf) { $DesignerRoots += (Join-Path $pf 'QSC') }
}

# --- Core query settings ---
$QrcPort        = 1710      # Q-SYS Remote Control (JSON-RPC) port, used for StatusGet
$QueryTimeoutMs = 2500      # how long to wait on each Core before giving up
$MaxParallel    = 8         # how many Cores to query at the same time

# --- HTTPS paths to try when looking for the firmware version ---
# QSC doesn't publicly document a "firmware version" endpoint, so we try a few
# likely Core Manager API paths and scan whatever comes back for a version number.
# The log at the bottom of the window shows what each one returned, so once you
# know which one works on your Cores you can move it to the top (or delete the rest).
# (Firmware 9.x and 10.x Cores answer the first one.)
$FirmwareEndpoints = @(
    '/api/v0/cores/self',                 # <- reports "firmware": {"name": "10.4.1"} (9.x and 10.x Cores)
    '/api/v0/cores/self/status',
    '/api/v0/systems/1/status',
    '/api/v0/cores/self/config/system'
)

# Make sure our folders exist.
foreach ($f in @($AppFolder, $BackupFolder)) {
    if (-not (Test-Path $f)) { New-Item -ItemType Directory -Path $f | Out-Null }
}

#endregion

#region ==== 2. C# HELPER TYPES ======================================
<#
  PowerShell can compile small C# classes on the fly with Add-Type (the compiler
  ships with Windows/.NET Framework). We use it for two things:

  1) QSystem  - one row of the address book. It implements INotifyPropertyChanged,
                which is how WPF knows to redraw a cell when a value changes
                (e.g. when a Core query comes back with its firmware).

  2) QslTrust - accepts a Core's self-signed HTTPS certificate the first time, then only that one.
                (Written in C# because a PowerShell scriptblock callback can't run
                on the background threads we use for querying.)
#>
if (-not ('QslShell' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public class QSystem : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void On(string p) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(p)); }

    // ---- Identity, for shared lists and per-Core logins ----
    // Id never changes. Modified = when a "your" field (or an address) last changed (UTC ticks):
    // when two people's copies of a shared list disagree, the newer edit wins.
    private string _id = "";        public string Id          { get { return _id; }        set { _id = value ?? ""; } }
    public long Modified;

    // ---- Fields YOU edit ----
    private string _name = "";      public string Name        { get { return _name; }      set { string v = value ?? ""; if (_name != v) { _name = v; Modified = DateTime.UtcNow.Ticks; On("Name"); } } }
    private string _group = "";     public string Group       { get { return _group; }     set { string v = value ?? ""; if (_group != v) { _group = v; Modified = DateTime.UtcNow.Ticks; On("Group"); } } }
    private string _ip = "";        public string IpAddress   { get { return _ip; }        set { string v = value ?? ""; if (_ip != v) { _ip = v; Modified = DateTime.UtcNow.Ticks; On("IpAddress"); } } }   // LAN B (campus, DHCP - can change)
    private string _lanA = "";      public string LanA        { get { return _lanA; }      set { string v = value ?? ""; if (_lanA != v) { _lanA = v; Modified = DateTime.UtcNow.Ticks; On("LanA"); } } }       // LAN A (AV network, static)
    private bool   _enabled = true; public bool   Enabled     { get { return _enabled; }   set { if (_enabled != value) { _enabled = value; Modified = DateTime.UtcNow.Ticks; On("Enabled"); } } }
    private string _notes = "";     public string Notes       { get { return _notes; }     set { string v = value ?? ""; if (_notes != v) { _notes = v; Modified = DateTime.UtcNow.Ticks; On("Notes"); } } }

    // ---- Fields filled in by "Query" (last known values are saved) ----
    private string _platform = "";  public string Platform    { get { return _platform; }  set { _platform = value ?? ""; On("Platform"); } }
    private string _firmware = "";  public string Firmware    { get { return _firmware; }  set { _firmware = value ?? ""; On("Firmware"); } }
    private string _design = "";    public string DesignName  { get { return _design; }    set { _design = value ?? ""; On("DesignName"); } }
    private string _state = "";     public string State       { get { return _state; }     set { _state = value ?? ""; On("State"); } }
    private string _checked = "";   public string LastChecked { get { return _checked; }   set { _checked = value ?? ""; On("LastChecked"); } }

    // ---- Calculated by the app: which installed Designer matches this Core ----
    private string _match = "";     public string DesignerMatch { get { return _match; }   set { _match = value ?? ""; On("DesignerMatch"); } }    // OK / Patch / Missing
    private string _mdet = "";      public string DesignerDetail { get { return _mdet; }   set { _mdet = value ?? ""; On("DesignerDetail"); } } // hover text

    // ---- Optional: what to type into Designer's F8 search box (blank = use the Design name) ----
    private string _f8 = "";        public string F8Search    { get { return _f8; }        set { _f8 = value ?? ""; On("F8Search"); } }

    // ---- The Core's "design code": changes every time a design is pushed. Used to decide when
    //      firmware needs re-reading (so we don't log in to every Core on every check). ----
    private string _code = "";      public string DesignCode  { get { return _code; }      set { _code = value ?? ""; On("DesignCode"); } }

    // ---- The Core's own name (e.g. "Room101-Core"). Designer's Load from Core search
    //      matches THIS, not the design name. Read from Core Manager or the Core's QDP announcement. ----
    private string _cname = "";     public string CoreName    { get { return _cname; }     set { string v = value ?? ""; if (_cname != v) { _cname = v; Modified = DateTime.UtcNow.Ticks; On("CoreName"); } } }
}

// One row of the Devices tab: something heard announcing itself with QDP on the LAN A network.
public class QDevice : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void On(string p) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(p)); }
    private void Set(ref string field, string value, string name) { value = value ?? ""; if (field != value) { field = value; On(name); } }

    private string _name = "", _type = "", _model = "", _a = "", _b = "", _inList = "", _seen = "", _status = "", _kind = "";
    public string Kind     { get { return _kind; }   set { Set(ref _kind, value, "Kind"); } }      // readable: Core, Touch screen, Amplifier...
    public string RawName = "";        // the name exactly as the device announced it (usually lowercase)
    public bool IsVirtual;             // an emulated / virtual Core (QDP says is_virtual = true)
    public string Name     { get { return _name; }   set { Set(ref _name, value, "Name"); } }
    public string Type     { get { return _type; }   set { Set(ref _type, value, "Type"); } }
    public string Model    { get { return _model; }  set { Set(ref _model, value, "Model"); } }
    public string LanA     { get { return _a; }      set { Set(ref _a, value, "LanA"); } }
    public string LanB     { get { return _b; }      set { Set(ref _b, value, "LanB"); } }
    public string InList   { get { return _inList; } set { Set(ref _inList, value, "InList"); } }
    public string LastSeen { get { return _seen; }   set { Set(ref _seen, value, "LastSeen"); } }
    public string Status   { get { return _status; } set { Set(ref _status, value, "Status"); } }
    public DateTime LastSeenTime;      // not shown; used to notice devices that stopped announcing
}

// Gives the launcher its own identity on the Windows taskbar (its own icon, name and pin)
// instead of being lumped in with PowerShell.
public static class QslShell
{
    [DllImport("shell32.dll")] static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    public static void SetProcessAppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch { } }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropKey { public Guid fmtid; public uint pid; public PropKey(Guid g, uint p) { fmtid = g; pid = p; } }
    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropKey k);
        [PreserveSig] int GetValue(ref PropKey k, out PropVariant v);
        [PreserveSig] int SetValue(ref PropKey k, ref PropVariant v);
        [PreserveSig] int Commit();
    }
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);

    static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static void SetString(IPropertyStore ps, uint pid, string val)
    {
        PropKey k = new PropKey(AppUserModel, pid);
        PropVariant v = new PropVariant();
        v.vt = 31;                                      // VT_LPWSTR
        v.p = Marshal.StringToCoTaskMemUni(val);
        try { ps.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
    }

    // id: taskbar ID   relaunch: command a pinned button runs   name/icon: what the pin shows
    public static string SetWindowAppId(IntPtr hwnd, string id, string relaunch, string name, string icon)
    {
        try
        {
            Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore ps;
            int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out ps);
            if (hr != 0 || ps == null) return "SHGetPropertyStoreForWindow returned " + hr;
            if (!string.IsNullOrEmpty(relaunch))
            {
                SetString(ps, 2, relaunch);                                  // RelaunchCommand
                SetString(ps, 4, name);                                      // RelaunchDisplayNameResource
                if (!string.IsNullOrEmpty(icon)) SetString(ps, 3, icon);     // RelaunchIconResource
            }
            SetString(ps, 5, id);                                            // ID
            ps.Commit();
            Marshal.ReleaseComObject(ps);
            return "";
        }
        catch (Exception e) { return e.Message; }
    }
}

public static class QslMouse
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern void mouse_event(int flags, int dx, int dy, int data, int extra);
}

// Which window is in front, and which program owns it (so we can hand focus back after
// briefly bringing Designer forward - see section 8c).
public static class QslWin
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
    public static int ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid; }
}

// HTTPS trust for Cores: "trust on first use", the way SSH does it.
// Cores use self-signed certificates, so normal checking always fails. Instead:
//   - a certificate Windows already trusts (e.g. from your own CA) is accepted as usual;
//   - the FIRST certificate seen at an address is remembered (Pins: address -> fingerprint);
//   - after that, only that same certificate is accepted at that address. A different one is
//     refused, so your Core login is never sent to something pretending to be the Core.
// Events tells the UI thread what happened ("NEW|ip|hash" to save, "CHANGED|ip|hash" to report).
public static class QslTrust
{
    public static System.Collections.Concurrent.ConcurrentDictionary<string, string> Pins =
        new System.Collections.Concurrent.ConcurrentDictionary<string, string>();
    public static System.Collections.Concurrent.ConcurrentQueue<string> Events =
        new System.Collections.Concurrent.ConcurrentQueue<string>();

    public static string Fingerprint(X509Certificate c)
    {
        using (var sha = System.Security.Cryptography.SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(c.GetRawCertData())).Replace("-", "");
    }

    private static bool Check(object sender, X509Certificate c, X509Chain ch, SslPolicyErrors e)
    {
        if (e == SslPolicyErrors.None) return true;                 // a properly trusted certificate
        var wr = sender as HttpWebRequest;
        if (wr == null || c == null) return false;                  // only our own requests to Cores
        string host = wr.Address.Host;
        string fp = Fingerprint(c);
        string pinned;
        if (Pins.TryGetValue(host, out pinned))
        {
            if (pinned == fp) return true;
            Events.Enqueue("CHANGED|" + host + "|" + fp);
            return false;
        }
        Pins[host] = fp;
        Events.Enqueue("NEW|" + host + "|" + fp);
        return true;
    }

    public static void Enable()
    {
        ServicePointManager.ServerCertificateValidationCallback = Check;
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11;
    }
}
'@
}

# Turn on trust-on-first-use for Cores' self-signed certificates (see QslTrust above).
[QslTrust]::Enable()

# Own taskbar identity for this process (must happen before any window is created).
[QslShell]::SetProcessAppId($AppId)

#endregion

#region ==== 3. SMALL UTILITIES ======================================

# Write text as UTF-8 WITHOUT a byte-order mark.
# (PowerShell 5.1's Set-Content -Encoding UTF8 adds a BOM, which some apps choke on.)
function Write-TextNoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# True only for a complete dotted IPv4 address like 10.20.30.40.
# (We don't use [IPAddress]::TryParse because it happily accepts typos like
#  "10.20.30" and silently turns them into 10.20.0.30.)
function Test-IpAddress([string]$Ip) {
    if (-not $Ip) { return $false }
    $parts = $Ip.Trim().Split('.')
    if ($parts.Count -ne 4) { return $false }
    foreach ($p in $parts) {
        if ($p -notmatch '^\d{1,3}$' -or [int]$p -gt 255) { return $false }
    }
    return $true
}

# Is this IP inside a range like 192.168.0.0/19 ?
function Test-InSubnet([string]$Ip, [string]$Cidr) {
    if (-not (Test-IpAddress $Ip) -or $Cidr -notmatch '^([\d\.]+)/(\d+)$') { return $false }
    $toNum = { param($a) $b = [System.Net.IPAddress]::Parse($a).GetAddressBytes(); [array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
    $size  = [uint32][math]::Pow(2, 32 - [int]$Matches[2])
    $net   = & $toNum $Matches[1]
    $n     = & $toNum $Ip.Trim()
    return ([math]::Floor($n / $size) -eq [math]::Floor($net / $size))
}

# "192.168.5.20" + 19 -> "192.168.0.0/19" (the network that address is on).
function Get-NetworkCidr([string]$Ip, [int]$Prefix) {
    $b = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes(); [array]::Reverse($b)
    $n = [BitConverter]::ToUInt32($b, 0)
    $size = [math]::Pow(2, 32 - $Prefix)
    $net = [uint32]([math]::Floor($n / $size) * $size)
    $x = [BitConverter]::GetBytes($net); [array]::Reverse($x)
    return "$([System.Net.IPAddress]::new($x))/$Prefix"
}

# "255.255.224.0" -> 19
function ConvertTo-PrefixLength([string]$Mask) {
    $bits = 0
    foreach ($octet in [System.Net.IPAddress]::Parse($Mask).GetAddressBytes()) { $bits += [Convert]::ToString($octet, 2).Replace('0', '').Length }
    return $bits
}

# Every IPv4 network this PC is on: @{ Ip; Nic; Cidr }
function Get-LocalNetworks {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.ToString()
            if ($ip -like '169.254.*') { continue }                                # no DHCP answer - ignore
            $prefix = 0
            try { $prefix = [int]$ua.PrefixLength } catch { }
            if (-not $prefix -and $ua.IPv4Mask) { $prefix = ConvertTo-PrefixLength $ua.IPv4Mask.ToString() }
            if (-not $prefix) { continue }
            $out.Add(@{ Ip = $ip; Nic = $nic.Name; Cidr = (Get-NetworkCidr $ip $prefix) })
        }
    }
    return $out
}

# Work out the LAN A network if it isn't set yet. Two ways in:
#   - a Core's own network settings (address + netmask)          -> exact
#   - a device heard on LAN A whose address is on one of this PC's networks -> that network
# Once known: the Devices tab listens on just that card, and addresses are sorted into the right column.
function Learn-LanASubnet([string]$LanAIp, [string]$Mask, [string]$Source) {
    if ($Settings.LanASubnet -or -not (Test-IpAddress $LanAIp)) { return }
    $cidr = $null
    if ($Mask -and (Test-IpAddress $Mask)) { $cidr = Get-NetworkCidr $LanAIp (ConvertTo-PrefixLength $Mask) }
    else {
        foreach ($n in Get-LocalNetworks) { if (Test-InSubnet $LanAIp $n.Cidr) { $cidr = $n.Cidr; break } }
    }
    if (-not $cidr) { return }
    $Settings.LanASubnet = $cidr
    Write-Log "Detected the LAN A (AV) network: $cidr (from $Source). Change it in Tools > Options if that's wrong."
    Repair-LanColumns
    Save-AppData
    Start-QdpListener
}

# Addresses that turn out to be on the LAN A network belong in the LAN A column.
function Repair-LanColumns {
    if (-not $Settings.LanASubnet) { return }
    foreach ($x in $Systems) {
        $b = $x.IpAddress.Trim()
        if (-not (Test-InSubnet $b $Settings.LanASubnet)) { continue }
        if (-not $x.LanA) { $x.LanA = $b }
        if ($x.LanA.Trim() -eq $b) { $x.IpAddress = '' }
    }
}

# The address(es) this row puts into Designer's hard links, following the "Links use" setting.
function Get-LinkIps([QSystem]$s) {
    $a = $s.LanA.Trim();      $okA = Test-IpAddress $a
    $b = $s.IpAddress.Trim(); $okB = Test-IpAddress $b
    switch ($Settings.LinkUse) {
        'LAN A' { if ($okA) { return @($a) } elseif ($okB) { return @($b) } }
        'Both'  { return @(@($b, $a) | Where-Object { Test-IpAddress $_ }) }
        default { if ($okB) { return @($b) } elseif ($okA) { return @($a) } }
    }
    return @()
}

# The single address to talk to for Query / Core Manager (same preference as the hard links).
function Get-QueryIp([QSystem]$s) {
    $a = $s.LanA.Trim(); $b = $s.IpAddress.Trim()
    if ($Settings.LinkUse -eq 'LAN A' -and (Test-IpAddress $a)) { return $a }
    if (Test-IpAddress $b) { return $b }
    if (Test-IpAddress $a) { return $a }
    return $null
}

# Pull "major.minor.patch" numbers out of any version-ish string ("10.4.1.123", "v9.13", ...).
# Returns $null if no version is found.
function ConvertTo-VersionParts([string]$Text) {
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    $patch = -1                                   # -1 = "patch unknown"
    if ($m.Groups[3].Success) { $patch = [int]$m.Groups[3].Value }
    return [pscustomobject]@{ Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value; Patch = $patch }
}

# Add a line to the log box at the bottom of the window (with a timestamp).
# Every line also goes to launcher.log in the data folder, so problems can be looked at later.
$LogFile = Join-Path $AppFolder 'launcher.log'

# The Log window (View > Log) shows these; we keep the most recent few thousand lines in memory.
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:LogLines.Add($line)
    if ($script:LogLines.Count -gt 5000) { $script:LogLines.RemoveRange(0, 1000) }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.ScrollToEnd()
    }
    try {
        # Start a fresh log once it passes ~1 MB (the old one is kept as launcher.old.log).
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Move-Item $LogFile (Join-Path $AppFolder 'launcher.old.log') -Force
        }
        [System.IO.File]::AppendAllText($LogFile, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd'), $line) + "`r`n")
    } catch { }
}

# Is any copy of Q-SYS Designer currently running?
# (Designer may rewrite HardLink.json when it closes, so we warn before writing it.)
function Get-RunningDesigner {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'Designer' -and $(try { $_.Path -like '*\QSC\*' } catch { $false })
    }
}

#endregion

#region ==== 4. FIND INSTALLED DESIGNER VERSIONS =====================
<#
  Each version installs side-by-side in its own folder, e.g.
      C:\Program Files\QSC\Q-SYS Designer 10.4\
  We look in those folders for the Designer .exe and read its version stamp,
  which includes the patch number (e.g. 10.4.1) that the folder name leaves out.
#>
function Find-DesignerInstalls {
    $found = New-Object System.Collections.Generic.List[object]

    # ---- Where to look ----
    # 1) Program Files\QSC\Q-SYS Designer *          (the normal install location)
    # 2) the installed-programs list in the registry (catches installs on other drives/folders)
    # 3) Options > "Extra Designer folders"          (portable copies, unusual setups)
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $DesignerRoots) {
        if ($root -and (Test-Path $root)) {
            foreach ($dir in Get-ChildItem -Path $root -Directory -Filter 'Q-SYS Designer*' -ErrorAction SilentlyContinue) { $candidates.Add($dir.FullName) }
        }
    }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($app in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
            if ($app.DisplayName -like 'Q-SYS Designer*' -and $app.InstallLocation) { $candidates.Add(([string]$app.InstallLocation).TrimEnd('\')) }
        }
    }
    foreach ($extra in ([string]$Settings.ExtraDesignerFolders -split ';')) {
        $extra = $extra.Trim().Trim('"')
        if (-not $extra -or -not (Test-Path $extra)) { continue }
        $candidates.Add($extra)                                                           # the folder itself...
        foreach ($dir in Get-ChildItem -Path $extra -Directory -ErrorAction SilentlyContinue) { $candidates.Add($dir.FullName) }   # ...or folders inside it
    }

    # ---- Look in each place once ----
    $seen = @{}
    foreach ($path in $candidates) {
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $dir = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $dir -or -not $dir.PSIsContainer) { continue }

        # Find the main exe. Prefer the exact name; fall back to any exe with "Designer" in it.
        $exes = @(Get-ChildItem -Path $dir.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        $exe  = $exes | Where-Object { $_.Name -ieq 'Q-Sys Designer.exe' } | Select-Object -First 1
        if (-not $exe) {
            $exe = $exes | Where-Object { $_.Name -match 'Designer' -and $_.Name -notmatch 'unins|setup|update' } |
                   Select-Object -First 1
        }
        if (-not $exe) { continue }

        # Version: prefer the exe's own version info, fall back to the folder name.
        $verText = $exe.VersionInfo.ProductVersion
        if (-not (ConvertTo-VersionParts $verText)) { $verText = $exe.VersionInfo.FileVersion }
        if (-not (ConvertTo-VersionParts $verText)) { $verText = $dir.Name }
        $v = ConvertTo-VersionParts $verText
        if (-not $v) { continue }

        $display = '{0}.{1}' -f $v.Major, $v.Minor
        if ($v.Patch -ge 0) { $display += ".$($v.Patch)" }

        $found.Add([pscustomobject]@{
            Version = $display
            Major   = $v.Major
            Minor   = $v.Minor
            Patch   = $v.Patch
            Folder  = $dir.Name
            Exe     = $exe.FullName
        })
    }

    # Newest first; if the same version turns up twice, keep one.
    return @($found | Sort-Object Major, Minor, Patch -Descending | Group-Object Exe | ForEach-Object { $_.Group[0] })
}

# Pick the best installed Designer for a given Core firmware string.
# Returns an object: Designer (or $null), Exact (bool), Text (for the grid column)
function Find-DesignerForFirmware([string]$Firmware) {
    $fw = ConvertTo-VersionParts $Firmware
    if (-not $fw) { return [pscustomobject]@{ Designer = $null; Exact = $false; Text = ''; Detail = '' } }

    $sameMinor = @($script:Designers | Where-Object { $_.Major -eq $fw.Major -and $_.Minor -eq $fw.Minor })

    # 1) Exact major.minor.patch match = Designer can connect to this Core.
    $exact = $sameMinor | Where-Object { $_.Patch -eq $fw.Patch -or $fw.Patch -lt 0 } | Select-Object -First 1
    if ($exact) { return [pscustomobject]@{ Designer = $exact; Exact = $true; Text = 'OK'
                                            Detail = "Designer $($exact.Version) is installed and matches this Core." } }

    # 2) Same major.minor but different patch = probably needs a different patch release.
    if ($sameMinor.Count -gt 0) {
        $near = $sameMinor[0]
        return [pscustomobject]@{ Designer = $near; Exact = $false; Text = 'Patch'
                                  Detail = "Core runs $Firmware; installed is $($near.Version). Designer usually needs the exact patch to connect." }
    }

    # 3) Nothing installed for this version.
    $want = '{0}.{1}' -f $fw.Major, $fw.Minor
    return [pscustomobject]@{ Designer = $null; Exact = $false; Text = 'Missing'
                              Detail = "Core runs $Firmware; no Designer $want is installed. Download it from qsys.com." }
}

#endregion

#region ==== 5. APP DATA: LOAD / SAVE THE ADDRESS BOOK ===============

# The live list the grid is bound to. ObservableCollection tells the grid when rows are added/removed.
$Systems = New-Object 'System.Collections.ObjectModel.ObservableCollection[QSystem]'

# App-wide settings (saved alongside the systems).
$Settings = @{
    Mode        = 'UDP'     # Designer hard-link mode: UDP or HTTPS

    # Which Core address(es) go into Designer's hard links ("Links use" dropdown):
    #   LAN B - campus address (default)   LAN A - AV network address   Both - one link for each
    # A row that only has one of the two always uses the one it has.
    LinkUse     = 'LAN B'

    # The AV (LAN A) network, e.g. "192.168.0.0/19". Leave blank and it's DETECTED automatically
    # (from the first Core heard or checked). Used to pick the network card for the Devices tab,
    # and to sort addresses into the LAN A / LAN B columns.
    LanASubnet  = ''

    # Keep the Core list in a shared folder (OneDrive, a network share...) so a small team sees
    # one list. Blank = just this PC. Settings, logins and window positions always stay per person.
    SharedFolder = ''

    # Extra places to look for Q-SYS Designer (semicolon-separated), besides Program Files\QSC
    # and the installed-programs list in the registry.
    ExtraDesignerFolders = ''

    # Per-Core logins for Cores that don't use the global one: @{ Id; User; PassEnc } each.
    # Passwords are encrypted for this Windows account only (DPAPI), so they never go in a shared list.
    CoreLogins  = @()

    # What to do after launching Designer for a Core ("Load from Core" dropdown):
    #   Off          - just open Designer
    #   Open dialog   - open the Load from Core & Connect dialog
    #   Select Core   - ...and select this Core's row in it (you click Load)
    #   Select + Load - ...and click "Load From Selected Core" too (only if exactly one match)
    F8Mode          = 'Select Core'
    # F8 timing: the launcher watches Designer load and presses F8 once Designer is READY
    # (section 8c), then waits this many extra seconds. No guessing how long loading takes.
    F8AfterReadySec = 1
    F8ReadyLimitSec = 45    # if Designer never looks ready by then, press F8 anyway (and say why in the log)
    DialogWaitSec   = 25    # how long to look for the F8 dialog before giving up

    # HTTPS paths tried for the firmware version, in order. "Find firmware API" puts
    # the one that works at the front and saves it, so later Queries try it first.
    FirmwareEndpoints = $FirmwareEndpoints

    # ---- Automatic behavior ----
    RefreshMinutes    = 10      # (older versions: how often every Core was checked - no longer used)

    # Checking a Core over the network (Remote Control port 1710, and Core Manager for firmware)
    # puts "client connected / closed" lines - and sometimes a sign-in - in the Core's event log.
    # So by default the launcher only LISTENS (QDP announcements, which leave no trace on the Core)
    # and talks to Cores only when you ask: Check all now (F5), Check now on a row, or launching a
    # Core whose firmware isn't known yet. 0 = only when asked; otherwise every N minutes.
    AutoCheckMinutes  = 0

    # Each Core address's HTTPS certificate fingerprint, remembered the first time (see QslTrust).
    CertPins          = @()
    AutoSync          = $true   # write Designer's hard links automatically when the list changes
    FirmwareProbeDone = $false  # set once the firmware API search has run (so it isn't repeated every start)

    CloseAction       = 'Tray'  # window X button: 'Tray' = keep running in the tray, 'Exit' = quit

    # Devices tab: listen for Q-SYS discovery (QDP) announcements on the LAN A network card
    QdpListen         = $true

    # Also find the older PTZ-IP cameras, which don't use QDP (they answer WS-Discovery instead).
    # Off by default: it means asking the network every 30 s, and most sites don't have them.
    PtzIpDiscovery    = $false

    # Groups you've set up in Edit > Groups (building, floor, department...). The Group column's
    # drop-down shows these PLUS any group already typed on a Core.
    Groups            = @()

    # Add Cores heard on LAN A (Devices tab) to the Cores list by themselves (section 7i).
    # Only Cores inside the LAN A range, never emulators, never ones you removed.
    AutoAddCores      = $true
    # Cores you removed, so auto-add leaves them out: announced names (lowercase) and LAN A addresses.
    IgnoredCores      = @()
    IgnoredClearedAt  = 0          # when someone last pressed "Allow them again" (ticks, UTC)

    # Where the windows were last time: "left,top,width,height,maximized" (blank = default)
    MainBounds        = ''
    LogBounds         = ''

    # ---- Core Manager login (see section 7f) ----
    CoreUser          = ''
    CorePassEnc       = ''      # DPAPI-encrypted; never stored as plain text
}

# Build a QSystem object from a saved/imported record (works with hashtables or JSON objects).
function New-QSystem($r) {
    $s = New-Object QSystem
    foreach ($p in 'Name','Group','IpAddress','LanA','Notes','Platform','Firmware','DesignName','State','LastChecked','F8Search','DesignCode','CoreName') {
        if ($r.$p) { $s.$p = [string]$r.$p }
    }
    if ($null -ne $r.Enabled) { $s.Enabled = [bool]$r.Enabled }
    # Every row gets a permanent Id (older lists didn't have one).
    $s.Id = if ($r.Id) { [string]$r.Id } else { [guid]::NewGuid().ToString() }
    # Setting the fields above bumped Modified - put back the real "last edited" time.
    $s.Modified = if ($r.Modified) { [long]$r.Modified } else { 0 }
    return $s
}

# One row -> the record saved in the JSON files.
function ConvertTo-SystemRecord([QSystem]$s) {
    [ordered]@{
        Id = $s.Id; Modified = $s.Modified
        Name = $s.Name; Group = $s.Group; IpAddress = $s.IpAddress.Trim(); LanA = $s.LanA.Trim(); Enabled = $s.Enabled; Notes = $s.Notes
        Platform = $s.Platform; Firmware = $s.Firmware; DesignName = $s.DesignName; F8Search = $s.F8Search; DesignCode = $s.DesignCode; CoreName = $s.CoreName
        State = $s.State; LastChecked = $s.LastChecked
    }
}

# Safety latch: stays $false until the address book has loaded. Without it, setting a
# dropdown's starting value (which fires its "changed" event) could save an EMPTY list
# over your real one before it was read.
$script:DataLoaded = $false

# The addresses this app last wrote into Designer's file. Used by Import: an address that's in
# Designer's file AND in this set is one WE put there (and you've since removed or changed here),
# so it is not brought back. Anything else in Designer's file was added inside Designer -> import it.
$script:LastSynced = New-Object 'System.Collections.Generic.HashSet[string]'

# Rows removed, by Id -> when (UTC ticks). Kept so a shared list doesn't bring them back.
$script:DeletedIds = @{}

# ---------- Shared Core list (optional) ----------
<#
  With a shared folder set, the Core list lives in <folder>\LauncherForQSYS-cores.json, and
  everyone's launcher reads and writes that one file. This PC still keeps its own copy in
  systems.json, so the list is there even if the share is offline.

  When two copies disagree, they're MERGED row by row (using each row's Id):
    - a row only one side has   -> kept (someone added it), unless it was deleted
    - a row both sides have     -> the more recently edited version wins
    - a deleted row             -> stays deleted (deletions are remembered for 6 months)
#>
$script:SharedStamp = $null       # the shared file's last-write time when we last read/wrote it
$script:SharedError = $null

function Get-SharedListPath {
    if ($Settings.SharedFolder) { return (Join-Path $Settings.SharedFolder 'LauncherForQSYS-cores.json') }
    return $null
}

function Read-SharedList([string]$Path) {
    $j = Get-Content $Path -Raw | ConvertFrom-Json
    return @{ Systems = @($j.Systems | Where-Object { $_ }); Deleted = @($j.Deleted | Where-Object { $_ }); Ignored = @($j.Ignored | Where-Object { $_ }); IgnoredClearedAt = [long]$j.IgnoredClearedAt }
}

function Write-SharedList([string]$Path) {
    # Forget deletions older than ~6 months.
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-180).Ticks
    foreach ($k in @($script:DeletedIds.Keys)) { if ($script:DeletedIds[$k] -lt $cutoff) { $script:DeletedIds.Remove($k) } }

    $data = [ordered]@{
        SavedAt = (Get-Date).ToString('s')
        SavedBy = "$env:USERNAME on $env:COMPUTERNAME"
        Systems = @($Systems | ForEach-Object { ConvertTo-SystemRecord $_ })
        Deleted = @($script:DeletedIds.Keys | ForEach-Object { [ordered]@{ Id = $_; When = $script:DeletedIds[$_] } })
        Ignored = @($Settings.IgnoredCores)          # Cores someone removed: auto-add leaves them out
        IgnoredClearedAt = [long]$Settings.IgnoredClearedAt
    }
    # Write to a temp file, then swap it in, so nobody ever reads a half-written list.
    $tmp = "$Path.tmp-$PID"
    Write-TextNoBom $tmp ($data | ConvertTo-Json -Depth 5)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    $script:SharedStamp = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
}

# Copy one row's values onto another row object (keeps the object the grid is showing).
function Copy-SystemFields([QSystem]$From, [QSystem]$To) {
    foreach ($p in 'Name','Group','IpAddress','LanA','Notes','Platform','Firmware','DesignName','State','LastChecked','F8Search','DesignCode','CoreName','Enabled') {
        $To.$p = $From.$p
    }
    $To.Modified = $From.Modified
}

# Merge another copy of the list (from the shared file) into ours. See the rules above.
function Merge-SharedList($Ext) {
    # Removed-Cores list: everyone's removals count (a union).
    # If someone pressed "Allow them again" after our last clear, take their list as it is.
    $theirClear = [long]$Ext.IgnoredClearedAt
    if ($theirClear -gt [long]$Settings.IgnoredClearedAt) {
        $Settings.IgnoredCores = @(); $Settings.IgnoredClearedAt = $theirClear
    }
    foreach ($i in @($Ext.Ignored)) { Add-IgnoredCore ([string]$i) }
    foreach ($d in $Ext.Deleted) {
        if (-not $d.Id) { continue }
        $t = [long]$d.When
        if (-not $script:DeletedIds.ContainsKey([string]$d.Id) -or $script:DeletedIds[[string]$d.Id] -lt $t) { $script:DeletedIds[[string]$d.Id] = $t }
    }
    $isDeleted = { param($id, $modified) $script:DeletedIds.ContainsKey($id) -and $script:DeletedIds[$id] -ge $modified }

    $mine = @{}; foreach ($x in $Systems) { $mine[$x.Id] = $x }
    $result = New-Object System.Collections.Generic.List[QSystem]
    $seen = @{}
    foreach ($r in $Ext.Systems) {
        $id = [string]$r.Id
        if (-not $id) { continue }
        $seen[$id] = $true
        if (& $isDeleted $id ([long]$r.Modified)) { continue }
        $local = $mine[$id]
        if ($local -and $local.Modified -ge [long]$r.Modified) { $result.Add($local) }        # ours is newer (or same)
        elseif ($local) { Copy-SystemFields (New-QSystem $r) $local; $result.Add($local) }     # theirs is newer
        else { $result.Add((New-QSystem $r)) }                                                 # added by someone else
    }
    foreach ($x in $Systems) {
        if (-not $seen.ContainsKey($x.Id) -and -not (& $isDeleted $x.Id $x.Modified)) { $result.Add($x) }   # added here
    }
    $Systems.Clear()
    foreach ($x in $result) { $Systems.Add($x) }
}

# Bring the shared file and our list in line: merge in others' changes, then write.
# Called when it's safe to rebuild the list (startup, the housekeeping timer, the refresh cycle).
function Sync-SharedList {
    $path = Get-SharedListPath
    if (-not $path -or -not $script:DataLoaded) { return }
    try {
        if (Test-Path -LiteralPath $path) {
            $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
            if ($stamp -eq $script:SharedStamp -and -not $script:SharedDirty) { return }   # nothing new either way
            if ($stamp -ne $script:SharedStamp) {
                $before = $Systems.Count
                Merge-SharedList (Read-SharedList $path)
                Write-Log "Core list: merged changes from the shared folder ($before -> $($Systems.Count) Cores)."
            }
        }
        Write-SharedList $path
        $script:SharedDirty = $false
        if ($script:SharedError) { Write-Log 'Shared Core list is reachable again.' }
        $script:SharedError = $null
    } catch {
        if (-not $script:SharedError) { Write-Log "Shared Core list not reachable ($path): $($_.Exception.Message). Using this PC's copy." }
        $script:SharedError = $_.Exception.Message
    }
}

function Save-AppData {
    if (-not $script:DataLoaded) { return }
    $data = [ordered]@{
        SavedAt    = (Get-Date).ToString('s')
        Settings   = $Settings
        LastSynced = @($script:LastSynced)
        Deleted    = @($script:DeletedIds.Keys | ForEach-Object { [ordered]@{ Id = $_; When = $script:DeletedIds[$_] } })
        Systems    = @($Systems | ForEach-Object { ConvertTo-SystemRecord $_ })    # this PC's copy (also when shared)
    }
    Write-TextNoBom $SystemsFile ($data | ConvertTo-Json -Depth 6)

    # Shared list: write straight away if nobody else changed it since we last looked;
    # otherwise leave it for Sync-SharedList (merging rebuilds the list, which isn't safe mid-task).
    $path = Get-SharedListPath
    if ($path) {
        $script:SharedDirty = $true
        try {
            $current = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).LastWriteTimeUtc } else { $null }
            if ($null -eq $current -or $current -eq $script:SharedStamp) {
                Write-SharedList $path
                $script:SharedDirty = $false
            }
        } catch { }
    }
}

function Load-AppData {
    if (-not (Test-Path $SystemsFile)) { return $false }
    $data = Get-Content $SystemsFile -Raw | ConvertFrom-Json
    if ($data.Settings) {
        foreach ($k in @($Settings.Keys)) { if ($null -ne $data.Settings.$k) { $Settings[$k] = $data.Settings.$k } }
        $Settings.FirmwareEndpoints = [string[]]@($Settings.FirmwareEndpoints)     # JSON may hand back a single string
        $Settings.CoreLogins        = @($Settings.CoreLogins | Where-Object { $_ -and $_.Id })
        # Older versions used different names for the F8 modes.
        $Settings.F8Mode = switch ($Settings.F8Mode) { 'Press F8' { 'Open dialog' } 'Fill search' { 'Select Core' } 'Fill + Load' { 'Select + Load' } default { $Settings.F8Mode } }
        $Settings.CertPins          = @($Settings.CertPins | Where-Object { $_ -and $_.Host -and $_.Hash })
        foreach ($pin in $Settings.CertPins) { [QslTrust]::Pins[[string]$pin.Host] = [string]$pin.Hash }
        $Settings.IgnoredCores      = @($Settings.IgnoredCores | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    foreach ($r in @($data.Systems)) { if ($r) { $Systems.Add((New-QSystem $r)) } }
    foreach ($ip in @($data.LastSynced)) { if ($ip) { [void]$script:LastSynced.Add([string]$ip) } }
    foreach ($d in @($data.Deleted)) { if ($d -and $d.Id) { $script:DeletedIds[[string]$d.Id] = [long]$d.When } }
    return $true
}

# ---------- Certificate pins (see QslTrust in section 2) ----------
# Called often (housekeeping timer + after checks): save new fingerprints, report changed ones.
$script:CertWarned = @{}
function Receive-CertEvents {
    $ev = $null; $dirty = $false
    while ([QslTrust]::Events.TryDequeue([ref]$ev)) {
        $kind, $ip, $hash = $ev -split '\|'
        if ($kind -eq 'NEW') {
            $Settings.CertPins = @(@($Settings.CertPins | Where-Object { $_.Host -ne $ip }) + [pscustomobject]@{ Host = $ip; Hash = $hash })
            $dirty = $true
        } elseif (-not $script:CertWarned.ContainsKey($ip)) {
            $script:CertWarned[$ip] = $true
            $who = ($Systems | Where-Object { $_.IpAddress.Trim() -eq $ip -or $_.LanA.Trim() -eq $ip } | Select-Object -First 1)
            $name = if ($who) { "'$($who.Name)'" } else { $ip }
            Write-Log "[$name $ip] HTTPS certificate is different from the one first seen there, so the launcher didn't send your Core login. If the Core was reset, replaced or re-imaged, right-click it > Trust this Core's new certificate."
            Show-TrayNote "$name has a different HTTPS certificate than before - login not sent. See the log."
        }
    }
    if ($dirty) { Save-AppData }
}

# Right-click > "Trust this Core's new certificate": forget its fingerprints, then check it.
function Reset-CoreCertificate([QSystem]$s) {
    if (-not $s) { Set-Status 'Select a Core first.'; return }
    foreach ($ip in @($s.IpAddress.Trim(), $s.LanA.Trim()) | Where-Object { $_ }) {
        $old = $null; [void][QslTrust]::Pins.TryRemove($ip, [ref]$old)
        $Settings.CertPins = @($Settings.CertPins | Where-Object { $_.Host -ne $ip })
        $script:CertWarned.Remove($ip); $script:Tokens.Remove($ip)
    }
    Save-AppData
    Write-Log "Forgot the remembered certificate for '$($s.Name)'; the next one seen will be trusted."
    Start-CoreQuery ([QSystem[]]@($s)) -Force
}

# ---------- Per-Core logins (section 7f has the global one) ----------
$script:RowPass = @{}      # Id -> decrypted password, cached for this session

function Get-CoreLoginEntry([QSystem]$s) { @($Settings.CoreLogins) | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1 }

# The login to use for a Core: its own, if it has one, otherwise the global login.
function Get-CoreLoginFor([QSystem]$s) {
    $e = Get-CoreLoginEntry $s
    if ($e) {
        if (-not $script:RowPass.ContainsKey($s.Id)) {
            try {
                $sec = ConvertTo-SecureString ([string]$e.PassEnc)
                $script:RowPass[$s.Id] = (New-Object System.Management.Automation.PSCredential('x', $sec)).GetNetworkCredential().Password
            } catch { $script:RowPass[$s.Id] = '' }
        }
        return @{ User = [string]$e.User; Pass = $script:RowPass[$s.Id]; Own = $true }
    }
    return @{ User = $script:CoreUser; Pass = $script:CorePass; Own = $false }
}

#endregion

#region ==== 6. DESIGNER HARD-LINK FILE: READ / IMPORT / SYNC ========

# Read Designer's current hard links. Returns: Mode, Links (array of IpAddress/IsEnabled), Names (hashtable ip->name)
function Read-DesignerHardLinks {
    $result = [pscustomobject]@{ Mode = 'UDP'; Links = @(); Names = @{} }

    if (Test-Path $HardLinkFile) {
        $j = Get-Content $HardLinkFile -Raw | ConvertFrom-Json
        if ($j.Mode)  { $result.Mode  = [string]$j.Mode }
        if ($j.Links) { $result.Links = @($j.Links) }
    }
    if (Test-Path $HardLinkNamesFile) {
        $n = Get-Content $HardLinkNamesFile -Raw | ConvertFrom-Json
        if ($n.Names) {
            foreach ($prop in $n.Names.PSObject.Properties) { $result.Names[$prop.Name] = [string]$prop.Value }
        }
    }
    return $result
}

# Add any hard links that exist in Designer but not in our list (never deletes anything).
function Import-DesignerHardLinks {
    $hl = Read-DesignerHardLinks
    $known = @{}
    foreach ($s in $Systems) { $known[$s.IpAddress.Trim()] = $true; $known[$s.LanA.Trim()] = $true }

    $added = 0
    foreach ($link in $hl.Links) {
        $ip = [string]$link.IpAddress
        if (-not $ip -or $known.ContainsKey($ip)) { continue }
        if ($script:LastSynced.Contains($ip)) { continue }   # we wrote it, then it was removed/changed here - leave it gone
        $known[$ip] = $true

        # Which column does this address belong in?
        $isA   = Test-InSubnet $ip $Settings.LanASubnet
        $field = if ($isA) { 'LanA' } else { 'IpAddress' }
        $name  = if ($hl.Names.ContainsKey($ip)) { ($hl.Names[$ip] -replace '\s*\[A\]$', '') } else { '' }

        # If a row with the same name already exists and that column is empty, fill it in
        # (this merges a Core's LAN A and LAN B links into one row).
        $row = $null
        if ($name) { $row = $Systems | Where-Object { $_.Name -eq $name -and -not $_.$field } | Select-Object -First 1 }
        if ($row) { $row.$field = $ip; continue }

        $s = New-Object QSystem
        $s.Id      = [guid]::NewGuid().ToString()
        $s.$field  = $ip
        $s.Enabled = [bool]$link.IsEnabled
        if ($name) { $s.Name = $name } else { $s.Name = "(imported) $ip" }
        $Systems.Add($s)
        $added++
    }
    $Settings.Mode = $hl.Mode
    return $added
}

# Build the exact JSON text Designer expects, from our address book.
function Build-DesignerJson {
    $links = New-Object System.Collections.Generic.List[object]
    $names = [ordered]@{}
    $seen  = @{}

    foreach ($s in $Systems) {
        $ips = @(Get-LinkIps $s)                        # 0, 1 or 2 addresses depending on "Links use"
        foreach ($ip in $ips) {
            if ($seen.ContainsKey($ip)) { continue }    # skip duplicates; first one wins
            $seen[$ip] = $true

            # Property order matches Designer's own file: IpAddress, then IsEnabled.
            $links.Add([ordered]@{ IpAddress = $ip; IsEnabled = [bool]$s.Enabled })

            if ($s.Name -and $s.Name -notlike '(imported)*') {
                # When both addresses are listed, tag the LAN A one so you can tell them apart in Designer.
                if ($ips.Count -gt 1 -and $ip -eq $s.LanA.Trim()) { $names[$ip] = "$($s.Name) [A]" }
                else { $names[$ip] = $s.Name }
            }
        }
    }

    return [pscustomobject]@{
        Count    = $links.Count
        HardLink = ([ordered]@{ Mode = $Settings.Mode; Links = $links.ToArray() } | ConvertTo-Json -Depth 5 -Compress)
        Names    = ([ordered]@{ Names = $names } | ConvertTo-Json -Depth 5 -Compress)
    }
}

# Preview what a Sync will change, so nothing disappears from Designer by surprise.
# Returns: Removed (Designer links that are NOT in our list - e.g. a Core's old DHCP address)
#          Added   (our IPs that Designer doesn't have yet)
function Get-SyncPreview {
    $hl = Read-DesignerHardLinks
    $ours = @{}
    foreach ($s in $Systems) { foreach ($ip in @(Get-LinkIps $s)) { $ours[$ip] = $s } }
    $theirs = @{}
    foreach ($l in $hl.Links) { $theirs[[string]$l.IpAddress] = $true }

    $removed = @(foreach ($l in $hl.Links) {
        $ip = [string]$l.IpAddress
        if (-not $ours.ContainsKey($ip)) {
            $label = if ($hl.Names.ContainsKey($ip)) { "$ip  ($($hl.Names[$ip]))" } else { $ip }
            $label
        }
    })
    $added = @(foreach ($ip in $ours.Keys) { if (-not $theirs.ContainsKey($ip)) { "$ip  ($($ours[$ip].Name))" } })
    return [pscustomobject]@{ Removed = $removed; Added = $added }
}

# Remember exactly which addresses Designer's file now holds because of us.
function Update-LastSynced {
    $script:LastSynced.Clear()
    foreach ($s in $Systems) { foreach ($ip in @(Get-LinkIps $s)) { [void]$script:LastSynced.Add($ip) } }
    Save-AppData
}

# Write our list into Designer's files (with a backup first). Returns a short status message.
function Sync-DesignerHardLinks {
    # --- Check for problems in the list before touching anything ---
    # Rows with no usable address, or a typo in either column.
    foreach ($s in $Systems) {
        if (@(Get-LinkIps $s).Count -eq 0) { Write-Log "SKIPPED (no valid IP): '$($s.Name)'" }
        foreach ($f in 'IpAddress', 'LanA') {
            $v = $s.$f.Trim()
            if ($v -and -not (Test-IpAddress $v)) { Write-Log "Typo? '$($s.Name)' $f = '$v' (ignored)" }
        }
    }
    # The same address on more than one row.
    $all  = foreach ($s in $Systems) { foreach ($ip in @(Get-LinkIps $s)) { [pscustomobject]@{ Ip = $ip; Name = $s.Name } } }
    $dups = @($all | Group-Object Ip | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dups) { Write-Log "DUPLICATE IP $($d.Name) used by: $(($d.Group | ForEach-Object Name) -join ', ')" }

    $new = Build-DesignerJson

    # --- Compare with what's already there; don't write if nothing changed ---
    $oldHL = ''; $oldNames = ''
    if (Test-Path $HardLinkFile)      { $oldHL    = (Get-Content $HardLinkFile -Raw).Trim() }
    if (Test-Path $HardLinkNamesFile) { $oldNames = (Get-Content $HardLinkNamesFile -Raw).Trim() }
    if ($oldHL -eq $new.HardLink -and $oldNames -eq $new.Names) { Update-LastSynced; return 'Designer hard links already match your list.' }

    # --- Back up the current files, then write ---
    if (-not (Test-Path $QscFolder)) { New-Item -ItemType Directory -Path $QscFolder | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path $HardLinkFile)      { Copy-Item $HardLinkFile      (Join-Path $BackupFolder "HardLink-$stamp.json") }
    if (Test-Path $HardLinkNamesFile) { Copy-Item $HardLinkNamesFile (Join-Path $BackupFolder "HardLinkNames-$stamp.json") }

    Write-TextNoBom $HardLinkFile      $new.HardLink
    Write-TextNoBom $HardLinkNamesFile $new.Names

    # --- Trim old backups ---
    Get-ChildItem $BackupFolder -Filter 'HardLink*.json' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip ($MaxBackups * 2) | Remove-Item -ErrorAction SilentlyContinue

    Update-LastSynced
    return "Wrote $($new.Count) hard links to Designer (backup saved as *-$stamp.json)."
}

#endregion

#region ==== 7. CORE QUERY (runs on background threads) ==============
<#
  This scriptblock runs once per Core on a background "runspace" so the window
  never freezes while we wait on the network. It can't see anything else in this
  script, so everything it needs is passed in as parameters.

  STEP A - QRC StatusGet on TCP 1710 (JSON-RPC, every message ends in a NULL byte).
           Gives us Platform (Core model), State, DesignName.
           The Core usually also sends an "EngineStatus" message right after
           connecting, which contains the same info - we accept either.

  STEP B - HTTPS GET on each candidate endpoint, scanning the reply for a
           "firmware"/"version" field that looks like 9.13.0 / 10.4.1.
#>
$QueryScript = {
    param([string]$Ip, [string[]]$Endpoints, [int]$Port, [int]$TimeoutMs, [string]$User = '', [string]$Pass = '', [string]$Auth = '',
          [bool]$Force = $true, [string]$KnownCode = '', [bool]$WasDown = $false)

    # ---- Core Manager login (only when you've saved a Core login in Settings) ----
    # POST /api/v0/logon with {"username","password"} -> the reply holds a token, which is
    # sent as "Authorization: Bearer <token>" on later requests. The password is never logged.
    function Get-CoreAuth([string]$Ip, [string]$User, [string]$Pass, [int]$TimeoutMs) {
        $out = @{ Auth = ''; Note = '' }
        if (-not $User) { return $out }
        try {
            $wr = [System.Net.HttpWebRequest]::Create("https://$Ip/api/v0/logon")
            $wr.Method = 'POST'; $wr.ContentType = 'application/json'; $wr.Accept = 'application/json'
            $wr.Timeout = $TimeoutMs; $wr.ReadWriteTimeout = $TimeoutMs
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ username = $User; password = $Pass } | ConvertTo-Json -Compress))
            $wr.ContentLength = $bytes.Length
            $rs = $wr.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
            $resp = $wr.GetResponse()
            $txt  = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $resp.Close()
            # The token may come back as JSON ({"token":"..."}) or as a bare line of text.
            $m = [regex]::Match($txt, '"(?:token|access_token|accessToken)"\s*:\s*"([^"]+)"')
            if ($m.Success) { $out.Auth = "Bearer $($m.Groups[1].Value)" }
            elseif ($txt.Trim() -and $txt.Trim() -notmatch '[\s\{\}<]') { $out.Auth = "Bearer $($txt.Trim().Trim('"'))" }
            else { $out.Note = "login replied but no token found ($($txt.Length) chars)" }
        }
        catch [System.Net.WebException] {
            $code = ''; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            $out.Note = if ($code -eq 401 -or $code -eq 403) { 'login rejected - check the Core username/password' } else { "login failed: $code $($_.Exception.Message)" }
        }
        catch { $out.Note = "login failed: $($_.Exception.Message)" }
        return $out
    }

    $r = @{ Ip = $Ip; Ok = $false; Platform = ''; State = ''; DesignName = ''; Firmware = ''; Log = @() }

    # ---------- STEP A: QRC StatusGet ----------
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "no answer on TCP $Port" }
        $client.EndConnect($iar)

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $req = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","method":"StatusGet","params":0,"id":1}' + [char]0)
        $stream.Write($req, 0, $req.Length)

        $buf      = New-Object byte[] 16384
        $pending  = ''
        $status   = $null
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs * 2)

        while (-not $status -and (Get-Date) -lt $deadline) {
            $n = $stream.Read($buf, 0, $buf.Length)        # throws if ReadTimeout passes
            if ($n -le 0) { break }
            $pending += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)

            # Split complete messages on the NULL terminator.
            while (($z = $pending.IndexOf([char]0)) -ge 0) {
                $one = $pending.Substring(0, $z)
                $pending = $pending.Substring($z + 1)
                $msg = $null
                try { $msg = $one | ConvertFrom-Json } catch { }
                if (-not $msg) { continue }
                if ($msg.id -eq 1 -and $msg.result)                     { $status = $msg.result }
                elseif ($msg.method -eq 'EngineStatus' -and -not $status) { $status = $msg.params }
                elseif ($msg.error) { $r.Log += "QRC error: $($msg.error.message)" }
            }
        }

        if ($status) {
            $r.Ok         = $true
            $r.Platform   = [string]$status.Platform
            $r.State      = [string]$status.State
            $r.DesignName = [string]$status.DesignName
            $r.DesignCode = [string]$status.DesignCode
            if ($status.IsEmulator) { $r.State += ' (emulating)' }
            $r.Log += "QRC OK: $($r.Platform), $($r.State), design '$($r.DesignName)'"
        } else {
            $r.Log += 'QRC: connected but got no status (External Control may be locked down)'
        }
    }
    catch { $r.Log += "QRC failed: $($_.Exception.Message)" }
    finally { if ($client) { $client.Close() } }

    # ---------- STEP B: details from Core Manager over HTTPS ----------
    # No point trying if the Core didn't answer at all.
    if (-not $r.Ok) { return $r }

    # Only log in to Core Manager when something could have changed. Firmware can't change
    # without a reboot and a design re-push, so the routine check stops here (no login, nothing
    # in the Core's event log) unless:
    #   - $Force      : first look at this Core, firmware unknown, or you picked "Check now"
    #   - design code : different from last time (a design was pushed - e.g. after a firmware update)
    #   - $WasDown    : the Core wasn't answering last time (it may have rebooted)
    $codeChanged = ($KnownCode -and $r.DesignCode -and $r.DesignCode -ne $KnownCode)
    if (-not ($Force -or $codeChanged -or $WasDown)) { return $r }
    if ($codeChanged) { $r.Log += 'Design changed since last check - re-reading firmware.' }
    $r.NeedsLogin = $false
    $r.Auth = $Auth          # login token from an earlier check (reused - Cores limit how often you can log in)
    $r.LanA = ''

    # GET a Core Manager API path. Tries with the token we have (or none); only if the Core
    # answers 401 does it log in, then tries once more. Cores without Access Control never
    # need a login at all.
    function Invoke-CoreGet([string]$Path) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                $wr = [System.Net.HttpWebRequest]::Create("https://$Ip$Path")
                $wr.Timeout = $TimeoutMs; $wr.ReadWriteTimeout = $TimeoutMs
                $wr.Accept = 'application/json'
                if ($r.Auth) { $wr.Headers.Add('Authorization', $r.Auth) }
                $resp = $wr.GetResponse()
                $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
                $resp.Close()
                return @{ Code = 200; Body = $body }
            }
            catch [System.Net.WebException] {
                $code = 0
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -eq 401 -and $attempt -eq 1 -and $User) {
                    $login = Get-CoreAuth $Ip $User $Pass $TimeoutMs
                    if ($login.Auth) { $r.Auth = $login.Auth; continue }     # logged in - try again
                    $r.Log += "Core Manager $($login.Note)"
                }
                if ($code -eq 401) { $r.NeedsLogin = $true }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
            catch { return @{ Code = 0; Body = $_.Exception.Message } }
        }
    }

    # Pull the firmware version out of a reply. Core Manager sends it as
    #   "firmware": { "name": "10.4.1", "build": "..." }
    # (Older/other replies may use a plain string; those are handled too.)
    function Get-FirmwareFrom([string]$Body) {
        try {
            $j = $Body | ConvertFrom-Json
            if ($j -is [array]) { $j = $j[0] }
            foreach ($cand in @($j.firmware.name, $j.firmware.version, $j.firmware, $j.firmwareVersion, $j.softwareVersion)) {
                if ($cand -is [string] -and $cand -match '^\s*v?(\d+\.\d+(\.\d+)*)') { return $Matches[1] }
            }
        } catch { }
        $m = [regex]::Match($Body, '"firmware"\s*:\s*\{[^{}]*?"(?:name|version)"\s*:\s*"v?(\d+\.\d+(?:\.\d+)*)"')
        if ($m.Success) { return $m.Groups[1].Value }
        $m = [regex]::Match($Body, '"(?:firmwareVersion|fwVersion|softwareVersion)"\s*:\s*"v?(\d+\.\d+(?:\.\d+)*)"')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }

    # --- Firmware: try each known path until one gives a version ---
    foreach ($ep in $Endpoints) {
        $g = Invoke-CoreGet $ep
        if ($g.Code -eq 200) {
            # The same reply carries the Core's own name ("name": "Room101-Core") - Designer's
            # F8 search matches that, so keep it.
            try {
                $j = $g.Body | ConvertFrom-Json
                if ($j -is [array]) { $j = $j[0] }
                if ($j.name -is [string] -and $j.name) { $r.CoreName = $j.name }
                elseif ($j.hostname -is [string] -and $j.hostname) { $r.CoreName = $j.hostname }
            } catch { }
            $fw = Get-FirmwareFrom $g.Body
            if ($fw) { $r.Firmware = $fw; $r.Log += "Firmware $fw from $ep"; break }
            $snippet = $g.Body.Substring(0, [Math]::Min(160, $g.Body.Length)) -replace '\s+', ' '
            $r.Log += "$ep -> 200 but no firmware field: $snippet"
        }
        elseif ($g.Code -eq 401) { $r.Log += "$ep -> 401 (Core has Access Control on; needs a Core login)"; break }
        elseif ($g.Code)         { $r.Log += "$ep -> HTTP $($g.Code)" }
        else                     { $r.Log += "$ep -> $($g.Body)"; break }      # network trouble - don't keep trying
    }

    # --- LAN A address, from the Core's own network settings ---
    if ($r.Firmware) {
        $g = Invoke-CoreGet '/api/v0/cores/self/config/network'
        if ($g.Code -eq 200) {
            try {
                $net = $g.Body | ConvertFrom-Json
                $lanA = @($net.interfaces) | Where-Object { $_.id -eq 'LAN A' -or $_.name -eq 'LAN A' } | Select-Object -First 1
                if ($lanA -and $lanA.ipAddress) { $r.LanA = [string]$lanA.ipAddress; $r.LanAMask = [string]$lanA.netMask }
            } catch { }
        }
    }

    return $r
}

# A pool of background threads, and a list of queries in flight.
$Pool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
$Pool.Open()
$Pending = New-Object System.Collections.ArrayList
$script:FailCount = @{}      # Core -> how many checks in a row it hasn't answered
$script:Tokens    = @{}      # IP -> Core Manager login token, reused so we don't hit the Core's login limit (HTTP 429)

# Start a query for each Core passed in.
# -Force : read firmware/LAN A from Core Manager even if nothing changed (right-click > Check now).
function Start-CoreQuery([QSystem[]]$Targets, [switch]$Force) {
    foreach ($s in $Targets) {
        $ip = Get-QueryIp $s                       # LAN B unless "Links use" = LAN A
        if (-not $ip) { Write-Log "Skip '$($s.Name)': no valid IP"; continue }

        # Does this Core need a Core Manager read (= a login) this time? See STEP B in the query.
        $needDetails = [bool]$Force -or -not $s.Firmware -or -not $s.DesignCode -or -not $s.CoreName
        # Was it down since we last looked? (A firmware update means a reboot, so re-read firmware.)
        # 'Not heard' = it stopped announcing at some point (section 7g remembers that in WentDown).
        $wasDown     = [bool]($s.State -and $s.State -notmatch 'Active|Standby|Online|Querying|Heard on LAN A') -or $script:WentDown.ContainsKey($s.Id)
        $script:WentDown.Remove($s.Id)
        $login       = Get-CoreLoginFor $s           # this Core's own login, or the global one

        $ps = [powershell]::Create()
        $ps.RunspacePool = $Pool
        [void]$ps.AddScript($QueryScript.ToString()).
                AddArgument($ip).AddArgument([string[]]$Settings.FirmwareEndpoints).
                AddArgument($QrcPort).AddArgument($QueryTimeoutMs).
                AddArgument($login.User).AddArgument($login.Pass).
                AddArgument([string]$script:Tokens[$ip]).
                AddArgument($needDetails).AddArgument([string]$s.DesignCode).AddArgument($wasDown)

        $s.State = 'Querying...'
        [void]$Pending.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); System = $s })
    }
    if ($Pending.Count -gt 0) { $script:PollTimer.Start() }
}

# Called by a timer on the UI thread: collect finished queries and update the grid.
function Receive-CoreQueries {
    foreach ($job in @($Pending)) {
        if (-not $job.Handle.IsCompleted) { continue }
        $s = $job.System
        try {
            $out = $job.PS.EndInvoke($job.Handle)
            $r = $out[0]
            if ($r.Platform)   { $s.Platform   = $r.Platform }
            if ($r.DesignName) { $s.DesignName = $r.DesignName }
            if ($r.DesignCode) { $s.DesignCode = $r.DesignCode }
            if ($r.CoreName)   {
                # Auto-added rows are named from the (lowercase) announcement; use the proper case.
                if ($s.Name -eq $r.CoreName -and $s.Name -cne $r.CoreName) { $s.Name = $r.CoreName }
                $s.CoreName = $r.CoreName
            }
            if ($r.Firmware)   { $s.Firmware   = $r.Firmware }     # keep last known value if not found this time

            # Rows still called "(imported) x.x.x.x" (or blank) get the Core's design name.
            # Names you typed yourself are never overwritten.
            if ($r.DesignName -and (-not $s.Name -or $s.Name -like '(imported)*' -or $s.Name -eq 'New system')) {
                $s.Name = $r.DesignName
            }
            if ($r.Ok) { $s.State = $(if ($r.State) { $r.State } else { 'Online' }) } else { $s.State = 'No response' }
            if ($r.Ok) { $script:FailCount[$s] = 0 } else { $script:FailCount[$s] = 1 + [int]$script:FailCount[$s] }
            if ($r.NeedsLogin) { $script:SawNeedsLogin = $true }
            if ($r.Auth) { $script:Tokens[$r.Ip] = $r.Auth }      # keep the token for next time

            # LAN A address straight from the Core (it's static, so a change is worth noting).
            # Its netmask also tells us the LAN A network, if we don't know it yet.
            if ($r.LanA) { Learn-LanASubnet $r.LanA $r.LanAMask "Core '$($s.Name)'" }
            if ($r.LanA -and $s.LanA.Trim() -ne $r.LanA) {
                if ($s.LanA) { Write-Log "[$($s.Name)] LAN A address changed: $($s.LanA) -> $($r.LanA)" }
                $s.LanA = $r.LanA
            }
            $s.LastChecked = Get-Date -Format 'yyyy-MM-dd HH:mm'
            # Log only what's worth reading: skip the routine "QRC OK" line, and once a Core has
            # been reported as not answering, don't repeat that every check.
            foreach ($line in $r.Log) {
                if ($line -like 'QRC OK*') { continue }
                if (-not $r.Ok -and [int]$script:FailCount[$s] -gt 1) { continue }
                Write-Log "[$($s.Name) $($r.Ip)] $line"
            }
        }
        catch { $s.State = 'Error'; Write-Log "[$($s.Name)] $($_.Exception.Message)" }
        finally { $job.PS.Dispose(); $Pending.Remove($job) }

        Update-DesignerMatch $s

        # You launched this Core before its firmware was known: launch it now.
        if ($script:LaunchAfter.ContainsKey($s.Id)) {
            $script:LaunchAfter.Remove($s.Id)
            if ($s.Firmware) { Start-DesignerForSystem $s }
            else { Set-Status "Couldn't read the firmware of '$($s.Name)' ($($s.State)). Check its Core login, or launch a version from the right-hand list." }
        }
    }
    if ($Pending.Count -eq 0) {
        $script:PollTimer.Stop()
        Invoke-AfterQuery          # merge / firmware / moved Cores / sync  (section 7e)
    }
}

# Refresh the "Designer" column for one Core (or all, if none given).
function Update-DesignerMatch([QSystem]$One) {
    $list = if ($One) { @($One) } else { @($Systems) }
    foreach ($s in $list) {
        $m = Find-DesignerForFirmware $s.Firmware
        $s.DesignerMatch  = $m.Text
        $s.DesignerDetail = $m.Detail
    }
}

#endregion

#region ==== 7c. TIDY-UP: MERGE LAN A / LAN B DUPLICATE ROWS ===========
<#
  A Core hard-linked by BOTH addresses shows up as two rows: one with only LAN B,
  one with only LAN A. After a Query, both report the same design name and platform,
  which tells us they're the same box. This finds those pairs and folds the LAN A
  address into the LAN B row, then removes the extra row. Nothing is lost: the LAN A
  address is kept in that row's LAN A column.
#>
function Find-DuplicatePairs {
    $pairs = New-Object System.Collections.Generic.List[object]
    $onlyA = @($Systems | Where-Object { $_.LanA -and -not $_.IpAddress -and $_.DesignName })
    foreach ($a in $onlyA) {
        $b = $Systems | Where-Object {
            $_ -ne $a -and $_.IpAddress -and (-not $_.LanA -or $_.LanA -eq $a.LanA) -and
            $_.DesignName -eq $a.DesignName -and $_.Platform -eq $a.Platform
        }
        $b = @($b)
        if ($b.Count -eq 1) { $pairs.Add([pscustomobject]@{ B = $b[0]; A = $a }) }   # skip anything ambiguous
    }
    return $pairs
}

# Runs automatically after every check. Only merges clear-cut pairs (exactly one match).
function Invoke-AutoMerge {
    $pairs = @(Find-DuplicatePairs)
    foreach ($p in $pairs) {
        $p.B.LanA = $p.A.LanA
        if ($p.A.Notes -and -not $p.B.Notes) { $p.B.Notes = $p.A.Notes }
        [void]$Systems.Remove($p.A)
        Write-Log "Merged '$($p.B.DesignName)': LAN B $($p.B.IpAddress) + LAN A $($p.B.LanA) are the same Core"
    }
    if ($pairs.Count) { Save-AppData }
    return $pairs.Count
}

#endregion

#region ==== 7d. FIND THE FIRMWARE API ON A CORE ======================
<#
  QSC doesn't document a "firmware version" endpoint, but Core Manager (the Core's
  web page) shows the firmware, so its own JavaScript must ask for it somewhere.
  This probe, run against one Core:

    1) downloads Core Manager's start page and the .js files it loads,
    2) pulls out every "/api/v.../..." address mentioned in that code,
    3) tries the likely-looking ones (status / system / info / version / firmware ...),
    4) if a reply contains a version number, saves that address as the first one
       Query uses from now on.

  Everything it sees is written to api-probe.txt in the data folder.
  If the Core has Access Control turned on, the API answers 401 (login needed) -
  try a Core without Access Control, or we add a login step later.
#>
$ProbeScript = {
    param([string]$Ip, [int]$TimeoutMs, [string]$User = '', [string]$Pass = '')

    # ---- Core Manager login (only when you've saved a Core login in Settings) ----
    # POST /api/v0/logon with {"username","password"} -> the reply holds a token, which is
    # sent as "Authorization: Bearer <token>" on later requests. The password is never logged.
    function Get-CoreAuth([string]$Ip, [string]$User, [string]$Pass, [int]$TimeoutMs) {
        $out = @{ Auth = ''; Note = '' }
        if (-not $User) { return $out }
        try {
            $wr = [System.Net.HttpWebRequest]::Create("https://$Ip/api/v0/logon")
            $wr.Method = 'POST'; $wr.ContentType = 'application/json'; $wr.Accept = 'application/json'
            $wr.Timeout = $TimeoutMs; $wr.ReadWriteTimeout = $TimeoutMs
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ username = $User; password = $Pass } | ConvertTo-Json -Compress))
            $wr.ContentLength = $bytes.Length
            $rs = $wr.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
            $resp = $wr.GetResponse()
            $txt  = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $resp.Close()
            # The token may come back as JSON ({"token":"..."}) or as a bare line of text.
            $m = [regex]::Match($txt, '"(?:token|access_token|accessToken)"\s*:\s*"([^"]+)"')
            if ($m.Success) { $out.Auth = "Bearer $($m.Groups[1].Value)" }
            elseif ($txt.Trim() -and $txt.Trim() -notmatch '[\s\{\}<]') { $out.Auth = "Bearer $($txt.Trim().Trim('"'))" }
            else { $out.Note = "login replied but no token found ($($txt.Length) chars)" }
        }
        catch [System.Net.WebException] {
            $code = ''; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            $out.Note = if ($code -eq 401 -or $code -eq 403) { 'login rejected - check the Core username/password' } else { "login failed: $code $($_.Exception.Message)" }
        }
        catch { $out.Note = "login failed: $($_.Exception.Message)" }
        return $out
    }

    $report = New-Object System.Collections.Generic.List[string]
    $result = @{ Report = $report; Endpoint = ''; Version = '' }
    $verPattern = '"firmware"\s*:\s*(?:\{[^{}]*?"(?:name|version)"\s*:\s*)?"v?(\d+\.\d+(?:\.\d+)*)"'

    # Small GET helper: returns @{ Code; Body } and never throws.
    function Get-Url([string]$Url) {
        try {
            $wr = [System.Net.HttpWebRequest]::Create($Url)
            $wr.Timeout = $TimeoutMs; $wr.ReadWriteTimeout = $TimeoutMs
            if ($login.Auth) { $wr.Headers.Add('Authorization', $login.Auth) }
            $resp = $wr.GetResponse()
            $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return @{ Code = $code; Body = $body }
        } catch [System.Net.WebException] {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            return @{ Code = $code; Body = "$($_.Exception.Message)" }
        } catch { return @{ Code = 0; Body = "$($_.Exception.Message)" } }
    }

    $base = "https://$Ip"

    # Log in first if a Core login is saved.
    $login = Get-CoreAuth $Ip $User $Pass $TimeoutMs
    if ($User) {
        if ($login.Auth) { $report.Add("Logged in as '$User'.") } else { $report.Add("Login as '$User': $($login.Note)") }
    } else { $report.Add('No Core login saved - Cores with Access Control will answer 401.') }

    # ---- Step 1: start page + its scripts ----
    $root = Get-Url "$base/"
    $report.Add("GET / -> $($root.Code), $($root.Body.Length) chars")
    $scripts = @([regex]::Matches($root.Body, '<script[^>]+src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $report.Add("Scripts: $($scripts -join ', ')")

    $code = $root.Body
    foreach ($src in $scripts) {
        $url = if ($src -match '^https?://') { $src } elseif ($src.StartsWith('/')) { "$base$src" } else { "$base/$src" }
        $js = Get-Url $url
        $report.Add("GET $src -> $($js.Code), $($js.Body.Length) chars")
        $code += "`n" + $js.Body
    }

    # ---- Step 2: every API path mentioned in the code ----
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($m in [regex]::Matches($code, '["''`](/?api/v\d+/[A-Za-z0-9_\-/\.\$\{\}:]+)')) {
        $p = $m.Groups[1].Value; if (-not $p.StartsWith('/')) { $p = "/$p" }
        [void]$paths.Add($p)
    }
    foreach ($m in [regex]::Matches($code, '["''`]/?((?:cores|systems|system|status|device)/[A-Za-z0-9_\-/]+)')) {
        [void]$paths.Add("/api/v0/$($m.Groups[1].Value)")
    }
    $report.Add('')
    $report.Add("API paths found in Core Manager code ($($paths.Count)):")
    foreach ($p in $paths) { $report.Add("   $p") }

    # ---- Step 3: try the likely ones (no template placeholders; a few known guesses too) ----
    $try = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        if ($p -match '[\$\{:]') { continue }
        if ($p -match 'status|system|info|version|firmware|about|self$|design|core$') { $try.Add($p) }
    }
    foreach ($g in '/api/v0/cores/self', '/api/v0/cores/self/status', '/api/v0/cores/self/info', '/api/v0/cores/self/config',
                   '/api/v0/cores/self/firmware', '/api/v0/cores/self/version', '/api/v0/cores/self/details',
                   '/api/v0/cores/self/config/network', '/api/v0/cores/self/config/system', '/api/v0/systems',
                   '/api/v0/systems/1', '/api/v0/systems/1/status', '/api/v0/cores', '/api/v0/system/info', '/api/v0/version') {
        if (-not $try.Contains($g)) { $try.Add($g) }
    }

    $report.Add('')
    $report.Add('Tried:')
    foreach ($p in ($try | Select-Object -First 50)) {
        $r = Get-Url "$base$p"
        $snippet = ($r.Body -replace '\s+', ' ')
        if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
        $report.Add("   $p -> $($r.Code)  $snippet")

        if ($r.Code -eq 200 -and -not $result.Endpoint) {
            $m = [regex]::Match($r.Body, $verPattern, 'IgnoreCase')
            if ($m.Success) { $result.Endpoint = $p; $result.Version = $m.Groups[1].Value }
        }
    }
    return $result
}

$script:ProbeJob = $null

function Start-ApiProbe([QSystem]$s, [switch]$Auto) {
    if (-not $s) { Set-Status 'Select a Core that answers (State = Active) first.'; return }
    if ($script:ProbeJob) { Set-Status 'A probe is already running.'; return }
    $ip = Get-QueryIp $s
    if (-not $ip) { Set-Status 'That row has no valid IP.'; return }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    $login = Get-CoreLoginFor $s
    [void]$ps.AddScript($ProbeScript.ToString()).AddArgument($ip).AddArgument(4000).
            AddArgument($login.User).AddArgument($login.Pass)
    $script:ProbeJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); System = $s; Ip = $ip; Auto = [bool]$Auto }
    Set-Status "Probing Core Manager on $ip for the firmware API (can take up to a minute)..."
    $script:ProbeTimer.Start()
}

function Receive-ApiProbe {
    $j = $script:ProbeJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $script:ProbeTimer.Stop()
    $script:ProbeJob = $null

    $Settings.FirmwareProbeDone = $true     # don't repeat this every start; the button can re-run it
    try { $r = $j.PS.EndInvoke($j.Handle)[0] } catch { Set-Status "Probe failed: $($_.Exception.Message)"; Save-AppData; return }
    finally { $j.PS.Dispose() }

    $file = Join-Path $AppFolder 'api-probe.txt'
    $header = "API probe of $($j.Ip) ($($j.System.Name)) at $(Get-Date)`r`n"
    Write-TextNoBom $file ($header + ($r.Report -join "`r`n"))

    if ($r.Endpoint) {
        # Put the winner first and save, so every Query uses it.
        $Settings.FirmwareEndpoints = [string[]](@($r.Endpoint) + @($Settings.FirmwareEndpoints | Where-Object { $_ -ne $r.Endpoint }))
        Save-AppData
        Write-Log "Firmware API found: $($r.Endpoint) (reported $($r.Version)). Re-checking every Core to fill in firmware."
        Start-RefreshCycle -Check
    } else {
        Save-AppData
        Write-Log "Couldn't find the firmware API automatically - details in $file."
        if ($j.Auto) { Invoke-AfterQuery }      # carry on with the rest of the automatic steps
        else { Set-Status "No firmware version found. Details saved to $file." }
    }
}

#endregion

#region ==== 7b. (removed) FIND A CORE THAT MOVED ======================
<#
  Older versions could scan a whole address range for a Core whose LAN B address changed.
  That knocked on hundreds of addresses at once, which looks like a port scan to network
  security tools, so it's gone. A Core's new LAN B address now comes from its own
  announcement on LAN A (section 7g). Without a network card on LAN A, edit the address
  by hand (or remove and re-add the Core) when it moves.
#>

#region ==== 7f. CORE LOGIN (for reading firmware) =====================
<#
  Cores with Access Control answer the Core Manager API with "401 Unauthorized"
  until you log in. You enter a Core username/password once (Settings > Core login);
  it is used for every Core.

  The password is saved in systems.json ENCRYPTED with Windows DPAPI
  (ConvertFrom-SecureString with no key). Only your Windows account on this PC can
  decrypt it - copying the file to another PC or user won't reveal it.
#>
$script:CoreUser = ''
$script:CorePass = ''

# Load the saved login into memory (called at startup, after the settings load).
function Restore-CoreLogin {
    $script:Tokens = @{}        # tokens belong to the old login
    $script:CoreUser = [string]$Settings.CoreUser
    $script:CorePass = ''
    if ($script:CoreUser -and $Settings.CorePassEnc) {
        try {
            $secure = ConvertTo-SecureString ([string]$Settings.CorePassEnc)
            $script:CorePass = (New-Object System.Management.Automation.PSCredential('x', $secure)).GetNetworkCredential().Password
        } catch { Write-Log "Couldn't read the saved Core password (was it saved under another Windows account?). Enter it again in Settings." }
    }
}

# Ask for the login with Windows' own credential prompt, save it encrypted, and re-check.
function Set-CoreLogin {
    $cred = $null
    try {
        $credArgs = @{ Message = 'Q-SYS Core login (a Core Manager user). Used to read each Core''s firmware version. Saved encrypted for your Windows account only.' }
        if ($Settings.CoreUser) { $credArgs.UserName = $Settings.CoreUser }      # pre-fill if changing it
        $cred = Get-Credential @credArgs
    } catch { }
    if (-not $cred) { return }
    $Settings.CoreUser    = $cred.UserName.TrimStart('')
    $Settings.CorePassEnc = ConvertFrom-SecureString $cred.Password
    $Settings.FirmwareProbeDone = $false        # look for the firmware API again, now logged in
    Restore-CoreLogin
    Save-AppData
    Update-LoginLabel
    Write-Log "Core login saved for user '$($Settings.CoreUser)'. Re-checking Cores..."
    Start-RefreshCycle -Check
}

# Right-click > "Core login for this Core..." (for Cores that don't use the global login)
function Set-CoreLoginForRow([QSystem]$s) {
    if (-not $s) { Set-Status 'Select a Core first.'; return }
    $e = Get-CoreLoginEntry $s
    if ($e) {
        $ans = [System.Windows.MessageBox]::Show("'$($s.Name)' has its own login ('$($e.User)').`n`nYes = change it`nNo = remove it (use the global login)`nCancel = leave it", 'Core login for this Core', 'YesNoCancel')
        if ($ans -eq 'Cancel') { return }
        $Settings.CoreLogins = @($Settings.CoreLogins | Where-Object { $_.Id -ne $s.Id })
        $script:RowPass.Remove($s.Id)
        if ($ans -eq 'No') {
            Save-AppData; Write-Log "'$($s.Name)' now uses the global Core login."
            Start-CoreQuery ([QSystem[]]@($s)) -Force
            return
        }
    }
    $cred = $null
    try { $cred = Get-Credential -Message "Core Manager login for '$($s.Name)' only. Saved encrypted for your Windows account." } catch { }
    if (-not $cred) { return }
    $Settings.CoreLogins = @(@($Settings.CoreLogins) + [pscustomobject]@{ Id = $s.Id; User = $cred.UserName.TrimStart('\'); PassEnc = (ConvertFrom-SecureString $cred.Password) })
    $script:RowPass.Remove($s.Id)
    foreach ($ip in @($s.IpAddress, $s.LanA)) { if ($ip) { $script:Tokens.Remove($ip.Trim()) } }
    Save-AppData
    Write-Log "'$($s.Name)' now uses its own Core login ('$($cred.UserName)'). Checking it..."
    Start-CoreQuery ([QSystem[]]@($s)) -Force
}

function Clear-CoreLogin {
    $Settings.CoreUser = ''; $Settings.CorePassEnc = ''
    Restore-CoreLogin; Save-AppData; Update-LoginLabel
    Write-Log 'Core login removed.'
}

#endregion

#region ==== 7e. THE AUTOMATIC REFRESH CYCLE ==========================
<#
  Runs at startup and then every RefreshMinutes. You never need to press anything:

    Start-RefreshCycle
      1. look for newly installed Designer versions
      2. import hard links that were added inside Designer
      3. check every enabled Core (background)            --> when all have answered:
    Invoke-AfterQuery
      4. merge Cores listed twice (LAN A row + LAN B row)
      5. first time only: find the firmware API, then re-check everything
      6. any Core that stopped answering: look for it nearby (new DHCP address)
      7. write Designer's hard links if anything changed
         (if Designer is open, wait until it closes - checked every 15 s)
      8. refresh the tray menu and the status line
#>
$script:SyncPending = $false   # changes waiting for Designer to close

function Start-RefreshCycle([switch]$Check) {
    # Don't start a new cycle while one is still running.
    if ($Pending.Count -gt 0 -or $script:ProbeJob) { return }
    $script:SawNeedsLogin = $false

    # 1) Designer versions (cheap: just looks at Program Files\QSC)
    $script:Designers = Find-DesignerInstalls
    if ($script:DesignerList) { $script:DesignerList.ItemsSource = $script:Designers }

    # 2) Links someone added inside Designer
    try {
        $n = Import-DesignerHardLinks
        if ($n) { Write-Log "Picked up $n new hard link(s) that were added in Designer."; Save-AppData }
    } catch { Write-Log "Couldn't read Designer's hard links: $($_.Exception.Message)" }

    # 3) Without -Check: listen only. Nothing is sent to the Cores, so nothing lands in their
    #    event logs. What we know comes from their announcements (section 7g).
    if (-not $Check) { Complete-PassiveRefresh; return }

    # 3) With -Check (you asked, or Options > automatic checks): check every enabled Core
    $script:LastNetCheck = Get-Date
    $targets = [QSystem[]]@($Systems | Where-Object { $_.Enabled -and (Get-QueryIp $_) })
    if ($targets.Count -gt 0) {
        Set-Status "Checking $($targets.Count) Cores..."
        Start-CoreQuery $targets
    } else {
        Invoke-AfterQuery
    }
}

# The quiet refresh: no network traffic to the Cores. Sync hard links, tray and status line.
function Complete-PassiveRefresh {
    Invoke-AutoSync
    Update-DesignerMatch
    Update-TrayMenu
    $heard = @($Systems | Where-Object { $_.Enabled -and $_.State -match 'Active|Standby|Online|Heard on LAN A' }).Count
    $quiet = @($Systems | Where-Object { $_.Enabled -and $_.State -eq 'Not heard' }).Count
    $note = if ($script:SyncPending) { '  Hard-link changes will be written when Designer closes.' } else { '' }
    $how  = if ($script:QdpSocket) { "listening on LAN A: $heard heard, $quiet not heard." } else { 'not listening on LAN A (see Options).' }
    Set-Status ("Updated {0}, {1} Check all now (F5) reads designs and firmware.{2}" -f (Get-Date -Format 'h:mm tt'), $how, $note)
}

# The refresh timer (every 5 min): quiet refresh, or a full check if Options asks for one.
function Invoke-RefreshTick {
    $every = [int]$Settings.AutoCheckMinutes
    if ($every -gt 0 -and (-not $script:LastNetCheck -or ((Get-Date) - $script:LastNetCheck).TotalMinutes -ge ($every - 1))) {
        Start-RefreshCycle -Check
    } else {
        Start-RefreshCycle
    }
}

function Invoke-AfterQuery {
    Save-AppData

    # 4) Same Core listed twice?
    $merged = Invoke-AutoMerge

    # 5) Firmware API: once, using the first Core that answered
    if (-not $Settings.FirmwareProbeDone -and -not ($Systems | Where-Object { $_.Firmware })) {
        $first = $Systems | Where-Object { $_.State -match 'Active|Standby|Online' } | Select-Object -First 1
        if ($first -and -not $script:ProbeJob) {
            Write-Log "Looking for the firmware API on '$($first.Name)' (one-time setup)..."
            Start-ApiProbe $first -Auto
            return                   # the probe re-starts the cycle (or continues it) when done
        }
    }

    # 6) Missing Cores: nothing to do here. A moved Core's new LAN B address arrives in its
    #    announcement on LAN A (section 7g).

    # 7) Designer's hard links
    Invoke-AutoSync

    # 8) Tray + status
    Update-DesignerMatch
    Update-TrayMenu
    $on  = @($Systems | Where-Object { $_.Enabled -and $_.State -match 'Active|Standby|Online|Heard on LAN A' }).Count
    $off = @($Systems | Where-Object { $_.Enabled -and $_.State -notmatch 'Active|Standby|Online|Heard on LAN A' }).Count
    $note = if ($script:SyncPending) { '  Hard-link changes will be written when Designer closes.' } else { '' }
    if ($script:SawNeedsLogin -and -not ($Systems | Where-Object { $_.Firmware })) {
        $note += '  Firmware needs a Core login: Settings and log > Core login.'
    }
    Set-Status ("Updated {0}:  {1} Cores answering, {2} not.{3}" -f (Get-Date -Format 'h:mm tt'), $on, $off, $note)
}

# Write Designer's hard links if they differ from the list - no questions asked.
function Invoke-AutoSync {
    if (-not $Settings.AutoSync -or -not $script:DataLoaded) { return }

    # Pick up anything added in Designer since the last check, so writing never wipes it out.
    try { if (Import-DesignerHardLinks) { Save-AppData } } catch { }

    $new = Build-DesignerJson
    $oldHL = ''; $oldNames = ''
    if (Test-Path $HardLinkFile)      { $oldHL    = (Get-Content $HardLinkFile -Raw).Trim() }
    if (Test-Path $HardLinkNamesFile) { $oldNames = (Get-Content $HardLinkNamesFile -Raw).Trim() }
    if ($oldHL -eq $new.HardLink -and $oldNames -eq $new.Names) {
        $script:SyncPending = $false
        if ($script:LastSynced.Count -eq 0) { Update-LastSynced }
        return
    }

    # Designer may rewrite the file when it closes, so wait for it.
    if (Get-RunningDesigner) {
        if (-not $script:SyncPending) { Write-Log 'Hard-link changes are waiting - they will be written when Q-SYS Designer closes.' }
        $script:SyncPending = $true
        return
    }

    try   { Write-Log (Sync-DesignerHardLinks); $script:SyncPending = $false }
    catch { Write-Log "Hard-link sync failed: $($_.Exception.Message)" }
}

#endregion

#region ==== 7g. DEVICES TAB: Q-SYS DISCOVERY (QDP) ON LAN A ==============
<#
  Every Q-SYS Core and peripheral announces itself about once a second with QDP: a small
  XML packet sent to multicast 224.0.23.175, UDP port 2467. It contains the device's name,
  type, part number and LAN A / LAN B addresses, e.g.

      <QDP><device><name>core-110f-dddd</name><type>core</type><part_number>Core 110f</part_number>
                   <lan_a_ip>192.168.1.118</lan_a_ip><lan_b_ip/> ...</device></QDP>

  We listen on the network card whose address is inside the LAN A range (Settings: LanASubnet),
  so only the AV network is heard - not other groups' Q-SYS gear on a shared building network.
  If the LAN A range isn't known yet, we listen on every network until the first device tells us.
  It's passive: we only listen. (Windows may ask once whether PowerShell may receive on the
  network - allow it on Private networks.)

  Bonus for Cores in your list: if a Core's announcement shows a different LAN B address than
  we have, that's a DHCP change - the row and Designer's hard links are updated right away.
#>
$QdpGroup = '224.0.23.175'
$QdpPort  = 2467

$Devices            = New-Object 'System.Collections.ObjectModel.ObservableCollection[QDevice]'
$script:DeviceIndex = @{}                 # device ref/name -> QDevice
$script:QdpSocket   = $null
$script:QdpStatus   = ''
$script:QdpBuffer   = New-Object byte[] 65535
$script:QdpTicks    = 0

# Which local network card is on the LAN A network?
function Find-LanAInterface {
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.ToString()
            if (Test-InSubnet $ip $Settings.LanASubnet) { return @{ Ip = $ip; Nic = $nic.Name } }
        }
    }
    return $null
}

function Update-DevStatus {
    if (-not $script:DevStatus) { return }
    $live = @($Devices | Where-Object { $_.Status -eq 'Live' }).Count
    $script:DevStatus.Text = "$($script:QdpStatus)    |    $($Devices.Count) devices heard, $live announcing now"
}

function Stop-QdpListener {
    if ($script:QdpSocket) { try { $script:QdpSocket.Close() } catch { } ; $script:QdpSocket = $null }
}

# This PC's addresses, as one string (to notice when a cable is plugged in or a network changes).
function Get-NetSnapshot { return ((Get-LocalNetworks | ForEach-Object { $_.Cidr + '@' + $_.Ip } | Sort-Object) -join ' ') }

# Every 15 s (housekeeping timer): a laptop moved between networks, a card came up, ...
# -> pick the listening card again. Also ends the 5-minute "listen everywhere" search.
function Test-NetworkChange {
    if (-not $Settings.QdpListen) { return }
    $now = Get-NetSnapshot
    if ($now -ne $script:NetSnapshot) { Write-Log 'Network connections changed - choosing the LAN A card again.'; Start-QdpListener; return }
    if (-not $Settings.LanASubnet -and $script:ListenAllUntil -and (Get-Date) -gt $script:ListenAllUntil -and $script:QdpSocket) {
        $script:ListenAllUntil = $null
        Stop-QdpListener
        $script:QdpStatus = 'No Q-SYS announcements heard in 5 minutes, so no LAN A card was found - not listening. Set the LAN A network in Options, or use Check all now (F5).'
        Write-Log $script:QdpStatus; Update-DevStatus
    }
}

function Start-QdpListener {
    Stop-QdpListener
    if (-not $Settings.QdpListen) { $script:QdpStatus = 'Not listening (turned off in Options).'; Update-DevStatus; return }

    # Not known yet? See if one of this PC's cards sits on the same network as a LAN A address
    # already in the list. Then that card is LAN A, and we never listen on the others.
    if (-not $Settings.LanASubnet) {
        foreach ($n in Get-LocalNetworks) {
            $hitCore = $Systems | Where-Object { (Test-IpAddress $_.LanA) -and (Test-InSubnet $_.LanA.Trim() $n.Cidr) } | Select-Object -First 1
            if ($hitCore) { Learn-LanASubnet $hitCore.LanA.Trim() '' "this PC's card $($n.Ip), on the same network as '$($hitCore.Name)'"; return }   # (restarts the listener)
        }
    }
    $script:NetSnapshot = Get-NetSnapshot

    # Which card(s) to listen on: the LAN A one if we know the LAN A network. Otherwise all of
    # them, but only for 5 minutes, to hear a first Core announce itself (that tells us which
    # card is LAN A). A PC with no card on LAN A then stops listening instead of sitting on the
    # enterprise network.
    if ($Settings.LanASubnet) {
        $hit = Find-LanAInterface
        if (-not $hit) {
            $script:QdpStatus = "No network card on the LAN A network ($($Settings.LanASubnet)) - not listening. Use Check all now (F5); listening starts by itself if this PC joins LAN A."
            Write-Log $script:QdpStatus; Update-DevStatus; return
        }
        $cards = @($hit)
    } else {
        $cards = @(Get-LocalNetworks)
        if (-not $cards.Count) { $script:QdpStatus = 'No network connection to listen on.'; Update-DevStatus; return }
        $script:ListenAllUntil = (Get-Date).AddMinutes(5)
    }
    try {
        $sock = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        # Share the port: Designer listens on 2467 too, and both must be able to.
        $sock.ExclusiveAddressUse = $false
        $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $QdpPort)))
        # Join the QDP group on the chosen card(s).
        foreach ($card in $cards) {
            try {
                $mo = New-Object System.Net.Sockets.MulticastOption([System.Net.IPAddress]::Parse($QdpGroup), [System.Net.IPAddress]::Parse($card.Ip))
                $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $mo)
            } catch { }
        }
        $sock.Blocking = $false
        $script:QdpSocket = $sock
        $script:QdpStatus = if ($Settings.LanASubnet) { "Listening for Q-SYS devices on $($cards[0].Ip) ($($cards[0].Nic))" }
                            else { "Listening on all networks until the LAN A network is detected ($(($cards | ForEach-Object { $_.Ip }) -join ', '))" }
        Write-Log $script:QdpStatus
        $script:QdpTimer.Start()
        Start-WsdDiscovery                      # PTZ-IP cameras too, if switched on (follows the LAN A card)
    } catch {
        $script:QdpStatus = "Couldn't listen for Q-SYS devices: $($_.Exception.Message)"
        Write-Log $script:QdpStatus
    }
    Update-DevStatus
}

# Timer tick (twice a second): read every packet waiting, then (every ~5 s) mark quiet devices.
function Receive-QdpPackets {
    $sock = $script:QdpSocket
    if ($sock) {
        $count = 0
        try {
            while ($sock.Available -gt 0 -and $count -lt 300) {
                [System.Net.EndPoint]$from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $n = $sock.ReceiveFrom($script:QdpBuffer, [ref]$from)
                $count++
                $text = [System.Text.Encoding]::UTF8.GetString($script:QdpBuffer, 0, $n).Trim([char]0, ' ', "`r", "`n")
                Update-DeviceFromQdp $text $from.Address.ToString()
            }
        } catch { }
    }

    # PTZ-IP cameras (WS-Discovery): read their answers, and ask again every 30 s (60 ticks).
    $wsd = $script:WsdSocket
    if ($wsd) {
        $count = 0
        try {
            while ($wsd.Available -gt 0 -and $count -lt 100) {
                [System.Net.EndPoint]$from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $n = $wsd.ReceiveFrom($script:QdpBuffer, [ref]$from)
                $count++
                Update-DeviceFromWsd ([System.Text.Encoding]::UTF8.GetString($script:QdpBuffer, 0, $n)) $from.Address.ToString()
            }
        } catch { }
        # Ask again every 5 min (600 ticks), and only while you're looking at the Devices tab.
        if ($script:QdpTicks % 600 -eq 599 -and (Test-DevicesTabShowing)) { Send-WsdProbe }
    }

    Complete-AutoAdd                     # any new Cores heard this second (7i)

    $script:QdpTicks++
    if ($script:QdpTicks % 10 -eq 0) {
        $now = Get-Date
        foreach ($d in $Devices) {
            # QDP devices announce every second; PTZ-IP cameras only answer our 30-second question.
            $quietAfter = if ($d.Type -eq 'ws-discovery') { 330 } else { 15 }     # cameras answer only when asked (every 5 min)
            if ($d.Status -eq 'Live' -and ($now - $d.LastSeenTime).TotalSeconds -gt $quietAfter) {
                $d.Status = 'Not live'
                # A listed Core went quiet: show it on the Cores tab too.
                if ($d.InList) { foreach ($x in @($Systems | Where-Object { $_.Name -eq $d.InList -and $_.State -ne 'Querying...' })) { $x.State = 'Not heard'; $script:WentDown[$x.Id] = $true } }
                $d.LastSeen = 'Last heard ' + $d.LastSeenTime.ToString('ddd h:mm:ss tt')
            }
        }
        Update-DevStatus
    }
}

# A readable kind of device, from its model number (the announced "type" is coarse - most
# peripherals just say "ioframe"). Falls back to the announced type.
function Get-DeviceKind([string]$Model, [string]$Type) {
    switch -Regex ($Model.ToUpperInvariant()) {
        '\(CORE MODE\)|^CORE\b'              { return 'Core' }
        '^TSC|^TSW'                           { return 'Touch screen' }
        '^NV-'                                { return 'Video endpoint' }
        '^NC-|^PTZ'                           { return 'Camera' }
        '^(CX-Q|SPA-Q|DPA-Q|CXD|DCA)'         { return 'Amplifier' }
        '^QIO'                                { return 'I/O (QIO)' }
        'I/O|^IO-'                            { return 'I/O frame' }
        '^(AD-|AC-|NL-)'                      { return 'Speaker' }
        '^PS-|PAGE'                           { return 'Paging station' }
    }
    if ($Type -eq 'core') { return 'Core' }
    if ($Type -eq 'ioframe') { return 'Peripheral' }          # what most peripherals announce
    if ($Type) { return (Get-Culture).TextInfo.ToTitleCase($Type) }
    return 'Device'
}

# Turn one QDP packet into a Devices row (and learn from it if it's one of our Cores).
function Update-DeviceFromQdp([string]$Text, [string]$FromIp) {
    if ($Text -notlike '*<device>*') { return }
    try { [xml]$x = $Text } catch { return }

    foreach ($dev in @($x.SelectNodes('//device'))) {
        # Read a child tag's text, or '' if it's missing/empty.
        $get = { param($tag) $node = $dev.SelectSingleNode($tag); if ($node) { $node.InnerText.Trim() } else { '' } }

        $name  = & $get 'name'
        $type  = & $get 'type'
        $model = & $get 'part_number'; if (-not $model) { $model = & $get 'platform' }
        $lanA  = & $get 'lan_a_ip'
        $lanB  = & $get 'lan_b_ip'
        $ref   = & $get 'ref'
        $virt  = (& $get 'is_virtual') -match '^(true|1|yes)$'   # emulator / virtual Core
        if (-not $lanA -and -not $lanB) { $lanA = $FromIp }
        if (-not $Settings.LanASubnet -and $lanA) { Learn-LanASubnet $lanA '' "the Q-SYS device '$name'" }

        $key = if ($ref) { $ref } elseif ($name) { $name } else { $FromIp }
        $d = $script:DeviceIndex[$key]
        if (-not $d) {
            $d = New-Object QDevice
            $script:DeviceIndex[$key] = $d
            $Devices.Add($d)
        }
        $d.RawName = $name; $d.Type = $type; $d.Model = $model; $d.LanA = $lanA; $d.LanB = $lanB
        $d.Kind = Get-DeviceKind $model $type
        $d.IsVirtual = $virt
        $d.LastSeenTime = Get-Date            # (not shown every second - only when it goes quiet)
        if ($d.Status -ne 'Live') { $d.Status = 'Live'; $d.LastSeen = '' }

        # Cores: match to the Cores list. A listed Core shows its proper name (announcements are lowercase).
        $sys = $null
        if ($d.Kind -eq 'Core') { $sys = Update-CoreFromQdp $d | Select-Object -Last 1 }   # (only the returned row, nothing else)
        if ($d.Kind -eq 'Core' -and -not $sys) { Request-AutoAddCore $d }                # new Core? maybe add it (7i)
        $d.Name = if ($sys -and $sys.CoreName) { $sys.CoreName } else { $name }
    }
}

# A Core announced itself. If it's in our list, fill in what we learn - including a new LAN B address.
function Update-CoreFromQdp([QDevice]$d) {
    # Match by the static things first (LAN A address, Core name); LAN B is the one that moves.
    $sys = $null
    if ($d.LanA) { $sys = $Systems | Where-Object { $_.LanA -and $_.LanA.Trim() -eq $d.LanA } | Select-Object -First 1 }
    if (-not $sys -and $d.RawName) { $sys = $Systems | Where-Object { $_.CoreName -and $_.CoreName -eq $d.RawName } | Select-Object -First 1 }
    $matchedByLanB = $false
    if (-not $sys -and $d.LanB) {
        $sys = $Systems | Where-Object { $_.IpAddress.Trim() -eq $d.LanB } | Select-Object -First 1
        $matchedByLanB = [bool]$sys
    }
    $d.InList = if ($sys) { $sys.Name } else { '' }
    if (-not $sys) { return $null }

    # It's announcing, so it's up. Keep a real state from the last check (Active / Standby);
    # otherwise show that we heard it.
    if ($sys.State -notmatch 'Active|Standby|Online|Querying') { $sys.State = 'Heard on LAN A' }

    # (-ne ignores upper/lower case, so a lowercase announcement never replaces a properly-cased name)
    $changed = $false
    if ($d.RawName -and $sys.CoreName -ne $d.RawName) { $sys.CoreName = $d.RawName; $changed = $true }
    if ($d.LanA -and -not $sys.LanA) { $sys.LanA = $d.LanA; $changed = $true }

    # New campus address? (Only trust this when we recognized the Core by LAN A or name.)
    if (-not $matchedByLanB -and (Test-IpAddress $d.LanB) -and $sys.IpAddress.Trim() -ne $d.LanB -and
        -not (Test-InSubnet $d.LanB $Settings.LanASubnet)) {
        $old = $sys.IpAddress
        $sys.IpAddress = $d.LanB
        $script:FailCount[$sys] = 0
        $changed = $true
        Write-Log "'$($sys.Name)' announced a new LAN B address: $old -> $($d.LanB). Hard links updated."
        Show-TrayNote "'$($sys.Name)' changed address ($old -> $($d.LanB)). Designer's hard links were updated."
        Invoke-AutoSync
        Update-TrayMenu
    }
    if ($changed) { Save-AppData }
    return $sys
}

# Devices tab > right-click > "Add this Core to my list".
# -Quiet = called by auto-add / "Add all": the row is queued and Complete-AutoAdd checks the
# whole batch in one go (one save, one hard-link sync, one tray note).
function Add-CoreFromDevice([QDevice]$d, [switch]$Quiet) {
    if (-not $d -or $d.Kind -ne 'Core') { if (-not $Quiet) { Set-Status 'Pick a Core (Kind = Core) to add.' }; return }
    if ($d.InList) { if (-not $Quiet) { Set-Status "'$($d.Name)' is already in your list as '$($d.InList)'." }; return }
    $s = New-Object QSystem
    $s.Id = [guid]::NewGuid().ToString()
    $s.Name = $(if ($d.Name) { $d.Name } else { $d.RawName })     # (a brand-new device has no display name yet)
    $s.CoreName = $d.RawName; $s.LanA = $d.LanA
    if ((Test-IpAddress $d.LanB) -and -not ($Settings.LanASubnet -and (Test-InSubnet $d.LanB $Settings.LanASubnet))) { $s.IpAddress = $d.LanB }
    $Systems.Add($s)
    $d.InList = $s.Name

    if ($Quiet) { [void]$script:AutoAddQueue.Add($s); return }

    # Added by hand: you clearly want it, so take it off the removed-Cores list.
    Remove-IgnoredCore $d.RawName; Remove-IgnoredCore $d.LanA
    Save-AppData
    Set-Status "Added '$($d.Name)'. Checking it now..."
    Start-CoreQuery ([QSystem[]]@($s)) -Force
    Invoke-AutoSync
    Update-TrayMenu
}

#endregion

#region ==== 7i. AUTO-ADD CORES HEARD ON LAN A ========================
<#
  Every Core announces itself on LAN A once a second (QDP, section 7g). The announcement already
  holds its name, LAN A address and LAN B address, so a Core can go into the Cores list (and from
  there into Designer's hard links) without anyone typing anything - and without a login.

  Rules (Options > Devices > "Automatically add Cores heard on LAN A"):
    - Only Cores whose LAN A address is inside the LAN A range. Until the range is known, nothing
      is added. That keeps other departments' Cores out if their announcements leak onto campus.
    - Never virtual / emulated Cores (the announcement says is_virtual = true).
    - Never a Core you removed: removing a row puts its name and LAN A address on IgnoredCores
      (shared with the team through the shared list). Adding it back by hand clears that.

  Logins: firmware isn't in the announcement, so each NEW Core gets one Core Manager read
  (Start-CoreQuery -Force). After that the usual rules apply (login only when something changed).
  New Cores are collected for a second and checked as one batch.
#>

$script:AutoAddQueue = New-Object System.Collections.Generic.List[QSystem]

# Wait 2 minutes after startup before auto-adding: the first check of your list fills in Core
# names and LAN A addresses, so a row you already have is recognized instead of added twice.
$script:AutoAddAfter = (Get-Date).AddMinutes(2)

# The removed-Cores list. Entries are lowercase names or LAN A addresses.
function Test-IgnoredCore([QDevice]$d) {
    $list = @($Settings.IgnoredCores)
    return (($d.RawName -and $list -contains $d.RawName.ToLowerInvariant()) -or ($d.LanA -and $list -contains $d.LanA))
}
function Add-IgnoredCore([string]$Key) {
    if (-not $Key) { return }
    $Key = $Key.Trim().ToLowerInvariant()
    if (@($Settings.IgnoredCores) -notcontains $Key) { $Settings.IgnoredCores = @(@($Settings.IgnoredCores) + $Key) }
}
function Remove-IgnoredCore([string]$Key) {
    if (-not $Key) { return }
    $Key = $Key.Trim().ToLowerInvariant()
    $Settings.IgnoredCores = @(@($Settings.IgnoredCores) | Where-Object { $_ -ne $Key })
}

# Would auto-add / "Add all" take this Core? Returns '' if yes, otherwise the reason it won't.
function Get-AutoAddBlock([QDevice]$d) {
    if ($d.Kind -ne 'Core')            { return 'not a Core' }
    if ($d.InList)                     { return 'already in the list' }
    if ($d.IsVirtual)                  { return 'virtual / emulated Core' }
    if (-not $Settings.LanASubnet)     { return 'LAN A range not known yet' }
    if (-not ((Test-IpAddress $d.LanA) -and (Test-InSubnet $d.LanA $Settings.LanASubnet))) { return 'LAN A address outside your LAN A range' }
    if (Test-IgnoredCore $d)           { return 'you removed it' }
    return ''
}

# Called for every announcement from a Core that isn't in the list.
function Request-AutoAddCore([QDevice]$d) {
    if (-not $Settings.AutoAddCores -or -not $script:DataLoaded -or (Get-Date) -lt $script:AutoAddAfter) { return }
    if ($script:AutoAddQueue | Where-Object { $_.LanA -eq $d.LanA }) { return }      # already queued
    if (Get-AutoAddBlock $d) { return }
    Add-CoreFromDevice $d -Quiet
}

# Check the queued new Cores as one batch: one save, one query round, one sync, one note.
function Complete-AutoAdd([string]$How = 'heard on LAN A') {
    if ($script:AutoAddQueue.Count -eq 0) { return }
    $new = [QSystem[]]@($script:AutoAddQueue)
    $script:AutoAddQueue.Clear()
    $names = ($new | ForEach-Object { $_.Name }) -join ', '
    Write-Log "Added $($new.Count) Core(s) $How`: $names (firmware is read when you first launch one, or on Check all now)"
    Save-AppData
    # No check here: firmware is read the first time you launch the Core (or on Check all now),
    # so a new Core never gets a log entry you didn't ask for.
    Invoke-AutoSync
    Update-TrayMenu
    Update-Welcome
    Show-TrayNote "Added $($new.Count) Core(s) $How`: $names"
    Set-Status "Added $($new.Count) Core(s) $How."
}

# Devices tab > right-click > "Add all Cores not in my list" (works with auto-add off too).
function Add-AllCoresFromDevices {
    $skipped = @()
    foreach ($d in @($Devices | Where-Object { $_.Kind -eq 'Core' -and -not $_.InList })) {
        $why = Get-AutoAddBlock $d
        if ($why) { $skipped += "$($d.Name) ($why)"; continue }
        Add-CoreFromDevice $d -Quiet
    }
    if ($skipped) { Write-Log ("Not added: " + ($skipped -join '; ') + ". Right-click > Add this Core adds one anyway.") }
    if ($script:AutoAddQueue.Count -eq 0) {
        Set-Status $(if ($skipped) { "No Cores added ($($skipped.Count) skipped - see View > Log)." } else { 'Every Core heard is already in your list.' })
        return
    }
    Complete-AutoAdd 'from the Devices tab'
}

#endregion

#region ==== 7h. DEVICES TAB: PTZ-IP CAMERAS (WS-DISCOVERY) ===========
<#
  QSC's older PTZ-IP cameras don't announce themselves with QDP. They use WS-Discovery (the
  standard most IP cameras use): you send a "Probe" to multicast 239.255.255.250, UDP 3702,
  and each device answers you directly with a "ProbeMatch" listing its address and some
  "scopes" (onvif://www.onvif.org/name/..., /hardware/..., and so on).

  So unlike QDP this is ASKING, not just listening - which is why it's an Options switch
  (off by default). When it's on:
    - a Probe goes out on the LAN A card every 30 s,
    - only replies that mention QSC / Q-SYS / PTZ-IP are shown (other brands' cameras on the
      AV network are skipped, and logged once each so you can see they were deliberately ignored),
    - cameras appear on the Devices tab as Kind "Camera (PTZ-IP)", Live while they keep answering.
#>
$WsdGroup = '239.255.255.250'
$WsdPort  = 3702
$script:WsdSocket  = $null
$script:WsdIgnored = @{}          # IP -> $true for non-Q-SYS replies already logged

function Stop-WsdDiscovery {
    if ($script:WsdSocket) { try { $script:WsdSocket.Close() } catch { } ; $script:WsdSocket = $null }
}

function Start-WsdDiscovery {
    Stop-WsdDiscovery
    if (-not $Settings.PtzIpDiscovery) { return }

    # Only on the LAN A card (QSC cameras live on the AV network).
    $hit = if ($Settings.LanASubnet) { Find-LanAInterface } else { $null }
    if (-not $hit) { Write-Log 'PTZ-IP camera search will start once the LAN A network is known.'; return }
    try {
        $sock = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        # Our own address on the LAN A card, any free port: cameras answer straight back to it.
        $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($hit.Ip), 0)))
        # Send the multicast Probe out of the LAN A card (not whichever card Windows prefers).
        $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastInterface,
                              [System.Net.IPAddress]::Parse($hit.Ip).GetAddressBytes())
        $sock.Blocking = $false
        $script:WsdSocket = $sock
        Write-Log "PTZ-IP camera search ready on $($hit.Ip) (asks while the Devices tab is open, every 5 min)."
        if (Test-DevicesTabShowing) { Send-WsdProbe }
        $script:QdpTimer.Start()                 # the same timer reads the answers
    } catch {
        Write-Log "Couldn't start the PTZ-IP camera search: $($_.Exception.Message)"
        Stop-WsdDiscovery
    }
}

# Is the Devices tab on screen? (The camera question goes out only then - nobody sees it otherwise.)
function Test-DevicesTabShowing { return ($Window.IsVisible -and $Window.WindowState -ne 'Minimized' -and $Tabs.SelectedIndex -eq 1) }

# Opening the Devices tab: ask the cameras now, unless we asked in the last 5 minutes.
function Invoke-DevicesTabOpened {
    if ($script:WsdSocket -and (-not $script:WsdLastProbe -or ((Get-Date) - $script:WsdLastProbe).TotalMinutes -ge 5)) { Send-WsdProbe }
}

# The WS-Discovery "Probe" message. An empty <d:Probe/> means "everyone, please answer".
function Send-WsdProbe {
    if (-not $script:WsdSocket) { return }
    $script:WsdLastProbe = Get-Date
    $probe = @"
<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
            xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <e:Header>
    <w:MessageID>uuid:$([guid]::NewGuid())</w:MessageID>
    <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body><d:Probe/></e:Body>
</e:Envelope>
"@
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($probe)
        [void]$script:WsdSocket.SendTo($bytes, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($WsdGroup), $WsdPort)))
    } catch { }
}

# Read one onvif scope value, e.g. Get-ScopeValue $scopes 'name' -> "PTZ-IP-12x72-Lobby"
function Get-ScopeValue([string]$Scopes, [string]$Key) {
    $m = [regex]::Match($Scopes, "onvif://www\.onvif\.org/$Key/(\S+)", 'IgnoreCase')
    if ($m.Success) { return [Uri]::UnescapeDataString($m.Groups[1].Value) }
    return ''
}

# Turn a ProbeMatch reply into a Devices row (Q-SYS cameras only).
function Update-DeviceFromWsd([string]$Text, [string]$FromIp) {
    if ($Text -notmatch 'ProbeMatch') { return }
    try { [xml]$x = $Text } catch { return }

    # local-name() ignores the XML namespaces, which vary from camera to camera.
    foreach ($pm in @($x.SelectNodes("//*[local-name()='ProbeMatch']"))) {
        $node   = $pm.SelectSingleNode("*[local-name()='Scopes']");  $scopes = if ($node) { $node.InnerText } else { '' }
        $node   = $pm.SelectSingleNode("*[local-name()='XAddrs']");  $xaddrs = if ($node) { $node.InnerText } else { '' }
        $node   = $pm.SelectSingleNode(".//*[local-name()='Address']"); $epr = if ($node) { $node.InnerText.Trim() } else { '' }

        # The camera's address: from its service URL, or failing that, who sent the reply.
        $m  = [regex]::Match($xaddrs, 'https?://(\d+\.\d+\.\d+\.\d+)')
        $ip = if ($m.Success) { $m.Groups[1].Value } else { $FromIp }

        # Q-SYS cameras only.
        if ("$scopes $xaddrs" -notmatch 'qsc|q-sys|qsys|ptz-ip') {
            if (-not $script:WsdIgnored.ContainsKey($ip)) {
                $script:WsdIgnored[$ip] = $true
                $who = (Get-ScopeValue $scopes 'name'), (Get-ScopeValue $scopes 'hardware') | Where-Object { $_ }
                Write-Log "PTZ-IP search: skipped a non-Q-SYS device at $ip ($(if ($who) { $who -join ', ' } else { 'no name given' }))."
            }
            continue
        }

        $name  = Get-ScopeValue $scopes 'name'
        $model = Get-ScopeValue $scopes 'hardware'
        $key   = 'wsd:' + $(if ($epr) { $epr } else { $ip })
        $d = $script:DeviceIndex[$key]
        if (-not $d) {
            $d = New-Object QDevice
            $script:DeviceIndex[$key] = $d
            $Devices.Add($d)
            Write-Log "Found a PTZ-IP camera at $ip ($(if ($name) { $name } else { 'no name given' }))."
        }
        $d.RawName = $name
        $d.Name    = if ($name) { $name } else { "PTZ-IP camera $ip" }
        $d.Type    = 'ws-discovery'
        $d.Model   = if ($model) { $model } else { 'PTZ-IP' }
        $d.Kind    = 'Camera (PTZ-IP)'
        $d.LanA    = $ip
        $d.LastSeenTime = Get-Date
        if ($d.Status -ne 'Live') { $d.Status = 'Live'; $d.LastSeen = '' }
    }
}

#endregion

#region ==== 8. LAUNCHING DESIGNER + "LOAD FROM CORE" AUTOMATION =====
<#
  Designer has no documented command-line switch for "load from this Core",
  so we drive it through UI Automation - Windows' accessibility interface, the same one
  screen readers use. It finds Designer's menus, lists and buttons by type and name and
  operates them directly: no mouse, no keystrokes, and Designer does NOT need to be the
  window in front, so you can keep working in other windows while it loads.

  Each launch for a Core becomes a "watch" that moves through stages, checked
  once a second by a timer so this window never freezes:

    WaitMain   -> wait until Designer is READY (not just its loading screen - see Test-DesignerReady),
                  then F8AfterReadySec more (default 1 s), then open File > Load from Core & Connect
                  through the menu (Invoke-DesignerMenu). Only if that fails: bring Designer to the
                  front and press F8 like a keystroke.
    WaitDialog -> find the dialog (a window with a search box + a "Load..." button)
    Pick       -> find this Core's row in the dialog's list by its Core name and select it - no typing,
                  so Designer's search box is left alone. (Click Load if mode = 'Select + Load'.)
                  Several matching rows (Local + Reflect paths)? Left for you to pick.
    Filter     -> fallback when the row can't be found directly: type the Core name in the search
                  box, let the list filter, then select the single match.

  If the dialog can't be found, the app writes a map of Designer's windows to
  designer-ui-dump.txt (in the data folder) so the matching rules can be adjusted.
#>

# ---------- 8a. Launch ----------
function Start-Designer($Designer, [QSystem]$ForSystem) {
    if (-not $Designer) { return }

    $proc = Start-Process -FilePath $Designer.Exe -WorkingDirectory (Split-Path $Designer.Exe) -PassThru
    Write-Log "Launched Designer $($Designer.Version) (PID $($proc.Id))"

    if ($ForSystem) {
        $search = Get-F8SearchText $ForSystem
        # Clipboard copy is the manual fallback: Ctrl+V into the F8 search box.
        try { [System.Windows.Clipboard]::SetText($search) } catch { }
        Write-Log "F8 search text: '$search' (also on the clipboard)"

        if ($Settings.F8Mode -ne 'Off') {
            [void]$F8Watches.Add(@{ Proc = $proc; Stage = 'WaitMain'; Since = Get-Date; Search = $search; Dialog = $null; ReadyTicks = 0; ReadyAt = $null; LastWhy = ''; RestorePid = $null })
            $script:F8Timer.Start()
            # Instant feedback, so you know it's working while Designer loads.
            Set-Status "Opening Designer $($Designer.Version) for '$($ForSystem.Name)'..."
            Show-TrayNote "Opening Designer $($Designer.Version) for $($ForSystem.Name)..."
        }
    }
}

# What to type in Designer's search box: the per-row override, else design name, else our name.
# What to type in Designer's F8 search box. Designer's search matches the CORE's name
# (e.g. "Room101-Core"), not the design name - so that comes first.
function Get-F8SearchText([QSystem]$s) {
    if ($s.F8Search)   { return $s.F8Search }      # manual override (kept in the data file)
    if ($s.CoreName)   { return $s.CoreName }
    if ($s.DesignName) { return $s.DesignName }
    return $s.Name
}

# ---------- 8b. UI Automation helpers ----------
# Short names for the long .NET type names.
$UIA_AE   = [System.Windows.Automation.AutomationElement]
$UIA_CT   = [System.Windows.Automation.ControlType]
$UIA_Tree = [System.Windows.Automation.TreeScope]

function New-UiaCondition($Property, $Value) { New-Object System.Windows.Automation.PropertyCondition($Property, $Value) }

# All windows owned by a process: top-level ones, plus windows nested one level down
# (WPF dialogs often show up as children of their owner window).
function Get-ProcessWindows([int]$ProcId) {
    $out  = New-Object System.Collections.Generic.List[object]
    $tops = $UIA_AE::RootElement.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ProcessIdProperty $ProcId))
    foreach ($t in $tops) {
        $out.Add($t)
        foreach ($c in $t.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Window))) { $out.Add($c) }
    }
    return $out
}

# Look for the Load from Core dialog: a window (not the main schematic window)
# containing an Edit box and a button whose name contains "Load".
function Find-LoadDialog($Proc) {
    $main = $Proc.MainWindowHandle.ToInt64()
    foreach ($w in Get-ProcessWindows $Proc.Id) {
        try {
            if ($w.Current.NativeWindowHandle -eq $main) { continue }      # skip the big main window
            $buttons = $w.FindAll($UIA_Tree::Descendants, (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Button))
            $load = $null
            foreach ($b in $buttons) { if ($b.Current.Name -match 'Load') { $load = $b; break } }
            if (-not $load) { continue }
            $edit = $w.FindFirst($UIA_Tree::Descendants, (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Edit))
            if (-not $edit) { continue }
            return @{ Window = $w; Button = $load; Edit = $edit }
        } catch { }   # windows can vanish mid-search; just keep looking
    }
    return $null
}

# Put text into a text box. ValuePattern sets it directly; fall back to focus + typing.
function Set-UiaText($Element, [string]$Text) {
    $vp = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        $vp.SetValue($Text)
    } else {
        $Element.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        # SendKeys treats + ^ % ~ ( ) { } [ ] as commands - wrap them in braces so they type literally.
        [System.Windows.Forms.SendKeys]::SendWait(($Text -replace '([\+\^%~\(\)\{\}\[\]])', '{$1}'))
    }
}

# Rows currently showing in the dialog's Core list (DataGrid rows or list items).
function Get-DialogRows($Window) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($type in @($UIA_CT::DataItem, $UIA_CT::ListItem)) {
        foreach ($r in $Window.FindAll($UIA_Tree::Descendants, (New-UiaCondition $UIA_AE::ControlTypeProperty $type))) {
            if (-not $r.Current.IsOffscreen) { $rows.Add($r) }
        }
    }
    return $rows
}

# Select a row: SelectionItemPattern if offered, otherwise click its middle.
function Select-UiaRow($Row) {
    $sp = $null
    if ($Row.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select(); return }
    $pt = $Row.GetClickablePoint()
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]$pt.X, [int]$pt.Y)
    [QslMouse]::mouse_event(0x02, 0, 0, 0, 0); [QslMouse]::mouse_event(0x04, 0, 0, 0, 0)    # left down, up
}

# Click a button through InvokePattern (no mouse needed).
function Invoke-UiaButton($Button) {
    $ip = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); return $true }
    return $false
}

# Diagnostic: write the control tree of every Designer window to a text file.
function Export-DesignerUiDump($Proc, [int]$MaxDepth = 7) {
    $file  = Join-Path $AppFolder 'designer-ui-dump.txt'
    $lines = New-Object System.Collections.Generic.List[string]
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

    # Walk one element and its children, indenting by depth.
    function Walk($el, $depth) {
        if ($depth -gt $MaxDepth -or $lines.Count -gt 4000) { return }
        try {
            $c = $el.Current
            $lines.Add(('{0}{1}  name="{2}"  id="{3}"  class="{4}"' -f ('  ' * $depth), $c.ControlType.ProgrammaticName, $c.Name, $c.AutomationId, $c.ClassName))
        } catch { return }
        $child = $walker.GetFirstChild($el)
        while ($child) { Walk $child ($depth + 1); $child = $walker.GetNextSibling($child) }
    }

    $procs = if ($Proc) { @($Proc) } else { @(Get-RunningDesigner) }
    foreach ($p in $procs) {
        $lines.Add("===== PID $($p.Id)  $($p.Path) =====")
        foreach ($w in Get-ProcessWindows $p.Id) {
            # The main schematic window is huge - only go 3 levels deep there.
            $isMain = ($w.Current.NativeWindowHandle -eq $p.MainWindowHandle.ToInt64())
            $saved = $MaxDepth; if ($isMain) { $MaxDepth = 3 }
            Walk $w 0
            $MaxDepth = $saved
        }
    }
    Write-TextNoBom $file ($lines -join "`r`n")
    return $file
}

# ---------- 8b2. Is Designer ready to use? ----------
<#
  Designer gives no "I'm ready" signal and has no remote-control API, so we watch for what a
  person would see. Designer counts as READY when ALL of these are true:
    1. Windows says the program is responding (not busy loading).
    2. Windows says it's waiting for input (WaitForInputIdle) - its startup work is done.
    3. Its main window is up: it has a menu (File, Edit...), or it is a big window titled
       "...Designer". The loading screen is small and has no menu.
    4. The main window is enabled and no other Designer window is open on top
       (a progress box, an "update available" note, a recovery prompt...).
  It has to stay that way for 2 checks in a row (2 seconds), so a brief quiet moment in the
  middle of loading doesn't count. Returns '' when ready, otherwise what it's waiting for
  (that text goes to the status bar and, if it never gets ready, the log).
#>
# Is this window Designer's main window (not its loading screen)? WPF menus show up in UI Automation
# as "Menu" (Win32 ones as "MenuBar"), so accept either, or a "File" menu item. Backup test: a big
# window whose title has "Designer" in it (the loading screen is small).
function Test-DesignerMainWindow($Win) {
    $menu = New-Object System.Windows.Automation.OrCondition(
        (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::MenuBar),
        (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Menu),
        (New-Object System.Windows.Automation.AndCondition(
            (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::MenuItem),
            (New-UiaCondition $UIA_AE::NameProperty 'File'))))
    if ($Win.FindFirst($UIA_Tree::Descendants, $menu)) { return $true }
    $c = $Win.Current
    return ($c.Name -match 'Designer' -and $c.BoundingRectangle.Width -ge 900 -and $c.BoundingRectangle.Height -ge 600)
}

function Test-DesignerReady($Proc) {
    if ($Proc.MainWindowHandle -eq [IntPtr]::Zero) { return 'starting' }
    if (-not $Proc.Responding)                     { return 'loading (busy)' }
    try { if (-not $Proc.WaitForInputIdle(0))      { return 'loading' } } catch { return 'loading' }

    # Look at Designer's top-level windows, and at dialogs nested inside them. Docked panels are
    # windows too in UI Automation, so a nested window only counts if it's MODAL (blocks you).
    $main = $null; $others = @()
    $tops = $UIA_AE::RootElement.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ProcessIdProperty $Proc.Id))
    foreach ($t in $tops) {
        try {
            if ($t.Current.IsOffscreen) { continue }
            if (-not $main -and (Test-DesignerMainWindow $t)) {
                $main = $t
                foreach ($c in $t.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Window))) {
                    $wp = $null
                    if ($c.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and $wp.Current.IsModal) {
                        $others += $(if ($c.Current.Name) { $c.Current.Name } else { '(untitled box)' })
                    }
                }
            } else {
                $others += $(if ($t.Current.Name) { $t.Current.Name } else { '(untitled window)' })
            }
        } catch { }       # windows come and go while it loads
    }
    if (-not $main)                  { return 'loading screen' }
    if (-not $main.Current.IsEnabled) { return 'busy (main window disabled)' }
    if ($others.Count)               { return "a Designer window is open: $($others -join ', ')" }
    return ''
}

# ---------- 8b3. Open "Load from Core & Connect" through Designer's menu ----------
# Opens each top-level menu (File first) until it finds an item named like "Load from Core",
# then clicks it - all through UI Automation, so Designer doesn't have to be in front.
# WPF shows a submenu as its own popup window, so we look in every Designer window for the item.
function Invoke-DesignerMenu($Proc, [string]$Pattern = 'Load.*Core') {
    $tops = $UIA_AE::RootElement.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ProcessIdProperty $Proc.Id))
    $main = $null
    foreach ($t in $tops) { try { if (-not $t.Current.IsOffscreen -and (Test-DesignerMainWindow $t)) { $main = $t; break } } catch { } }
    if (-not $main) { return $false }

    $isItem = New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::MenuItem
    # The top-level menu items (File, Edit, View...), File first.
    $menuRoot = $main.FindFirst($UIA_Tree::Descendants, (New-Object System.Windows.Automation.OrCondition(
        (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::Menu), (New-UiaCondition $UIA_AE::ControlTypeProperty $UIA_CT::MenuBar))))
    $topItems = if ($menuRoot) { @($menuRoot.FindAll($UIA_Tree::Children, $isItem)) } else { @($main.FindAll($UIA_Tree::Descendants, $isItem)) }
    $topItems = @($topItems | Sort-Object { if ($_.Current.Name -match '^_?File$') { 0 } else { 1 } })

    foreach ($top in $topItems) {
        $ec = $null
        if (-not $top.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$ec)) { continue }
        try { $ec.Expand() } catch { continue }
        # Look in the menu itself and in every Designer window (the popup is one of them).
        # The submenu builds its items a moment after it opens, so keep looking for up to ~1 s.
        $found = $null
        for ($try = 0; $try -lt 20 -and -not $found; $try++) {
            Start-Sleep -Milliseconds 50
            $places = @($top) + @($UIA_AE::RootElement.FindAll($UIA_Tree::Children, (New-UiaCondition $UIA_AE::ProcessIdProperty $Proc.Id)))
            foreach ($place in $places) {
                try {
                    foreach ($mi in $place.FindAll($UIA_Tree::Descendants, $isItem)) {
                        if (($mi.Current.Name -replace '_', '') -match $Pattern -and $mi.Current.IsEnabled) { $found = $mi; break }
                    }
                } catch { }
                if ($found) { break }
            }
        }
        if ($found) {
            $ip = $null
            if ($found.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) {
                $ip.Invoke()                                   # (WPF runs this async; the dialog opens on its own)
                Write-Log "Opened '$($found.Current.Name -replace '_', '')' from Designer's '$($top.Current.Name -replace '_', '')' menu."
                return $true
            }
        }
        try { $ec.Collapse() } catch { }
    }
    return $false
}

# ---------- 8b4. Find a Core's row in the Load from Core dialog ----------
# All the text in a row: its own name plus every cell/text inside it.
function Get-RowText($Row) {
    $parts = New-Object System.Collections.Generic.List[string]
    try {
        $parts.Add($Row.Current.Name)
        foreach ($e in $Row.FindAll($UIA_Tree::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            try { if ($e.Current.Name) { $parts.Add($e.Current.Name) } } catch { }
        }
    } catch { }
    return $parts
}

# Rows whose text includes exactly the Core name (ignoring upper/lower case).
# Long lists only build the rows on screen, so we also ask the list itself (ItemContainerPattern)
# to find and build ("realize") a matching row that's scrolled out of view.
function Find-CoreRows($Window, [string]$CoreName) {
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($type in @($UIA_CT::DataItem, $UIA_CT::ListItem, $UIA_CT::TreeItem)) {
        foreach ($r in $Window.FindAll($UIA_Tree::Descendants, (New-UiaCondition $UIA_AE::ControlTypeProperty $type))) {
            # A cell equal to the Core name, or starting with it ("Balboa-Core (Reflect)").
            $txt = @(Get-RowText $r)
            if ($txt -contains $CoreName -or @($txt | Where-Object { $_ -like "$CoreName *" }).Count) { $hits.Add($r) }
        }
    }
    if ($hits.Count) { return $hits }

    foreach ($type in @($UIA_CT::DataGrid, $UIA_CT::List, $UIA_CT::Table, $UIA_CT::Tree)) {
        foreach ($list in $Window.FindAll($UIA_Tree::Descendants, (New-UiaCondition $UIA_AE::ControlTypeProperty $type))) {
            $icp = $null
            if (-not $list.TryGetCurrentPattern([System.Windows.Automation.ItemContainerPattern]::Pattern, [ref]$icp)) { continue }
            $item = $null
            try { $item = $icp.FindItemByProperty($null, $UIA_AE::NameProperty, $CoreName) } catch { }
            if ($item) {
                $vp = $null
                if ($item.TryGetCurrentPattern([System.Windows.Automation.VirtualizedItemPattern]::Pattern, [ref]$vp)) { try { $vp.Realize() } catch { } }
                $hits.Add($item)
            }
        }
    }
    return $hits
}

# Select a row through UI Automation (scrolling it into view first).
function Select-CoreRow($Row) {
    $sc = $null
    if ($Row.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$sc)) { try { $sc.ScrollIntoView() } catch { } }
    $sp = $null
    if ($Row.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select(); return $true }
    return $false
}

# After a row is selected: click Load (Select + Load mode), or leave Load for you.
function Complete-CoreSelection($w) {
    if ($Settings.F8Mode -eq 'Select + Load') {
        Start-Sleep -Milliseconds 300
        if (Invoke-UiaButton $w.Dialog.Button) { Write-Log "Clicked '$($w.Dialog.Button.Current.Name)'."; Set-Status 'Loading the design from the Core...' }
        else { Write-Log 'Selected the Core, but could not click Load - press it yourself.' }
    } else {
        Set-Status "Selected '$($w.Search)' - click Load."
    }
}

# ---------- 8c. The launch state machine (one timer tick per second) ----------
$F8Watches = New-Object System.Collections.ArrayList
$script:LaunchAfter = @{}      # Core Id -> launch once its firmware check comes back
$script:WentDown    = @{}      # Core Id -> it stopped announcing since its last check (maybe rebooted)

function Invoke-F8Watches {
    foreach ($w in @($F8Watches)) {
        $p = $w.Proc
        try { $p.Refresh() } catch { }
        if ($p.HasExited) { $F8Watches.Remove($w); continue }
        $elapsed = ((Get-Date) - $w.Since).TotalSeconds

        try {
            switch ($w.Stage) {

                # Wait until Designer is actually ready (8b2), then press F8 a moment later.
                'WaitMain' {
                    if ($p.MainWindowHandle -eq [IntPtr]::Zero) {       # no window at all yet
                        if ($elapsed -gt 120) { Write-Log 'Designer window never appeared; giving up on F8.'; $F8Watches.Remove($w) }
                        else { $StatusText.Text = 'Waiting for Designer: starting...' }      # (status bar only)
                        break
                    }
                    if (-not $w.ReadyAt) {
                        $why = Test-DesignerReady $p
                        if ($why) {
                            $w.ReadyTicks = 0
                            $StatusText.Text = "Waiting for Designer: $why..."          # status bar only (no log spam)
                            if ($why -ne $w.LastWhy) { Write-Log "Waiting for Designer: $why"; $w.LastWhy = $why }
                            if ($elapsed -lt $Settings.F8ReadyLimitSec) { break }
                            # Took too long: save a map of Designer's windows (so the ready test can be
                            # fixed), then press F8 anyway.
                            $f = Export-DesignerUiDump $p
                            Write-Log "Designer still not ready after $($Settings.F8ReadyLimitSec) s ($why). Pressing F8 anyway. Window map saved to $f."
                        } else {
                            $w.ReadyTicks++
                            if ($w.ReadyTicks -lt 2) { break }          # ready twice in a row = really ready
                        }
                        $w.ReadyAt = Get-Date
                        Write-Log ("Designer ready after {0:N0} s." -f $elapsed)
                        Set-Status 'Designer is ready. Opening Load from Core...'
                    }
                    if (((Get-Date) - $w.ReadyAt).TotalSeconds -lt $Settings.F8AfterReadySec) { break }

                    # The direct way: click File > Load from Core & Connect through UI Automation.
                    $opened = $false
                    try { $opened = Invoke-DesignerMenu $p } catch { }
                    if (-not $opened) {
                        # Designer's menus snap shut when its window isn't the active one. So bring it
                        # forward for a moment, use the menu, and hand focus back to whatever you were
                        # using as soon as the dialog is up (WaitDialog below).
                        $prevPid = [QslWin]::ForegroundPid()
                        $shell = New-Object -ComObject WScript.Shell
                        if ($prevPid -ne $p.Id -and $shell.AppActivate($p.Id)) {
                            Start-Sleep -Milliseconds 300
                            try { $opened = Invoke-DesignerMenu $p } catch { }
                            if ($opened) { $w.RestorePid = $prevPid; Write-Log 'Brought Designer forward for a moment to use its menu.' }
                        }
                    }
                    if (-not $opened) {
                        # Fallback: act like a person - bring Designer to the front and press F8.
                        Write-Log "Couldn't find Load from Core in Designer's menus; pressing F8 instead (needs Designer in front)."
                        $shell = New-Object -ComObject WScript.Shell
                        if (-not $shell.AppActivate($p.Id)) { Write-Log 'Could not bring Designer to the front to press F8.'; $F8Watches.Remove($w); break }
                        Start-Sleep -Milliseconds 300
                        [System.Windows.Forms.SendKeys]::SendWait('{F8}')
                        Write-Log 'Pressed F8 (Load from Core & Connect).'
                    }
                    if ($Settings.F8Mode -eq 'Open dialog') { $F8Watches.Remove($w); break }
                    $w.Stage = 'WaitDialog'; $w.Since = Get-Date
                }

                # Find the dialog, then type the search text.
                'WaitDialog' {
                    $d = Find-LoadDialog $p
                    if (-not $d) {
                        if ($elapsed -gt $Settings.DialogWaitSec) {
                            $f = Export-DesignerUiDump $p
                            Write-Log "Couldn't find the Load from Core dialog's search box/Load button. Saved a map of Designer's windows to $f - send that file to get the automation adjusted. (Search text is on the clipboard: Ctrl+V.)"
                            $F8Watches.Remove($w)
                        }
                        break
                    }
                    $w.Dialog = $d
                    # Give focus back to the program you were in (if we borrowed it to open the menu).
                    if ($w.RestorePid) {
                        try { [void](New-Object -ComObject WScript.Shell).AppActivate([int]$w.RestorePid) } catch { }
                        $w.RestorePid = $null
                    }
                    $w.Stage = 'Pick'; $w.Since = Get-Date
                }

                # Find the Core's row directly and select it - nothing typed. The list can take a few
                # seconds to fill in (Cores show "Contacting" at first), so keep looking for up to 6 s.
                'Pick' {
                    $rows = @(Find-CoreRows $w.Dialog.Window $w.Search)
                    if ($rows.Count -eq 1) {
                        if (Select-CoreRow $rows[0]) {
                            Write-Log "Selected '$($w.Search)' in the Load from Core list."
                            Complete-CoreSelection $w
                            $F8Watches.Remove($w); break
                        }
                    }
                    elseif ($rows.Count -gt 1) {
                        Write-Log "$($rows.Count) rows for '$($w.Search)' (Local vs Reflect path, or a redundant pair) - pick the one you want."
                        Set-Status "Pick '$($w.Search)' in the list (it's listed $($rows.Count) times)."
                        $F8Watches.Remove($w); break
                    }
                    if ($elapsed -lt 6) { break }
                    # Fallback: type the name in the search box and let Designer filter the list.
                    Set-UiaText $w.Dialog.Edit $w.Search
                    Write-Log "Couldn't select '$($w.Search)' directly; typed it into the search box instead."
                    $w.Stage = 'Filter'; $w.Since = Get-Date
                }

                # Give the list ~1.5 s to filter (Cores may still be "Contacting"), then look at the rows.
                'Filter' {
                    if ($elapsed -lt 1.5) { break }
                    $rows = Get-DialogRows $w.Dialog.Window
                    if ($rows.Count -eq 0 -and $elapsed -lt 6) { break }     # list may still be filling in

                    if ($rows.Count -eq 1) {
                        Select-UiaRow $rows[0]
                        Write-Log 'Selected the only matching Core.'
                        Complete-CoreSelection $w
                    }
                    elseif ($rows.Count -gt 1) { Write-Log "$($rows.Count) rows match '$($w.Search)' - pick the right one (Local vs Reflect path, or redundant pair)." }
                    else {
                        $f = Export-DesignerUiDump $p
                        Write-Log "No rows match '$($w.Search)'. Set an 'F8 search' value for this Core (e.g. its Core name), or check the hard link is enabled. Window map saved to $f."
                    }
                    $F8Watches.Remove($w)
                }
            }
        }
        catch {
            Write-Log "F8 automation stopped: $($_.Exception.Message)"
            $F8Watches.Remove($w)
        }
    }
    if ($F8Watches.Count -eq 0) { $script:F8Timer.Stop() }
}

function Start-DesignerForSystem([QSystem]$s) {
    if (-not $s) { return }
    if (-not $s.Firmware -or $script:WentDown.ContainsKey($s.Id)) {
        # Firmware not known yet (e.g. a Core added from its announcement), or the Core went quiet
        # since its last check (a firmware update means a reboot): check it once - you asked for
        # this Core, so a log entry on it is fine - then launch when the answer comes back.
        if (-not (Get-QueryIp $s)) { Set-Status "No address for '$($s.Name)'."; return }
        $script:LaunchAfter[$s.Id] = $true
        Set-Status "Reading the firmware of '$($s.Name)' first..."
        Start-CoreQuery ([QSystem[]]@($s)) -Force
        return
    }
    $match = Find-DesignerForFirmware $s.Firmware
    if (-not $match.Designer) {
        [System.Windows.MessageBox]::Show("'$($s.Name)' runs firmware $($s.Firmware).`n`nNo matching Q-SYS Designer is installed. Download $($s.Firmware) from qsys.com.", 'Designer not installed') | Out-Null
        return
    }
    if (-not $match.Exact) {
        $ans = [System.Windows.MessageBox]::Show("'$($s.Name)' runs $($s.Firmware) but the installed Designer is $($match.Designer.Version).`n`nDesigner usually needs the exact same version to connect. Launch anyway?", 'Version mismatch', 'YesNo')
        if ($ans -ne 'Yes') { return }
    }
    Start-Designer $match.Designer $s
}

#endregion

#region ==== 9. THE WINDOWS (XAML layouts) ============================
<#
  Main window: menu bar (File / Edit / View / Tools / Help), a search box with the
  everyday buttons, the Core list, installed Designers, and a status bar.
  Separate windows, built in this section:
    - Log      (View > Log, Ctrl+L)   floating and resizable
    - Options  (Tools > Options)      every setting in one place
    - Help     (Help > Help, F1)      opens QSysLauncher-Help.html next to this script
    - About    (Help > About)         version and file locations
#>
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Q-SYS Launcher" Width="1300" Height="720" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <!-- Grey text for the columns the app fills in -->
    <Style x:Key="Auto" TargetType="DataGridCell">
      <Setter Property="Foreground" Value="#555"/>
    </Style>
    <!-- Name column: hover to see the Core's own name (what Designer's F8 search uses) -->
    <Style x:Key="NameCell" TargetType="DataGridCell">
      <Setter Property="ToolTip" Value="{Binding CoreName}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding CoreName}" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <!-- Designer column: OK green / Patch amber / Missing red; hover for the details -->
    <Style x:Key="DesignerCell" TargetType="DataGridCell">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="ToolTip" Value="{Binding DesignerDetail}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding DesignerMatch}" Value="OK"><Setter Property="Foreground" Value="#1E8449"/></DataTrigger>
        <DataTrigger Binding="{Binding DesignerMatch}" Value="Patch"><Setter Property="Foreground" Value="#B9770E"/></DataTrigger>
        <DataTrigger Binding="{Binding DesignerMatch}" Value="Missing"><Setter Property="Foreground" Value="#C0392B"/></DataTrigger>
        <DataTrigger Binding="{Binding DesignerDetail}" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <!-- Devices tab: hover Kind for the raw type; hover Status for when it was last heard -->
    <Style x:Key="KindCell" TargetType="DataGridCell">
      <Setter Property="ToolTip" Value="{Binding Type}"/>
    </Style>
    <Style x:Key="DevStatusCell" TargetType="DataGridCell">
      <Setter Property="ToolTip" Value="{Binding LastSeen}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding LastSeen}" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <!-- State column: hover to see when it was last checked (date/time) -->
    <Style x:Key="StateCell" TargetType="DataGridCell" BasedOn="{StaticResource Auto}">
      <Setter Property="ToolTip" Value="{Binding LastChecked}"/>
    </Style>
  </Window.Resources>

  <DockPanel>

    <!-- ===== MENU BAR ===== -->
    <Menu DockPanel.Dock="Top" Padding="4,2">
      <MenuItem Header="_File">
        <MenuItem x:Name="MnuRefresh"    Header="_Check all Cores now" InputGestureText="F5"/>
        <MenuItem x:Name="MnuSync"       Header="_Sync hard links to Designer (with preview)..."/>
        <Separator/>
        <MenuItem x:Name="MnuDataFolder" Header="Open _data folder"/>
        <MenuItem x:Name="MnuShortcut"   Header="Create desktop _shortcut"/>
        <Separator/>
        <MenuItem x:Name="MnuExit"       Header="E_xit"/>
      </MenuItem>
      <MenuItem Header="_Edit">
        <MenuItem x:Name="MnuAdd"         Header="_Add Core"/>
        <MenuItem x:Name="MnuGroups"      Header="_Groups..."/>
        <MenuItem x:Name="MnuRemove"      Header="_Remove selected..." InputGestureText="Del"/>
        <Separator/>
        <MenuItem x:Name="MnuCheck"       Header="_Check selected now (incl. firmware)"/>
        <MenuItem x:Name="MnuCoreManager" Header="Open Core _Manager"/>
      </MenuItem>
      <MenuItem Header="_View">
        <MenuItem x:Name="MnuLog" Header="_Log" InputGestureText="Ctrl+L"/>
      </MenuItem>
      <MenuItem Header="_Tools">
        <MenuItem x:Name="MnuLogin"   Header="Core _login..."/>
        <MenuItem x:Name="MnuProbe"   Header="Find _firmware API (selected Core)"/>
        <MenuItem x:Name="MnuDump"    Header="_Dump Designer UI (F8 diagnostics)"/>
        <Separator/>
        <MenuItem x:Name="MnuOptions" Header="_Options..."/>
      </MenuItem>
      <MenuItem Header="_Help">
        <MenuItem x:Name="MnuHelp"  Header="_Help" InputGestureText="F1"/>
        <MenuItem x:Name="MnuAbout" Header="_About Launcher for Q-SYS"/>
      </MenuItem>
    </Menu>

    <!-- ===== STATUS BAR (bottom): what just happened | version ===== -->
    <Border DockPanel.Dock="Bottom" BorderBrush="#DDD" BorderThickness="0,1,0,0" Background="#F7F7F7" Padding="10,4">
      <DockPanel>
        <TextBlock x:Name="VersionText" DockPanel.Dock="Right" Foreground="#777" Margin="16,0,0,0"/>
        <TextBlock x:Name="StatusText" Foreground="#225" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>

    <DockPanel Margin="10,8,10,10">

      <!-- ===== TOOLBAR: search + everyday buttons | name and version ===== -->
      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
          <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBox x:Name="SearchBox" Width="220" VerticalAlignment="Center" Margin="0,0,14,0"/>
          <Button x:Name="BtnLaunch"  Content="Launch Designer" FontWeight="SemiBold"
                  ToolTip="Opens the Designer version that matches the selected Core. Double-clicking a grey column does the same."/>
          <Button x:Name="BtnRefresh" Content="Check all now" ToolTip="Checks every Core over the network: design, state, firmware (F5). Each check shows in the Core's event log."/>
        </StackPanel>
        <TextBlock x:Name="HeaderVersion" HorizontalAlignment="Right" VerticalAlignment="Center"
                   FontSize="15" FontWeight="SemiBold" Foreground="#345"/>
      </DockPanel>

      <!-- ===== TABS: Cores (your list) | Devices (heard live on LAN A) ===== -->
      <TabControl x:Name="Tabs">

        <TabItem Header="  Cores  ">
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="6"/>
              <ColumnDefinition Width="230"/>
            </Grid.ColumnDefinitions>

            <DockPanel Grid.Column="0">
              <!-- + / - under the list -->
              <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,6,0,0">
                <Button x:Name="BtnPlus"  Content="+" Width="32" Padding="0,1" FontSize="15" FontWeight="Bold" ToolTip="Add a Core"/>
                <Button x:Name="BtnMinus" Content="-" Width="32" Padding="0,1" FontSize="15" FontWeight="Bold" ToolTip="Remove the selected Cores (asks first)"/>
              </StackPanel>

              <Grid>
              <!-- White columns are yours to edit; grey ones are filled in automatically.
                   CanUserDeleteRows is off so the Delete key goes through Remove (which asks first). -->
              <!-- Columns size themselves to fit (ColumnWidth="Auto"); drag or double-click a column edge
                   to adjust. No "fill the rest" column - that makes WPF's scroll bars flicker.
                   FrozenColumnCount keeps On + Name in view when scrolling sideways. -->
              <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                        HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" FrozenColumnCount="2"
                        ColumnWidth="Auto" MinColumnWidth="40"
                        SelectionMode="Extended" HeadersVisibility="Column" GridLinesVisibility="All" HorizontalGridLinesBrush="#E8EBEE" VerticalGridLinesBrush="#E8EBEE"
                        AlternatingRowBackground="#F6F8FA">
                <DataGrid.Columns>
                  <DataGridCheckBoxColumn Header="On"               Binding="{Binding Enabled, UpdateSourceTrigger=PropertyChanged}"/>
                  <DataGridTextColumn     Header="Name"             Binding="{Binding Name}" CellStyle="{StaticResource NameCell}"/>
                  <!-- Group: shows as text; when editing it's a drop-down of known groups that you can
                       also type a new name into (IsEditable). The list comes from the "GroupList"
                       resource, filled in by Update-GroupList. -->
                  <DataGridTemplateColumn Header="Group" SortMemberPath="Group" MinWidth="80">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><TextBlock Text="{Binding Group}" Margin="2,0" VerticalAlignment="Center"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                    <DataGridTemplateColumn.CellEditingTemplate>
                      <DataTemplate>
                        <ComboBox IsEditable="True" ItemsSource="{DynamicResource GroupList}" MinWidth="120"
                                  Text="{Binding Group, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellEditingTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn     Header="LAN B IP"         Binding="{Binding IpAddress}"/>
                  <DataGridTextColumn     Header="LAN A IP"         Binding="{Binding LanA}"/>
                  <DataGridTextColumn     Header="Core Model"       Binding="{Binding Platform}" IsReadOnly="True" CellStyle="{StaticResource Auto}"/>
                  <DataGridTextColumn     Header="Firmware"         Binding="{Binding Firmware}"  IsReadOnly="True" CellStyle="{StaticResource Auto}"/>
                  <DataGridTextColumn     Header="Designer" Binding="{Binding DesignerMatch}" IsReadOnly="True" CellStyle="{StaticResource DesignerCell}"/>
                  <DataGridTextColumn     Header="Design Name"      Binding="{Binding DesignName}" IsReadOnly="True" CellStyle="{StaticResource Auto}"/>
                  <DataGridTextColumn     Header="State"            Binding="{Binding State}"  IsReadOnly="True" CellStyle="{StaticResource StateCell}"/>
                  <DataGridTextColumn     Header="Notes"            Binding="{Binding Notes}" MinWidth="160"/>
                </DataGrid.Columns>
              </DataGrid>

              <!-- Shown only while the list is empty (first run): how to get started. -->
              <Border x:Name="WelcomePanel" Background="#FAFCFD" BorderBrush="#DDE5EA" BorderThickness="1"
                      Margin="40,50,40,40" Padding="24" VerticalAlignment="Top" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock Text="No Cores in your list yet" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,10"/>
                  <TextBlock TextWrapping="Wrap" Margin="0,0,0,6" Text="&#x2022; Cores on your AV network show up by themselves on the Devices tab. Right-click one and choose 'Add this Core to my Cores'."/>
                  <TextBlock TextWrapping="Wrap" Margin="0,0,0,6" Text="&#x2022; Or click + below and type a Core's IP address. Its name, model, firmware and the matching Designer version fill in on their own."/>
                  <TextBlock TextWrapping="Wrap" Margin="0,0,0,6" Text="&#x2022; Hard links you already have in Designer are imported automatically."/>
                  <TextBlock TextWrapping="Wrap" Margin="0,0,0,14" Text="&#x2022; If your Cores use Access Control, set a login in Tools &gt; Core login so firmware can be read."/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="WelDevices" Content="Show the Devices tab"/>
                    <Button x:Name="WelAdd"     Content="+ Add a Core"/>
                    <Button x:Name="WelHelp"    Content="Help"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              </Grid>
            </DockPanel>

            <GridSplitter Grid.Column="1" Width="6" HorizontalAlignment="Stretch" Background="Transparent"/>

            <DockPanel Grid.Column="2">
              <TextBlock DockPanel.Dock="Top" Text="Installed Q-SYS Designer" FontWeight="SemiBold" Margin="0,0,0,4"/>
              <Button DockPanel.Dock="Bottom" x:Name="BtnLaunchVer" Content="Launch this version" Margin="0,6,0,0" HorizontalAlignment="Left"/>
              <ListView x:Name="DesignerList">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Version" DisplayMemberBinding="{Binding Version}" Width="80"/>
                    <GridViewColumn Header="Folder"  DisplayMemberBinding="{Binding Folder}"  Width="140"/>
                  </GridView>
                </ListView.View>
              </ListView>
            </DockPanel>
          </Grid>
        </TabItem>

        <TabItem Header="  Devices (LAN A)  ">
          <DockPanel Margin="0,6,0,0">
            <TextBlock x:Name="DevStatus" DockPanel.Dock="Bottom" Margin="0,6,0,0" Foreground="#555"/>
            <!-- Read-only: this list builds itself from what's announcing on the network. -->
            <DataGrid x:Name="DevGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False"
                      SelectionMode="Extended" HeadersVisibility="Column" GridLinesVisibility="All" HorizontalGridLinesBrush="#E8EBEE" VerticalGridLinesBrush="#E8EBEE"
                      HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" FrozenColumnCount="1"
                      ColumnWidth="Auto" MinColumnWidth="40"
                      AlternatingRowBackground="#F6F8FA">
              <DataGrid.Columns>
                <!-- Name: as the device announces it (devices report lowercase network names);
                     Cores in your list show their proper name instead. -->
                <DataGridTextColumn Header="Name"             Binding="{Binding Name}"/>
                <!-- Kind: worked out from the model; hover for the raw type the device reported. -->
                <DataGridTextColumn Header="Kind"             Binding="{Binding Kind}" CellStyle="{StaticResource KindCell}"/>
                <DataGridTextColumn Header="Model"            Binding="{Binding Model}"/>
                <DataGridTextColumn Header="LAN A IP"         Binding="{Binding LanA}"/>
                <DataGridTextColumn Header="LAN B IP"         Binding="{Binding LanB}"/>
                <!-- For Cores: the matching row on the Cores tab (blank = not in your list). -->
                <DataGridTextColumn Header="In Cores list as" Binding="{Binding InList}"/>
                <!-- Live / Not live; hover "Not live" to see when it was last heard. -->
                <DataGridTextColumn Header="Status"           Binding="{Binding Status}" CellStyle="{StaticResource DevStatusCell}"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </TabItem>
      </TabControl>
    </DockPanel>
  </DockPanel>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))

# Grab every named control into a variable of the same name ($Grid, $MnuExit, ...).
foreach ($node in $Xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $n = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 -ExpandProperty Value
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}
$script:DesignerList = $DesignerList

function Set-Status([string]$Text) { $StatusText.Text = $Text; Write-Log $Text }

# Load a small XAML window and return it plus a table of its named controls.
function New-XamlWindow([string]$XamlText) {
    [xml]$x = $XamlText
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $named = @{}
    foreach ($node in $x.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $n = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 -ExpandProperty Value
        $named[$n] = $w.FindName($n)
    }
    return @{ Window = $w; C = $named }
}

# ---- Remember window size and position ----
# Saved as "left,top,width,height,maximized" in the settings. WPF measures in device-independent
# units, so we check against SystemParameters' virtual screen (all monitors, same units).
function Save-WindowBounds($Win, [string]$Key) {
    if (-not $Win) { return }
    $b = if ($Win.WindowState -eq 'Maximized') { $Win.RestoreBounds } else { New-Object System.Windows.Rect($Win.Left, $Win.Top, $Win.ActualWidth, $Win.ActualHeight) }
    if ($b.Width -lt 200 -or $b.Height -lt 150 -or [double]::IsInfinity($b.Left)) { return }   # not shown yet / nonsense
    $max = [int]($Win.WindowState -eq 'Maximized')
    $Settings[$Key] = '{0:0},{1:0},{2:0},{3:0},{4}' -f $b.Left, $b.Top, $b.Width, $b.Height, $max
}

# NOTE: PowerShell variable names ignore upper/lower case ($w and $W are the SAME variable),
# so the window is $Win and the numbers have their own distinct names.
function Restore-WindowBounds($Win, [string]$Key) {
    $v = [string]$Settings[$Key]
    if ($v -notmatch '^(-?\d+),(-?\d+),(\d+),(\d+),([01])$') { return }
    $left = [double]$Matches[1]; $top = [double]$Matches[2]; $width = [double]$Matches[3]; $height = [double]$Matches[4]
    $max = $Matches[5] -eq '1'

    # Still on a screen? Require a decent chunk (incl. the title bar) to be inside the monitors' area,
    # otherwise keep the default centered position.
    $vs = New-Object System.Windows.Rect(
        [System.Windows.SystemParameters]::VirtualScreenLeft, [System.Windows.SystemParameters]::VirtualScreenTop,
        [System.Windows.SystemParameters]::VirtualScreenWidth, [System.Windows.SystemParameters]::VirtualScreenHeight)
    $titleBar = New-Object System.Windows.Rect($left, $top, $width, 40)
    $vis = [System.Windows.Rect]::Intersect($vs, $titleBar)
    if ($vis.IsEmpty -or $vis.Width -lt 150) { return }

    $Win.WindowStartupLocation = 'Manual'
    $Win.Left = $left; $Win.Top = $top; $Win.Width = $width; $Win.Height = $height
    if ($max) { $Win.WindowState = 'Maximized' }        # maximizes on the monitor it was on
}

# Set a ComboBox to the item whose text matches.
function Select-ComboItem($Combo, [string]$Value) {
    foreach ($item in $Combo.Items) { if ($item.Content -eq $Value) { $Combo.SelectedItem = $item } }
}

# ---------- 9a. LOG WINDOW (View > Log) ----------
# Built the first time you open it, then just hidden/shown, so it keeps its size and position.
function Show-LogWindow {
    if (-not $script:LogWindow) {
        $lw = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Log" Width="1000" Height="480" FontFamily="Segoe UI" FontSize="13">
  <DockPanel>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="8,6">
      <Button x:Name="LogCopy"  Content="Copy all"      Padding="10,3" Margin="0,0,6,0"/>
      <Button x:Name="LogFile"  Content="Open log file" Padding="10,3" Margin="0,0,6,0"/>
      <Button x:Name="LogClear" Content="Clear view"    Padding="10,3" Margin="0,0,6,0"/>
      <TextBlock Text="Full history is in launcher.log (data folder)." Foreground="#777" VerticalAlignment="Center" Margin="10,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="LogText" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
  </DockPanel>
</Window>
'@
        $script:LogWindow = $lw.Window
        Restore-WindowBounds $script:LogWindow 'LogBounds'
        $script:LogBox    = $lw.C.LogText                     # Write-Log appends here from now on
        $script:LogBox.Text = ($script:LogLines -join "`r`n") + "`r`n"
        if ($Window.Icon) { $script:LogWindow.Icon = $Window.Icon }

        $lw.C.LogCopy.Add_Click({ [System.Windows.Clipboard]::SetText($script:LogBox.Text) })
        $lw.C.LogFile.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })
        $lw.C.LogClear.Add_Click({ $script:LogBox.Clear() })
        # Closing just hides it (unless the whole app is exiting).
        $script:LogWindow.Add_Closing({
            param($sender, $e)
            Save-WindowBounds $script:LogWindow 'LogBounds'
            if (-not $script:Exiting) { $e.Cancel = $true; $script:LogWindow.Hide(); Save-AppData }
        })
    }
    $script:LogWindow.Show()
    [void]$script:LogWindow.Activate()
    $script:LogBox.ScrollToEnd()
}

# Switch the shared Core list on, off, or to another folder.
function Set-SharedFolder([string]$Folder) {
    if ($Folder -and -not (Test-Path -LiteralPath $Folder)) {
        [System.Windows.MessageBox]::Show("That folder doesn't exist:`n$Folder", 'Shared Core list') | Out-Null
        return
    }
    $Settings.SharedFolder = $Folder
    $script:SharedStamp = $null
    if (-not $Folder) {
        Save-AppData
        Write-Log 'Core list is now kept on this PC only (it keeps everything from the shared list).'
        return
    }
    $path = Get-SharedListPath
    if (Test-Path -LiteralPath $path) {
        # A list is already there: merge ours into it (nothing is lost either way).
        Sync-SharedList
        Write-Log "Now using the shared Core list in $Folder (merged with this PC's list)."
    } else {
        Save-AppData
        Write-Log "Started a shared Core list in $Folder - point your teammates' launchers at the same folder."
    }
    Update-DesignerMatch; Update-TrayMenu
}

# ---------- 9b. OPTIONS DIALOG (Tools > Options) ----------
# Changes apply when you click OK.
$StartupLnk    = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$OldStartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Q-SYS Launcher.lnk'     # name used before v0.12

# The app icon ships next to the script (an original design, not QSC's).
$IconFile = Join-Path (Split-Path $ScriptPath) 'QSysLauncher.ico'

function Show-OptionsDialog {
    $od = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Options" SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="GroupBox"><Setter Property="Padding" Value="8"/><Setter Property="Margin" Value="0,0,0,10"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Width" Value="170"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Margin" Value="0,3"/></Style>
    <Style TargetType="TextBlock"><Setter Property="VerticalAlignment" Value="Center"/></Style>
  </Window.Resources>
  <StackPanel Margin="16" Width="500">

    <GroupBox Header="Designer hard links">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="Core address to use"/>
        <ComboBox x:Name="OptLinkUse" Grid.Column="1">
          <ComboBoxItem Content="LAN B"/><ComboBoxItem Content="LAN A"/><ComboBoxItem Content="Both"/>
        </ComboBox>
        <TextBlock Grid.Row="1" Text="Link mode"/>
        <ComboBox x:Name="OptMode" Grid.Row="1" Grid.Column="1">
          <ComboBoxItem Content="UDP"/><ComboBoxItem Content="HTTPS"/>
        </ComboBox>
        <CheckBox x:Name="OptAutoSync" Grid.Row="2" Grid.ColumnSpan="2" Margin="0,8,0,0"
                  Content="Keep Designer's hard links in sync automatically"/>
      </Grid>
    </GroupBox>

    <GroupBox Header="Launching Designer for a Core">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="After Designer opens"/>
        <ComboBox x:Name="OptF8" Grid.Column="1">
          <ComboBoxItem Content="Off"/><ComboBoxItem Content="Open dialog"/><ComboBoxItem Content="Select Core"/><ComboBoxItem Content="Select + Load"/>
        </ComboBox>
        <TextBlock Grid.Row="1" Text="Extra wait before F8"/>
        <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,3">
          <TextBox x:Name="OptF8Delay" Width="50"/>
          <TextBlock Text="  seconds after Designer is ready (it waits for loading to finish)" Foreground="#666"/>
        </StackPanel>
      </Grid>
    </GroupBox>

    <GroupBox Header="Checking Cores">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="Check Cores over the network"/>
        <StackPanel Grid.Column="1">
          <ComboBox x:Name="OptRefresh">
            <ComboBoxItem Content="Only when I ask"/><ComboBoxItem Content="Every 30 min"/><ComboBoxItem Content="Every 60 min"/><ComboBoxItem Content="Every 4 hours"/>
          </ComboBox>
          <TextBlock Foreground="#666" TextWrapping="Wrap" MaxWidth="330" Margin="0,2,0,0"
                     Text="Each check adds connect/close lines to the Core's event log. Listening on LAN A adds nothing."/>
        </StackPanel>
        <TextBlock Grid.Row="1" Text="Core login (for firmware)"/>
        <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,3">
          <Button x:Name="OptLoginBtn" Content="Change..." Padding="10,2" Margin="0,0,10,0"/>
          <TextBlock x:Name="OptLoginLabel" Foreground="#666"/>
        </StackPanel>
      </Grid>
    </GroupBox>

    <GroupBox Header="Devices tab (Q-SYS discovery)">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <CheckBox x:Name="OptQdp" Grid.ColumnSpan="2" Content="Listen for Q-SYS devices on the LAN A network"/>
        <TextBlock Grid.Row="1" Text="LAN A network (CIDR)"/>
        <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,3">
          <TextBox x:Name="OptLanA" Width="140"/>
          <TextBlock Text="  blank = detect automatically" Foreground="#666"/>
        </StackPanel>
        <CheckBox x:Name="OptPtz" Grid.Row="2" Grid.ColumnSpan="2" Margin="0,8,0,0"
                  Content="Also find PTZ-IP cameras (older QSC line; asks the network every 30 s)"/>
        <StackPanel Grid.Row="3" Grid.ColumnSpan="2" Margin="0,8,0,0">
          <CheckBox x:Name="OptAutoAdd" Content="Automatically add Cores heard on LAN A to my Cores list"/>
          <StackPanel Orientation="Horizontal" Margin="20,4,0,0">
            <TextBlock x:Name="OptIgnoredLabel" Foreground="#666" VerticalAlignment="Center"/>
            <Button x:Name="OptIgnoredClear" Content="Allow them again" Padding="8,1" Margin="8,0,0,0"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </GroupBox>

    <GroupBox Header="Core list and Designer">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="Shared Core list folder"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,3">
          <TextBox x:Name="OptShared" Width="220"/>
          <Button x:Name="OptSharedBrowse" Content="..." Width="30" Margin="6,0,0,0"/>
        </StackPanel>
        <TextBlock Grid.Row="1" Grid.Column="1" Foreground="#666" TextWrapping="Wrap" Margin="0,0,0,6"
                   Text="Blank = this PC only. A OneDrive or network folder lets a team share one list. Logins and settings stay per person."/>
        <TextBlock Grid.Row="2" Text="Extra Designer folders"/>
        <TextBox x:Name="OptExtraDesigner" Grid.Row="2" Grid.Column="1" Margin="0,3"
                 ToolTip="Only needed if Designer is installed somewhere unusual. Separate several folders with ;"/>
      </Grid>
    </GroupBox>

    <GroupBox Header="Windows">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="Window close button (X)"/>
        <ComboBox x:Name="OptClose" Grid.Column="1">
          <ComboBoxItem Content="Keep running in the tray"/><ComboBoxItem Content="Exit the launcher"/>
        </ComboBox>
        <CheckBox x:Name="OptStartup" Grid.Row="1" Grid.ColumnSpan="2" Margin="0,8,0,0"
                  Content="Start with Windows (runs in the tray)"/>
      </Grid>
    </GroupBox>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="OptOK"     Content="OK"     Width="80" IsDefault="True" Margin="0,0,8,0"/>
      <Button x:Name="OptCancel" Content="Cancel" Width="80" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $script:OptDlg = $od.Window
    $c = $od.C
    if ($Window.IsVisible) { $script:OptDlg.Owner = $Window } else { $script:OptDlg.WindowStartupLocation = 'CenterScreen' }

    # --- fill in the current values ---
    Select-ComboItem $c.OptLinkUse $Settings.LinkUse
    Select-ComboItem $c.OptMode    $Settings.Mode
    Select-ComboItem $c.OptF8      $Settings.F8Mode
    Select-ComboItem $c.OptRefresh $(switch ([int]$Settings.AutoCheckMinutes) { 30 { 'Every 30 min' } 60 { 'Every 60 min' } 240 { 'Every 4 hours' } default { 'Only when I ask' } })
    $c.OptClose.SelectedIndex = $(if ($Settings.CloseAction -eq 'Exit') { 1 } else { 0 })
    $c.OptAutoSync.IsChecked  = [bool]$Settings.AutoSync
    $c.OptStartup.IsChecked   = (Test-Path $StartupLnk)
    $c.OptF8Delay.Text        = [string]$Settings.F8AfterReadySec
    $c.OptQdp.IsChecked       = [bool]$Settings.QdpListen
    $c.OptPtz.IsChecked       = [bool]$Settings.PtzIpDiscovery
    $c.OptAutoAdd.IsChecked   = [bool]$Settings.AutoAddCores
    # Removed Cores that auto-add leaves out (the button empties that list when you press OK).
    $script:OptClearIgnored = $false
    $script:OptIgnoredLabel = $c.OptIgnoredLabel
    $c.OptIgnoredLabel.Text = "Removed Cores it leaves out: $(@($Settings.IgnoredCores).Count) entries"
    $c.OptIgnoredClear.IsEnabled = @($Settings.IgnoredCores).Count -gt 0
    $c.OptIgnoredClear.Add_Click({ $script:OptClearIgnored = $true; $script:OptIgnoredLabel.Text = 'Removed Cores can be added again (after OK).'; $this.IsEnabled = $false })
    $c.OptLanA.Text           = [string]$Settings.LanASubnet
    $c.OptShared.Text         = [string]$Settings.SharedFolder
    $c.OptExtraDesigner.Text  = [string]$Settings.ExtraDesignerFolders
    $script:OptSharedBox = $c.OptShared
    $c.OptSharedBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Folder for the shared Core list (everyone on the team picks the same folder)'
        if ($script:OptSharedBox.Text -and (Test-Path $script:OptSharedBox.Text)) { $fb.SelectedPath = $script:OptSharedBox.Text }
        if ($fb.ShowDialog() -eq 'OK') { $script:OptSharedBox.Text = $fb.SelectedPath }
    })
    $script:OptLoginLabel = $c.OptLoginLabel
    Update-LoginLabel

    $c.OptLoginBtn.Add_Click({ Invoke-CoreLoginPrompt })
    $c.OptOK.Add_Click({ $script:OptDlg.DialogResult = $true })

    $ok = $script:OptDlg.ShowDialog()
    $script:OptLoginLabel = $null
    if (-not $ok) { return }

    # --- apply ---
    $Settings.LinkUse  = $c.OptLinkUse.SelectedItem.Content
    $Settings.Mode     = $c.OptMode.SelectedItem.Content
    $Settings.F8Mode   = $c.OptF8.SelectedItem.Content
    $Settings.AutoSync = [bool]$c.OptAutoSync.IsChecked
    $Settings.CloseAction = $(if ($c.OptClose.SelectedIndex -eq 1) { 'Exit' } else { 'Tray' })
    $delay = 0
    if ([int]::TryParse($c.OptF8Delay.Text, [ref]$delay) -and $delay -ge 0 -and $delay -le 60) { $Settings.F8AfterReadySec = $delay }
    $Settings.AutoCheckMinutes = switch ([string]$c.OptRefresh.SelectedItem.Content) { 'Every 30 min' { 30 } 'Every 60 min' { 60 } 'Every 4 hours' { 240 } default { 0 } }
    # Discovery: restart the listener if its settings changed.
    $newLanA = $c.OptLanA.Text.Trim()
    $okLanA  = (-not $newLanA) -or ($newLanA -match '^(\d+\.){3}\d+/\d+$' -and (Test-IpAddress ($newLanA -split '/')[0]))
    if (-not $okLanA) { Write-Log "Ignored LAN A network '$newLanA' - use the form 10.20.0.0/22, or leave it blank to detect it." ; $newLanA = $Settings.LanASubnet }
    $qdpChanged = ($newLanA -ne $Settings.LanASubnet) -or ([bool]$c.OptQdp.IsChecked -ne [bool]$Settings.QdpListen)
    $Settings.LanASubnet = $newLanA
    $Settings.QdpListen  = [bool]$c.OptQdp.IsChecked
    $ptzChanged = [bool]$c.OptPtz.IsChecked -ne [bool]$Settings.PtzIpDiscovery
    $Settings.PtzIpDiscovery = [bool]$c.OptPtz.IsChecked
    $Settings.AutoAddCores   = [bool]$c.OptAutoAdd.IsChecked
    if ($script:OptClearIgnored) { $Settings.IgnoredCores = @(); $Settings.IgnoredClearedAt = [DateTime]::UtcNow.Ticks; Write-Log 'Removed-Cores list cleared: auto-add may add those Cores again.' }
    if ($qdpChanged) { Start-QdpListener }                      # (also restarts the PTZ-IP search)
    elseif ($ptzChanged) {
        if ($Settings.PtzIpDiscovery) { Start-WsdDiscovery } else { Stop-WsdDiscovery; Write-Log 'PTZ-IP camera search turned off.' }
    }

    # Extra Designer folders -> rescan right away.
    $newExtra = $c.OptExtraDesigner.Text.Trim()
    if ($newExtra -ne [string]$Settings.ExtraDesignerFolders) {
        $Settings.ExtraDesignerFolders = $newExtra
        $script:Designers = Find-DesignerInstalls
        $script:DesignerList.ItemsSource = $script:Designers
        Update-DesignerMatch
    }

    # Shared Core list folder.
    $newShared = $c.OptShared.Text.Trim().Trim('"')
    if ($newShared -ne [string]$Settings.SharedFolder) { Set-SharedFolder $newShared }

    $wantStartup = [bool]$c.OptStartup.IsChecked
    if ($wantStartup -ne (Test-Path $StartupLnk)) { Set-StartWithWindows $wantStartup }

    Save-AppData
    Write-Log 'Options saved.'
    Invoke-AutoSync
    Update-TrayMenu
}

# "Start with Windows" = a shortcut in your Startup folder that runs this script with -Tray.
function Set-StartWithWindows([bool]$On) {
    if ($On) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($StartupLnk)
        $sc.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`" -Tray"
        $sc.WorkingDirectory = Split-Path $ScriptPath
        $sc.WindowStyle      = 7      # minimized
        if (Test-Path $IconFile) { $sc.IconLocation = "$IconFile,0" }
        $sc.Save()
        Write-Log "Will start with Windows (shortcut: $StartupLnk)"
    } elseif (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk
        Write-Log 'Will no longer start with Windows.'
    }
}

# File > Create desktop shortcut: a shortcut with the app's icon that starts it normally.
function New-DesktopShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`""
    $sc.WorkingDirectory = Split-Path $ScriptPath
    $sc.WindowStyle      = 7
    $sc.Description      = $AppName
    if (Test-Path $IconFile) { $sc.IconLocation = "$IconFile,0" }
    $sc.Save()
    Set-Status "Desktop shortcut created: $lnk"
}

# Core login (Tools > Core login, or the button in Options).
function Update-LoginLabel {
    if ($script:OptLoginLabel) {
        $script:OptLoginLabel.Text = if ($Settings.CoreUser) { "Saved for: $($Settings.CoreUser)" } else { 'None saved' }
    }
}
function Invoke-CoreLoginPrompt {
    if ($Settings.CoreUser) {
        $ans = [System.Windows.MessageBox]::Show("A Core login is saved for '$($Settings.CoreUser)'.`n`nYes = change it`nNo = remove it`nCancel = leave it", 'Core login', 'YesNoCancel')
        if ($ans -eq 'Yes') { Set-CoreLogin } elseif ($ans -eq 'No') { Clear-CoreLogin }
    } else { Set-CoreLogin }
    Update-LoginLabel
}

# ---------- 9c. HELP and ABOUT ----------
$HelpFile = Join-Path (Split-Path $ScriptPath) 'QSysLauncher-Help.html'
function Show-Help {
    if (Test-Path $HelpFile) { Start-Process $HelpFile }
    else { [System.Windows.MessageBox]::Show("The help file wasn't found:`n$HelpFile`n`nKeep QSysLauncher-Help.html in the same folder as the script.", 'Help') | Out-Null }
}
# ---------- 9d. GROUPS (Edit > Groups) ----------
# The drop-down list for the Group column: your saved groups + every group already on a Core.
$GroupList = New-Object 'System.Collections.ObjectModel.ObservableCollection[string]'
$Window.Resources.Add('GroupList', $GroupList)          # the XAML finds it by this name

function Update-GroupList {
    $all = @(@($Settings.Groups) + @($Systems | ForEach-Object { $_.Group })) |
           Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } |
           Sort-Object -Unique
    # Only touch the list if it changed (rebuilding it while a drop-down is open would close it).
    if ((@($GroupList) -join "`n") -ne (@($all) -join "`n")) {
        $GroupList.Clear()
        foreach ($g in $all) { $GroupList.Add($g) }
    }
}

function Show-GroupEditor {
    $ge = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Groups" Width="400" Height="440" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="14">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,10" Foreground="#444"
               Text="Groups organize your Cores (building, floor, department...). They're offered in the Group column's drop-down, and the tray menu shows Cores in submenus by group."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="GrpClose" Content="Close" Width="80" IsCancel="True"/>
    </StackPanel>
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <Button x:Name="GrpAdd" DockPanel.Dock="Right" Content="Add" Width="80" Margin="8,0,0,0"/>
      <TextBox x:Name="GrpNew" ToolTip="Type a group name, then Add (or press Enter)"/>
    </DockPanel>
    <StackPanel DockPanel.Dock="Right" Margin="8,0,0,0">
      <Button x:Name="GrpRename" Content="Rename..." Width="80" Margin="0,0,0,6"/>
      <Button x:Name="GrpRemove" Content="Remove"    Width="80"/>
    </StackPanel>
    <ListBox x:Name="GrpList" DisplayMemberPath="Label"/>
  </DockPanel>
</Window>
'@
    $script:GrpDlg = $ge.Window
    $script:GrpC   = $ge.C
    if ($Window.IsVisible) { $script:GrpDlg.Owner = $Window } else { $script:GrpDlg.WindowStartupLocation = 'CenterScreen' }

    # Fill the list: each group with how many Cores are in it.
    $refresh = {
        Update-GroupList
        $script:GrpC.GrpList.ItemsSource = @($GroupList | ForEach-Object {
            $name = $_
            $n = @($Systems | Where-Object { $_.Group.Trim() -eq $name }).Count
            [pscustomobject]@{ Name = $name; Label = $(if ($n) { "$name   ($n)" } else { $name }) }
        })
    }
    $script:GrpRefresh = $refresh
    & $refresh

    # Add: from the text box (button or Enter)
    $add = {
        $name = $script:GrpC.GrpNew.Text.Trim()
        if (-not $name) { return }
        if (@($Settings.Groups) -notcontains $name) { $Settings.Groups = @(@($Settings.Groups) + $name) }
        $script:GrpC.GrpNew.Clear()
        Save-AppData
        & $script:GrpRefresh
    }
    $script:GrpAddAction = $add
    $script:GrpC.GrpAdd.Add_Click({ & $script:GrpAddAction })
    $script:GrpC.GrpNew.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { & $script:GrpAddAction; $e.Handled = $true } })

    # Rename: updates the saved list AND every Core in that group.
    $script:GrpC.GrpRename.Add_Click({
        $sel = $script:GrpC.GrpList.SelectedItem
        if (-not $sel) { return }
        $new = [Microsoft.VisualBasic.Interaction]::InputBox("Rename group '$($sel.Name)' to:", 'Rename group', $sel.Name).Trim()
        if (-not $new -or $new -eq $sel.Name) { return }
        $Settings.Groups = @(@($Settings.Groups | Where-Object { $_ -ne $sel.Name }) + $new)
        foreach ($x in $Systems) { if ($x.Group.Trim() -eq $sel.Name) { $x.Group = $new } }
        Save-AppData; Update-TrayMenu
        Write-Log "Group '$($sel.Name)' renamed to '$new'."
        & $script:GrpRefresh
    })

    # Remove: Cores in it are left with no group (after asking).
    $script:GrpC.GrpRemove.Add_Click({
        $sel = $script:GrpC.GrpList.SelectedItem
        if (-not $sel) { return }
        $members = @($Systems | Where-Object { $_.Group.Trim() -eq $sel.Name })
        if ($members.Count) {
            $ans = [System.Windows.MessageBox]::Show("$($members.Count) Core(s) are in '$($sel.Name)'. Remove the group? They'll have no group.", 'Remove group', 'YesNo')
            if ($ans -ne 'Yes') { return }
            foreach ($x in $members) { $x.Group = '' }
        }
        $Settings.Groups = @($Settings.Groups | Where-Object { $_ -ne $sel.Name })
        Save-AppData; Update-TrayMenu
        Write-Log "Group '$($sel.Name)' removed."
        & $script:GrpRefresh
    })

    [void]$script:GrpDlg.ShowDialog()
}

function Show-About {
    $msg = "$AppName  v$AppVersion`n`n" +
           "An address book and launcher for Q-SYS Designer: finds installed versions, keeps a Core list, " +
           "checks Cores automatically, keeps Designer's hard links in sync, and shows Q-SYS devices heard on LAN A.`n`n" +
           "Independent community tool. Not made, endorsed or supported by QSC, LLC. " +
           "Q-SYS is a trademark of QSC, LLC.`n`n" +
           "Script:       $ScriptPath`n" +
           "Your data:  $AppFolder`n" +
           "Hard links: $HardLinkFile`n`n" +
           "Runs on Windows PowerShell $($PSVersionTable.PSVersion) (built into Windows)."
    [System.Windows.MessageBox]::Show($msg, "About $AppName") | Out-Null
}

#endregion

#region ==== 10. TRAY ICON =========================================
<#
  NotifyIcon is the Windows Forms "system tray" icon. It works fine alongside a WPF
  window because both run on this same thread's message loop.

  Left-click  -> show the window
  Right-click -> menu: your Cores (click = launch matching Designer), Designer
                 versions, Refresh now, Exit
#>
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$TrayIcon.Text = $AppName
$TrayIcon.ContextMenuStrip = $TrayMenu
$TrayIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
})

# The app's own icon (QSysLauncher.ico next to the script), at the small size the tray uses.
function Get-AppIcon {
    if (Test-Path $IconFile) {
        try { return New-Object System.Drawing.Icon($IconFile, [System.Windows.Forms.SystemInformation]::SmallIconSize) } catch { }
    }
    return [System.Drawing.SystemIcons]::Application
}

# Small pop-up note from the tray (e.g. "Room 101 changed address").
function Show-TrayNote([string]$Text) {
    try { $script:TrayIcon.ShowBalloonTip(6000, $AppName, $Text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}

# (Re)build the tray menu from the current list. Called after every refresh and edit.
function Update-TrayMenu {
    if (-not $script:TrayMenu) { return }
    $m = $script:TrayMenu
    $m.Items.Clear()

    # --- "Open" (bold, like a default action) ---
    $open = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList "Open $AppName"
    $open.Font = New-Object System.Drawing.Font($open.Font, [System.Drawing.FontStyle]::Bold)
    $open.Add_Click({ Show-MainWindow })
    [void]$m.Items.Add($open)
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # --- One item per enabled Core; grouped into submenus if you use the Group column ---
    $cores  = @($Systems | Where-Object { $_.Enabled } | Sort-Object Group, Name)
    $groups = @($cores | Group-Object Group)
    foreach ($g in $groups) {
        $target = $m.Items
        if ($groups.Count -gt 1 -or $g.Name) {
            $title = if ($g.Name) { $g.Name } else { 'Other' }
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $title
            [void]$m.Items.Add($sub)
            $target = $sub.DropDownItems
        }
        foreach ($s in $g.Group) {
            $label = $s.Name
            if ($s.Firmware) { $label += "    $($s.Firmware)" }
            if ($s.State -and $s.State -notmatch 'Active|Standby|Online|Heard on LAN A') { $label += '    (not answering)' }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $label
            $item.Tag = $s                                    # the click handler reads the Core from here
            $item.ToolTipText = "$($s.DesignName)  |  LAN B $($s.IpAddress)  LAN A $($s.LanA)"
            $item.Add_Click({
                param($sender, $e)
                try { Start-DesignerForSystem $sender.Tag } catch { Write-Log "Launch failed: $($_.Exception.Message)" }
            })
            [void]$target.Add($item)
        }
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # --- Plain Designer launches (no Core) ---
    $ver = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Designer versions'
    foreach ($d in @($script:Designers)) {
        $i = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList "Q-SYS Designer $($d.Version)"
        $i.Tag = $d
        $i.Add_Click({ param($sender, $e) try { Start-Designer $sender.Tag $null } catch { Write-Log "Launch failed: $($_.Exception.Message)" } })
        [void]$ver.DropDownItems.Add($i)
    }
    [void]$m.Items.Add($ver)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Log'
    $logItem.Add_Click({ Show-LogWindow })
    [void]$m.Items.Add($logItem)
    $optItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Options...'
    $optItem.Add_Click({ Show-OptionsDialog })
    [void]$m.Items.Add($optItem)

    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Check all Cores now'
    $refresh.Add_Click({ Start-RefreshCycle -Check })
    [void]$m.Items.Add($refresh)
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exit = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Exit'
    $exit.Add_Click({ Exit-App })
    [void]$m.Items.Add($exit)
}

function Show-MainWindow {
    $Window.Show()
    if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
    [void]$Window.Activate()
    $Window.Topmost = $true; $Window.Topmost = $false        # nudge it in front of other windows
}

# Really quit (the window's X button only hides to the tray).
function Exit-App {
    $script:Exiting = $true
    if ($Window.IsVisible) { Save-WindowBounds $Window 'MainBounds' }     # (if hidden, it was saved when hidden)
    if ($script:LogWindow -and $script:LogWindow.IsVisible) { Save-WindowBounds $script:LogWindow 'LogBounds' }
    try { $Grid.CommitEdit('Row', $true) | Out-Null; Save-AppData } catch { }
    if ($script:SyncPending) { Write-Log 'Exited with hard-link changes not yet written (Designer was open). They will be written next time.' }
    Stop-QdpListener
    Stop-WsdDiscovery
    foreach ($t in @($script:PollTimer, $script:F8Timer, $script:ProbeTimer, $script:RefreshTimer, $script:HouseTimer, $script:QdpTimer)) {
        try { $t.Stop() } catch { }
    }
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
    try { $Pool.Close(); $Pool.Dispose() } catch { }
    try { if ($script:LogWindow) { $script:LogWindow.Close() } } catch { }
    try { $Window.Close() } catch { }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()     # ends Dispatcher.Run() at the bottom
}

#endregion

#region ==== 11. WIRING: WINDOW EVENTS =============================

# --- Search box filters the list on any text column ---
$View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Systems)
$View.Filter = [Predicate[object]]{
    param($o)
    $q = $SearchBox.Text.Trim()
    if (-not $q) { return $true }
    return ("$($o.Name) $($o.Group) $($o.IpAddress) $($o.LanA) $($o.DesignName) $($o.Notes) $($o.Platform)" -like "*$q*")
}
$SearchBox.Add_TextChanged({ $View.Refresh() })
$Grid.ItemsSource = $View

# --- After you edit a row: save, and push the change to Designer + tray ---
# (Deferred with BeginInvoke so the new value is committed first.)
$Grid.Add_RowEditEnding({
    $Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        Save-AppData; Update-DesignerMatch; Invoke-AutoSync; Update-TrayMenu; Update-GroupList
    }) | Out-Null
})

# --- Everyday buttons ---
$BtnLaunch.Add_Click({ Start-DesignerForSystem $Grid.SelectedItem })
$Grid.Add_MouseDoubleClick({
    # Double-click a grey (automatic) column launches; on a white column it edits the cell.
    if ($Grid.CurrentColumn -and $Grid.CurrentColumn.IsReadOnly) { Start-DesignerForSystem $Grid.SelectedItem }
})
function Add-NewSystem {
    $s = New-Object QSystem
    $s.Id = [guid]::NewGuid().ToString()
    $s.Name = 'New system'
    $Systems.Add($s)
    $Grid.SelectedItem = $s
    $Grid.ScrollIntoView($s)
    Set-Status 'Added a row - type its LAN B IP; the rest fills in on the next check.'
}
$BtnPlus.Add_Click({ Add-NewSystem })

# --- First-run welcome: visible only while the list is empty ---
function Update-Welcome { $WelcomePanel.Visibility = if ($Systems.Count -eq 0) { 'Visible' } else { 'Collapsed' } }
$Systems.Add_CollectionChanged({ Update-Welcome })
$WelDevices.Add_Click({ $Tabs.SelectedIndex = 1 })
# Devices tab opened -> PTZ-IP camera question (section 7h). Only the tab control's own changes count
# (the grids inside raise SelectionChanged too).
$Tabs.Add_SelectionChanged({ param($sender, $e) if ($e.OriginalSource -eq $Tabs -and $Tabs.SelectedIndex -eq 1) { Invoke-DevicesTabOpened } })
$WelAdd.Add_Click({ Add-NewSystem })
$WelHelp.Add_Click({ Show-Help })
$BtnMinus.Add_Click({ Remove-SelectedSystems })
$BtnRefresh.Add_Click({ Start-RefreshCycle -Check })

# --- Right-click menu on the list ---
function Remove-SelectedSystems {
    $sel = @($Grid.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $names = ($sel | ForEach-Object { $_.Name }) -join ', '
    $ans = [System.Windows.MessageBox]::Show("Remove from your list and from Designer's hard links?`n`n$names", 'Remove', 'YesNo')
    if ($ans -ne 'Yes') { return }
    foreach ($s in $sel) {
        $script:DeletedIds[$s.Id] = [DateTime]::UtcNow.Ticks      # so a shared list doesn't bring it back
        # ...and so auto-add (7i) doesn't either: remember its name and LAN A address.
        Add-IgnoredCore $s.CoreName; Add-IgnoredCore $s.LanA
        foreach ($d in @($Devices | Where-Object { $_.InList -and $_.InList -eq $s.Name })) { Add-IgnoredCore $d.RawName; Add-IgnoredCore $d.LanA; $d.InList = '' }
        [void]$Systems.Remove($s)
    }
    Save-AppData
    Invoke-AutoSync
    Update-TrayMenu
    Set-Status "Removed $($sel.Count)."
}

$ctx = New-Object System.Windows.Controls.ContextMenu
function Add-ContextItem([string]$Header, [scriptblock]$Action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Add_Click($Action)
    [void]$ctx.Items.Add($mi)
}
Add-ContextItem 'Launch matching Designer' { Start-DesignerForSystem $Grid.SelectedItem }
Add-ContextItem 'Open Core Manager'        { $s = $Grid.SelectedItem; if ($s) { $ip = Get-QueryIp $s; if ($ip) { Start-Process "https://$ip" } } }
Add-ContextItem 'Trust this Core''s new certificate' { Reset-CoreCertificate $Grid.SelectedItem }
Add-ContextItem 'Check now (incl. firmware)' { $sel = [QSystem[]]@($Grid.SelectedItems); if ($sel.Count) { Start-CoreQuery $sel -Force } }
[void]$ctx.Items.Add((New-Object System.Windows.Controls.Separator))
Add-ContextItem 'Core login for this Core...' { Set-CoreLoginForRow $Grid.SelectedItem }
[void]$ctx.Items.Add((New-Object System.Windows.Controls.Separator))
Add-ContextItem 'Remove from list'         { Remove-SelectedSystems }
$Grid.ContextMenu = $ctx

# --- Devices tab ---
$script:DevStatus = $DevStatus
$DevView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Devices)
$DevView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Kind', 'Ascending')))
$DevView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Name', 'Ascending')))
$DevGrid.ItemsSource = $DevView

$devCtx = New-Object System.Windows.Controls.ContextMenu
foreach ($pair in @(
    @('Open web page',               { $d = $DevGrid.SelectedItem; if ($d) { $ip = if ($d.LanA) { $d.LanA } else { $d.LanB }; if ($ip) { Start-Process "https://$ip" } } }),
    @('Copy IP address',             { $d = $DevGrid.SelectedItem; if ($d) { $ip = if ($d.LanA) { $d.LanA } else { $d.LanB }; if ($ip) { [System.Windows.Clipboard]::SetText($ip) } } }),
    @('Add this Core to my Cores',   { Add-CoreFromDevice $DevGrid.SelectedItem }),
    @('Add all Cores not in my list', { Add-AllCoresFromDevices }),
    @('Forget devices not heard now', {
        foreach ($d in @($Devices | Where-Object { $_.Status -ne 'Live' })) {
            [void]$Devices.Remove($d)
            foreach ($k in @($script:DeviceIndex.Keys)) { if ($script:DeviceIndex[$k] -eq $d) { $script:DeviceIndex.Remove($k) } }
        }
        Update-DevStatus
    })
)) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $pair[0]
    $mi.Add_Click($pair[1])
    [void]$devCtx.Items.Add($mi)
}
$DevGrid.ContextMenu = $devCtx

# Right-click selects the row under the mouse first (WPF doesn't do that by itself).
$Grid.Add_PreviewMouseRightButtonDown({
    param($sender, $e)
    try {
        $d = $e.OriginalSource
        while ($d -and -not ($d -is [System.Windows.Controls.DataGridRow])) {
            if ($d -is [System.Windows.Media.Visual]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
            else { $d = [System.Windows.LogicalTreeHelper]::GetParent($d) }
        }
        if ($d -and -not $d.IsSelected) { $Grid.SelectedItems.Clear(); $d.IsSelected = $true }
    } catch { }
})

# --- Installed Designer list ---
$BtnLaunchVer.Add_Click({
    $d = $DesignerList.SelectedItem
    if ($d) { Start-Designer $d $null } else { Set-Status 'Pick a version first.' }
})
$DesignerList.Add_MouseDoubleClick({ if ($DesignerList.SelectedItem) { Start-Designer $DesignerList.SelectedItem $null } })

# --- Menu bar ---
# File
$MnuRefresh.Add_Click({ Start-RefreshCycle -Check })
$MnuSync.Add_Click({ Invoke-SyncWithPreview })
$MnuDataFolder.Add_Click({ Start-Process explorer.exe $AppFolder })
$MnuShortcut.Add_Click({ try { New-DesktopShortcut } catch { Set-Status "Couldn't create the shortcut: $($_.Exception.Message)" } })
$MnuExit.Add_Click({ Exit-App })
# Edit
$MnuAdd.Add_Click({ Add-NewSystem })
$MnuGroups.Add_Click({ Show-GroupEditor })
$MnuRemove.Add_Click({ Remove-SelectedSystems })
$MnuCheck.Add_Click({ $sel = [QSystem[]]@($Grid.SelectedItems); if ($sel.Count) { Start-CoreQuery $sel -Force } else { Set-Status 'Select one or more Cores first.' } })
$MnuCoreManager.Add_Click({ $s = $Grid.SelectedItem; if ($s) { $ip = Get-QueryIp $s; if ($ip) { Start-Process "https://$ip" } } })
# View
$MnuLog.Add_Click({ Show-LogWindow })
# Tools
$MnuLogin.Add_Click({ Invoke-CoreLoginPrompt })
$MnuProbe.Add_Click({ Start-ApiProbe $Grid.SelectedItem })
$MnuDump.Add_Click({
    if (-not (Get-RunningDesigner)) { Set-Status 'Open Designer (and its F8 dialog) first.'; return }
    try { Set-Status "Saved Designer UI map to $(Export-DesignerUiDump $null)" }
    catch { Set-Status "Dump failed: $($_.Exception.Message)" }
})
$MnuOptions.Add_Click({ Show-OptionsDialog })
# Help
$MnuHelp.Add_Click({ Show-Help })
$MnuAbout.Add_Click({ Show-About })

# --- Keyboard shortcuts: F1 help, F5 refresh, Ctrl+L log, Delete = remove selected rows ---
$Window.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $typing = [System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]
    switch ($e.Key) {
        'F1'     { Show-Help; $e.Handled = $true }
        'F5'     { Start-RefreshCycle -Check; $e.Handled = $true }
        'L'      { if ($ctrl) { Show-LogWindow; $e.Handled = $true } }
        'Delete' { if (-not $typing -and $Grid.IsKeyboardFocusWithin) { Remove-SelectedSystems; $e.Handled = $true } }
    }
})

# Manual sync with a preview of what will be removed (the automatic sync doesn't ask).
#   -SkipRemovalPrompt : addresses we EXPECT to disappear (e.g. a Core's old DHCP address).
function Invoke-SyncWithPreview([string[]]$SkipRemovalPrompt = @()) {
    $Grid.CommitEdit('Row', $true) | Out-Null
    if (Get-RunningDesigner) {
        $ans = [System.Windows.MessageBox]::Show("Q-SYS Designer is open.`n`nIt may overwrite the hard-link file when it closes, and won't see the changes until it restarts. Close Designer first for best results.`n`nWrite anyway?", 'Designer is running', 'YesNo')
        if ($ans -ne 'Yes') { return }
    }
    $p = Get-SyncPreview
    $surprises = @($p.Removed | Where-Object { $SkipRemovalPrompt -notcontains ($_ -split '\s+')[0] })
    if ($surprises.Count -gt 0) {
        $msg = "These hard links are in Designer but NOT in your list, so Sync will remove them:`n`n  " +
               ($p.Removed -join "`n  ")
        if ($p.Added.Count -gt 0) { $msg += "`n`nAnd will add:`n  " + ($p.Added -join "`n  ") }
        $msg += "`n`nContinue?"
        $ans = [System.Windows.MessageBox]::Show($msg, 'Sync preview', 'YesNo')
        if ($ans -ne 'Yes') { return }
    }
    try   { Save-AppData; Set-Status (Sync-DesignerHardLinks); $script:SyncPending = $false }
    catch { Set-Status "Sync failed: $($_.Exception.Message)" }
}

# --- Closing the window hides it to the tray; minimizing does too ---
$Window.Add_Closing({
    param($sender, $e)
    if ($script:Exiting) { return }
    $e.Cancel = $true
    Save-WindowBounds $Window 'MainBounds'
    if ($Settings.CloseAction -eq 'Exit') {
        # Exit after this event finishes (closing from inside Closing isn't allowed).
        $Window.Dispatcher.BeginInvoke([action]{ Exit-App }) | Out-Null
        return
    }
    try { $Grid.CommitEdit('Row', $true) | Out-Null; Save-AppData } catch { }
    $Window.Hide()
    if (-not $script:TrayTipShown) {
        $script:TrayTipShown = $true
        Show-TrayNote 'Still running in the tray (if you don''t see the icon, click the ^ arrow by the clock). Right-click it for your Cores, or use File > Exit to quit.'
    }
})

# --- Any unexpected error in a click handler goes to the log instead of closing the app ---
$Window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-Log "Unexpected error: $($e.Exception.Message)"
    $e.Handled = $true
})

# --- Timers ---
# Collects background Core checks (ticks only while checks are running).
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$PollTimer.Add_Tick({ Receive-CoreQueries })

# Watches freshly launched Designers so it can press F8.
$script:F8Timer = New-Object System.Windows.Threading.DispatcherTimer
$F8Timer.Interval = [TimeSpan]::FromSeconds(1)
$F8Timer.Add_Tick({ Invoke-F8Watches })


# Waits for a "Find firmware API" probe.
$script:ProbeTimer = New-Object System.Windows.Threading.DispatcherTimer
$ProbeTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$ProbeTimer.Add_Tick({ Receive-ApiProbe })

# Reads QDP announcements (Devices tab), twice a second.
$script:QdpTimer = New-Object System.Windows.Threading.DispatcherTimer
$QdpTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$QdpTimer.Add_Tick({ Receive-QdpPackets })

# The automatic refresh, every RefreshMinutes.
$script:RefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$RefreshTimer.Interval = [TimeSpan]::FromMinutes(5)      # quiet refresh; see Invoke-RefreshTick
$RefreshTimer.Add_Tick({ Invoke-RefreshTick })

# Housekeeping, once a second:
#   - another copy was started -> show this window instead
#   - every 15 s: if hard-link changes are waiting on Designer to close, try again
$script:HouseTicks = 0
$script:HouseTimer = New-Object System.Windows.Threading.DispatcherTimer
$HouseTimer.Interval = [TimeSpan]::FromSeconds(1)
$HouseTimer.Add_Tick({
    if ($script:ShowSignal.WaitOne(0)) { Show-MainWindow }
    if ($script:ExitSignal.WaitOne(0)) { Write-Log 'A newer copy was started - closing this one.'; Exit-App; return }
    $script:HouseTicks++
    if ($script:SyncPending -and ($script:HouseTicks % 15 -eq 0)) { Invoke-AutoSync }
    Receive-CertEvents                           # new / changed HTTPS certificates (section 5)
    if ($script:HouseTicks % 15 -eq 0) { Test-NetworkChange }   # network cards added / changed (section 7g)
    if ($Settings.SharedFolder -and ($script:HouseTicks % 5 -eq 0)) {
        $n = $Systems.Count
        Sync-SharedList
        if ($Systems.Count -ne $n) { Update-DesignerMatch; Update-TrayMenu }
        Update-GroupList                         # someone else may have added a group
    }
})

#endregion

#region ==== 12. START UP ===========================================

# 1) Load the list. First run: build it from Designer's existing hard links.
try {
    if (Load-AppData) {
        $script:DataLoaded = $true
        Write-Log "Loaded $($Systems.Count) systems from $SystemsFile"
    } else {
        $n = Import-DesignerHardLinks
        foreach ($x in $Systems) { if (-not $x.Id) { $x.Id = [guid]::NewGuid().ToString() } }
        $script:DataLoaded = $true
        Save-AppData
        Write-Log "First run: imported $n hard links from Designer into $SystemsFile"
    }
} catch {
    # Leave the latch off so a damaged file is never overwritten; say so.
    Write-Log "Could not load data: $($_.Exception.Message). Changes will NOT be saved this session - fix or rename $SystemsFile."
}

# 2) Saved login + check interval (safe now - the list and settings are loaded).
Restore-CoreLogin
Sync-SharedList                  # shared Core list (if one is set): merge it in now
Repair-LanColumns
Update-Welcome
Update-GroupList

# The Start-with-Windows shortcut was renamed in v0.12 - swap the old one for the new one.
if (Test-Path $OldStartupLnk) { Remove-Item $OldStartupLnk -ErrorAction SilentlyContinue; Set-StartWithWindows $true }

# 3) Installed Designers, icons, tray.
$script:Designers = Find-DesignerInstalls
$DesignerList.ItemsSource = $script:Designers
Update-DesignerMatch
$appIcon = Get-AppIcon
$TrayIcon.Icon = $appIcon
try {
    # Window (and taskbar) icon straight from the .ico, so Windows can pick the best size.
    if (Test-Path $IconFile) { $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($IconFile))) }
    else {
        $Window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $appIcon.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
} catch { }

# Taskbar identity for the main window: its own button and icon, and "Pin to taskbar" pins
# a button that starts THIS script (not plain PowerShell).
try {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).EnsureHandle()
    $relaunch = "`"$(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`""
    $err = [QslShell]::SetWindowAppId($hwnd, $AppId, $relaunch, $AppName, $(if (Test-Path $IconFile) { "$IconFile,0" } else { '' }))
    if ($err) { Write-Log "Taskbar identity not set: $err" }
} catch { Write-Log "Taskbar identity not set: $($_.Exception.Message)" }
Update-TrayMenu
$TrayIcon.Visible = $true
Write-Log "$AppName v$AppVersion started. Tray icon added (Windows may tuck it behind the ^ arrow by the clock)."

# 4) Put the window back where it was last time, then show it (unless started with -Tray),
#    start the timers, and run the first check.
Restore-WindowBounds $Window 'MainBounds'
if (-not $Tray) { $Window.Show() }
$Window.Title        = "$AppName  v$AppVersion"
$HeaderVersion.Text  = "$AppName  v$AppVersion"
$VersionText.Text    = "v$AppVersion"
$StatusText.Text = "$($Systems.Count) systems  |  $(@($script:Designers).Count) Designer versions  |  checking Cores..."
$RefreshTimer.Start()
$HouseTimer.Start()
Start-QdpListener
Invoke-RefreshTick          # quiet startup refresh (or a full check, if Options asks for automatic checks)

# 5) Run until Exit. (Dispatcher.Run keeps the app alive even while the window is hidden.)
[System.Windows.Threading.Dispatcher]::Run()

#endregion
