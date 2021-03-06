//
//  TGModernEncryptedUpdates.m
//  Telegram
//
//  Created by keepcoder on 27.10.14.
//  Copyright (c) 2014 keepcoder. All rights reserved.
//

#import "TGModernEncryptedUpdates.h"
#import "SecretLayer1.h"
#import "SecretLayer17.h"
#import "SecretLayer20.h"
#import "Crypto.h"
#import "SenderHeader.h"
#import "MessagesUtils.h"
#import "SelfDestructionController.h"
@implementation TGModernEncryptedUpdates


-(void)proccessUpdate:(TL_encryptedMessage *)update {
    
    TL_encryptedChat *chat = [[ChatsManager sharedManager] find:[update chat_id]];
    
    EncryptedParams *params = [EncryptedParams findAndCreate:[update chat_id]];
    
    
    if(chat) {
        
        
        long keyId = 0;
        [update .bytes getBytes:&keyId range:NSMakeRange(0, 8)];
      
        
        NSData *key = [params ekey:keyId];
        
        assert(key);
        
        NSData *msg_key = [update.bytes subdataWithRange:NSMakeRange(8, 16)];
        NSData *decrypted = [Crypto encrypt:0 data:[update.bytes subdataWithRange:NSMakeRange(24, update.bytes.length - 24)] auth_key:key msg_key:msg_key encrypt:NO];
        
        int messageLength = 0;
        
        [decrypted getBytes:&messageLength range:NSMakeRange(0, 4)];
        
        decrypted = [decrypted subdataWithRange:NSMakeRange(4, decrypted.length-4)];
        
        
        int layer = MIN_ENCRYPTED_LAYER;
        if (decrypted.length >= 4)
        {
            
            int32_t possibleLayerSignature = 0;
            [decrypted getBytes:&possibleLayerSignature length:4];
            if (possibleLayerSignature == (int32_t)0x1be31789)
            {
                if (decrypted.length >= 4 + 1)
                {
                    uint8_t randomBytesLength = 0;
                    [decrypted getBytes:&randomBytesLength range:NSMakeRange(4, 1)];
                    while ((randomBytesLength + 1) % 4 != 0)
                    {
                        randomBytesLength++;
                    }
                    
                    if (decrypted.length >= 4 + 1 + randomBytesLength + 4 + 4 + 4)
                    {
                        int32_t value = 0;
                        [decrypted getBytes:&value range:NSMakeRange(4 + 1 + randomBytesLength, 4)];
                        layer = value;
                        
                    }
                }
            }
        }
        
        
        layer = MAX(1, layer);
        
        Class DeserializeClass = NSClassFromString([NSString stringWithFormat:@"Secret%d__Environment",layer]);
        
        SEL proccessMethod = NSSelectorFromString([NSString stringWithFormat:@"proccess%dLayer:params:conversation:encryptedMessage:",layer]);
        
        IMP imp = [self methodForSelector:proccessMethod];
        void (*func)(id, SEL, id, EncryptedParams *, TL_conversation *, TL_encryptedMessage *) = (void *)imp;
        func(self, proccessMethod,[DeserializeClass parseObject:decrypted],params,chat.dialog, update);
        
        
        
        
    }
    
}



