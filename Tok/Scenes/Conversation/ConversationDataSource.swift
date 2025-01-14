//
//  ConversationDataSource.swift
//  Tok
//
//  Created by Bryce on 2018/9/10.
//  Copyright © 2018年 Insight. All rights reserved.
//

import RxSwift
import RxCocoa
import SwiftDate

class ConversationDataSource {
    
    let disposeBag = DisposeBag()
    
    let chat: OCTChat
    
    private(set) var messageList = OrderedArray<MessageModel>()
    
    let batchUpdates = PublishSubject<(IndexSet, [IndexPath], IndexSet, Bool)>()
    
    let errors = PublishSubject<String>()
    
    let audioPlayer = AlertAudioPlayer()
    
    let titleUpdated = BehaviorRelay(value: ("", "", UserStatus.offline))
    
    let hasMore = BehaviorRelay(value: true)
    
    let findFriendBot = FindFriendBotModel()
    
    let offlineBot = OfflineBotModel()
    
    // MARK: - Private
    
    fileprivate let chats: OCTSubmanagerChats
    fileprivate let messageAbstracts: Results<OCTMessageAbstract>!
    fileprivate var peers: Results<OCTPeer>?
    
    fileprivate var messagesToken: RLMNotificationToken?
    fileprivate var friendToken: RLMNotificationToken?
    fileprivate var peersToken: RLMNotificationToken?
    fileprivate var chatToken: RLMNotificationToken?
    
    fileprivate lazy var sender: Sender = {
        let id = UserService.shared.toxMananger!.user.publicKey
        let name = UserService.shared.nickName ?? id
        return Sender(id: id, displayName: name)
    }()
    
    private let avatarCache = NSCache<NSString, UIImage>()
    private let nameCache = NSCache<NSString, NSString>()
    
    private var initialTotal = 0
    private let pageSize = 15
    
    private var hasResend = false
    
