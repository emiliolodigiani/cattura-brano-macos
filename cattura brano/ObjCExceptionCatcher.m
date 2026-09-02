//
//  ObjCExceptionCatcher.m
//  cattura brano
//

#import "ObjCExceptionCatcher.h"

NSError * _Nullable CBCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"ObjCException"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}