-(BOOL)proccessServiceMessage:(id)message withLayer:(int)layer params:(EncryptedParams *)params conversation:(TL_conversation *)conversation {
    
    if([message isKindOfClass:convertClass(@"Secret%d_DecryptedMessage_decryptedMessageService", layer)]) {
        
        id action = [message valueForKey:@"action"];
        long random_id = [[message valueForKey:@"random_id"] longValue];
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionNotifyLayer", layer)]) {
            
            int layer = [[action valueForKey:@"layer"] intValue];
            
            if(params.layer != MAX_ENCRYPTED_LAYER && params.layer != layer) {
                [self upgradeLayer:params conversation:conversation];
            }
            
            return YES;
            
        }
        
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionSetMessageTTL", layer)]) {
            
            int ttl_seconds = [[action valueForKey:@"ttl_seconds"] intValue];
            
            
            TL_secretServiceMessage *msg = [TL_secretServiceMessage createWithN_id:[MessageSender getFutureMessageId] flags:TGNOFLAGSMESSAGE from_id:[conversation.encryptedChat peerUser].n_id to_id:[TL_peerSecret createWithChat_id:params.n_id] date:[[MTNetwork instance] getTime] action:[TL_messageActionSetMessageTTL createWithTtl:ttl_seconds] fakeId:[MessageSender getFakeMessageId] randomId:random_id out_seq_no:-1 dstate:DeliveryStateNormal];
            
            
            [MessagesManager addAndUpdateMessage:msg];
            
            params.ttl = ttl_seconds;
            
            
           // Destructor *destructor = [[Destructor alloc] initWithTLL:ttl_seconds max_id:msg.n_id chat_id:params.n_id];
          //  [SelfDestructionController addDestructor:destructor];
            
            return YES;
        }
        
        
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionDeleteMessages", layer)]) {
            
            
            NSArray *random_ids = [action valueForKey:@"random_ids"];
            
            [[Storage manager] deleteMessagesWithRandomIds:random_ids completeHandler:^(BOOL result) {
                
                NSMutableDictionary *update = [[NSMutableDictionary alloc] init];
                
                NSMutableArray *ids = [[NSMutableArray alloc] init];
                
                
                for (NSNumber *msgId in random_ids) {
                    
                    TL_destructMessage *message = [[MessagesManager sharedManager] findWithRandomId:[msgId longValue]];
                    
                    if(message) {
                        [ids addObject:@(message.n_id)];
                    }
                    
                    if(message && message.conversation) {
                        [update setObject:message.conversation forKey:@(message.conversation.peer.peer_id)];
                    }
                    
                }
                
                for (TL_conversation *dialog in update.allValues) {
                    [[DialogsManager sharedManager] updateLastMessageForDialog:dialog];
                }
                
                [Notification perform:MESSAGE_DELETE_EVENT data:@{KEY_MESSAGE_ID_LIST:ids}];
                
            }];
            
            return YES;
        }
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionFlushHistory", layer)]) {
            
            [[Storage manager] deleteMessagesInDialog:conversation completeHandler:^{
                
                [Notification perform:MESSAGE_FLUSH_HISTORY data:@{KEY_DIALOG:conversation}];
                
                [[DialogsManager sharedManager] updateLastMessageForDialog:conversation];
                
            }];
            
            return YES;
        }
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionScreenshotMessages", layer)]) {
            
            TL_secretServiceMessage *msg = [TL_secretServiceMessage createWithN_id:[MessageSender getFutureMessageId] flags:TGNOFLAGSMESSAGE from_id:[conversation.encryptedChat peerUser].n_id to_id:[TL_peerSecret createWithChat_id:params.n_id] date:[[MTNetwork instance] getTime] action:[TL_messageActionEncryptedChat createWithTitle:NSLocalizedString(@"MessageAction.Secret.TookScreenshot", nil)] fakeId:[MessageSender getFakeMessageId] randomId:random_id out_seq_no:-1 dstate:DeliveryStateNormal];
            
            [MessagesManager addAndUpdateMessage:msg];
            
            return YES;
        
        }
        
        if([action isKindOfClass:convertClass(@"Secret%d_DecryptedMessageAction_decryptedMessageActionRequestKey", layer)]) {
            
            
            
        }

        
    }
    
    
    return NO;
}


Class convertClass(NSString *c, int layer) {
    return NSClassFromString([NSString stringWithFormat:c,layer]);
}