    init(chat: OCTChat) {
        self.chat = chat
        self.chats = UserService.shared.toxMananger!.chats
        
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "chatUniqueIdentifier == %@", chat.uniqueIdentifier),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "senderUniqueIdentifier != nil AND messageText != nil AND messageText.status == 1"),
                NSPredicate(format: "senderUniqueIdentifier != nil AND messageText == nil"),
                NSPredicate(format: "senderUniqueIdentifier == nil"),
                ]),
            ])
        
        messageAbstracts = UserService.shared.toxMananger!.objects.messages(predicate: predicate).sortedResultsUsingProperty("dateInterval", ascending: true)
        initialTotal = messageAbstracts.count
        hasMore.accept(messageAbstracts.count > 0)
        
        bindOnline()
        addMessagesNotification()
        addFriendNotification()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        
        titleUpdated
            .distinctUntilChanged { $0.1 == $1.1 }
            .debug("titleUpdatedForQuery")
            .subscribe(onNext: { [weak self] _ in
                guard let self = self else { return }
                self.queryFriendIsSupportOfflineMessage()
            })
            .disposed(by: disposeBag)
        
        loadData()
    }
    
    deinit {
        messagesToken?.invalidate()
        friendToken?.invalidate()
        peersToken?.invalidate()
        chatToken?.invalidate()
        NotificationCenter.default.removeObserver(self)
        
        print("👍👍👍===== \(self) deinit =====👍👍👍")
    }
    
    func loadData() {
        guard hasMore.value else {
            return
        }
        
        let total = initialTotal
        let displayTotal = messageList.count
        
        let endIndex = total - displayTotal
        let startIndex = max(endIndex - pageSize, 0)
        
        for i in (startIndex..<endIndex).reversed() {
            let messageAbstract = messageAbstracts[i]
            
            let sender = messageAbstract.isOutgoing()
                ? self.sender
                : Sender(id: messageAbstract.senderUniqueIdentifier!, displayName: getName(messageAbstract: messageAbstract))
            let fileStorage = UserService.shared.toxMananger!.configuration().fileStorage
            let model = MessageModel(model: messageAbstract, sender: sender, fileStorage: fileStorage)
            messageList.insert(model, at: 0)
        }
        
        hasMore.accept(endIndex > pageSize)
    }
    
    func avatarFor(indexPath: IndexPath) -> UIImage? {
        let message = messageList[indexPath.section]
        if isFromCurrentSender(message: message) {
            return UserService.shared.avatarImage
        }
        
        if chat.isGroup {
            return getPeerAvatar(indexPath: indexPath)
        } else if let friend = self.chat.friends?.firstObject() as? OCTFriend {
            if let avatar = friend.avatarData {
                return UIImage(data: avatar)
            }
        }
        return AvatarManager.shared.avatarFromString("?", diameter: 40)
    }
    
    func isFindFriendBot() -> Bool {
        guard let friend = chat.friends?.firstObject() as? OCTFriend else {
            return false
        }
        return friend.publicKey == findFriendBot.publicKey
    }
    
    // MARK: - Private Methods
    
    @objc
    private func applicationDidBecomeActive() {
        updateLastReadDate()
    }
    
    private func bindOnline() {
        let friend = chat.friends?.firstObject() as! OCTFriend
        let status: UserStatus = friend.isConnected ? .online : .offline
        if friend.isConnected == false, friend.supportOfflineMessage, offlineBot.getBot()?.isConnected == true {
            let statusString = NSLocalizedString("OfflineMessageBot online", comment: "")
            titleUpdated.accept((friend.nickname, statusString, .online))
        } else {
            titleUpdated.accept((friend.nickname, status.toString(), status))
        }
    }
    
    private func queryFriendIsSupportOfflineMessage() {
        guard let bot = offlineBot.getBot() else {
            return
        }
        
        guard bot.isConnected else {
            return
        }
        
        let friend = chat.friends?.firstObject() as! OCTFriend
        chats.queryFriendIsSupportOfflineMessage(friend)
    }
    
    private func addMessagesNotification() {
        self.messagesToken = messageAbstracts.addNotificationBlock { [weak self] change in
            guard let self = self else { return }
            switch change {
            case .initial:
                break
            case .update(let results, let deletes, let insertions, let modifications):
                guard let results = results else { return }
                
                let deleteIndexs = deletes
                    .map { index -> Int? in
                        let listIndex = index - (self.initialTotal - self.messageList.count)
                        
                        self.initialTotal -= 1
                        guard listIndex >= 0, listIndex < self.messageList.count else {
                            return nil
                        }
                        self.messageList.remove(at: listIndex)
                        
                        return listIndex
                    }
                    .compactMap { $0 }
                
                let insertIndexs = insertions
                    .map { index -> Int? in
                        
                        let listIndex = index - (self.initialTotal - self.messageList.count)
                        self.initialTotal += 1
                        
                        guard listIndex >= 0 else {
                            return nil
                        }
                        
                        let messageAbstract = results[index]
                        let model = self.convertModel(model: messageAbstract)
                        self.messageList.insert(newElement: model)
                        
                        return listIndex
                    }
                    .compactMap { $0 }
                
                let modifyIndexs = modifications
                    .map { index -> IndexPath? in
                        
                        let listIndex = index - (self.initialTotal - self.messageList.count)
                        guard listIndex >= 0 else {
                            return nil
                        }
                        
                        let messageAbstract = results[index]
                        var model = self.messageList[listIndex]
                        model.message = messageAbstract
                        return IndexPath(row: 0, section: listIndex)
                    }
                    .compactMap { $0 }
                
                self.batchUpdates.onNext((IndexSet(insertIndexs), modifyIndexs, IndexSet(deleteIndexs), self.hasResend))
                self.hasResend = false
                if UIApplication.isActive {
                    self.updateLastReadDate()
                }
            case .error(let error):
                fatalError("\(error)")
            }
        }
    }
    
    private func addFriendNotification() {
        guard let friend = chat.friends?.firstObject() as? OCTFriend else {
            return
        }
        
        var predicate: NSPredicate
        if let bot = offlineBot.getBot() {
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "uniqueIdentifier == %@", friend.uniqueIdentifier),
                NSPredicate(format: "uniqueIdentifier == %@", bot.uniqueIdentifier),
                ])
        } else {
            predicate = NSPredicate(format: "uniqueIdentifier == %@", friend.uniqueIdentifier)
        }
        
        let results = UserService.shared.toxMananger!.objects.friends(predicate: predicate)
        
        friendToken = results.addNotificationBlock { [weak self] change in
            guard let self = self else { return }
            switch change {
            case .initial:
                break
            case .update:
                self.bindOnline()
            case .error(let error):
                fatalError("\(error)")
            }
        }
    }
    
    private func getPeerAvatar(indexPath: IndexPath) -> UIImage? {
        let message = messageList[indexPath.section]
        if message.message.senderPublicKey.isNotEmpty,
            let image = avatarCache.object(forKey: message.message.senderPublicKey as NSString) {
            return image
        }
        
        let result = UserService.shared.toxMananger!.objects.peers(predicate: NSPredicate(format: "groupNumber == %d AND publicKey == %@", chat.groupNumber, message.message.senderPublicKey))
        let peer = result.firstObject
        if let data = peer?.avatarData, let image = UIImage(data: data) {
            avatarCache.setObject(image, forKey: message.message.senderPublicKey as NSString)
            return image
        } else {
            let temp = AvatarManager.shared.avatarFromString(peer?.nickname ?? "?", diameter: 40)
            avatarCache.setObject(temp, forKey: message.message.senderPublicKey as NSString)
            return temp
        }
    }
    
    private func getName(messageAbstract: OCTMessageAbstract) -> String {
        guard chat.isGroup else {
            return (chat.friends?.firstObject() as! OCTFriend).nickname
        }
        
        let publicKey = messageAbstract.senderPublicKey
        if publicKey.isNotEmpty, let name = nameCache.object(forKey: publicKey as NSString) {
            return name as String
        }
        
        let friend = UserService.shared.toxMananger!.objects.friends(predicate: NSPredicate(format: "publicKey == %@", publicKey)).firstObject
        if let friend = friend {
            nameCache.setObject((friend.nickname as NSString), forKey: publicKey as NSString)
            return friend.nickname
        }
        
        let result = UserService.shared.toxMananger!.objects.peers(predicate: NSPredicate(format: "publicKey == %@", publicKey))
        guard let peer = result.firstObject else {
            return ""
        }
        if let name = peer.nickname {
            nameCache.setObject((name as NSString), forKey: publicKey as NSString)
            return name as String
        } else if let pk = peer.publicKey, pk.isNotEmpty {
            let temp = (pk as NSString).substring(to: 6)
            nameCache.setObject((temp as NSString), forKey: publicKey as NSString)
            return temp
        }
        
        return ""
    }
}

