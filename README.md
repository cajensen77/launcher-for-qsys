# Launcher for Q-SYS

A small Windows tray utility that turns your Cores into an address book. Pick a Core, and it opens the Designer version that matches the Core's firmware and loads the design from the Core (Load from Core & Connect), with no hunting for IP addresses or version numbers. It also keeps Designer's hard-link list in sync with that address book.

It works for anyone who looks after Q-SYS Cores. It was built with end-user owners in mind (universities, campuses, facilities) who maintain one system spread over many Cores. It runs on what Windows already has (PowerShell and .NET), so there is nothing to install.

**Download:** see [Releases](../../releases) for the latest zip.

## Features

| Feature | What it does |
| --- | --- |
| Core address book | One list of your Cores: name, group, LAN A and LAN B addresses, Core model, firmware, running design, notes. Sort, filter and group it. |
| Designer version matching | Finds every installed Designer version and shows, per Core, whether the matching version is installed (OK / Patch / Missing). |
| One-click launch + Load from Core | Opens the matching Designer, waits until it is fully loaded, opens Load from Core & Connect, selects that Core and (optionally) clicks Load. |
| Hard-link sync | Keeps Designer's shared hard-link list (used by every installed version) in step with your address book, with Core names attached. |
| Moving LAN B addresses | When DHCP changes a Core's LAN B address, the launcher hears the new address in the Core's own announcement and updates the list and hard links right away. |
| Live discovery (Devices tab) | Lists Cores and peripherals announcing on the AV network (LAN A): kind, model, LAN A/B, live or not. Optional: older PTZ-IP cameras. |
| Auto-add Cores | Cores heard on your LAN A that aren't in your list are added automatically. Emulators and Cores you removed are left out. |
| Quiet on the network | By default it only listens. It talks to a Core only when you ask (Check all now, Check now, or launching a Core whose firmware isn't known), so Core event logs stay clean. |
| Logins | One login for all Cores, or a login per Core. Passwords are stored encrypted for your Windows account only. |
| Team sharing | Point several PCs at one shared folder to share one Core list. Edits merge, and removals stick. |
| Groups | Group Cores (building, floor, department) with a group editor and a drop-down. |
| Tray utility | Runs in the system tray, can start with Windows, and launches a Core from the tray menu. |

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- At least one Q-SYS Designer installed
- For discovery: a network card on the AV network (LAN A). Without one, everything else still works over LAN B.

## Setup

1. Download the zip from [Releases](../../releases).
2. Right-click the zip > **Properties** > tick **Unblock** > OK. (Windows flags downloaded scripts; this clears it for every file in the zip.)
3. Extract the folder anywhere, e.g. Documents.
4. Double-click `Start QSys Launcher.cmd`. The first time, it imports your existing Designer hard links as a starting list.
5. When Windows Firewall asks about PowerShell, allow it on **Private** networks. Discovery needs this.
6. If your Cores use Access Control: **Tools > Core login** (one login for all), or right-click a Core for its own login.
7. Optional, in **Options**: start with Windows, auto-sync, Load from Core mode, a shared folder for team use.

Your list and settings live in `%AppData%\QSysLauncher` (with automatic backups). Nothing is written to Designer's install folders. Full details are in the built-in help (Help menu).

## Limitations

| Limitation | What to know |
| --- | --- |
| Exact Designer version | Designer generally needs the Core's exact firmware version to connect. *Missing* means install that version; *Patch* means only the last number differs. |
| Hard links write when Designer is closed | Designer can overwrite the shared hard-link file while it's open, so changes are held and written when you close Designer. |
| Discovery needs multicast | The Devices tab and auto-add rely on Q-SYS discovery on LAN A: Firewall allowed (Private), an IGMP querier on the AV switches, and the PC's card on LAN A. |
| Load from Core automation | Designer has no remote-control interface, so the launcher operates Designer's menu and dialog through Windows' accessibility interface (UI Automation). A future Designer version that changes that dialog may need an update. |
| Brief focus switch | If you're working in another window, Designer jumps forward for about a second to open its menu, then focus returns to you. For the smoothest run, launch and just wait the few seconds until the design is loaded. |
| Core Manager logins | Firmware is read through Core Manager. With Access Control on, a login is needed, and each login shows in the Core's event log (minimized by design). |
| Logins are per PC | Passwords are encrypted for your Windows account and are not shared through a shared folder. Each person enters their own. |

## Problems?

Open an [issue](../../issues) and attach `launcher.log` from `%AppData%\QSysLauncher` (View > Log shows it too). For Load from Core problems, also attach `designer-ui-dump.txt` from the same folder.

## Not a QSC product

Independent tool, not made, endorsed or supported by QSC. Q-SYS is a trademark of QSC, LLC. Use at your own risk; your Designer and Cores are not modified beyond Designer's hard-link list.
