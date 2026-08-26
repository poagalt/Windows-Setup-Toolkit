# Windows Setup Toolkit

A program meant to debloat a fresh Windows installation in a controlled, 
customizable fashion on a device from any manufacturer. Runnable from 
flash drive, only needs Powershell 5.

## Using the GUI

Download the [latest release](https://github.com/poagalt/Windows-Setup-Toolkit/releases/latest),
unzip it, and double-click **`Run-WinSetupToolkit.cmd`**. It self-elevates and
opens on the mode screen. The given presets should be fairly self-explanatory.

Windows will warn that the publisher cannot be verified, because the launcher is
not code-signed. Press **Run**. Check the download against `SHA256SUMS.txt` on
the release page if you want to be sure of it:

```powershell
Get-FileHash .\WinSetupToolkit-1.0.0.zip -Algorithm SHA256
```

Or fetch and verify it in one step. This checks the hash against the release and
unpacks it, without running anything:

```powershell
irm https://raw.githubusercontent.com/poagalt/Windows-Setup-Toolkit/main/install.ps1 | iex
```

- **See all options** -- contains all other information you could need: the full 
  item list to modify a given preset or create your own with Custom, app
  removal for existing things you've downloaded, opt-in QoL changes, and
  more. Filter, Group by, and Sort by give you many options for viewing.
- **Compare modes** -- what one mode removes that another does not, and a
  button on each item to hand it to the mode that is missing it.
- **Windows setup completion file** -- create and customize an 
  `autounattend.xml` that automatically completes Windows setup straight 
  from installation media. It can be configured to run any preset of this
  deboat script directly afterwards, setting up your computer exactly as
  you want it from the start. It can also run from the Windows setup screen
  if your computer comes pre-installed.
- **Revert past changes** -- undo anything a previous run left behind.

Two settings under **Authority** in the all options window change how the run treats
what it has been told to remove, rather than adding anything to the list:

- **Allow vendor cleanup downloads** -- on by default; lets the tool fetch
  McAfee's own scrubber and similar vendor removal utilities.
- **Take ownership when Windows refuses** -- default on for Aggressive and Extreme, 
  off otherwise. Some services, scheduled tasks, and policy keys are owned by 
  TrustedInstaller and refuse even an administrator. With this on, the toolkit 
  seizes the key and retries, and only reports success if the retry actually worked. 
  It has no effect on apps Windows marks non-removable -- those are refused by the 
  app deployment stack rather than by permissions, and forcing them corrupts Windows 
  servicing.

## Command line

Verify the toolkit works on a machine without touching it. This one needs no
elevation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSetupToolkit.ps1 -SelfTest
```

List every item that applies here, with the mode that selects it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSetupToolkit.ps1 -ListItems
```

| Switch | What it does |
|---|---|
| *(none)* | Opens the GUI. This is the normal path. |
| `-Preset <name>` | `Conservative`, `Balanced` (default), `Aggressive`, `Extreme`. |
| `-SelfTest` | Verifies the toolkit works on this machine. Changes nothing, needs no elevation. |
| `-ListItems` | Prints every item that applies here, with its preset tier. |
| `-Console -Preview` | Full dry run, no GUI. Writes a report. |
| `-Console -Apply` | Unattended run. Restore point first. |
| `-ProfilePath x.json` | Uses a selection saved from the GUI. Overrides `-Preset`. |
| `-Select id1,id2` | Runs specific item ids. |
| `-NoDownloads` | Refuses to fetch vendor scrubbers. Downloads are **on** by default. |
| `-NoScan` | Curated manifest only; skips the runtime software scan. |
| `-ExportUnattend out.xml` | Writes a complete `autounattend.xml` for the selection. See below. |
| `-UnattendAccount <name>` | The local account the answer file creates. Defaults to `User`. |
| `-UnattendComputer <name>` | Computer name for the answer file. Empty lets Windows pick one. |
| `-UnattendLocale <tag>` | Language and locale, e.g. `en-GB`. Defaults to `en-US`. |

Reproducible across a fleet: save a selection once from the GUI, then

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSetupToolkit.ps1 -Console -Apply -ProfilePath .\my-profile.json
```

## Windows setup plus debloat

**Windows setup completion file** on the mode screen writes a **complete,
self-contained** `autounattend.xml`. Put it at the top level of your
installation USB stick, next to `setup.exe`, and Windows Setup automatically
applies it. It is plain-text, so you can read it to see exactly what it will
do.

Most options are self-explanatory, but it is highly recommended to leave options
you don't understand blank, since some are dangerous if used incorrectly. The 
existing defaults work for anyone and are best for the vast majority of people.

**How to use:**
- **Placement and naming** The top level of the installation USB stick, beside
  `setup.exe`, named exactly `autounattend.xml`.
- **Make the Windows installation media first, then copy the file onto it.**
- **Nothing on that page touches the computer you are on now.** The output is 
  purely a setup file, that is its only use.

**Any password you type on that page is stored in the file as plain text.** It
has to be: that is how Windows applies it. Make sure you own the installation 
media or device this script will run off of before putting in passwords for
*Your account* and *Wi-Fi*. You can easily make an account passowrd or connect
to Wi-Fi after Windows setup is complete.

**Use with Windows pre-installed devices** It
opens on the setup questions rather than on Windows Setup, so there is no
installer to read the stick and plugging it in does nothing on its own. 

**How to Use:** 
- Press **Shift+F10** at the first setup screen
- In the terminal that opens, use 
`for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\autounattend.xml copy /y %d:\autounattend.xml C:\Windows\Panther\unattend.xml`
  to copy the file onto your computer. It tries every drive letter, so you do not
  have to work out which one the stick is.
- In the same terminal, use 
`%WINDIR%\System32\Sysprep\sysprep.exe /generalize /oobe /reboot /unattend:C:\Windows\Panther\unattend.xml`
  to run it.

It will restart your computer and apply the setup. `/generalize` is not optional
here: without it Windows re-runs only the account and setup questions, and every
removal in the file is skipped in silence.

Choosing an edition, wiping a disk, and skipping the Windows 11 hardware checks
are ignored either way. Those are decisions made while *installing*, and this
machine already is. Everything else applies.

Do this **before creating an account**. Once you have finished the setup
questions the same command still works, but it resets the machine back through
them, making it significantly longer -- and sysprep refuses outright on a machine
where an account has already installed Store apps.

**Rufus writes an answer file of its own** Use either its customization 
options or this autounattend generator - they both do the exact same thing.

**Debloating directly after device setup** There is an
*Auto-debloat after setup* button in the `Windows setup completion` UI - it is
Off by default, so no file does this unless you say so. Pick a preset (the 
application will skip incompatible options if any exist), then copy the whole 
`WinSetupToolkit` folder onto the same USB stick beside `autounattend.xml` and 
`setup.exe`. If you chose a custom preset, the picker copies your choice into 
the toolkit's own `profile_saves` folder, since that folder is what travels to 
the machine.

Setup copies it to the machine while it installs and runs it at the very end of 
Setup, before the sign-in screen appears**. Nobody is signed in, nothing asks for 
a password, and no UAC prompt appears, because Windows runs it as the system 
account. Since the machine is a fresh install, its state is completely known 
and there is no risk in doing this.

*Auto-debloat after setup* is unavailable while **Account type** under *Your
account* is set to a standard user, because then the only account on the machine
would be unable to revert the changes. The application assumes this is a mistake
from the user and does not allow it.

Because there is no screen to show it on, a detailed write-up is produced in
a folder on the desktop (same folder as a usual apply) detailing everything the 
toolkit would have said on screen: totals, what needs a restart, what to do next, 
and every item with what happened to it. The first person to sign in gets a small 
window prompting them to open the completed GUI page, which has that information
too, and visually formatted for your convenience. The text file is just in case
something goes wrong with the GUI.

Anything needing a download may fail on a machine whose network is not up yet;
the run reports each of those rather than stopping.

The same thing from the command line:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSetupToolkit.ps1 -ExportUnattend .\autounattend.xml -Preset Balanced -UnattendAccount nathan
```

## The item list

**See all options** holds everything the run will do, in three boxed sections:
**Remove**, **Add** -- software plus quality-of-life tweaks -- and **Extras**,
which is how the run behaves rather than what it touches.

**Edits last as long as the window.** Closing the application drops them, the
  way closing anything else without saving does. What it does not touch is
  anything you chose to keep: a mode redefined with **Save > Default**, and any
  selection loaded from a file.
**Save** has two behaviors: it can write a `.json` you can carry to another 
  machine (loading a preset from file checks for what actually applies to 
  the machine it's being loaded on and lists what it dropped) or change the 
  default of one of the factory presets. Unless you save your preset changes,
  in one of those two ways they will be lost when you exit the app.

### Unselectable options

To display the reason something is grayed-out per-option, enable "verbose mode" 
in the "app options" section of the all options window. For reference, they are:
**not on this machine**, **already installed**, **already set**, or
ruled out by another tick. 

### Settings, not just removals

**App permissions govern only Microsoft Store apps.**

**Power options:**
| | what it is worth |
|---|---|
| Stop scheduled tasks waking the machine | the fix for a laptop that comes out of the bag warm and flat |
| Drop the network while asleep | a few hundred milliwatts on a machine background traffic was keeping awake, nothing at all on one that already idles |
| Let idle USB and PCIe devices power down | a little, steadily -- and the first thing to undo if a dock or audio interface misbehaves |
| Real sleep instead of Modern Standby | by far the largest saving, and the one that can leave a machine that will not wake |

### Nothing is installed by default

No factory preset installs anything by default - it's all bloat removal unless
you decide you want more.

## Removing Edge

Pick a replacement in either of two places -- a strip under *Uninstall Microsoft
Edge*, or the **Web browser** block in **Add**. They are the same choice, and you
can pick more than one.

**On a machine whose only browser is Edge**, Chrome is queued automatically and
a notice says so once, because removing Edge there otherwise leaves no way to
reach the internet. On a machine that already has another browser nothing is
queued and there is no notice. Backing out of Edge removal withdraws a browser
the toolkit queued for you and leaves alone one you asked for by name.

**Ticking Edge removal also ticks Edge's extensions**, which are otherwise left
as folders in a profile nothing reads any more. Picking a *mode* that removes
Edge does not -- an extension is something you deliberately installed, which is
why no mode selects one.

**Change default browser cannot be done silently** Windows 11 puts
a kernel driver and a signed hash in the way, so you will have to do this
manuall after debloating is finished. If you forget, it will be very easy to
tell why and fix it in a few seconds the next time you try to open a pdf.

## Protected items

- Windows frameworks, shell hosts, sign-in UI, servicing, and media codecs
- Drivers, redistributables, and runtimes -- Visual C++, .NET, WebView2,
  chipset, audio, GPU, and wireless
- Core Windows services and anything driver-backed
- **Vendor tools that own power, thermals, firmware, lighting, or hotkeys** --
  Lenovo Vantage and Legion, Dell Power Manager and Command Update, HP Power
  Manager, Armoury Crate, NitroSense, MSI Center, Samsung Settings, and Razer
  Synapse. These are system dependencies on the hardware they ship with;
  removing them costs you battery charge limits and fan curves.
- Peripheral suites -- Logitech, Corsair, SteelSeries, Wacom, and X-Rite

The full list is at the bottom of the all options window.

## Why removals come back

Five ways a removal undoes itself. The first catches nearly everybody:

| Vector | Why it matters |
|---|---|
| Package removed per-user but still **provisioned** | Windows re-stages it at the next sign-in and after every feature update. This is the one that catches people out. |
| ContentDeliveryManager silent installs | Puts Instagram, Prime Video, and Candy Crush back at next sign-in. |
| `DisableWindowsConsumerFeatures` unset | Suggested apps return. |
| EdgeUpdate active while Edge is gone | Reinstalls the browser. |
| `PushToInstall` tasks enabled | Re-delivers Store apps. |

Every run closes all of these rather than reporting them, and only touches the
Edge updater when Edge is actually gone.

**Two options in Extras go further** and re-apply your saved selection later:
after a **feature update**, which is the one event that reliably undoes a
debloat, and at **every logon**, which honestly I have no idea why you would
want that but it's there. Both re-apply removals only -- no installs or
QoL changes.

Both run as the system account, which has no desktop, so they tell you through a
small task in your own session at the next sign-in. Each account that signs in
is told once. Installing either one copies the toolkit into `ProgramData` first,
so the guard keeps working after the folder you ran it from goes away -- and it
refuses to install at all if that copy fails, rather than registering a task
that would fail in silence every boot.

## Undoing a run

Every run creates a folder under `C:\ProgramData\WinSetupToolkit\run-<timestamp>\`
holding the log, a per-item report, the append-only journal of every change, a
`.reg` export of every key before it was touched, and the rollback script.

**Every apply also leaves a folder on your desktop** -- `WinSetupToolkit apply` and
the date -- with the rollback script, *What this run did.md*, the common issues
document, the log, and a *Read me first* saying what each one is for 
(Unless you manually untick any of those options, which is not recommended). 
Deleting the folder is perfectly safe, though if you do not have access to the 
application after it was run (someone else's USB drive), it is not advisable.

A system restore point is also made before an apply, so you should have that as
well, identifiable by the matching date to the folder on your desktop.

### The rollback script

**Use the `.cmd`, not the `.ps1` beside it.** Windows associates `.ps1` with a
text editor, so double-clicking the script opens it in a text editor rather than
running it. Running it opes a GUI - it does not immediately undo anything, it 
sends you to an all-options window for reversion.

This script does not depend on the application's presence at all - it is designed
specifically to be stand-alone from it, in case you don't have access to it.

From a terminal it also takes:

| | |
|---|---|
| `-Console` | no window: put everything back, printing as it goes |
| `-ListOnly` | change nothing, just report what is still in place |
| `-Only a,b` | restrict to named options |
| `-Theme dark` | open in one palette rather than following Windows |

**Revert past changes** on the application's main screen is the same page for
a run whose folder you still have, plus two things the script cannot offer: 
the recurring options listed above, with whether each is currently active, and a
**reinstall** for software past runs uninstalled. 

### What comes back, and what does not

Registry values, service start types, scheduled tasks, and Windows features roll
back exactly. **An uninstalled program is a reinstall rather than an undo**, and
nothing that works from a record of what changed can do better; those are listed
by name so you know what they were.

Anything that deletes a folder sends it to the Recycle Bin, and the rollback puts
it back from there. On a volume with no Recycle Bin those items refuse rather
than deleting permanently behind your back.

**Extreme turns that off.** *Make this run permanent* deletes outright and
empties the Recycle Bin when the run finishes, including anything you put there
yourself beforehand. Registry and service changes still reverse; nothing that
touched the file system does. Untick it in the all options window if you want a way back.

**Note:** Windows features and capabilities cannot be changed at all while a restart is
pending.

## Diagnosing issues after an apply

**The common issues document** is written by every mode into the run folder and
the desktop folder. If some behavior doesn't feel right after an apply and you
suspect this application, open this document.

It is a lookup table rather than a document to read. Ctrl+F what is actually
broken -- *camera not working*, *cant print*, *no updates*, *win+v not working*
-- and it names the options that could cause it and how to undo that one option.

Once you've found the option you think is culpable, the section underneath the 
list of lookup phrases is every way to revert the change manually (or you can
revert it with the script, if possible)

## Outcomes

During an apply, every option ends on one of nine results. The run screen
colors them and lets you click any status to hide or show that group.

| Status | Meaning |
|---|---|
| `Removed` | The target existed and is gone. |
| `Changed` | A setting was written. |
| `AlreadySet` | The target is here and already exactly what this would make it. Nothing to do. |
| `NotPresent` | Nothing to do, because the target is not here. **A success** -- on a clean install much of the list legitimately isn't there. |
| `Skipped` | Deliberately not attempted. |
| `Obstruction` | Something is in the way that nothing has tried yet -- a degraded component store, winget missing, or a change Windows hands to you rather than letting any program make. |
| `Partial` | Some actions succeeded, some did not. |
| `Blocked` | Windows was asked and refused. The message says whether administrator rights would fix it or nothing will. |
| `Failed` | An error. |

`Found` is not an outcome: it is something the leftover hunt turned up for you
to look at, and nothing was changed.

In a preview, clicking a line also offers to drop that item from what **Apply**
will do. Click it again to put it back -- nothing about excluding an item is
final until you press Apply.

## License and commercial use

Source-available under the **PolyForm Noncommercial License 1.0.0**
([LICENSE](LICENSE)). Every line the tool runs is in this repository, and the
removal list is plain JSON in `Manifest\`, so you can check what a preset
touches without running anything.

- **Personal use is free**, on as many of your own machines as you like. Nothing
  is withheld, time-limited, or feature-gated.
- **Commercial use needs a license.** If you are paid for the work -- a
  refurbisher, repair shop, MSP, or IT department deploying across a fleet --
  get in touch.

Not affiliated with or endorsed by Microsoft. *Windows* is a trademark of
Microsoft Corporation.
