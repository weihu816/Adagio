{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE DeriveGeneric #-}

module KVStore
  (
    Server(..)
  , Client(..)
  , RemoteClient(..)
  , LocalClient(..)
  , KVKey, KVVal
  , CName
  , RId
  , ID
  , newLocalClient
  , clientName
  , Message(..)
  , PMessage(..)
  , TxnStatue(..)
  ) where

import Data.Binary
import GHC.Generics (Generic)
import Data.Map (Map)
import Control.Concurrent.STM
import System.IO
import Control.Distributed.Process
  hiding (Message, mask, finally, handleMessage, proxy)
import Data.Typeable


-- Key-Value Storage 
type KVKey = String
type KVVal = String
type RId   = Int
type ID    = String
type TxnId = String
type KVVersion = Int
 

data TxnStatue = TXN_UNDECIDED | TXN_COMMITED | TXN_ABORTED

-- Server
data Server = Server {
  clients   :: TVar (Map String Client),
  proxychan :: TChan (Process ()),                 -- sendRemote
  servers   :: TVar [ProcessId],
  ftable    :: TVar (Map RId (RId, ProcessId)),    -- ftable in the Chord ring
  peers     :: TVar [(RId, ProcessId)],
  ringSize  :: Int,
  ringId    :: RId,                                -- TODO: Should really be unique
  spid      :: ProcessId,
  counter   :: TVar (Int, Int),                     -- largest sequence number proposed and observed
  votes     :: TVar (Map ID (Int, Int)),            -- Sender: uuid => (remain count, max)
  messages  :: TVar (Map ID (Bool, Int, ProcessId, String, CName)), -- Receiver: uuid => (flag, pval, pid, msg)
  mmdb      :: TVar (Map KVKey KVVal),                -- In memory database
  txns      :: TVar (Map TxnId (TxnStatue, Bool, [(KVKey, KVVal, KVVersion)])),  -- isDirty
  txnVotes  :: TVar (Map ID Int)
}

-- Client
type CName = String
data Client = ClientLocal LocalClient | ClientRemote RemoteClient

-- RemoteClient
data RemoteClient = RemoteClient {
  remoteName :: CName,
  clientHome :: ProcessId
}

-- LocalClient
data LocalClient = LocalClient {
  localName      :: CName,
  clientHandle   :: Handle,
  clientKicked   :: TVar (Maybe String),
  clientSendChan :: TChan Message
}

-- Extract client name
clientName :: Client -> CName
clientName (ClientLocal  c) = localName c
clientName (ClientRemote c) = remoteName c

-- Create a new local client
newLocalClient :: CName -> Handle -> STM LocalClient
newLocalClient name h = do
  c <- newTChan
  k <- newTVar Nothing
  return LocalClient {
    localName = name, clientHandle = h, clientSendChan = c, clientKicked = k
  }

-- Message
data Message = Notice String
             | Tell CName String
             | Broadcast CName String
             | Command String
             | DB String
  deriving (Typeable, Generic)
instance Binary Message

-- PMessage
data PMessage
  = MsgServerInfo         Bool RId ProcessId [CName]
  | MsgAppServer          ProcessId
  | MsgSend               CName Message
  | MsgBroadcast          Message
  | MsgKick               CName CName
  | MsgNewClient          CName ProcessId
  | MsgClientDisconnected CName ProcessId
  | MulticastRequest      ProcessId String ID CName
  | MulticastPropose      ProcessId Int ID -- pid propose uuid
  | MulticastDeciscion    ProcessId Int ID -- pid propose uuid
  | SetRequest            KVKey KVVal CName
  | GetRequest            KVKey CName
  | GetResponse           KVKey (Maybe KVVal) 
  | KVRequest             ProcessId TxnId [(KVKey, KVVal, KVVersion)]
  | KVResponse            ProcessId TxnId
  deriving (Typeable, Generic)
instance Binary PMessage

