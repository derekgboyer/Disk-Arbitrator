//
//  DiskArbitratorAppController.m
//  DiskArbitrator
//
//  Created by Aaron Burghardt on 1/10/10.
//  Copyright 2010 Aaron Burghardt. All rights reserved.
//

#import "DiskArbitratorAppController.h"
#import "DiskArbitratorAppController+Toolbar.h"
#import "AppError.h"
#import "Arbitrator.h"
#import "Disk.h"
#import "SheetController.h"
#import "DiskInfoController.h"
#import "AttachDiskImageController.h"
#import "AuditLog.h"
#import "TrustedDiskStore.h"
#import <ServiceManagement/ServiceManagement.h>
#include <unistd.h>
#include <errno.h>

static NSString * const LaunchAgentPlistName = @"us.burghardt.Disk-Arbitrator.plist";
static NSString * const LaunchAgentLabel = @"us.burghardt.Disk-Arbitrator";

////////////////////////////////////////////////////////////////////////////////

@interface AppController ()
{
	NSMutableArray *displayErrorQueue; //
	NSMutableArray *diskInfoControllers;
	id userActivity;
}

@end

////////////////////////////////////////////////////////////////////////////////

@implementation AppController

@synthesize window;
@synthesize statusMenu;
@synthesize tableView;
@synthesize disksArrayController;
@synthesize sortDescriptors;
@synthesize statusItem;
@synthesize arbitrator;
@synthesize hasUserLaunchAgent;
@synthesize installUserLaunchAgentMenuTitle;

- (void)dealloc
{
	if (arbitrator.isActivated)
		[arbitrator deactivate];
}

- (void)setStatusItemIconWithName:(NSString *)name
{
	NSString *iconPath = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];
	NSImage *statusIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
	statusItem.button.image = statusIcon;
}

