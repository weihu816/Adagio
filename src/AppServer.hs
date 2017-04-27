{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE OverloadedStrings #-}

module AppServer where

import qualified Data.List as List
import Network hiding (sClose)
import System.IO
import Utils

hostname :: String
hostname = "127.0.0.1"

port :: String
port = "55550"


doRead :: String -> IO (Maybe (String, Int))
doRead key = do
    hdl <- connectTo hostname $ PortNumber (read port :: PortNumber)
    hSetBuffering hdl NoBuffering
    _ <- hGetLine hdl
    clientname <- genUUID
    hPutStrLn hdl clientname
    hPutStrLn hdl $ "/get " ++ key
    str <- hGetLine hdl
    hClose hdl
    putStrLn $ "[DEBUG] doRead: " ++ key ++ " -> " ++ str
    case words str of
        [val, ver] -> return $ Just (val, read ver :: Int)
        _ -> return Nothing


doCommit :: String -> [(String, String, Int)] -> IO Bool
doCommit txnId l = do
    hdl <- connectTo hostname $ PortNumber (read port :: PortNumber)
    hSetBuffering hdl NoBuffering
    _ <- hGetLine hdl
    clientname <- genUUID
    hPutStrLn hdl clientname
    let s = List.intercalate " " $ map (\(x, y, z) -> x++"#"++y++"#"++(show z)) l
    hPutStrLn hdl $ "/commit " ++ txnId ++ " " ++ s
    str <- hGetLine hdl
    hClose hdl
    putStrLn $ "[DEBUG] doCommit: " ++ txnId
    case words str of
        ["OK"] -> return True
        _ -> return False

-- This does not work...
-- doRead2 :: IO ()
-- doRead2 = withSocketsDo $ do
--     addrInfo <- getAddrInfo Nothing (Just clientname) (Just port)
--     let serverAddr = head addrInfo
--     sock <- socket (addrFamily serverAddr) Stream defaultProtocol
--     connect sock (addrAddress serverAddr)
--     send sock $ CEREAL.encode $ VoteReady
--     rMsg <- recv sock 1024
--     let Right x = CEREAL.decode rMsg
--     putStrLn x
--     sClose sock

-- This does not work...
-- doRead :: KVKey -> IO ()
-- doRead key = do
--     backend <- initializeBackend "localhost" port (Worker.rcdata initRemoteTable)
--     node <- newLocalNode backend
--     Node.runProcess node (appserver key backend)

-- appserver :: KVKey -> Backend -> Process ()
-- appserver key backend = do
--     mynode <- getSelfNode
--     peers0 <- liftIO $ findPeers backend 1000000
--     let peers = filter (/= mynode) peers0
--     say ("peers are " ++ show peers)
--     when (null peers) (return ())
--     whereisRemoteAsync (head peers) "dAppServer"
--     m <- expectTimeout 100000 :: Process (Maybe PMessage)
--     case m of
--         Just (MsgAppServer spid) -> do
--             send spid $ GetRequestPid key "appserver"
--             n <- expectTimeout 100000 :: Process (Maybe PMessage)
--             case n of
--                 Just (GetResponse _ (Just x)) -> return ()
--                 _ -> return ()
--         _ -> return ()



