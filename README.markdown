## Introduction

Disk Arbitrator is a Mac OS X forensic utility designed to help the user ensure correct forensic procedures are followed during imaging of a disk device. 
Disk Arbitrator is essentially a user interface to the Disk Arbitration framework, which enables a program to participate in the management of block 
storage devices, including the automatic mounting of file systems.  When enabled, Disk Arbitrator will block the mounting of file systems to avoid mounting as read-write and violating the integrity of the evidence.

It is important to note that Disk Arbitrator is *not* a software write blocker---it does not change the state of currently attached devices nor does it affect newly attached devices to force a device to be read-only. The user still must be careful to not accidentally write to a disk with a command such as "dd".  Owing to this fact, a hardware or software write-blocker may still be desirable for the most sound procedure.  Disk Arbitrator compliments a write-blocker with additional useful features and eliminates the typical forensic recommendation to "disable disk arbitration."

## System Requirements

* Mac with Apple silicon or Intel
* macOS 13 Ventura or later
* A universal build (`arm64` and `x86_64`) from the Xcode project. Xcode 15 or later is enough; current Xcode is fine.
* The app is not sandboxed. Disk Arbitration mount approval does not work from an App Sandbox.

Build the **DiskArbitrator** scheme in Xcode. Release produces one universal `Disk Arbitrator.app`. Ad-hoc signing (`CODE_SIGN_IDENTITY = -`) plus the hardened runtime lets that local build run on Apple silicon. It is not notarized. The first time you open a downloaded copy, use the Finder (right-click the app, choose Open) or allow it under System Settings > Privacy & Security. Copy it to `/Applications` before you rely on it. Running it from a disk image hits App Translocation, and a Launch Agent then points at a path that disappears.

## Permissions

Disk Arbitrator has no privilege helper. Mount decisions are made by a normal user-level Disk Arbitration approval session.

* **Full Disk Access** is not required for the approval callback itself. Grant it anyway when the disk list stays empty, Get Info cannot read a volume, or you will image the disk from this Mac. macOS does not prompt. Open the menu item **Full Disk Access…**, or go to System Settings > Privacy & Security > Full Disk Access, add **Disk Arbitrator**, then quit and reopen it.
* **Login Items.** "Install User Launch Agent" registers the agent inside the app bundle with `SMAppService` (macOS 13 and later). macOS may leave it waiting for approval under System Settings > General > Login Items & Extensions. Allow it there. The agent starts Disk Arbitrator at login and relaunches it if it quits. That is still after login: disks attached at the login window or earlier can already be mounted. System Integrity Protection prevents unloading `diskarbitrationd`, so there is no supported way for this app to block those early mounts.
* An older install may still have `~/Library/LaunchAgents/us.burghardt.Disk-Arbitrator.plist`. Install the agent again from version 0.9 so launchd uses the copy embedded in the app. The old file hard-coded the executable path and used the obsolete `EnableTransactions` key.

## Limitations on current macOS

These are limits of Disk Arbitration and SIP, not optional features that were removed.

* This is still not a write blocker. A volume that is already mounted is left as it is. `dd` and other tools can still write to the raw device. Use a hardware write-blocker when the procedure requires one.
* Protection exists only while the app is running and activated. Quitting it, or letting macOS terminate it, stops the approval callback. Version 0.9 turns off sudden termination and App Nap so a running copy stays scheduled to answer mount requests.
* **Block Mounts** dissents every new mount, including APFS volumes on external disks and disk images. It does not unmount volumes that are already mounted, and it does not change the startup disk.
* **Read-only** dissents the system mount, then mounts again with the `rdonly` option. For HFS it still passes `-j` (ignore journal). APFS, ExFAT, and MS-DOS do not get `-j`; a dirty APFS volume usually mounts read-only without replaying a journal, but if it does not, attach a disk image with a shadow file or mount it by hand. After a read-only request, Disk Arbitrator checks `statfs`. If the volume came up writable, it unmounts it and shows an error. Confirm with `mount` before you trust the volume.
* The first system mount request is rejected, and only a mount Disk Arbitrator itself just submitted is approved. That closes a gap where a second system attempt could be allowed read-write before the read-only remount started.
* APFS containers show up as one whole disk plus a volume per container entry. Snapshot and synthesized disks that have no BSD name are ignored so they cannot crash the callback.
* Disk icons come from Finder (`NSWorkspace`). The old kext-bundle lookup does not work when the media driver lives only in the kernel collection, which is the usual case on Apple silicon.
* Menu-bar icons are the original artwork (about 20×24 pixels). They are functional on a Retina display and are not redrawn at 2x.
* Encrypted disk images ask for a password in the app. The old Authorization Services prompt stopped returning the password the user typed. Software license agreements are still answered "Yes" automatically.
* Time Machine and other automatic mounts are blocked while Disk Arbitrator is activated. That is the same behavior as before.

