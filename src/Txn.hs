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


type KVKey = String
type KVVal = String
type KVTxnId = (Int, Int) -- (client_id, txn_id)
type KVTime = Integer

-- TODO, with more clients, need txn_id to be (txn_id, client_id) tuples

data KVRequest 
    = GetReq { issuedUTC :: KVTime , reqkey :: KVKey }
    | PutReq { issuedUTC :: KVTime , putkey :: KVKey , putval :: KVVal }
    | DelReq { issuedUTC :: KVTime, delkey :: KVKey }
    deriving (Generic, Show)

data KVResponse
    = KVSuccess { key :: KVKey, val :: Maybe KVVal}
    | KVFailure { errorMsg :: String }
    deriving (Generic, Show)

data KVDecision = DecisionCommit | DecisionAbort
    deriving (Generic, Show, Eq)

data KVVote = VoteReady | VoteAbort
    deriving (Generic, Show, Eq)

data KVMessage = KVRegistration { txn_id :: KVTxnId , pid :: ProcessId }
                | KVResponse {
                  txn_id   :: KVTxnId
                , worker_id :: Int
                , response :: KVResponse
                }
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
                , success  :: Maybe String
               }
               | KVVote {
                  txn_id   :: KVTxnId -- READY or ABORT, sent by worker
                , worker_id :: Int
                , vote     :: KVVote
                , request  :: KVRequest
               }        
  deriving (Generic, Show)

instance Binary KVRequest
instance Binary KVMessage
instance Binary KVResponse
instance Binary KVDecision
instance Binary KVVote

--MICROSECONDS
kV_TIMEOUT_MICRO :: KVTime
kV_TIMEOUT_MICRO = 1000000