- (void)refreshStatusItemIcon
{
	if (arbitrator.isActivated == NO)
		[self setStatusItemIconWithName:@"StatusItem Disabled 1"];
	
	else if (arbitrator.mountMode == MM_BLOCK)
		[self setStatusItemIconWithName:@"StatusItem Green"];

	else if (arbitrator.mountMode == MM_READONLY)
		[self setStatusItemIconWithName:@"StatusItem Orange"];
	
	else
		NSAssert1(NO, @"Invalid mount mode: %ld\n", (long)arbitrator.mountMode);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	[self refreshLaunchAgentStatus];
	
	NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
	[defaults setObject:[NSNumber numberWithInt:LOG_INFO] forKey:AppLogLevelDefaultsKey];
	[defaults setObject:[NSNumber numberWithBool:YES]     forKey:@"ShowMainWindowAtStartup"];
	[defaults setObject:[NSNumber numberWithBool:NO]     forKey:@"ShowMainWindowAtActivate"];
	[[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
	
	displayErrorQueue = [NSMutableArray new];
	
	// App Nap or sudden termination would delay or kill the mount-approval callback and
	// let diskarbitrationd mount the volume read-write.
	userActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
	                                                               reason:@"Respond immediately to disk mount requests"];
	[[NSProcessInfo processInfo] disableSuddenTermination];

	NSStatusBar *bar = [NSStatusBar systemStatusBar];
	self.statusItem = [bar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *altImage = [[NSImage imageNamed:@"StatusItem Disabled 1.png"] copy];
    [altImage setTemplate:YES];
    self.statusItem.button.alternateImage = altImage;
	NSButtonCell *statusButtonCell = (NSButtonCell *)self.statusItem.button.cell;
	if ([statusButtonCell isKindOfClass:[NSButtonCell class]])
		statusButtonCell.highlightsBy = NSNoCellMask;
	[self setStatusItemIconWithName:@"StatusItem Disabled 1"];
	statusItem.menu = statusMenu;

	[self insertStatusMenuItemWithTitle:NSLocalizedString(@"Full Disk Access…", nil) action:@selector(showFullDiskAccessHelp:)];
	[self insertStatusMenuItemWithTitle:NSLocalizedString(@"Audit Log…", nil) action:@selector(showAuditLog:)];
	[self insertStatusMenuItemWithTitle:NSLocalizedString(@"Trusted Disks…", nil) action:@selector(showTrustedDisks:)];
	[self insertStatusMenuItemWithTitle:NSLocalizedString(@"Trust Selected Disk", nil) action:@selector(trustSelectedDisk:)];
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(diskDidChange:) name:DADiskDidChangeNotification object:nil];
	[center addObserver:self selector:@selector(trustedDisksChanged:) name:TrustedDiskStoreDidChangeNotification object:nil];
	[center addObserver:self selector:@selector(didAttemptEject:) name:DADiskDidAttemptEjectNotification object:nil];
	[center addObserver:self selector:@selector(didAttemptMount:) name:DADiskDidAttemptMountNotification object:nil];
	[center addObserver:self selector:@selector(didAttemptUnmount:) name:DADiskDidAttemptUnmountNotification object:nil];
	
	self.arbitrator = [Arbitrator new];
	[arbitrator addObserver:self forKeyPath:@"isActivated" options:0 context:NULL];
	[arbitrator addObserver:self forKeyPath:@"mountMode" options:0 context:NULL];
	[self refreshStatusItemIcon];  // arbitrator status initial state is taken from user defaults, which was initialized before KVO initialized

	Log(LOG_INFO, @"Disk Arbitrator %@ running. activated=%d mode=%ld",
		[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
		(int)arbitrator.isActivated, (long)arbitrator.mountMode);

	self.sortDescriptors = [NSArray arrayWithObject:[[NSSortDescriptor alloc] initWithKey:@"BSDNameNumber" ascending:YES]];
	
	SetupToolbar(window, self);
	window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
	window.worksWhenModal = YES;
	
	[tableView registerForDraggedTypes: @[NSPasteboardTypeFileURL] ];

	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ShowMainWindowAtStartup"])
		[window makeKeyAndOrderFront:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ShowMainWindowAtActivate"])
		[window makeKeyAndOrderFront:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (object == arbitrator)
		if ([keyPath isEqual:@"isActivated"] || [keyPath isEqual:@"mountMode"])
			[self refreshStatusItemIcon];
}

- (IBAction)showAboutPanel:(id)sender
{
	[NSApp orderFrontStandardAboutPanel:sender];
	ActivateDiskArbitratorApp();
}

- (IBAction)showMainWindow:(id)sender
{
	[window makeKeyAndOrderFront:sender];
	ActivateDiskArbitratorApp();
}

- (void)insertStatusMenuItemWithTitle:(NSString *)title action:(SEL)action
{
	NSInteger preferencesIndex = [statusMenu indexOfItemWithTarget:self andAction:@selector(showPreferences:)];
	if (preferencesIndex == NSNotFound)
		return;

	NSInteger insertAt = preferencesIndex + 1;
	while (insertAt < (NSInteger)statusMenu.numberOfItems) {
		NSMenuItem *existing = [statusMenu itemAtIndex:insertAt];
		if (existing.isSeparatorItem || existing.action == @selector(performActivation:) || existing.action == @selector(performDeactivation:))
			break;
		insertAt++;
	}

	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
	item.target = self;
	[statusMenu insertItem:item atIndex:insertAt];
}

- (IBAction)showAuditLog:(id)sender
{
	[[AuditLogWindowController sharedController] showWindow:sender];
	ActivateDiskArbitratorApp();
}

- (IBAction)showTrustedDisks:(id)sender
{
	[[TrustedDisksWindowController sharedController] showWindow:sender];
	ActivateDiskArbitratorApp();
}

- (IBAction)trustSelectedDisk:(id)sender
{
	NSError *error = nil;
	TrustedDiskRule *rule = [[TrustedDiskStore sharedStore] trustDisk:self.selectedDisk error:&error];
	if (!rule) {
		[[NSAlert alertWithError:error] runModal];
		return;
	}
	[self.tableView reloadData];
}

- (void)trustedDisksChanged:(NSNotification *)notification
{
	[self.tableView reloadData];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(trustSelectedDisk:)) {
		Disk *disk = self.selectedDisk;
		BOOL identifiable = DAVolumeUUIDForDisk(disk).length > 0 || DAMediaUUIDForDisk(disk).length > 0;
		BOOL alreadyTrusted = identifiable && [[TrustedDiskStore sharedStore] ruleMatchingDisk:disk] != nil;
		menuItem.title = alreadyTrusted ? NSLocalizedString(@"Selected Disk Is Trusted", nil)
										: NSLocalizedString(@"Trust Selected Disk", nil);
		return identifiable && !alreadyTrusted;
	}
	if (menuItem.action == @selector(performActivation:))
		return !self.arbitrator.isActivated;
	if (menuItem.action == @selector(performDeactivation:))
		return self.arbitrator.isActivated;
	return YES;
}

- (IBAction)showPreferences:(id)sender
{
	static NSWindowController *controller = nil;

	if (!controller)
		controller = [[NSWindowController alloc] initWithWindowNibName:@"Preferences"];

	[controller.window makeKeyAndOrderFront:self];
	ActivateDiskArbitratorApp();
}

- (IBAction)performActivation:(id)sender
{
	[arbitrator activate];
}

- (IBAction)performDeactivation:(id)sender
{
	[arbitrator deactivate];
}

- (IBAction)toggleActivation:(id)sender
{
	if (arbitrator.isActivated)
		[self performDeactivation:sender];
	else
		[self performActivation:sender];
}

- (IBAction)performSetMountBlockMode:(id)sender
{
	arbitrator.mountMode = MM_BLOCK;
}

- (IBAction)performSetMountReadOnlyMode:(id)sender
{
	arbitrator.mountMode = MM_READONLY;
}

- (void)performMountSheetDidEnd:(NSWindow *)sheet
	returnCode:(NSInteger)returnCode sheetController:(SheetController *)controller;
{
	[sheet orderOut:self];
	
	Disk *selectedDisk = self.selectedDisk;
	NSMutableArray *arguments = [NSMutableArray array];
	
	if (returnCode == NSModalResponseOK) {
		NSDictionary *options = controller.userInfo;
		
		if ([[options objectForKey:@"readOnly"] boolValue] == YES)
			[arguments addObject:@"rdonly"];

		if ([[options objectForKey:@"noOwners"] boolValue] == YES)
			[arguments addObject:@"noowners"];

		if ([[options objectForKey:@"noBrowse"] boolValue] == YES)
			[arguments addObject:@"nobrowse"];

		if ([[options objectForKey:@"ignoreJournal"] boolValue] == YES)
			[arguments addObject:@"-j"];

		NSString *path = [options objectForKey:@"path"];
		
		[selectedDisk mountAtPath:path withArguments:arguments];
	}
}

- (IBAction)performMount:(id)sender
{
	Disk *selectedDisk = self.selectedDisk;

	NSAssert(selectedDisk, @"No disk selected.");
	NSAssert(selectedDisk.isMounted == NO, @"Disk is already mounted.");

	SheetController *controller = [[SheetController alloc] initWithWindowNibName:@"MountOptions"];
	[controller window]; // triggers controller to load the NIB
	
	[[controller userInfo] setObject:[NSNumber numberWithBool:YES] forKey:@"readOnly"];
	[[controller userInfo] setObject:[NSNumber numberWithBool:selectedDisk.isHFS] forKey:@"ignoreJournal"];
	[[controller userInfo] setObject:[NSNumber numberWithBool:selectedDisk.isHFS] forKey:@"isHFS"];
	
	[window makeKeyAndOrderFront:self];

	[window beginSheet:controller.window completionHandler:^(NSModalResponse returnCode)
		{
			[self performMountSheetDidEnd:controller.window
				returnCode:returnCode sheetController:controller];
		}];
}

- (IBAction)performUnmount:(id)sender
{
	Disk *theDisk = self.selectedDisk;
	
	if (!theDisk) return;
	
	[theDisk unmountWithOptions: theDisk.isWholeDisk ?  kDiskUnmountOptionWhole : kDiskUnmountOptionDefault];
}

- (IBAction)performMountOrUnmount:(id)sender
{
	Disk *theDisk = self.selectedDisk;
	
	if (theDisk.isMounted)
		[self performUnmount:sender];
	else
		[self performMount:sender];
}

- (void)_childDidAttemptUnmountBeforeEject:(NSNotification *)notif
{
	Disk *disk = notif.object;

	// Disk may be a mountable whole disk that we were waiting on, so the parent may be the disk itself
	
	Disk *parent = disk.isWholeDisk ? disk : disk.parent;
	
	Log(LOG_DEBUG, @"%s disk: %@ child: %@", __func__, parent, disk);
	
	[[NSNotificationCenter defaultCenter] removeObserver:self name:DADiskDidAttemptUnmountNotification object:disk];
	
	// Confirm the child unmounted
	
	if (disk.isMounted) {
		// Unmount of child failed
		
		NSMutableDictionary *info = [[notif userInfo] mutableCopy];
		
		Log(LOG_INFO, @"%s eject disk: %@ canceled due to mounted child: %@", __func__, disk, info);
		
		NSString *statusString = [NSString stringWithFormat:@"%@:\n\n%@",
								  NSLocalizedString(@"Failed to unmount child", nil),
								  [info objectForKey:NSLocalizedFailureReasonErrorKey]];
		
		[info setObject:statusString forKey:NSLocalizedFailureReasonErrorKey];
		[info setObject:statusString forKey:NSLocalizedRecoverySuggestionErrorKey];
		
		[[NSNotificationCenter defaultCenter] postNotificationName:DADiskDidAttemptEjectNotification object:disk userInfo:info];
	}
	
	// Child from notification is unmounted, check for remaining children to unmount
	
	for (Disk *child in parent.children) {
		if (child.isMounted)
			return;			// Still waiting for child
	}
	
	// Need to test if parent is ejectable because we enable "Eject" for a disk
	// that has children that can be unmounted (ala Disk Utility)
	
	if (parent.isEjectable)
		[parent eject];
}

- (IBAction)performEject:(id)sender
{
	Disk *selectedDisk = self.selectedDisk;
	BOOL waitForChildren = NO;
	
	NSSet *disks;
	if (selectedDisk.isWholeDisk && selectedDisk.isLeaf)
		disks = [NSSet setWithObject:selectedDisk];
	else
		disks = selectedDisk.children;
	
	for (Disk *disk in disks) {
		if (disk.isMountable && disk.isMounted) {
			[[NSNotificationCenter defaultCenter] addObserver:self
													 selector:@selector(_childDidAttemptUnmountBeforeEject:)
														 name:DADiskDidAttemptUnmountNotification
													   object:disk];
			[disk unmountWithOptions:0];
			waitForChildren = YES;
		}
	}

	if (!waitForChildren) {
		if (selectedDisk.isEjectable)
			[selectedDisk eject];
	}
}

- (IBAction)performGetInfo:(id)sender
{
	DiskInfoController *controller = [[DiskInfoController alloc] initWithWindowNibName:@"DiskInfo"];
	controller.disk = self.selectedDisk;
	[controller showWindow:self];
	[controller refreshDiskInfo];
    if (!diskInfoControllers) {
        diskInfoControllers = [[NSMutableArray alloc] init];
    }
    [diskInfoControllers addObject:controller];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(diskInfoWindowDidClose:) name:NSWindowWillCloseNotification object:[controller window]];
}

- (void)diskInfoWindowDidClose:(NSNotification *)notif
{
    DiskInfoController *controllerToRemove = nil;
    for (DiskInfoController *controller in diskInfoControllers) {
        if ([controller window] == [notif object]) {
            controllerToRemove = controller;
            break;
        }
    }
    if (controllerToRemove) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:[notif object]];
        [diskInfoControllers removeObject:controllerToRemove];
    }
}

