//
//  BotModel.swift
//  Tok
//
//  Created by Bryce on 2019/4/19.
//  Copyright © 2019 Insight. All rights reserved.
//

import UIKit

protocol BotModelProtocol {
    
    var nickName: String { get }
    var statusMessage: String { get }
    var avatar: UIImage? { get }
    
    var publicKey: String { get }
    var address: String { get }
    var beAdded: Bool { get }

    func getBot() -> OCTFriend?
}

extension BotModelProtocol {
    var beAdded: Bool {
        return getBot() != nil
    }
    
    func getBot() -> OCTFriend? {
        let predicate = NSPredicate(format: "publicKey == %@", publicKey)
        let results = UserService.shared.toxMananger!.objects.friends(predicate: predicate)
        return results.firstObject
    }
}

struct FindFriendBotModel: BotModelProtocol {
    
    var nickName: String {
        return getBot()?.nickname ?? NSLocalizedString("FindFriendBot", comment: "")
    }
    
    var statusMessage: String {
        return getBot()?.statusMessage ?? NSLocalizedString("What can I do? FindFriendBot can help you find more friends. Type '/help' for a list of commands in the input bar.", comment: "")
    }
    
    var avatar: UIImage? {
        return getBot()?.avatar ?? UIImage(named: "FindFriendBotPlaceholder")
    }
    
    enum Command: String {
        case start = "/start"
        case set = "/set"
    }
    
    var publicKey: String {
        return UserDefaults.standard.findFriendBotPublicKey
    }
    
    private(set) var address: String {
        get {
            return UserDefaults.standard.findFriendBotAddress
        }
        set {
            UserDefaults.standard.findFriendBotAddress = newValue
        }
    }
}

struct OfflineBotModel: BotModelProtocol {
    var nickName: String {
        return getBot()?.nickname ?? NSLocalizedString("OfflineMessageBot", comment: "")
    }
    
    var statusMessage: String {
        return getBot()?.statusMessage ?? NSLocalizedString("offlinebot_bio", comment: "")
    }
    
    var avatar: UIImage? {
        return getBot()?.avatar ?? UIImage(named: "OfflineBotPlaceholder")
    }
    
    var publicKey: String {
        return UserDefaults.standard.offlineBotPublicKey
    }
    
    private(set) var address: String {
        get {
            return UserDefaults.standard.offlineBotAddress
        }
        set {
            UserDefaults.standard.offlineBotAddress = newValue
        }
    }
}

fileprivate extension UserDefaults {
    
    var findFriendBotAddress: String {
        get {
            return string(forKey: "FindFriendBotAddressKey") ?? "3415845A7145854DE91046FF4666503A83EED05BC47CA222644C5F47A8E0F072938433360B34"
        }
        set {
            set(newValue, forKey: "FindFriendBotAddressKey")
        }
    }
    
    var findFriendBotPublicKey: String {
        return String(findFriendBotAddress.prefix(Int(kOCTToxPublicKeyLength)))
    }
    
    var offlineBotAddress: String {
        get {
            #if DEBUG
            return string(forKey: "OfflineBotAddressKey") ?? "354FF4AFFAADE38A01FD3397244E4DDF323C6548E21BFD1C258A206FC5AFD02A38A93458D7DE"
            #else
            return string(forKey: "OfflineBotAddressKey") ?? "EC6EFF1B9CA5E5C2E41715A187497094B9D61F1604FBC1B6F202B1F1C89B4501B4EB7E520B24"
            #endif
        }
        set {
            set(newValue, forKey: "OfflineBotAddressKey")
        }
    }
    
    var offlineBotPublicKey: String {
        return String(offlineBotAddress.prefix(Int(kOCTToxPublicKeyLength)))
    }
}
