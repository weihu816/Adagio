{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module KVProtocol
  (
    KVRequest(..)
  , KVResponse(..)
  , KVMessage(..)
  , KVVote(..)
  , KVDecision(..)
  , KVKey
  , KVVal
  , KVTxnId
  , KVTime
  , kV_TIMEOUT_MICRO
  , getMessage
  , sendMessage
  , connectToHost
  , listenOnPort
  ) where

import Data.Serialize as CEREAL
import Data.ByteString.Lazy  as B
import Data.ByteString.Char8 as C8
import Debug.Trace
import Control.Exception as E
import Control.Concurrent
import Control.Monad
import Network as NETWORK
import Network.Socket as SOCKET
import Network.Socket.ByteString as SOCKETBSTRING
import Network.BSD as BSD

import GHC.Generics (Generic)

import Data.Time.Clock

import Network
import System.IO as IO
import Rainbow as Rainbow

import qualified Lib

type KVKey = String
type KVVal = String
type KVTime = Integer

type KVTxnId = (Int, Int) -- (client_id, txn_id)


-- TODO, with more clients, need txn_id to be (txn_id, client_id) tuples

data KVRequest
    = GetRequest      KVTime KVKey           -- issue time, key
    | SetRequest      KVTime KVKey KVVal  -- issue time, key, value
    | DeleteRequest   KVTime KVKey         -- issue time, key     
    deriving (Generic, Show)
instance Binary KVRequest

data KVResponse = KVSuccess KVKey Maybe KVVal | KVFailure String  -- error message
    deriving (Generic, Show)
instance Binary KVResponse

data KVDecision = DecisionCommit | DecisionAbort
    deriving (Generic, Show, Eq)
instance Binary KVDecision

data KVVote = VoteReady| VoteAbort
    deriving (Generic, Show, Eq)
instance Binary KVVote

data KVMessage
    = KVRegistration    KVTxnId, HostName, Int-- txnid, hostname, portid
    | KVResponse        KVTxnId, Int, KVResponse -- txn_id, worker_id, response
    | KVRequest {  -- PREPARE
                  txn_id   :: KVTxnId
                , request :: KVRequest
                }
               | KVDecision { -- COMMIT or ABORT, sent by master
                  txn_id   :: KVTxnId
                , decision :: KVDecision
                , request  :: KVRequest
                }
               | KVAck {
                  txn_id   :: KVTxnId --final message, sent by worker
                , ack_id   :: Maybe Int --either the workerId (if sent FROM worker), or Nothing
                , success  :: Maybe B.ByteString
               }
               | KVVote {
                  txn_id   :: KVTxnId -- READY or ABORT, sent by worker
                , worker_id :: Int
                , vote     :: KVVote
                , request  :: KVRequest
               }        
  deriving (Generic, Show)