- (IBAction)performAttachDiskImage:(id)sender
{
	AttachDiskImageController *controller = [[AttachDiskImageController alloc] initWithWindowNibName:@"AttachDiskImageAccessory"];
	[controller window];
	[controller performAttachDiskImage:sender];
}

#pragma mark Launch Agent

- (SMAppService *)launchAgentService
{
	return [SMAppService agentServiceWithPlistName:LaunchAgentPlistName];
}

- (NSString *)userLaunchAgentPath {

	NSString *path = nil;
	
	CFStringRef identifier = CFBundleGetIdentifier(CFBundleGetMainBundle());
	if (identifier) {
		path = [NSString stringWithFormat:@"%@/%@/%@.plist", NSHomeDirectory(), @"Library/LaunchAgents", identifier];
	}

	return  path;
}

- (BOOL)legacyLaunchAgentInstalled
{
	NSString *path = self.userLaunchAgentPath;
	return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (void)removeLegacyLaunchAgentPlist
{
	NSString *path = self.userLaunchAgentPath;
	if (path.length == 0)
		return;
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

- (void)bootoutLaunchAgent
{
	// Drops a job loaded from ~/Library/LaunchAgents. SMAppService jobs use the same label.
	// bootout can quit this process when launchd started it; KeepAlive on the new agent starts it again.
	NSTask *task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
	task.arguments = @[ @"bootout", [NSString stringWithFormat:@"gui/%d/%@", getuid(), LaunchAgentLabel] ];
	if ([task launchAndReturnError:NULL])
		[task waitUntilExit];
}

- (void)refreshLaunchAgentStatus {
	SMAppServiceStatus status = self.launchAgentService.status;
	BOOL registered = (status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval);
	self.hasUserLaunchAgent = registered || [self legacyLaunchAgentInstalled];
	if (self.hasUserLaunchAgent)
		self.installUserLaunchAgentMenuTitle = @"Uninstall User Launch Agent...";
	else
		self.installUserLaunchAgentMenuTitle = @"Install User Launch Agent...";
}

- (BOOL)canInstallLaunchAgent {
	return (self.hasUserLaunchAgent == NO);
}

- (void)showFullDiskAccessHelp:(id)sender
{
	ActivateDiskArbitratorApp();

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = NSLocalizedString(@"Full Disk Access", nil);
	alert.informativeText = NSLocalizedString(@"Mount blocking uses a Disk Arbitration approval callback and does not itself require Full Disk Access. Grant it if the disk list stays empty, Get Info cannot read a volume, or you image disks from this Mac. macOS will not prompt; add Disk Arbitrator in System Settings > Privacy & Security > Full Disk Access, then quit and reopen it.", nil);
	[alert addButtonWithTitle:NSLocalizedString(@"Open Full Disk Access Settings", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Close", nil)];
	if ([alert runModal] == NSAlertFirstButtonReturn) {
		NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"];
		[[NSWorkspace sharedWorkspace] openURL:url
		                          configuration:[NSWorkspaceOpenConfiguration configuration]
		                      completionHandler:nil];
	}
}

- (IBAction)installUserLaunchAgent:(id)sender {
	NSError *error = nil;
	NSAlert *alert = nil;
	SMAppService *service = self.launchAgentService;

	ActivateDiskArbitratorApp();

	if (self.hasUserLaunchAgent) {
		BOOL hadLegacy = [self legacyLaunchAgentInstalled];
		[self removeLegacyLaunchAgentPlist];
		NSError *unregisterError = nil;
		BOOL unregistered = [service unregisterAndReturnError:&unregisterError];
		if (hadLegacy)
			[self bootoutLaunchAgent];
		if (unregistered || hadLegacy) {
			alert = [[NSAlert alloc] init];
			alert.messageText = NSLocalizedString(@"Launch Agent removed.", nil);
			alert.informativeText = NSLocalizedString(@"Disk Arbitrator will no longer start at login. If it quits now, launchd is dropping the old job.", nil);
		}
		else if (unregisterError) {
			alert = [NSAlert alertWithError:unregisterError];
		}
	}
	else {
		// A plist left in ~/Library/LaunchAgents uses an absolute path and fights SMAppService for the same label.
		// Don't bootout here: if launchd started this process, bootout would kill it before register returns.
		BOOL hadLegacy = [self legacyLaunchAgentInstalled];
		[self removeLegacyLaunchAgentPlist];

		if ([service registerAndReturnError:&error]) {
			alert = [[NSAlert alloc] init];
			alert.messageText = NSLocalizedString(@"Launch Agent installed.", nil);
			if (service.status == SMAppServiceStatusRequiresApproval) {
				alert.informativeText = NSLocalizedString(@"macOS requires approval before the agent can run. In System Settings > General > Login Items, allow Disk Arbitrator. The agent relaunches the app if it quits.", nil);
				[alert addButtonWithTitle:NSLocalizedString(@"Open Login Items", nil)];
				[alert addButtonWithTitle:NSLocalizedString(@"Close", nil)];
				if ([alert runModal] == NSAlertFirstButtonReturn)
					[SMAppService openSystemSettingsLoginItems];
				alert = nil;
			}
			else {
				alert.informativeText = NSLocalizedString(@"launchd will open Disk Arbitrator at login and relaunch it if it quits. Copy the app to /Applications before installing so the agent keeps finding it.", nil);
			}
		}
		else if (error) {
			alert = [NSAlert alertWithError:error];
			if (hadLegacy) {
				alert.informativeText = NSLocalizedString(@"The previous Launch Agent file was removed, but launchd may still have the old job loaded. Log out and back in, then install the Launch Agent again.", nil);
			}
		}
	}
	if (alert)
		[alert runModal];
	
	[self refreshLaunchAgentStatus];
}

#pragma mark Selected Disk

- (Disk *)selectedDisk
{
	NSIndexSet *indexes = [disksArrayController selectionIndexes];
	
	if (indexes.count == 1)
		return [disksArrayController.arrangedObjects objectAtIndex:indexes.lastIndex];
	else
		return nil;
}

- (BOOL)canEjectSelectedDisk
{
	/* "Eject" in the GUI means eject or unmount (like Disk Utility)
	 * To the Disk class, "ejectable" means the media object is ejectable.
	 */

	Disk *selectedDisk = self.selectedDisk;
	BOOL canEject = [selectedDisk isEjectable];

	if (!canEject) {
		for (Disk *child in selectedDisk.children) {
			if (child.isMountable && child.isMounted)
				canEject = YES;
		}
	}
	return canEject;
}

- (BOOL)canMountSelectedDisk
{
	Disk *disk = self.selectedDisk;
	
	if (disk.isMountable && !disk.isMounted)
		return YES;
	else
		return NO;
}

- (BOOL)canUnmountSelectedDisk
{
	Disk *disk = self.selectedDisk;

	return (disk.isMountable && disk.isMounted);
	
//	// Yes if the disk or any children are mounted
//	
//	if (disk.mountable && disk.mounted) return YES;
//	
//	for (Disk *child in disk.children)
//		if (child.mountable && child.mounted)
//			return YES;
}

#pragma mark TableView Delegates

// A custom cell is used for the media description column.  Couldn't find a way to bind it to the disk
// object, so implemented the dataSource delegate.

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)rowIndex
{
    Disk *disk;
	
    NSParameterAssert(rowIndex >= 0 && rowIndex < arbitrator.disks.count);
    disk = [disksArrayController.arrangedObjects objectAtIndex:rowIndex];

	if ([column.identifier isEqual:@"BSDName"])
		return disk.BSDName;

	//	fprintf(stdout, "getting value: %s\n", disk.BSDName.UTF8String);
	return disk;
}

- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{
    Log(LOG_DEBUG, @"%s op: %ld info: %@", __func__, (long)op, info);

	NSArray<NSURL *> *files = [info.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
	                                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	NSURL *file = files.firstObject;

	if ( file ) {
		NSArray *extensions = [AttachDiskImageController diskImageFileExtensions];

		if ([extensions containsObject:file.pathExtension.lowercaseString] == NO) {
			return NSDragOperationNone;
		}
		return NSDragOperationGeneric;
	}
	return NSDragOperationNone;
}

- (void)doAttachDiskImageAtPath:(NSString *)path
{
	NSError *error;
	
	AttachDiskImageController *controller = [[AttachDiskImageController alloc] initWithWindowNibName:@"AttachDiskImageAccessory"];
	[controller window];

	NSArray *options;
	if (arbitrator.isActivated)
		options = [NSArray arrayWithObjects:@"-readonly", @"-nomount", nil];
	else
		options = [NSArray arrayWithObjects:@"-readonly", @"-mount", @"optional", nil];
	
	if (![controller attachDiskImageAtPath:path options:options password:nil error:&error])
	{
		[NSApp presentError:error];
	}
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info
			  row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
	Log(LOG_DEBUG, @"%s", __func__);

	NSArray<NSURL *> *files = [info.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
	                                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	NSURL *file = files.firstObject;
	if ( file ) {
		Log(LOG_DEBUG, @"file: %@", file);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self doAttachDiskImageAtPath:file.path];
		});
	}
	return YES;
}

#pragma mark Window Delegates

- (void)windowWillClose:(NSNotification *)notification
{
	[NSApp deactivate];
}

#pragma mark Disk Notifications

- (void)didPresentErrorWithRecovery:(BOOL)didRecover contextInfo:(void *)contextInfo
{
	// If another sheet has unexpected been displayed, recover gracefully
	
	if (window.attachedSheet) {
		Log(LOG_INFO, @"Discarding pending errors: %@", displayErrorQueue);
		[displayErrorQueue removeAllObjects];
		return;
	}
	
	if (displayErrorQueue.count > 0)
	{
		NSError *nextError = [displayErrorQueue objectAtIndex:0];
	
		[window makeKeyAndOrderFront:self];
		[NSApp presentError:nextError
			 modalForWindow:window
				   delegate:self
		 didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
				contextInfo:NULL];

		[displayErrorQueue removeObjectAtIndex:0];
	}		
}

- (void)presentDiskError:(NSError *)error
{
	if (!error)
		return;

	if (window.attachedSheet) {
		[displayErrorQueue addObject:error];
		return;
	}

	[window makeKeyAndOrderFront:self];
	[NSApp presentError:error
		 modalForWindow:window
			   delegate:self
	 didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
			contextInfo:NULL];
}

- (void)diskDidChange:(NSNotification *)notif
{
	NSUInteger row = [disksArrayController.arrangedObjects indexOfObject:notif.object];
	
	[tableView setNeedsDisplayInRect:[tableView rectOfRow:row]];
	[window.toolbar validateVisibleItems];
}

- (void)didAttemptMount:(NSNotification *)notif
{
	Disk *disk = notif.object;
	NSMutableDictionary *info;
	
	if (disk.isMounted && [disk.mountArgs containsObject:@"rdonly"] && disk.isFileSystemWritable) {
		Log(LOG_ERR, @"Volume %@ was requested read-only but mounted writable; unmounting.", disk.BSDName);
		[[AuditLog sharedLog] recordEvent:DAAuditEventError
									  disk:disk
									action:@"read_only_mount_came_up_writable"
								   message:NSLocalizedString(@"The volume mounted writable after a read-only request. It has been unmounted.", nil)];
		NSDictionary *info = @{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", NSLocalizedString(@"Read-only mount failed", nil), disk.BSDName],
			NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"The volume mounted writable after a read-only request. It has been unmounted.", nil),
			NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Confirm the volume is unmounted before imaging, and use a hardware write-blocker for evidence.", nil)
		};
		NSError *error = [NSError errorWithDomain:AppErrorDomain code:EPERM userInfo:info];
		[disk unmountWithOptions:kDiskUnmountOptionDefault];
		[self presentDiskError:error];
	}
	else if (disk.isMounted) {
		Log(LOG_DEBUG, @"%s: Mounted: %@", __func__, disk.BSDName);
	}
	else {
		// If the mount failed, the notification userInfo will have keys/values that correspond to an NSError
		
		info = [[notif userInfo] mutableCopy];
		
		NSString *reason = [info objectForKey:NSLocalizedFailureReasonErrorKey];
		Log(LOG_ERR, @"Mount failed: %@ (%@) %@", disk.BSDName, [info objectForKey:DAStatusErrorKey], reason);
		
		[info setObject:[NSString stringWithFormat:@"%@: %@", NSLocalizedString(@"Mount rejected", nil), disk.BSDName]
				 forKey:NSLocalizedDescriptionKey];
		
		NSError *error = [NSError errorWithDomain:AppErrorDomain
											 code:[[info objectForKey:DAStatusErrorKey] intValue]
										 userInfo:info];

		// Don't show our internal dissenter error
		if (![reason isEqualToString:arbitrator.dissenterMessage]) {
			if (window.attachedSheet) {
				[displayErrorQueue addObject:error];
			}
			else {
				[window makeKeyAndOrderFront:self];
				[NSApp presentError:error
					 modalForWindow:window
						   delegate:self
				 didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
						contextInfo:NULL];
			}
		}
	}
	[window.toolbar validateVisibleItems];
}

- (void)didAttemptUnmount:(NSNotification *)notif
{
	Disk *disk = notif.object;
	NSMutableDictionary *info;

	Log(LOG_DEBUG, @"%s: Unmount %@: %@", __func__, (disk.isMounted ? @"failed" : @"succeeded"), disk.BSDName);

	if (disk.isMounted) {
		// If the unmount failed, the notification userInfo will have keys/values that correspond to an NSError
		
		info = [[notif userInfo] mutableCopy];
		
		Log(LOG_INFO, @"Unmount %@ failed: (%@) %@", disk.BSDName, [info objectForKey:DAStatusErrorKey], [info objectForKey:NSLocalizedFailureReasonErrorKey]);
		
		[info setObject:NSLocalizedString(@"Unmount failed", nil) forKey:NSLocalizedDescriptionKey];
		
		NSError *error = [NSError errorWithDomain:AppErrorDomain
											 code:[[info objectForKey:DAStatusErrorKey] intValue]
										 userInfo:info];

		if (window.attachedSheet) {
			[displayErrorQueue addObject:error];
		}
		else {
			
			[window makeKeyAndOrderFront:self];
			[NSApp presentError:error
				 modalForWindow:window
					   delegate:self
			 didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
					contextInfo:NULL];
		}
	}
	[window.toolbar validateVisibleItems];
}

- (void)didAttemptEject:(NSNotification *)notif
{
	Disk *disk = notif.object;
	
	if ([notif userInfo]) {
		
		NSMutableDictionary *info = [[notif userInfo] mutableCopy];
		
		// If the eject failed, the notification userInfo will have keys/values that correspond to an NSError
		
		Log(LOG_INFO, @"Ejecting %@ failed: (%@) %@", disk.BSDName, [info objectForKey:DAStatusErrorKey], [info objectForKey:NSLocalizedFailureReasonErrorKey]);
		
		[info setObject:NSLocalizedString(@"Eject failed", nil) forKey:NSLocalizedDescriptionKey];
		
		NSError *error = [NSError errorWithDomain:AppErrorDomain
											 code:[[info objectForKey:DAStatusErrorKey] intValue]
										 userInfo:info];

		if (window.attachedSheet) {
			[displayErrorQueue addObject:error];
		}
		else {
			
			[window makeKeyAndOrderFront:self];
			[NSApp presentError:error
				 modalForWindow:window
					   delegate:self
			 didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
					contextInfo:NULL];
		}
	}
	else {
		Log(LOG_DEBUG, @"%s: Ejected: %@", __func__, disk);
	}
	[window.toolbar validateVisibleItems];
}

@end
