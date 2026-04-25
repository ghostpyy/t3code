#ifndef CPRIVATE_UMBRELLA_H
#define CPRIVATE_UMBRELLA_H

// CoreSimulator
#import "CoreSimulator/SimServiceContext.h"
#import "CoreSimulator/SimDeviceSet.h"
#import "CoreSimulator/SimDevice.h"
#import "CoreSimulator/SimRuntime.h"
#import "CoreSimulator/SimDeviceType.h"
#import "CoreSimulator/SimDeviceBootInfo.h"
#import "CoreSimulator/SimDeviceNotifier-Protocol.h"

// SimulatorKit
#import "SimulatorKit/SimDeviceIOProtocol-Protocol.h"
#import "SimulatorKit/SimDeviceIOPortInterface-Protocol.h"
#import "SimulatorKit/SimDeviceIOPortConsumer-Protocol.h"
#import "SimulatorKit/SimDisplayRenderable-Protocol.h"
#import "SimulatorKit/SimDisplayIOSurfaceRenderable-Protocol.h"
#import "SimulatorKit/SimDisplayDescriptorState-Protocol.h"
#import "SimulatorKit/SimDeviceLegacyClient.h"
#import "SimulatorKit/SimDisplayVideoWriter.h"

// SimulatorBridge
#import "SimulatorBridge/SimulatorBridge-Protocol.h"

// SimulatorApp
#import "SimulatorApp/Indigo.h"

// AccessibilityPlatformTranslation
#import "AccessibilityPlatformTranslation/AXPTranslator_iOS.h"
#import "AccessibilityPlatformTranslation/AXPTranslatorRequest.h"
#import "AccessibilityPlatformTranslation/AXPTranslatorResponse.h"
#import "AccessibilityPlatformTranslation/AXPMacPlatformElement.h"

#endif /* CPRIVATE_UMBRELLA_H */
