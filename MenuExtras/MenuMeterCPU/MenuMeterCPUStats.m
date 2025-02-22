//
//  MenuMeterCPUStats.m
//
//  Reader object for CPU information and load
//
//  Copyright (c) 2002-2014 Alex Harper
//
//  This file is part of MenuMeters.
//
//  MenuMeters is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License version 2 as
//  published by the Free Software Foundation.
//
//  MenuMeters is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with MenuMeters; if not, write to the Free Software
//  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
//

#import "MenuMeterCPUStats.h"
#import <IOKit/pwr_mgt/IOPM.h>
#import "TemperatureReader.h"
#import "MenuMeterDefaults.h"
#include <TargetConditionals.h>

@implementation MenuMeterCPULoad
@end

///////////////////////////////////////////////////////////////
//
//  Private methods
//
///////////////////////////////////////////////////////////////

@interface MenuMeterCPUStats (PrivateMethods)
- (NSString *)cpuPrettyName;
- (UInt32)clockFrequency;
@end


///////////////////////////////////////////////////////////////
//
//  Localized strings
//
///////////////////////////////////////////////////////////////

#define kProcessorNameFormat				@"%u %@ @ %@"
#define kTaskThreadFormat					@"%d tasks, %d threads"
#define kLoadAverageFormat					@"%@, %@, %@"
#define kNoInfoErrorMessage					@"No info available"
#define kHyperThreadsPerCoreFormat			@" (%@ hyperthreads per core)"
#define kPhysicalCoresFormat				@"%@%@ physical cores"
#define kCPUPowerLimitStatusFormat			@"speed %@%%, scheduler %@%%"

///////////////////////////////////////////////////////////////
//
//  init/dealloc
//
///////////////////////////////////////////////////////////////

@implementation MenuMeterCPUStats
uint32_t cpuCount;
uint32_t coreCount;
uint32_t packageCount;

- (id)init {

	// Allow super to init
	self = [super init];
	if (!self) {
		return nil;
	}

	// Gather the pretty name
	cpuName = [self cpuPrettyName];
	if (!cpuName) {
		return nil;
	}

	// Set up a NumberFormatter for localization. This is based on code contributed by Mike Fischer
	// (mike.fischer at fi-works.de) for use in MenuMeters.
	// We have to do this early so we can use the resulting format on the GHz processor string
	NSNumberFormatter *tempFormatter = [[NSNumberFormatter alloc] init];
	[tempFormatter setLocalizesFormat:YES];
	[tempFormatter setFormat:@"0.00"];
	// Go through an archive/unarchive cycle to work around a bug on pre-10.2.2 systems
	// see http://cocoa.mamasam.com/COCOADEV/2001/12/2/21029.php
	twoDigitFloatFormatter = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:tempFormatter]];
	if (!twoDigitFloatFormatter) {
		return nil;
	}

	// Gather the clock rate string
	uint32_t clockRate = [self clockFrequency];
	if (clockRate > 1000000000) {
		clockSpeed = [NSString stringWithFormat:@"%@GHz",
					  [twoDigitFloatFormatter stringForObjectValue:
					   [NSNumber numberWithFloat:(float)clockRate / 1000000000]]];
	} else {
		clockSpeed = [NSString stringWithFormat:@"%dMHz", clockRate / 1000000];
	}
	if (!clockSpeed) {
		return nil;
	}

	// Gather the cpu count

	size_t sysctlLength = sizeof(cpuCount);
	int mib[2] = { CTL_HW, HW_NCPU };
	if (sysctl(mib, 2, &cpuCount, &sysctlLength, NULL, 0)) {
		return nil;
	}

	size_t size=sizeof(coreCount);
	if(sysctlbyname("hw.physicalcpu", &coreCount, &size, NULL, 0)){
		coreCount=cpuCount;
	}

	size=sizeof(packageCount);
	if(sysctlbyname("hw.packages", &packageCount, &size, NULL, 0)){
		packageCount=1;
	}


	// Set up our mach host and default processor set for later calls
	machHost = mach_host_self();
	processor_set_default(machHost, &processorSet);

	// Build the storage for the prior ticks and store the first block of data
	natural_t processorCount;
	processor_cpu_load_info_t processorTickInfo;
	mach_msg_type_number_t processorInfoCount;
	kern_return_t err = host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &processorCount,
											(processor_info_array_t *)&processorTickInfo, &processorInfoCount);
	if (err != KERN_SUCCESS) {
		return nil;
	}
	priorCPUTicks = (processor_cpu_load_info_t) malloc(processorCount * sizeof(struct processor_cpu_load_info));
	for (natural_t i = 0; i < processorCount; i++) {
		for (natural_t j = 0; j < CPU_STATE_MAX; j++) {
			priorCPUTicks[i].cpu_ticks[j] = processorTickInfo[i].cpu_ticks[j];
		}
	}
	vm_deallocate(mach_task_self(), (vm_address_t)processorTickInfo, (vm_size_t)(processorInfoCount * sizeof(natural_t)));

	// Send on back
	return self;

} // init