extension ConversationDataSource {
    func addTextMessage(_ text: String) {
        var string = text
        
        if isFindFriendBot(), text.lowercased() == FindFriendBotModel.Command.start.rawValue {
            string = text + " " + UserService.shared.toxMananger!.user.userAddress
        }
        
        chats.sendMessage(to: self.chat, text: string, type: .normal, successBlock: { [unowned self] _ in
            self.updateLastReadDate()
        }, failureBlock: { [weak self] _ in
            guard let self = self,
                let friend = self.chat.friends?.firstObject() as? OCTFriend,
                friend.isConnected == false else {
                    return
            }
            
            if self.offlineBot.beAdded == false
                || (friend.supportOfflineMessage && self.offlineBot.getBot()?.isConnected == false) {
                self.errors.onNext(NSLocalizedString("No offline message bots are available", comment: ""))
            } else if friend.supportOfflineMessage == false, self.offlineBot.getBot()?.isConnected == true {
                self.errors.onNext(NSLocalizedString("Your friend didn’t add an offline messaging bot", comment: ""))
            }
        })
        UserService.shared.toxMananger!.objects.change(chat, enteredText: "")
    }
    
    func addPhotoMessage(_ image: UIImage, isOriginal: Bool = false) {
        let theData = isOriginal ? image.jpegData(compressionQuality: 0.9) : image.compress()
        guard let data = theData else {
            return
        }
        
        let fileName = "\(Date().timeIntervalSince1970 * 1000).jpg"
        sendFile(data: data, fileName: fileName)
    }
    
    func addFileMessage(_ fileUrl: URL) {
        sendFile(url: fileUrl)
    }
    
    func addAudioMessage(_ fileUrl: URL, _ duration: Int) {
        guard let data = try? Data(contentsOf: fileUrl) else {
            return
        }
        
        sendFile(data: data, fileName: buildAudioFileName(duration))
    }
    