-(void)upgradeLayer:(EncryptedParams *)params conversation:(TL_conversation *)conversation {
    params.layer = MAX_ENCRYPTED_LAYER;
    
    [params save];
    
    UpgradeLayerSenderItem *upgradeLayer = [[UpgradeLayerSenderItem alloc] initWithConversation:conversation];
    
    [upgradeLayer send];
}




-(void)proccess1Layer:(Secret1_DecryptedMessage *)message params:(EncryptedParams *)params conversation:(TL_conversation *)conversation  encryptedMessage:(TL_encryptedMessage *)encryptedMessage  {
    
    BOOL isProccessed = [self proccessServiceMessage:message withLayer:1 params:params conversation:conversation];
    
    if(isProccessed)
        return;
    
    if([message isKindOfClass:[Secret1_DecryptedMessage_decryptedMessage class]]) {
        
        Secret1_DecryptedMessage_decryptedMessage *msg = (Secret1_DecryptedMessage_decryptedMessage *) message;
        
        TLMessageMedia *media = [self media:msg.media layer:1 file:encryptedMessage.file];
        
        int ttl = params.ttl;
        
        TL_localMessage *localMessage = [TL_destructMessage createWithN_id:[MessageSender getFutureMessageId] flags:TGUNREADMESSAGE from_id:[conversation.encryptedChat peerUser].n_id to_id:[TL_peerSecret createWithChat_id:params.n_id] date:encryptedMessage.date message:msg.message media:media destruction_time:0 randomId:[msg.random_id intValue] fakeId:[MessageSender getFakeMessageId] ttl_seconds:ttl out_seq_no:-1 dstate:DeliveryStateNormal];
        
        [MessagesManager addAndUpdateMessage:localMessage];
        
    }
      
}

-(void)proccess17Layer:(Secret17_DecryptedMessage *)message params:(EncryptedParams *)params conversation:(TL_conversation *)conversation  encryptedMessage:(TL_encryptedMessage *)encryptedMessage  {
    
    Secret17_DecryptedMessageLayer *layerMessage = (Secret17_DecryptedMessageLayer *)message;
    
    
    NSLog(@"local = %d, remote = %d",params.in_seq_no * 2 + [params in_x],[layerMessage.out_seq_no intValue]);
    
    if([layerMessage.out_seq_no intValue] != 0 && [layerMessage.out_seq_no intValue] < params.in_seq_no * 2 + [params in_x] )
        return;
    
    
    id media = [TL_messageMediaEmpty create];
    
    
    
    
     if([layerMessage.message isKindOfClass:[Secret17_DecryptedMessage_decryptedMessage class]]) {
         media = [self media:[layerMessage.message valueForKey:@"media"] layer:17 file:encryptedMessage.file];
     }
    
    TGSecretInAction *action = [[TGSecretInAction alloc] initWithActionId:arc4random() chat_id:params.n_id messageData:[Secret17__Environment serializeObject:layerMessage.message]  fileData:[TLClassStore serialize:media] date:encryptedMessage.date in_seq_no:[layerMessage.out_seq_no intValue] layer:17];
    
    
    [[Storage manager] insertSecretInAction:action];
    
    [self dequeueInActions:params conversation:conversation];
    
}


-(void)proccess20Layer:(Secret20_DecryptedMessage *)message params:(EncryptedParams *)params conversation:(TL_conversation *)conversation  encryptedMessage:(TL_encryptedMessage *)encryptedMessage  {
    
    Secret20_DecryptedMessageLayer *layerMessage = (Secret20_DecryptedMessageLayer *)message;
    
    
    NSLog(@"local = %d, remote = %d",params.in_seq_no * 2 + [params in_x],[layerMessage.out_seq_no intValue]);
    
    if([layerMessage.out_seq_no intValue] != 0 && [layerMessage.out_seq_no intValue] < params.in_seq_no * 2 + [params in_x] )
        return;
    
    
    id media = [TL_messageMediaEmpty create];
    
    
    
    if([layerMessage.message isKindOfClass:[Secret20_DecryptedMessage_decryptedMessage class]]) {
        media = [self media:[layerMessage.message valueForKey:@"media"] layer:20 file:encryptedMessage.file];
    }
    
    TGSecretInAction *action = [[TGSecretInAction alloc] initWithActionId:arc4random() chat_id:params.n_id messageData:[Secret20__Environment serializeObject:layerMessage.message]  fileData:[TLClassStore serialize:media] date:encryptedMessage.date in_seq_no:[layerMessage.out_seq_no intValue] layer:20];
    
    
    [[Storage manager] insertSecretInAction:action];
    
    [self dequeueInActions:params conversation:conversation];
    
}