- (void)dealloc {

	if (priorCPUTicks) free(priorCPUTicks);

} // dealloc

///////////////////////////////////////////////////////////////
//
//  CPU info
//
///////////////////////////////////////////////////////////////

- (NSString *)cpuName {

	return cpuName;

} // cpuName

- (NSString *)cpuSpeed {

	return clockSpeed;

} // cpuSpeed

- (uint32_t)numberOfCPUs {
	return cpuCount;
} // numberOfCPUs

- (uint32_t)numberOfCores {
	return coreCount;
} 

-(NSString*)packages{
	if(packageCount==1){
		return @"";
	}else{
		return [NSString stringWithFormat:@"%@x ",@(packageCount)];
	}
}
- (NSString *)processorDescription {
	return [NSString stringWithFormat:@"%@%@ @ %@", [self packages], [self cpuName], [self cpuSpeed]];
} // processorDescription
- (NSString *)coreDescription {
	NSString*hyperinfo=@"";
	if(cpuCount!=coreCount){
		hyperinfo=[NSString stringWithFormat:[localizedStrings objectForKey:kHyperThreadsPerCoreFormat],@(cpuCount/coreCount)];
	}
	return [NSString stringWithFormat:@"%@%@", [NSString stringWithFormat:[localizedStrings objectForKey:kPhysicalCoresFormat],[self packages],@(coreCount/packageCount)],hyperinfo];
} // coreDescription

///////////////////////////////////////////////////////////////
//
//  Load info
//
///////////////////////////////////////////////////////////////

- (NSString *)currentProcessorTasks {

	struct processor_set_load_info loadInfo;
	mach_msg_type_number_t count = PROCESSOR_SET_LOAD_INFO_COUNT;
	kern_return_t err = processor_set_statistics(processorSet, PROCESSOR_SET_LOAD_INFO,
												 (processor_set_info_t)&loadInfo, &count);

	if (err != KERN_SUCCESS) {
		return [localizedStrings objectForKey:kNoInfoErrorMessage];
	} else {
		return [NSString stringWithFormat:[localizedStrings objectForKey:kTaskThreadFormat],
				loadInfo.task_count, loadInfo.thread_count];
	}

} // currentProcessorTasks

- (NSString *)loadAverage {

	// Fetch using getloadavg() to better match top, from Michael Nordmeyer (http://goodyworks.com)
	double loads[3] = { 0, 0, 0 };
	if (getloadavg(loads, 3) != 3) {
		return [localizedStrings objectForKey:kNoInfoErrorMessage];
	} else {
		return [NSString stringWithFormat:[localizedStrings objectForKey:kLoadAverageFormat],
				[twoDigitFloatFormatter stringForObjectValue:[NSNumber numberWithFloat:(float)loads[0]]],
				[twoDigitFloatFormatter stringForObjectValue:[NSNumber numberWithFloat:(float)loads[1]]],
				[twoDigitFloatFormatter stringForObjectValue:[NSNumber numberWithFloat:(float)loads[2]]]];
	}

} // loadAverage