    private func sendFile(data: Data, fileName: String) {
        let submanagerFiles = UserService.shared.toxMananger!.files
        submanagerFiles.send(data, withFileName: fileName, to: chat) { [weak self] error in
            guard let self = self, let friend = self.chat.friends?.firstObject() as? OCTFriend else { return }
            if friend.isConnected == false, self.offlineBot.beAdded == true {
                self.errors.onNext(NSLocalizedString("Only text offline messages are supported", comment: ""))
            }
        }
    }
    
    private func sendFile(url: URL) {
        let submanagerFiles = UserService.shared.toxMananger!.files
        submanagerFiles.sendFile(atPath: url.standardizedFileURL.path, moveToUploads: true, to: chat) { [weak self] error in
            guard let self = self, let friend = self.chat.friends?.firstObject() as? OCTFriend else { return }
            if friend.isConnected == false, self.offlineBot.beAdded == true {
                self.errors.onNext(NSLocalizedString("Only text offline messages are supported", comment: ""))
            }
        }
    }
    
    private func buildAudioFileName(_ duration: Int) -> String {
        return "\(UUID().uuidString)_\(duration).\(audioExtension)"
    }
    
    func resendMessage(index: Int) {
        let message = messageList[index]
        guard message.isOutgoing else {
            return
        }
        
        switch message.kind {
        case .text(let text):
            if message.message.messageText?.status == 2 {
                deleteMessage(index: index)
                addTextMessage(text)
            }
        case .photo(let model):
            guard let image = model.image else { return }
            deleteMessage(index: index)
            addPhotoMessage(image)
        case .video(let model):
            guard let url = model.url else {
                return
            }
            
            deleteMessage(index: index)
            addFileMessage(url)
        case .file(let model):
            guard let filePath = model.path else {
                return
            }
            
            let url = URL(fileURLWithPath: filePath)
            deleteMessage(index: index)
            addFileMessage(url)
        case .audio(let model):
            guard let filePath = model.path else {
                return
            }
            
            let url = URL(fileURLWithPath: filePath)
            deleteMessage(index: index)
            addAudioMessage(url, model.duration)
        default:
            return
        }
        
        hasResend = true
    }
    
    func deleteMessage(index: Int) {
        let message = messageList[index]
        UserService.shared.toxMananger!.chats.removeMessages([message.message], withoutNotifying: nil)
    }
    
    func handleFileMessageOperation(index: Int, status: FileTransferProgress) -> Bool {
        let model = messageList[index]
        
        let cancelBlock = {
            try? UserService.shared.toxMananger!.files.cancelFileTransfer(model.message)
        }
        
        if status == .waiting {
            if model.isOutgoing {
                cancelBlock()
            } else {
                UserService.shared.toxMananger!.files.acceptFileTransfer(model.message, failureBlock: nil)
            }
            return true
        }
        
        if case .loading = status {
            cancelBlock()
            return true
        }
        
        return false
    }
}

extension ConversationDataSource {
    func markAllMessageAsRead() {
        UserService.shared.toxMananger!.chats.markChatMessages(asRead: chat)
    }
    
    func updateLastReadDate() {
        if chat.isInvalidated {
            return
        }
        UserService.shared.toxMananger!.objects.change(chat, lastReadDateInterval: Date().timeIntervalSince1970)
    }
    
    func convertModel(model: OCTMessageAbstract) -> MessageModel {
        let fileStorage = UserService.shared.toxMananger!.configuration().fileStorage
        let sender = model.isOutgoing() ? self.sender : Sender(id: model.senderUniqueIdentifier!, displayName: getName(messageAbstract: model))
        return MessageModel(model: model, sender: sender, fileStorage: fileStorage)
    }
}

extension ConversationDataSource: MessagesDataSource {
    
    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int {
        return messageList.count
    }
    
    func currentSender() -> Sender {
        return sender
    }
    
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType {
        return messageList[indexPath.section]
    }
    
    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        return NSAttributedString(string: MessageKitDateFormatter.shared.string(from: message.sentDate), attributes: [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 10), NSAttributedString.Key.foregroundColor: UIColor.darkGray])
    }
    
    func messageTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        let name = message.sender.displayName
        return NSAttributedString(string: name, attributes: [NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .caption1)])
    }
}

extension Results {
    func toList<T>() -> [T] {
        var list = [T]()
        for index in 0..<count {
            let item = self[index] as! T
            list.append(item)
        }
        return list
    }
}