-(void)dequeueInActions:(EncryptedParams *)params conversation:(TL_conversation *)conversation {
    
    [[Storage manager] selectSecretInActions:params.n_id completeHandler:^(NSArray *list) {
        
        [ASQueue dispatchOnStageQueue:^{
            
            
            [list enumerateObjectsUsingBlock:^(TGSecretInAction *action, NSUInteger idx, BOOL *stop) {
                
                if(action.in_seq_no == params.in_seq_no * 2 + [params in_x]) {
                    
                    
                    id messageObject = [NSClassFromString([NSString stringWithFormat:@"Secret%d__Environment",action.layer]) parseObject:action.messageData];
                    
                    id media = [TLClassStore deserialize:action.fileData];
                    
                    BOOL isProccessed = [self proccessServiceMessage:messageObject withLayer:action.layer params:params conversation:conversation];
                    
                    
                    if(!isProccessed && [messageObject isKindOfClass:NSClassFromString([NSString stringWithFormat:@"Secret%d_DecryptedMessage_decryptedMessage",action.layer])]) {
                        
                        
                        TL_destructMessage *localMessage = [TL_destructMessage createWithN_id:[MessageSender getFutureMessageId] flags:TGUNREADMESSAGE from_id:[conversation.encryptedChat peerUser].n_id to_id:[TL_peerSecret createWithChat_id:params.n_id] date:action.date message:[messageObject valueForKey:@"message"] media:media destruction_time:0 randomId:[[messageObject valueForKey:@"random_id"] longValue] fakeId:[MessageSender getFakeMessageId] ttl_seconds:[[messageObject valueForKey:@"ttl"] intValue] out_seq_no:-1 dstate:DeliveryStateNormal];
                        
                        [MessagesManager addAndUpdateMessage:localMessage];
                        
                    }
                    
                    params.in_seq_no++;
                    
                    [[Storage manager] removeSecretInAction:action];
                    
                    
                }
                
                
            }];
            
        }];
        
        
    }];
    
}


