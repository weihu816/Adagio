{-# OPTIONS -Wall -fwarn-tabs -fno-warn-type-defaults  #-}
{-# LANGUAGE TemplateHaskell, DeriveDataTypeable, DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Distributed.Process
import Control.Distributed.Process.Node as Node
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Concurrent.MVar
import Control.Concurrent.STM.TChan
import Control.Monad.STM
import Control.Monad (forever)
import System.Environment
import qualified Worker as Worker
import Control.Concurrent (threadDelay)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
-- import KVStore


mysend :: ProcessId -> String -> Process ()
mysend pid msg = send pid msg

mysend2 :: ProcessId -> (ProcessId, String) -> Process ()
mysend2 pid msg = send pid msg


replyBack :: (ProcessId, String) -> Process ()
replyBack (sender, msg) = send sender msg

logMessage :: String -> Process ()
logMessage msg = say $ "handling " ++ msg

main :: IO()
main = do
    [port] <- getArgs
    -- backend <- initializeBackend "localhost" port (Worker.rcdata initRemoteTable)
    -- node <- newLocalNode backend
    -- Node.runProcess node (appserver backend)

    -- let pmsg = MsgBroadcast (Broadcast "Rex" "Hello")
    Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
    node <- Node.newLocalNode t initRemoteTable
    Node.runProcess node $ do
        echoPid <- spawnLocal $ forever $ receiveWait [match logMessage, match replyBack]
        say "send some messages!"
        self <- getSelfPid
        mysend echoPid "hello"
        mysend2 echoPid (self, "hello")

        m <- expectTimeout 1000000
        case m of
            Nothing  -> say "nothing came back!"
            Just s -> say $ "got " ++ s ++ " back!"
        liftIO $ threadDelay 2000000


-- appserver :: Backend -> Process ()
-- appserver = undefined