## Downloads

You can find links to compiled executables on the [releases](https://github.com/aburgh/Disk-Arbitrator/releases) page.

## Quick Start

### Installation

To install, drag the Disk Arbitrator application to the desired location, for example /Applications.

You may optionally want to have Disk Arbitrator automatically running every time you log in. There are two ways to do this:

* Add Disk Arbitrator to your Login Items in the User & Groups (or Accounts on older OS X versions) preference panel in System Preferences.

* Use the included "Install User Launch Agent" feature (accessible from the menu). On macOS 13 and later this registers a Launch Agent that is stored inside the app bundle. launchd starts Disk Arbitrator when you log in and relaunches it if it quits. Approve the item under System Settings > General > Login Items if macOS asks. This is the strongest option while you are logged in. It does not cover mounts that happen before login.

### Usage

When launched, it adds its icon to the status bar on the right side of the menu bar. The status bar icon indicates one of three states:

* Green: the utility is activated and in Block Mounts mode.

* Orange: the utility is activated and in Read-only mode.

* Gray: the utility is deactivated and attached disks will be automatically mounted by the system.

Disk Arbitrator continuously monitors for disks to appear and disappear and tracks the disks in the main window. When a new disk is attached, the system notifies Disk Arbitrator and gives it a chance to reject mounting of a disk volume.  Disk Arbitrator responds as such:

* When deactivated, it just observes the disk changes

* When activated and in Block Mounts mode, it simply rejects every new system attempt to mount a volume.

* When activated and in Read-only mode, it rejects the original mount action and automatically sends its own request to mount the volume, but it ensures the mount includes the option to make the file system read-only.  It also checks the file system type and, if it is HFS, it includes the flag to ignore the journal.

**Reminder:** Disk Arbitrator does its work by actively participating in the mounting process. If the utility is deactivated or is quit and not running, there is no protection from auto-mounting attached disks.  However, once a disk appears and the process of either mounting or rejecting the mount is finished, then Disk Arbitrator may be quit without affecting the state of the disk.

### Working With Disk Images

As of version 0.3.0, Disk Arbitrator has support for disk images.  

Using Disk Arbitrator's Attach Disk Image feature, attaching the disk image is effectively coordinated.  When "Attach Disk Image..." is selected from the menu, an open panel appears which includes additional options for attaching and mounting the disk image.  The default is to only attach the disk image.  When the "Open" button is clicked, Disk Arbitrator attaches the disk using hdiutil.  Once it is attached, Disk Arbitrator's normal behavior applies, so if it is activated and the mode is set to Read-Only, the volumes on the disk image will be mounted read-only.  If the mode is set to Block Mounts, the volumes will be ignored.

The disk image open panel includes an option to attempt to mount the disk image for when Disk Arbitrator isn't activated and is being used as a convenient means to attach a disk image.  When the mount option is used, Disk Arbitrator passes "-mount optional" to hdiutil, which attempts to attach and mount the disk image, but with the benefit that if the mount fails, the disk image is not detached.

Disk Arbitrator also supports drag and drop to attach a disk image.  Simply drag one or more disk images from a Finder window to Disk Arbitrator's list of disks to initiate attaching the disk images.  When using drag and drop, the default options include "-mount optional", so mounting is also attempted.  If the mount fails, the disk image remains attached and can be mounted manually.

Notes:

* Attempting to attach and mount a disk image outside of Disk Arbitrator, either by double-clicking it in the Finder or using hdiutil attach, will behave as before: the disk image will be attached, then the system will attempt to mount it, Disk Arbitrator will reject the mount, and the disk image will be unattached because the mount failed.

* If a disk image with a Software License Agreement is attached, Disk Arbitrator automatically replies "Yes" to the agreement.  Caveat Emptor.

### A Note On Dirty Journals

When set to Read-only mode, the mount request that Disk Arbitrator sends includes the option to ignore the journal, which is useful when the HFS file system was last detached without unmounting (e.g., the system crashed, or an external drive was unplugged without ejecting it). If you are working with a disk that was not cleanly ejected, then attempts to attach it read-only will normally fail because HFS knows the journal needs to be replayed and it is not allowed to make the changes, so it fails to mount.

Mounting a disk image with a dirty file system can be achieved by using a shadow file, but this is less than ideal. The shadow file protects the original disk image from changes, but the file system is mounted read-write.  A better option is to execute the two steps manually, using Terminal:

1. `hdiutil attach -nomount disk_image.dmg`
2. `mount_hfs -j -o rdonly /dev/diskx /mount/path`

Disk Arbitrator provides a convenient way to execute the second step, and a future version will perform both steps in one operation.
