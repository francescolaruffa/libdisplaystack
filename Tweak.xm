//
//  Created by Dan Zimmerman
//  Copyright 2010 Dan Zimmerman
//
#import "DSDisplayController.h"

#import <SpringBoard/SpringBoard.h>
#import <SpringBoard/SBUIController.h>
#import <SpringBoard/SBAwayController.h>
#import <SpringBoard/SBApplicationController.h>
#import <SpringBoard/SBSoundPreferences.h>
#import <SpringBoard/SBUIController.h>
#import <SpringBoard/SBDisplayStack.h>
#import <SpringBoard/SBDisplay.h>
#import <SpringBoard/SBAlert.h>
#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBIconList.h>
#import "SBAppDosadoView.h"

#import "UIModalView.h"
#import "UIModalViewDelegate.h"

@interface SpringBoard (Backgrounder)
- (void)setBackgroundingEnabled:(BOOL)enable forDisplayIdentifier:(NSString *)identifier;
@end

@interface SBUIController (CategoriesSB)
- (void)categoriesSBCloseAll;
- (void)activateApplicationFromSwitcher:(id)app;
@end

@interface UIDevice (iPad)
- (BOOL)isWildcat;
@end

%class SBApplicationController;
%class SBAwayController;
%class SBSoundPreferences;
%class SBUIController;
%class SBAppDosadoView;

static NSString *killedApp;
static NSMutableArray *displayStacks;
static NSMutableArray *activeApps;
static NSMutableArray *backgroundedApps;
static DSDisplayController *sharedInstance;


#define SBWPreActivateDisplayStack        [displayStacks objectAtIndex:0]
#define SBWActiveDisplayStack             [displayStacks objectAtIndex:1]
#define SBWSuspendingDisplayStack         [displayStacks objectAtIndex:2]
#define SBWSuspendedEventOnlyDisplayStack [displayStacks objectAtIndex:3]
#define springBoardApp (SpringBoard *)[UIApplication sharedApplication]
#define kSpringBoardDisplayIdentifier @"com.apple.springboard"

%hook SBDisplayStack

- (id)init
{
	if ((self = %orig)) {
		[displayStacks addObject:self];
	}
	return self;
}

