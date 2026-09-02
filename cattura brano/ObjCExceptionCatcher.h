//
//  ObjCExceptionCatcher.h
//  cattura brano
//
//  Swift non può intercettare le NSException Objective-C: se una API come
//  AVAudioEngine ne solleva una dentro un gestore di eventi, AppKit la
//  "ingoia" e lascia il runtime della concorrenza Swift in uno stato
//  corrotto, con crash al primo controllo di isolamento successivo
//  (visto sul MacBook con il microfono integrato non disponibile).
//  Questo shim la trasforma in un NSError gestibile da Swift.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Esegue `block` e cattura un'eventuale NSException, restituendola come
/// NSError (dominio "ObjCException", motivo nella localizedDescription).
/// Restituisce nil se il blocco termina senza eccezioni.
FOUNDATION_EXPORT NSError * _Nullable CBCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