-(TLMessageMedia *)media:(id)media layer:(int)layer file:(TLEncryptedFile *)file {
    
    
    if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaEmpty", layer)])
        return [TL_messageMediaEmpty create];
    
    
    if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaGeoPoint", layer)]) {
        return [TL_messageMediaGeo createWithGeo:[TL_geoPoint createWithN_long:[[media valueForKey:@"plong"] doubleValue] lat:[[media valueForKey:@"lat"] doubleValue]]];
    }
    
    if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaContact", layer)]) {
        
        return [TL_messageMediaContact createWithPhone_number:[media valueForKey:@"phone_number"] first_name:[media valueForKey:@"first_name"] last_name:[media valueForKey:@"last_name"] user_id:[[media valueForKey:@"user_id"] intValue]];
    }
    
    
    
    // ------------------ start save file key -----------------
    
    
    TL_fileLocation *location = [TL_fileLocation createWithDc_id:[file dc_id] volume_id:[file n_id] local_id:-1 secret:[file access_hash]];
    
    if(![media valueForKey:@"key"] || ![media valueForKey:@"iv"]) {
        DLog(@"drop encrypted media class ====== %@ ======",NSStringFromClass([media class]));
        return [TL_messageMediaEmpty create];
    }
    
    [[Storage yap] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [transaction setObject:@{@"key": [media valueForKey:@"key"], @"iv":[media valueForKey:@"iv"]} forKey:[NSString stringWithFormat:@"%lu",file.n_id] inCollection:ENCRYPTED_IMAGE_COLLECTION];
    }];
    
    // ------------------ end save file key -----------------
    
    
    
    if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaPhoto", layer)]) {
        
        TL_photoCachedSize *s0 = [TL_photoCachedSize createWithType:@"jpeg" location:location w:[[media valueForKey:@"thumb_w"] intValue] h:[[media valueForKey:@"thumb_h"] intValue] bytes:[media valueForKey:@"thumb"]];
        TL_photoSize *s1 = [TL_photoSize createWithType:@"jpeg" location:location w:[[media valueForKey:@"w"] intValue] h:[[media valueForKey:@"h"] intValue] size:[[media valueForKey:@"size"] intValue]];
        
        NSMutableArray *size =  [NSMutableArray arrayWithObjects:s0,s1,nil];
        
        return [TL_messageMediaPhoto createWithPhoto:[TL_photo createWithN_id:[file n_id] access_hash:[file access_hash] user_id:0 date:[[MTNetwork instance] getTime] caption:@"" geo:[TL_geoPointEmpty create] sizes:size]];
        
    } else if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaDocument", layer)]) {
        
        TLPhotoSize *size = [TL_photoSizeEmpty createWithType:@"jpeg"];
        
        
        if( ((NSData *)[media valueForKey:@"thumb"]).length > 0) {
            size = [TL_photoCachedSize createWithType:@"x" location:[TL_fileLocation createWithDc_id:0 volume_id:0 local_id:0 secret:0] w:[[media valueForKey:@"thumb_w"] intValue] h:[[media valueForKey:@"thumb_h"] intValue] bytes:[media valueForKey:@"thumb"]];
        }
        
        return [TL_messageMediaDocument createWithDocument:[TL_document createWithN_id:file.n_id access_hash:file.access_hash date:[[MTNetwork instance] getTime] mime_type:[media valueForKey:@"mime_type"] size:file.size thumb:size dc_id:[file dc_id] attributes:[@[[TL_documentAttributeFilename createWithFile_name:[media valueForKey:@"file_name"]]] mutableCopy]]];
        
        
    } else if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaVideo", layer)]) {
        
        NSString *mime_type = [media respondsToSelector:@selector(mime_type)] ? [media valueForKey:@"mime_type"] : @"mp4";
        
        return [TL_messageMediaVideo createWithVideo:[TL_video createWithN_id:file.n_id access_hash:file.access_hash user_id:0 date:[[MTNetwork instance] getTime] caption:@"" duration:[[media valueForKey:@"duration"] intValue] mime_type:mime_type size:file.size thumb:[TL_photoCachedSize createWithType:@"jpeg" location:location w:[[media valueForKey:@"thumb_w"] intValue] h:[[media valueForKey:@"thumb_h"] intValue] bytes:[media valueForKey:@"thumb"]] dc_id:[file dc_id] w:[[media valueForKey:@"w"] intValue] h:[[media valueForKey:@"h"] intValue]]];
        
    } else if([media isKindOfClass:convertClass(@"Secret%d_DecryptedMessageMedia_decryptedMessageMediaAudio", layer)]) {
        
        NSString *mime_type = [media respondsToSelector:@selector(mime_type)] ? [media valueForKey:@"mime_type"] : @"ogg";
        
        return [TL_messageMediaAudio createWithAudio:[TL_audio createWithN_id:file.n_id access_hash:file.access_hash user_id:0 date:[[MTNetwork instance] getTime] duration:[[media valueForKey:@"duration"] intValue] mime_type:mime_type size:file.size dc_id:file.dc_id]];
        
    } else {
        alert(@"Unknown secret media", @"");
    }
    
    return [TL_messageMediaEmpty create];
}


@end