- (void)dealloc
{
    [displayStacks removeObject:self];
    %orig;
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application
{
	displayStacks = (NSMutableArray *)CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
	activeApps = [[NSMutableArray alloc] init];
	backgroundedApps = [[NSMutableArray alloc] init];
    %orig;
}

- (void)setBackgroundingEnabled:(BOOL)enable forDisplayIdentifier:(NSString *)identifier
{
	if (enable) {
		if (![backgroundedApps containsObject:identifier])
			[backgroundedApps addObject:identifier];
	} else {
		if ([backgroundedApps containsObject:identifier])
			[backgroundedApps removeObject:identifier];
	}
	%orig;
}

%end

%hook SBApplication

- (void)_relaunchAfterExit
{
    if ([[self displayIdentifier] isEqualToString:killedApp]) {
        // We killed this app; do not let it relaunch
        [killedApp release];
        killedApp = nil;
    } else {
        %orig;
    }
}

- (void)launchSucceeded:(BOOL)unknownFlag
{
	NSString *identifier = [self displayIdentifier];
	if (![activeApps containsObject:identifier]) {
		[activeApps addObject:identifier];
	}
	%orig;
}

- (void)exitedAbnormally
{
	[activeApps removeObject:[self displayIdentifier]];
	%orig;
}

- (void)exitedCommon
{
    // Application has exited (either normally or abnormally);
    // remove from active applications list
    [activeApps removeObject:[self displayIdentifier]];
    %orig;
}

%end

__attribute__((constructor)) static void LibDisplayStackInitializer()
{
	dlopen("/Library/MobileSubstrate/DynamicLibraries/Backgrounder.dylib", RTLD_LAZY);
	//Make sure its loaded!
	%init;
}

@implementation DSDisplayController

- (SBDisplayStack *)preActivateStack
{
	return SBWPreActivateDisplayStack;
}

- (SBDisplayStack *)activeStack
{
	return SBWActiveDisplayStack;
}

- (SBDisplayStack *)suspendingStack
{
	return SBWSuspendingDisplayStack;
}

- (SBDisplayStack *)suspendedEventOnlyStack
{
	return SBWSuspendedEventOnlyDisplayStack;
}

- (SBApplication *)activeApp
{
	// Return active app if there is one, otherwise SpringBoard
	if ([[[UIDevice currentDevice] systemVersion] floatValue] < 4.0)
		return [SBWActiveDisplayStack topApplication] ?: [(SBApplicationController *)[$SBApplicationController sharedInstance] springBoard];
	else
		return [SBWActiveDisplayStack topApplication] ?: [(SBApplicationController *)[$SBApplicationController sharedInstance] applicationWithDisplayIdentifier:@"com.apple.springboard"];
}

- (NSSet *)activeApplications
{
	return [[NSSet alloc] initWithArray:activeApps];
}

- (NSArray *)activeApps
{
	return [[activeApps copy] retain];
}

- (NSSet *)backgroundedApplications
{
	return [[NSSet alloc] initWithArray:backgroundedApps];
}

- (NSArray *)backgroundedApps
{
	return [[backgroundedApps copy] retain];
}

+ (void)initialize
{
	sharedInstance = [[DSDisplayController alloc] init];
}

+ (DSDisplayController *)sharedInstance
{
	if (!sharedInstance)
		sharedInstance = [[DSDisplayController alloc] init];
	return sharedInstance;
}

- (void)activateAppWithDisplayIdentifier:(NSString *)identifier animated:(BOOL)animated
{
	SBAwayController *awayCont = [$SBAwayController sharedAwayController];
	if ([awayCont isLocked])
		[awayCont unlockWithSound:[$SBSoundPreferences playLockSound]];
	
	SBApplication *fromApp = [SBWActiveDisplayStack topApplication];
    NSString *fromDisplayId = fromApp ? [fromApp displayIdentifier] : kSpringBoardDisplayIdentifier;
	NSLog(@"From app display identifier is: %@", fromDisplayId);
	SBApplication *app = [(SBApplicationController *)[$SBApplicationController sharedInstance] applicationWithDisplayIdentifier:identifier];
	
	if ([[app displayIdentifier] isEqualToString:[fromApp displayIdentifier]])
		return;
		// Make sure that the target app is not the same as the current app
		// NOTE: This is checked as there is no point in proceeding otherwise
		// NOTE: Save the identifier for later use
		//deactivatingApp = [fromDisplayId copy];

	
		BOOL switchingToSpringBoard = [identifier isEqualToString:kSpringBoardDisplayIdentifier];

		if ([fromDisplayId isEqualToString:kSpringBoardDisplayIdentifier]) {
			// Switching from SpringBoard; simply activate the target app
			[app setDisplaySetting:0x4 flag:YES]; // animate
			if (!animated)
				[app setActivationSetting:0x1000 value:[NSNumber numberWithInteger:1]];
			// Activate the target application
			[SBWPreActivateDisplayStack pushDisplay:app];
		} else {
			if ([[[UIDevice currentDevice] systemVersion] floatValue] < 4.0f) {
				if (!switchingToSpringBoard) {
					// Switching to another app; setup app-to-app
					[app setActivationSetting:0x40 flag:YES]; // animateOthersSuspension
					[app setActivationSetting:0x20000 flag:YES]; // appToApp
					[app setDisplaySetting:0x4 flag:YES]; // animate
					if (!animated)
						[app setActivationSetting:0x1000 value:[NSNumber numberWithInteger:1]];

					// Activate the target application (will wait for
					// deactivation of current app)
					[SBWPreActivateDisplayStack pushDisplay:app];
				}
				// Deactivate the current application

				// NOTE: Must set animation flag for deactivation, otherwise
				//       application window does not disappear (reason yet unknown)
				[fromApp setDeactivationSetting:0x2 flag:YES]; // animate
				if (!animated)
					[fromApp setDeactivationSetting:0x8 value:[NSNumber numberWithInteger:1]];

				// Deactivate by moving from active stack to suspending stack
				[SBWActiveDisplayStack popDisplay:fromApp];
				[SBWSuspendingDisplayStack pushDisplay:fromApp];
				
			} else {
				if (!switchingToSpringBoard)
					[[objc_getClass("SBUIController") sharedInstance] activateApplicationFromSwitcher:app];
				else {
					// Deactivate the current application

					// NOTE: Must set animation flag for deactivation, otherwise
					//       application window does not disappear (reason yet unknown)
					[fromApp setDeactivationSetting:0x2 flag:YES]; // animate
					if (!animated)
						[fromApp setDeactivationSetting:0x8 value:[NSNumber numberWithInteger:1]];

					// Deactivate by moving from active stack to suspending stack
					[SBWActiveDisplayStack popDisplay:fromApp];
					[SBWSuspendingDisplayStack pushDisplay:fromApp];
				}
			}
		}

		if (!switchingToSpringBoard) {
			// If CategoriesSB is installed, dismiss any open categories
			SBUIController *uiCont = (SBUIController *)[$SBUIController sharedInstance];
			if ([uiCont respondsToSelector:@selector(categoriesSBCloseAll)])
				[uiCont categoriesSBCloseAll];
		}
}

- (void)activateApplication:(SBApplication *)app animated:(BOOL)animated
{
	[self activateAppWithDisplayIdentifier:[app displayIdentifier] animated:animated];
}

- (void)backgroundTopApplication
{
	NSString *displayIdentifier = [[SBWActiveDisplayStack topApplication] displayIdentifier];
	if (displayIdentifier && ![displayIdentifier isEqualToString:kSpringBoardDisplayIdentifier] && [springBoardApp respondsToSelector:@selector(setBackgroundingEnabled:forDisplayIdentifier:)])
		[springBoardApp setBackgroundingEnabled:YES forDisplayIdentifier:displayIdentifier];
}

- (void)setBackgroundingEnabled:(BOOL)enabled forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (![springBoardApp respondsToSelector:@selector(setBackgroundingEnabled:forDisplayIdentifier:)])
		return;
	if (displayIdentifier && ![displayIdentifier isEqualToString:kSpringBoardDisplayIdentifier])
		[springBoardApp setBackgroundingEnabled:enabled forDisplayIdentifier:displayIdentifier];
}

