//
//  AimyboxResult.swift
//  AimyboxCore
//
//  Created by Vladyslav Popovych on 30.11.2019.
//  Copyright © 2019 Just Ai. All rights reserved.
//

import Foundation

public extension Aimybox {
    /**
     Used to support versions of swift < 5.0.
     */
    enum Result<T, E> where E: Error {
        case success(T)
        case faillure(E)
        /**
         Same as success, but don't have any assosiated value.
         
         Used in case when assosiated value type is Void.
         ```
         Aimybox.Result<Void, Aimybox.STTError>
         ```
         */
    }
    
    typealias SpeechToTextResult = Aimybox.Result<Void, Aimybox.SpeechToTextError>
}
