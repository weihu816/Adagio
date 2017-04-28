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
    commitTxn,
    fundsTransferTest
  ) where

import qualified Data.Map as Map
import Data.Map (Map)
import Control.Concurrent
import Control.Concurrent.STM
import GHC.Base
import Utils
import qualified AppServer
import Data.Maybe
import Control.Concurrent.Async
import System.Random

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
  rSet <- atomically $ readTVar readSet
  case Map.lookup key rSet of
    Just (_, val, ver) -> return (Just val)
    _ -> do
      res <- AppServer.doRead key
      case res of
        Just (val, ver) -> do atomically $ updateRSet txn key val ver
                              return (Just val)
        _  -> error ("readTxn " ++ key) >> return Nothing

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
commitTxn TxnManager{..} = do
  wSet <- atomically $ readTVar writeSet
  if Map.null wSet then return True
  else AppServer.doCommit txnId (Map.elems wSet)


-- Some txn tests
fundsTransferTest :: Int -> Int -> IO ()
fundsTransferTest startingTotal accounts = do

  lock <- newMVar ()
  putStrLn "Step 1: Initializing accounts"
  txn1 <- beginTxn
  writeTxn txn1 "ROOT" (show startingTotal)
  foldl (\x y -> x >> writeTxn txn1 ("CHILD" ++ show y) "0") (return ()) [0 .. (accounts - 1)]
  res1 <- commitTxn txn1
  assert res1 (return ())
  putStrLn "Transaction 1 completed..."
  putStrLn "==========================================\n"

  putStrLn "Starting step 2 in 2 seconds..."
  threadDelay 2000000

  putStrLn "Step 2: Distributing funds"
  txn2 <- beginTxn
  -- show root
  root' <- readTxn txn2 "ROOT"
  let root = fromJust root'
  putStrLn $ "ROOT = " ++ root
  -- Show children
  foldl (\x y -> x >> do
    child' <- readTxn txn2 ("CHILD" ++ show y)
    let child = fromJust child'
    putStrLn $ "CHILD" ++ show y ++ " = " ++ child)
    (return ()) [0 .. (accounts - 1)]
  let fundsPerChild = (read root :: Int) `quot` accounts
  -- distribute funds to root
  foldl (\x y -> x >> writeTxn txn2 ("CHILD" ++ show y) (show fundsPerChild))
    (return ()) [0 .. (accounts - 1)]
  -- update root
  writeTxn txn2 "ROOT" $ show $ (read root :: Int) - fundsPerChild * accounts
  res2 <- commitTxn txn2
  assert res2 (return ())
  putStrLn "Transaction 2 completed..."
  putStrLn "==========================================\n"

  putStrLn "Starting step 3 in 2 seconds..."
  threadDelay 2000000

  putStrLn "Step 3: Gathering funds"
  jobs <- foldl (\x y -> do
          l <- x
          a <- async (fundTransferTask y lock); return (a:l))
    (return []) [0 .. (accounts - 1)]
  mapM_ wait jobs
  putStrLn "==========================================\n"

  putStrLn "Starting step 4 in 2 seconds..."
  threadDelay 2000000

  putStrLn "Step 4: Validating funds"
  txn4 <- beginTxn
  root' <- readTxn txn4 "ROOT"
  let root = fromJust root'
  putStrLn $ "ROOT = " ++ root
  cnt <- foldl (\x y -> do
      c <- x
      child' <- readTxn txn4 ("CHILD" ++ show y)
      let child = fromJust child'
      putStrLn $ "CHILD" ++ show y ++ " = " ++ child
      return (c + read child :: Int)
    ) (return 0) [0 .. (accounts - 1)]
  let total = cnt + read root :: Int
  res4 <- commitTxn txn4
  assert res4 (return ())
  putStrLn "Transaction 4 completed..."
  putStrLn "==========================================\n"
  putStrLn $ "FINAL TOTAL = " ++ (show total)
  return ()

fundTransferTask :: Int -> MVar () -> IO ()
fundTransferTask index lock = do
    sec <- randomRIO (0, 9)
    threadDelay $ 500000 * sec
    txn <- beginTxn
    root' <- readTxn txn "ROOT"
    let root = fromJust root'
    atomicPutStrLn lock (show index ++ "> ROOT = " ++ root)
    child' <- readTxn txn ("CHILD" ++ show index)
    let child = fromJust child'
    atomicPutStrLn lock $ show index ++ "> CHILD" ++ show index ++ " = " ++ child
    writeTxn txn "ROOT" $ show ((read child :: Int) + (read root :: Int))
    writeTxn txn ("CHILD" ++ show index) "0"
    res <- commitTxn txn
    if res then atomicPutStrLn lock $ show index ++ "> Transaction 3 completed by Thread-" ++ show index
    else atomicPutStrLn lock $ show index ++ "> CHILD" ++ show index ++ " aborted <<<<<<<<<<"