- (void)setBackgroundingEnabled:(BOOL)enabled forApplication:(SBApplication *)app
{
	[self setBackgroundingEnabled:enabled forDisplayIdentifier:[app displayIdentifier]];
}

- (void)exitAppWithDisplayIdentifier:(NSString *)identifier animated:(BOOL)animated
{
	[self exitAppWithDisplayIdentifier:identifier animated:animated force:NO];
}

- (void)exitApplication:(SBApplication *)app animated:(BOOL)animated
{
	[self exitAppWithDisplayIdentifier:[app displayIdentifier] animated:animated];
}

- (void)exitAppWithDisplayIdentifier:(NSString *)identifier animated:(BOOL)animated force:(BOOL)force
{
	// Can't deactivate SpringBoard
	if ([identifier isEqualToString:kSpringBoardDisplayIdentifier])
		return;
	
	// Ensure app exists
	SBApplication *app = [(SBApplicationController *)[$SBApplicationController sharedInstance] applicationWithDisplayIdentifier:identifier];
	if (!app)
		return;
		if (force && ([identifier isEqualToString:@"com.apple.mobilephone"]
			|| [identifier isEqualToString:@"com.apple.mobilemail"]
			|| [identifier isEqualToString:@"com.apple.mobilesafari"]
			|| [identifier hasPrefix:@"com.apple.mobileipod"]
			|| [identifier isEqualToString:@"com.googlecode.mobileterminal"]))
		{
			// Is an application with native backgrounding capability
			// FIXME: Either find a way to detect which applications support
			//        native backgrounding, or use a timer to ensure
			//        termination.
			[app kill];
			// Save identifier to prevent possible auto-relaunch
			[killedApp release];
			killedApp = [identifier copy];
		} else {
			if ([SBWActiveDisplayStack containsDisplay:app]) {
				// NOTE: Must set animation flag for deactivation, otherwise
				//       application window does not disappear (reason yet unknown)
				[app setDeactivationSetting:0x2 flag:YES]; // animate
				if (!animated)
					[app setDeactivationSetting:0x8 value:[NSNumber numberWithInteger:1]];
				// Remove from active display stack
				[SBWActiveDisplayStack popDisplay:app];
			}
			// Deactivate the application
			[SBWSuspendingDisplayStack pushDisplay:app];
		}
	
}
- (void)exitApplication:(SBApplication *)app animated:(BOOL)animated force:(BOOL)force
{
	[self exitAppWithDisplayIdentifier:[app displayIdentifier] animated:animated force:force];
}
- (void)deactivateTopApplicationAnimated:(BOOL)animated
{	
	[self deactivateTopApplicationAnimated:animated force:NO];
}
- (void)deactivateTopApplicationAnimated:(BOOL)animated force:(BOOL)force
{
	SBApplication *app = [SBWActiveDisplayStack topApplication];
	if (!app)
		return;
	NSString *identifier = [app displayIdentifier];
	// Can't deactivate SpringBoard
	if ([identifier isEqualToString:kSpringBoardDisplayIdentifier])
		return;
	if (force && ([identifier isEqualToString:@"com.apple.mobilephone"]
		|| [identifier isEqualToString:@"com.apple.mobilemail"]
		|| [identifier isEqualToString:@"com.apple.mobilesafari"]
		|| [identifier hasPrefix:@"com.apple.mobileipod"]
		|| [identifier isEqualToString:@"com.googlecode.mobileterminal"]))
	{
		// Is an application with native backgrounding capability
		// FIXME: Either find a way to detect which applications support
		//        native backgrounding, or use a timer to ensure
		//        termination.
		[app kill];
		// Save identifier to prevent possible auto-relaunch
		[killedApp release];
		killedApp = [identifier copy];
	} else {
		// NOTE: Must set animation flag for deactivation, otherwise
		//       application window does not disappear (reason yet unknown)
		[app setDeactivationSetting:0x2 flag:YES]; // animate
		if (!animated)
			[app setDeactivationSetting:0x8 value:[NSNumber numberWithInteger:1]];
		// Remove from active display stack
		[SBWActiveDisplayStack popDisplay:app];

		// Deactivate the application
		[SBWSuspendingDisplayStack pushDisplay:app];
	}
}

- (void)enableBackgroundingForDisplayIdentifier:(NSString *)identifier
{
	[self setBackgroundingEnabled:YES forDisplayIdentifier:identifier];
}

- (void)disableBackgroundingForDisplayIdentifier:(NSString *)identifier
{
	[self setBackgroundingEnabled:NO forDisplayIdentifier:identifier];
}

@end



