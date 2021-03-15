// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterTextInputPlugin.h"

#import <objc/message.h>

#include <algorithm>
#include <memory>

#include "flutter/shell/platform/common/text_input_model.h"
#import "flutter/shell/platform/darwin/common/framework/Headers/FlutterCodecs.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterViewController_Internal.h"

static NSString* const kTextInputChannel = @"flutter/textinput";

// See https://api.flutter.dev/flutter/services/SystemChannels/textInput-constant.html
static NSString* const kSetClientMethod = @"TextInput.setClient";
static NSString* const kShowMethod = @"TextInput.show";
static NSString* const kHideMethod = @"TextInput.hide";
static NSString* const kClearClientMethod = @"TextInput.clearClient";
static NSString* const kSetEditingStateMethod = @"TextInput.setEditingState";
static NSString* const kUpdateEditStateResponseMethod = @"TextInputClient.updateEditingState";
static NSString* const kPerformAction = @"TextInputClient.performAction";
static NSString* const kMultilineInputType = @"TextInputType.multiline";

static NSString* const kTextAffinityDownstream = @"TextAffinity.downstream";
static NSString* const kTextAffinityUpstream = @"TextAffinity.upstream";

static NSString* const kTextInputAction = @"inputAction";
static NSString* const kTextInputType = @"inputType";
static NSString* const kTextInputTypeName = @"name";

static NSString* const kSelectionBaseKey = @"selectionBase";
static NSString* const kSelectionExtentKey = @"selectionExtent";
static NSString* const kSelectionAffinityKey = @"selectionAffinity";
static NSString* const kSelectionIsDirectionalKey = @"selectionIsDirectional";
static NSString* const kComposingBaseKey = @"composingBase";
static NSString* const kComposingExtentKey = @"composingExtent";
static NSString* const kTextKey = @"text";

/**
 * The affinity of the current cursor position. If the cursor is at a position representing
 * a line break, the cursor may be drawn either at the end of the current line (upstream)
 * or at the beginning of the next (downstream).
 */
typedef NS_ENUM(NSUInteger, FlutterTextAffinity) {
  FlutterTextAffinityUpstream,
  FlutterTextAffinityDownstream
};

/*
 * Updates a range given base and extent fields.
 */
static flutter::TextRange RangeFromBaseExtent(NSNumber* base,
                                              NSNumber* extent,
                                              const flutter::TextRange& range) {
  if (base == nil || extent == nil) {
    return range;
  }
  if (base.intValue == -1 && extent.intValue == -1) {
    return flutter::TextRange(0, 0);
  }
  return flutter::TextRange([base unsignedLongValue], [extent unsignedLongValue]);
}

/**
 * Private properties of FlutterTextInputPlugin.
 */
@interface FlutterTextInputPlugin () <NSTextInputClient>

/**
 * A text input context, representing a connection to the Cocoa text input system.
 */
@property(nonatomic) NSTextInputContext* textInputContext;

/**
 * The channel used to communicate with Flutter.
 */
@property(nonatomic) FlutterMethodChannel* channel;

/**
 * The FlutterViewController to manage input for.
 */
@property(nonatomic, weak) FlutterViewController* flutterViewController;

/**
 * The affinity for the current cursor position.
 */
@property FlutterTextAffinity textAffinity;

/**
 * ID of the text input client.
 */
@property(nonatomic, nonnull) NSNumber* clientID;

/**
 * Keyboard type of the client. See available options:
 * https://api.flutter.dev/flutter/services/TextInputType-class.html
 */
@property(nonatomic, nonnull) NSString* inputType;

/**
 * An action requested by the user on the input client. See available options:
 * https://api.flutter.dev/flutter/services/TextInputAction-class.html
 */
@property(nonatomic, nonnull) NSString* inputAction;

/**
 * Handles a Flutter system message on the text input channel.
 */
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result;

/**
 * Updates the text input model with state received from the framework via the
 * TextInput.setEditingState message.
 */
- (void)setEditingState:(NSDictionary*)state;

@end

@implementation FlutterTextInputPlugin {
  /**
   * The currently active text input model.
   */
  std::unique_ptr<flutter::TextInputModel> _activeModel;
}

