{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Txn
  (
    TxnManager(..),
    beginTxn,
    readTxn,
    writeTxn,
    commitTxn
  ) where

import qualified Data.Map as Map
import Data.Map (Map)
import Control.Concurrent.STM
import Utils
import qualified AppServer

type KVKey = String
type KVVal = String
type KVVersion = Int
type KVOldVersion = Int

-- TxnManager
data TxnManager = TxnManager {
  txnId     :: String,
  readSet   :: TVar (Map KVKey (KVKey, KVVal, KVVersion)),
  writeSet  :: TVar (Map KVKey (KVKey, KVVal, KVOldVersion))
}

beginTxn :: IO TxnManager
beginTxn = do
  r <- newTVarIO Map.empty
  w <- newTVarIO Map.empty
  tId <- genUUID
  return TxnManager { txnId = tId, readSet = r, writeSet = w }


readTxn :: TxnManager -> KVKey -> IO (Maybe KVVal)
readTxn txn@TxnManager{..} key = do
  r <- atomically $ do
    rSet <- readTVar readSet
    case Map.lookup key rSet of
      Just (_, val, ver) ->
        if ver == 0 then return Nothing else return (Just val)
      _ -> return Nothing
  case r of
    Just _ -> return r
    Nothing -> do
      res <- AppServer.doRead key
      case res of
        Just (val, ver) -> do atomically $ updateRSet txn key val ver
                              return (Just val)
        _  -> return Nothing


writeTxn :: TxnManager -> KVKey -> KVVal -> IO ()
writeTxn txn@TxnManager{..} key val = do
  r <- atomically $ do rSet <- readTVar readSet; return (Map.lookup key rSet)
  case r of
    Just (_, _, ver) -> atomically $ updateRWSets txn key val ver
    Nothing -> do
      res <- AppServer.doRead key
      case res of
        Just (_, ver) -> atomically $ updateRWSets txn key val ver
        _             -> atomically $ updateRWSets txn key val 0


updateRSet :: TxnManager -> KVKey -> KVVal -> KVVersion -> STM ()
updateRSet TxnManager{..} key val ver = do
  rSet <- readTVar readSet
  let new_rSet = Map.insert key (key, val, ver) rSet
  writeTVar readSet new_rSet


updateRWSets :: TxnManager -> KVKey -> KVVal -> KVVersion -> STM ()
updateRWSets TxnManager{..} key val ver = do
  rSet <- readTVar readSet
  wSet <- readTVar writeSet
  let new_rSet = Map.insert key (key, val, ver) rSet
      new_wSet = Map.insert key (key, val, ver) wSet
  writeTVar readSet new_rSet
  writeTVar writeSet new_wSet


commitTxn :: TxnManager -> IO Bool
commitTxn txn@TxnManager{..} = do
  wSet <- atomically $ readTVar writeSet
  if (length wSet == 0) then return True
  else AppServer.doCommit txnId (Map.elems wSet)