- (NSArray *)currentLoadBySorting: (BOOL)sorted {

	// Read the current ticks
	natural_t processorCount;
	processor_cpu_load_info_t processorTickInfo;
	mach_msg_type_number_t processorInfoCount;
	kern_return_t err = host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &processorCount,
											(processor_info_array_t *)&processorTickInfo, &processorInfoCount);
	if (err != KERN_SUCCESS) return nil;

	// We have valid info so build return array
	NSMutableArray *loadInfo = [NSMutableArray array];
	for (natural_t i = 0; i < processorCount; i++) {

		// Calc load types and totals, with guards against 32-bit overflow
		// (values are natural_t)
		uint64_t system = 0, user = 0, idle = 0, total = 0;

		if (processorTickInfo[i].cpu_ticks[CPU_STATE_SYSTEM] >= priorCPUTicks[i].cpu_ticks[CPU_STATE_SYSTEM]) {
			system = processorTickInfo[i].cpu_ticks[CPU_STATE_SYSTEM] - priorCPUTicks[i].cpu_ticks[CPU_STATE_SYSTEM];
		} else {
			system = processorTickInfo[i].cpu_ticks[CPU_STATE_SYSTEM] + (UINT_MAX - priorCPUTicks[i].cpu_ticks[CPU_STATE_SYSTEM] + 1);
		}
		if (processorTickInfo[i].cpu_ticks[CPU_STATE_USER] >= priorCPUTicks[i].cpu_ticks[CPU_STATE_USER]) {
			user = processorTickInfo[i].cpu_ticks[CPU_STATE_USER] - priorCPUTicks[i].cpu_ticks[CPU_STATE_USER];
		} else {
			user = processorTickInfo[i].cpu_ticks[CPU_STATE_USER] + (ULONG_MAX - priorCPUTicks[i].cpu_ticks[CPU_STATE_USER] + 1);
		}
		// Count nice as user (nice slot non-zero only on  OS versions prior to 10.4)
		// Radar 5644966, duplicate 5555821. Apple says its intentional, so stop
		// pretending its going to get fixed.
		if (processorTickInfo[i].cpu_ticks[CPU_STATE_NICE] >= priorCPUTicks[i].cpu_ticks[CPU_STATE_NICE]) {
			user += processorTickInfo[i].cpu_ticks[CPU_STATE_NICE] - priorCPUTicks[i].cpu_ticks[CPU_STATE_NICE];
		} else {
			user += processorTickInfo[i].cpu_ticks[CPU_STATE_NICE] + (ULONG_MAX - priorCPUTicks[i].cpu_ticks[CPU_STATE_NICE] + 1);
		}
		if (processorTickInfo[i].cpu_ticks[CPU_STATE_IDLE] >= priorCPUTicks[i].cpu_ticks[CPU_STATE_IDLE]) {
			idle = processorTickInfo[i].cpu_ticks[CPU_STATE_IDLE] - priorCPUTicks[i].cpu_ticks[CPU_STATE_IDLE];
		} else {
			idle = processorTickInfo[i].cpu_ticks[CPU_STATE_IDLE] + (ULONG_MAX - priorCPUTicks[i].cpu_ticks[CPU_STATE_IDLE] + 1);
		}
		total = system + user + idle;

		float normalize = (total < 1) ? 1 : (1.0 / total);

		MenuMeterCPULoad *load = [[MenuMeterCPULoad alloc] init];
		load.system = system * normalize;
		load.user = user * normalize;
		[loadInfo addObject:load];
	}

	// Copy the new data into previous
	for (natural_t i = 0; i < processorCount; i++) {
		for (natural_t j = 0; j < CPU_STATE_MAX; j++) {
			priorCPUTicks[i].cpu_ticks[j] = processorTickInfo[i].cpu_ticks[j];
		}
	}

	// Sort the load if necessary
	if (sorted == YES) {
		NSMutableArray *sorted = [NSMutableArray array];
		processorCount=(natural_t)[loadInfo count];
		for (natural_t i = 0; i < processorCount; i++) {
			float maxSum = 0.0;
			natural_t maxIndex = 0;
			for (natural_t j = 0; j < (processorCount - i); j++) {
				MenuMeterCPULoad *load = [loadInfo objectAtIndex: j];
				float sum = load.system + load.user;
				if (sum > maxSum) {
					maxSum = sum;
					maxIndex = j;
				}
			}
			[sorted addObject: [loadInfo objectAtIndex: maxIndex]];
			[loadInfo removeObjectAtIndex: maxIndex];
		}
		loadInfo = sorted;
	}

	// Dealloc
	vm_deallocate(mach_task_self(), (vm_address_t)processorTickInfo, (vm_size_t)(processorInfoCount * sizeof(natural_t)));

	// Send the gathered data back
	return loadInfo;

} // currentLoad

- (float_t)cpuProximityTemperature {
	NSString*sensor=[[MenuMeterDefaults sharedMenuMeterDefaults] cpuTemperatureSensor];
	if([sensor isEqualToString:kCPUTemperatureSensorDefault]){
		sensor=[TemperatureReader defaultSensor];
	}
	return [TemperatureReader temperatureOfSensorWithName:sensor];
} // cpuProximityTemperature