- (instancetype)initWithViewController:(FlutterViewController*)viewController {
  self = [super init];
  if (self != nil) {
    _flutterViewController = viewController;
    _channel = [FlutterMethodChannel methodChannelWithName:kTextInputChannel
                                           binaryMessenger:viewController.engine.binaryMessenger
                                                     codec:[FlutterJSONMethodCodec sharedInstance]];
    __weak FlutterTextInputPlugin* weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
      [weakSelf handleMethodCall:call result:result];
    }];
    _textInputContext = [[NSTextInputContext alloc] initWithClient:self];
  }
  return self;
}

#pragma mark - Private

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  BOOL handled = YES;
  NSString* method = call.method;
  if ([method isEqualToString:kSetClientMethod]) {
    if (!call.arguments[0] || !call.arguments[1]) {
      result([FlutterError
          errorWithCode:@"error"
                message:@"Missing arguments"
                details:@"Missing arguments while trying to set a text input client"]);
      return;
    }
    NSNumber* clientID = call.arguments[0];
    if (clientID != nil) {
      NSDictionary* config = call.arguments[1];

      _clientID = clientID;
      _inputAction = config[kTextInputAction];
      NSDictionary* inputTypeInfo = config[kTextInputType];
      _inputType = inputTypeInfo[kTextInputTypeName];
      self.textAffinity = FlutterTextAffinityUpstream;

      _activeModel = std::make_unique<flutter::TextInputModel>();
    }
  } else if ([method isEqualToString:kShowMethod]) {
    [self.flutterViewController addKeyResponder:self];
    [_textInputContext activate];
  } else if ([method isEqualToString:kHideMethod]) {
    [self.flutterViewController removeKeyResponder:self];
    [_textInputContext deactivate];
  } else if ([method isEqualToString:kClearClientMethod]) {
    _clientID = nil;
    _inputAction = nil;
    _inputType = nil;
    _activeModel = nullptr;
  } else if ([method isEqualToString:kSetEditingStateMethod]) {
    NSDictionary* state = call.arguments;
    [self setEditingState:state];

    // Close the loop, since the framework state could have been updated by the
    // engine since it sent this update, and needs to now be made to match the
    // engine's version of the state.
    [self updateEditState];
  } else {
    handled = NO;
  }
  result(handled ? nil : FlutterMethodNotImplemented);
}

- (void)setEditingState:(NSDictionary*)state {
  NSString* selectionAffinity = state[kSelectionAffinityKey];
  if (selectionAffinity != nil) {
    _textAffinity = [selectionAffinity isEqualToString:kTextAffinityUpstream]
                        ? FlutterTextAffinityUpstream
                        : FlutterTextAffinityDownstream;
  }

  NSString* text = state[kTextKey];
  if (text != nil) {
    _activeModel->SetText([text UTF8String]);
  }

  flutter::TextRange selected_range = RangeFromBaseExtent(
      state[kSelectionBaseKey], state[kSelectionExtentKey], _activeModel->selection());
  _activeModel->SetSelection(selected_range);

  flutter::TextRange composing_range = RangeFromBaseExtent(
      state[kComposingBaseKey], state[kComposingExtentKey], _activeModel->composing_range());
  size_t cursor_offset = selected_range.base() - composing_range.start();
  _activeModel->SetComposingRange(composing_range, cursor_offset);
}

/**
 * Informs the Flutter framework of changes to the text input model's state.
 */
- (void)updateEditState {
  if (_activeModel == nullptr) {
    return;
  }

  NSString* const textAffinity = (self.textAffinity == FlutterTextAffinityUpstream)
                                     ? kTextAffinityUpstream
                                     : kTextAffinityDownstream;

  int composingBase = _activeModel->composing() ? _activeModel->composing_range().base() : -1;
  int composingExtent = _activeModel->composing() ? _activeModel->composing_range().extent() : -1;

  NSDictionary* state = @{
    kSelectionBaseKey : @(_activeModel->selection().base()),
    kSelectionExtentKey : @(_activeModel->selection().extent()),
    kSelectionAffinityKey : textAffinity,
    kSelectionIsDirectionalKey : @NO,
    kComposingBaseKey : @(composingBase),
    kComposingExtentKey : @(composingExtent),
    kTextKey : [NSString stringWithUTF8String:_activeModel->GetText().c_str()]
  };

  [_channel invokeMethod:kUpdateEditStateResponseMethod arguments:@[ self.clientID, state ]];
}

#pragma mark -
#pragma mark FlutterIntermediateKeyResponder

/**
 * Handles key down events received from the view controller, responding TRUE if
 * the event was handled.
 *
 * Note, the Apple docs suggest that clients should override essentially all the
 * mouse and keyboard event-handling methods of NSResponder. However, experimentation
 * indicates that only key events are processed by the native layer; Flutter processes
 * mouse events. Additionally, processing both keyUp and keyDown results in duplicate
 * processing of the same keys. So for now, limit processing to just handleKeyDown.
 */
- (BOOL)handleKeyDown:(NSEvent*)event {
  return [_textInputContext handleEvent:event];
}

#pragma mark -
#pragma mark NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)range {
  if (_activeModel == nullptr) {
    return;
  }

  if (range.location != NSNotFound) {
    // The selected range can actually have negative numbers, since it can start
    // at the end of the range if the user selected the text going backwards.
    // NSRange uses NSUIntegers, however, so we have to cast them to know if the
    // selection is reversed or not.
    long signedLength = static_cast<long>(range.length);
    long location = range.location;
    long textLength = _activeModel->text_range().end();

    size_t base = std::clamp(location, 0L, textLength);
    size_t extent = std::clamp(location + signedLength, 0L, textLength);
    _activeModel->SetSelection(flutter::TextRange(base, extent));
  }

  _activeModel->AddText([string UTF8String]);
  if (_activeModel->composing()) {
    _activeModel->CommitComposing();
    _activeModel->EndComposing();
  }
  [self updateEditState];
}

- (void)doCommandBySelector:(SEL)selector {
  if ([self respondsToSelector:selector]) {
    // Note: The more obvious [self performSelector...] doesn't give ARC enough information to
    // handle retain semantics properly. See https://stackoverflow.com/questions/7017281/ for more
    // information.
    IMP imp = [self methodForSelector:selector];
    void (*func)(id, SEL, id) = reinterpret_cast<void (*)(id, SEL, id)>(imp);
    func(self, selector, nil);
  }
}

- (void)insertNewline:(id)sender {
  if (_activeModel == nullptr) {
    return;
  }
  if (_activeModel->composing()) {
    _activeModel->CommitComposing();
    _activeModel->EndComposing();
  }
  if ([self.inputType isEqualToString:kMultilineInputType]) {
    [self insertText:@"\n" replacementRange:self.selectedRange];
  }
  [_channel invokeMethod:kPerformAction arguments:@[ self.clientID, self.inputAction ]];
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange {
  if (_activeModel == nullptr) {
    return;
  }
  if (!_activeModel->composing()) {
    _activeModel->BeginComposing();
  }

  // Input string may be NSString or NSAttributedString.
  BOOL isAttributedString = [string isKindOfClass:[NSAttributedString class]];
  NSString* marked_text = isAttributedString ? [string string] : string;
  _activeModel->UpdateComposingText([marked_text UTF8String]);

  [self updateEditState];
}

- (void)unmarkText {
  if (_activeModel != nullptr) {
    return;
  }
  _activeModel->CommitComposing();
  _activeModel->EndComposing();
  [self updateEditState];
}

- (NSRange)selectedRange {
  if (_activeModel == nullptr) {
    return NSMakeRange(NSNotFound, 0);
  }
  return NSMakeRange(_activeModel->selection().base(),
                     _activeModel->selection().extent() - _activeModel->selection().base());
}

- (NSRange)markedRange {
  if (_activeModel == nullptr) {
    return NSMakeRange(NSNotFound, 0);
  }
  return NSMakeRange(
      _activeModel->composing_range().base(),
      _activeModel->composing_range().extent() - _activeModel->composing_range().base());
}

- (BOOL)hasMarkedText {
  return _activeModel != nullptr && _activeModel->composing_range().length() > 0;
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                               actualRange:(NSRangePointer)actualRange {
  if (_activeModel == nullptr) {
    return nil;
  }
  if (actualRange != nil) {
    *actualRange = range;
  }
  NSString* text = [NSString stringWithUTF8String:_activeModel->GetText().c_str()];
  NSString* substring = [text substringWithRange:range];
  return [[NSAttributedString alloc] initWithString:substring attributes:nil];
}

- (NSArray<NSString*>*)validAttributesForMarkedText {
  return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  // TODO: Implement.
  // Note: This function can't easily be implemented under the system-message architecture.
  return CGRectZero;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  // TODO: Implement.
  // Note: This function can't easily be implemented under the system-message architecture.
  return 0;
}

@end