///////////////////////////////////////////////////////////////
//
//  Utility
//
///////////////////////////////////////////////////////////////

- (NSString *)cpuPrettyName {

#if  1

	char cpumodel[64];
	size_t size = sizeof(cpumodel);
	if (!sysctlbyname("machdep.cpu.brand_string", cpumodel, &size, NULL, 0)){
		NSString*s=[NSString stringWithUTF8String:cpumodel];
		NSRange r;
		r=[s rangeOfString:@"@"];
		if(r.location!=NSNotFound){
			s=[s substringToIndex:r.location];
		}
		r=[s rangeOfString:@"CPU"];
		if(r.location!=NSNotFound){
			s=[s substringToIndex:r.location];
		}
		s=[s stringByReplacingOccurrencesOfString:@"(TM)" withString:@"™"];
		s=[s stringByReplacingOccurrencesOfString:@"(R)" withString:@"®"];

		NXArchInfo const *archInfo = NXGetLocalArchInfo();
		if (archInfo) {
			s = [s stringByAppendingFormat:@" (%@)",[NSString stringWithCString:archInfo->description]];
		}

		return s;
	}
	return @"???";
#else
	// Start with nothing
	NSString					*prettyName = @"Unknown CPU";

	// Try older API for the pretty name (Aquamon demonstrated this)
	NXArchInfo const *archInfo = NXGetLocalArchInfo();
	if (archInfo) {
		prettyName = [NSString stringWithCString:archInfo->description];
	}

	// Now try to do better for 7455 Apollo, 7447 AlBooks, and Sahara G3s.
	// Note that this still doesn't work for some 7455s in 10.2.
	// Since those same machines return the correct type in Classic
	// I'm assuming its an Apple bug.
	SInt32 gestaltVal = 0;
	OSStatus err = Gestalt(gestaltNativeCPUtype, &gestaltVal);
	if (err == noErr) {
		if (gestaltVal == gestaltCPUApollo) {
			prettyName = @"PowerPC 7455";
		} else if (gestaltVal == gestaltCPUG47447) {
			// Gestalt says 7447, but CHUD says 7457. Let's believe CHUD.
			// Patch from Alex Eddy
			prettyName = @"PowerPC 7457";
		} else if (gestaltVal == gestaltCPU750FX) {
			prettyName = @"PowerPC 750fx";
		}
	}
	return prettyName;
#endif

} // _cpuPrettyName

- (UInt32) clockFrequency {
	uint32_t clockRate = 0;

	// First try with sysctl
	int mib[2] = { CTL_HW, HW_CPU_FREQ };
	size_t sysctlLength = sizeof(clockRate);
	int res = sysctl(mib, 2, &clockRate, &sysctlLength, NULL, 0);

	// Try using IOKit
	if (res != 0) {
		mach_port_t platformExpertDevice = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
		CFTypeRef platformClockFrequency = IORegistryEntryCreateCFProperty(platformExpertDevice, CFSTR("clock-frequency"), kCFAllocatorDefault, 0);
		if (CFGetTypeID(platformClockFrequency) == CFDataGetTypeID()) {
			const CFDataRef platformClockFrequencyData = (const CFDataRef) platformClockFrequency;
			const UInt8* clockFreqBytes = CFDataGetBytePtr(platformClockFrequencyData);
			clockRate = CFSwapInt32BigToHost(*(UInt32*)(clockFreqBytes)) * 1000;
			CFRelease(platformClockFrequency);
		}
		IOObjectRelease(platformExpertDevice);
	}

	return clockRate;
} // getClockFrequency

- (NSString *)cpuPowerLimitStatus {
	CFDictionaryRef dic = NULL;
	IOPMCopyCPUPowerStatus(&dic);
	if (dic) {
		NSDictionary *d = CFBridgingRelease(dic);
		NSNumber *speedLimit = d[[NSString stringWithUTF8String:kIOPMCPUPowerLimitProcessorSpeedKey]];
		NSNumber *schedulerLimit = d[[NSString stringWithUTF8String:kIOPMCPUPowerLimitSchedulerTimeKey]];
		return [NSString stringWithFormat:[localizedStrings objectForKey:kCPUPowerLimitStatusFormat],speedLimit,schedulerLimit];
	}
	else {
		return nil;
	}
}
@end
